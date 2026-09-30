import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var voiceAnalyzer: VoiceAnalyzer?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            )
        else { return }

        let fm = FileManager.default
        let pending =
            entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(
                Data(
                    "resuming \(pending.count) untranscribed session(s)\n".utf8
                ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                let unnamed = try await transcribe(dir)
                notifyUser(
                    title: "quill — transcript ready",
                    body: dir.lastPathComponent
                        + (unnamed > 0 ? " · \(unnamed) voice(s) to name from the menu" : "")
                )
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        await voiceAnalyzer?.release()
        voiceAnalyzer = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    /// Returns how many of the session's voices are still unnamed.
    private func transcribe(_ dir: URL) async throws -> Int {
        // Both metadata schemas normalize to ordered (file, speaker, offset)
        // inputs — one per segment under v2, one per track under v1. Each
        // segment transcribes independently and shifts onto the session
        // clock, so timing gaps around a capture recovery stay visible.
        let (inputs, captureStatus) = try SessionMeta.readInputs(from: dir)
        let engine = try await preparedEngine()
        let directory = Config.voicesEnabled() ? loadVoiceDirectory(for: dir) : nil
        var voices = SessionVoices()

        // First pass: words, and voices when enabled, for every segment file.
        var tracks: [(input: SessionMeta.TrackInput, words: [TimedWord], analysis: VoiceAnalyzer.Analysis?)] = []
        for input in inputs {
            let audio = dir.appendingPathComponent(input.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing segment \(input.file)")
                continue
            }
            log(dir, "transcribing \(input.file) (\(engine.name))")
            // One bad segment (empty, truncated) shouldn't cost us the rest —
            // log it and keep going.
            let words: [TimedWord]
            do {
                words = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(input.file): \(error)")
                continue
            }
            let analysis = directory == nil ? nil : await analyzeVoices(audio, file: input.file, dir: dir)
            tracks.append((input, words, analysis))
        }

        // Call audio leaking into the mic shows up as extra mic voices that
        // only speak while the other side does; they stay plain "me".
        let remoteSpeech = tracks.filter { $0.input.speaker == TrackKind.system.speaker }
            .flatMap { track in
                (track.analysis?.spans ?? []).map { span in
                    let offset = TimeInterval(track.input.offsetMs) / 1000
                    return (start: span.start + offset, end: span.end + offset)
                }
            }

        var merged: [Transcript.Segment] = []
        for track in tracks {
            var wordVoices: [Int?]?
            if let directory, let analysis = track.analysis {
                let echoes =
                    track.input.speaker == TrackKind.mic.speaker
                    ? VoiceSpan.echoSpeakers(
                        in: analysis.spans, offset: TimeInterval(track.input.offsetMs) / 1000,
                        remoteSpeech: remoteSpeech)
                    : []
                let kept = analysis.speakers.filter { !echoes.contains($0.index) }
                let ids = voices.assign(kept, file: track.input.file, directory: directory)
                log(dir, "\(track.input.file): \(kept.count) voices" + (echoes.isEmpty ? "" : ", \(echoes.count) echo"))
                wordVoices = VoiceSpan.speakers(of: track.words, in: analysis.spans).map { $0.flatMap { ids[$0] } }
            }
            let segments = TranscriptSegment.grouped(track.words, voices: wordVoices)
            merged += Transcript.shifted(segments, speaker: track.input.speaker, offsetMs: track.input.offsetMs)
        }
        merged.sort { $0.start_ms < $1.start_ms }

        var transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        transcript.applyNames(voices)
        try transcript.write(to: dir, captureStatus: captureStatus)
        // After transcript.json: its presence marks the session done, and the
        // naming window only lists sessions that have both files.
        if !voices.voices.isEmpty { try voices.write(to: dir) }
        log(dir, "done — \(merged.count) segments, \(voices.voices.count) voices")
        return voices.unnamedCount
    }

    /// Voice identification is best-effort: a failure (model download while
    /// offline, for instance) leaves the track as plain "me"/"them".
    private func analyzeVoices(_ audio: URL, file: String, dir: URL) async -> VoiceAnalyzer.Analysis? {
        do {
            return try await preparedVoiceAnalyzer().analyze(audio)
        } catch {
            log(dir, "voice identification skipped for \(file): \(error)")
            return nil
        }
    }

    private func loadVoiceDirectory(for dir: URL) -> VoiceDirectory? {
        do {
            return try VoiceDirectory.load(root: dir.deletingLastPathComponent())
        } catch {
            log(dir, "voice identification skipped — unreadable voice directory: \(error)")
            return nil
        }
    }

    private func preparedVoiceAnalyzer() async throws -> VoiceAnalyzer {
        if let voiceAnalyzer { return voiceAnalyzer }
        let analyzer = VoiceAnalyzer()
        try await analyzer.prepare()
        voiceAnalyzer = analyzer
        return analyzer
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(
                Data(
                    "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
                ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized. Internal (not private) so the offset-preserving
/// merge math is unit-testable.
struct Transcript: Codable {
    /// `voice_id` points into the session's voices.json and `voice` is that
    /// voice's name once known; both are absent when voice identification
    /// didn't run, so `speaker` keeps its me/them meaning either way.
    struct Segment: Codable, Equatable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
        var voice_id: Int? = nil
        var voice: String? = nil

        /// Who the readable transcript shows: the name, else a numbered
        /// "voice 2" so unnamed voices stay distinguishable.
        var displayName: String {
            voice ?? voice_id.map { "voice \($0)" } ?? speaker
        }
    }

    let engine: String
    let model: String
    let created_at: String
    var segments: [Segment]

    /// Shift one audio file's transcript segments onto the session clock by
    /// the file's start offset. Segments are never collapsed against a
    /// previous file's end — a capture gap stays visible as a timestamp gap.
    static func shifted(
        _ segments: [TranscriptSegment], speaker: String, offsetMs: Int
    ) -> [Segment] {
        segments.map {
            Segment(
                speaker: speaker,
                start_ms: Int($0.start * 1000) + offsetMs,
                end_ms: Int($0.end * 1000) + offsetMs,
                text: $0.text,
                voice_id: $0.voiceId
            )
        }
    }

    /// Set every segment's `voice` from the session's current voice names.
    mutating func applyNames(_ voices: SessionVoices) {
        let names = Dictionary(uniqueKeysWithValues: voices.voices.map { ($0.id, $0.name) })
        for i in segments.indices {
            segments[i].voice = segments[i].voice_id.flatMap { names[$0] ?? nil }
        }
    }

    static func read(from dir: URL) throws -> Transcript {
        try JSONDecoder().decode(
            Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
    }

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    /// `captureStatus` (v2 sessions only) is persisted in the readable header
    /// so an incomplete recording stays visibly incomplete after the
    /// transient notification disappears.
    func write(to dir: URL, captureStatus: TrackStatus? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent, captureStatus: captureStatus).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    func rendered(title: String, captureStatus: TrackStatus? = nil) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))"]
        if let captureStatus, captureStatus != .complete {
            lines.append("capture: \(captureStatus.rawValue)")
        }
        lines.append("")
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.displayName):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
