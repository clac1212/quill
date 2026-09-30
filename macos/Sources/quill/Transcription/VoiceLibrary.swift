import Foundation

/// Naming voices after the fact, from the menu. Naming a voice enrolls its
/// embedding in the voice directory, rewrites that session's transcript, and
/// names the same person wherever they are still unnamed in other sessions —
/// so each name given makes every past and future meeting more complete.
enum VoiceLibrary {
    /// Sessions whose system track was split into voices, newest first.
    static func sessions(root: URL) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return
            entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent(SessionVoices.fileName).path)
                    && fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Unnamed, non-ignored voices across all sessions — the menu's badge.
    static func unnamedCount(root: URL) -> Int {
        sessions(root: root).reduce(0) { total, dir in
            total + ((try? SessionVoices.read(from: dir))?.unnamedCount ?? 0)
        }
    }

    /// Give a session voice a name, or clear it with nil. A new name is
    /// enrolled and propagated to other sessions' unnamed voices.
    static func setName(_ name: String?, voiceId: Int, session dir: URL, root: URL) throws {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = (name?.isEmpty ?? true) ? nil : name
        var voices = try required(dir)
        guard let i = voices.voices.firstIndex(where: { $0.id == voiceId }) else { return }
        voices.voices[i].name = cleaned
        voices.voices[i].ignored = false
        try save(voices, to: dir)

        guard let cleaned else { return }
        var directory = try VoiceDirectory.load(root: root)
        directory.enroll(cleaned, embedding: voices.voices[i].embedding)
        try directory.save(root: root)
        try nameUnnamedVoices(root: root, directory: directory)
    }

    /// Stop asking about a voice (noise, a one-off guest) without naming it.
    static func setIgnored(_ ignored: Bool, voiceId: Int, session dir: URL) throws {
        var voices = try required(dir)
        guard let i = voices.voices.firstIndex(where: { $0.id == voiceId }) else { return }
        voices.voices[i].ignored = ignored
        try voices.write(to: dir)
    }

    /// Match every unnamed voice in every session against the directory.
    /// Ignored voices are left alone — the user said they don't care.
    static func nameUnnamedVoices(root: URL, directory: VoiceDirectory) throws {
        for dir in sessions(root: root) {
            guard var voices = try SessionVoices.read(from: dir) else { continue }
            var changed = false
            for i in voices.voices.indices where voices.voices[i].name == nil && !voices.voices[i].ignored {
                if let name = directory.match(voices.voices[i].embedding) {
                    voices.voices[i].name = name
                    changed = true
                }
            }
            if changed { try save(voices, to: dir) }
        }
    }

    // MARK: -

    /// `sessions(root:)` only lists folders that have a voices file, so a
    /// missing one here means the folder was edited underneath us.
    private static func required(_ dir: URL) throws -> SessionVoices {
        guard let voices = try SessionVoices.read(from: dir) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: dir.path])
        }
        return voices
    }

    /// Persist voices and re-render the transcript with the new names.
    private static func save(_ voices: SessionVoices, to dir: URL) throws {
        try voices.write(to: dir)
        var transcript = try Transcript.read(from: dir)
        transcript.applyNames(voices)
        try transcript.write(to: dir, captureStatus: try SessionMeta.readInputs(from: dir).captureStatus)
    }
}
