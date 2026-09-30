import Foundation

/// Voice identification on the system track: diarization splits "them" into
/// voices, and a speaker embedding (L2-normalized WeSpeaker vector) per voice
/// is matched against a local directory of voices the user has named.
enum VoiceMath {
    /// Cosine similarity above which two embeddings are the same person.
    /// Measured on two real French meetings: the same person across meetings
    /// scored 0.80–0.94, different people at most 0.45.
    static let matchThreshold: Float = 0.6

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for (x, y) in zip(a, b) {
            dot += x * y
            na += x * x
            nb += y * y
        }
        let norm = (na * nb).squareRoot()
        return norm > 0 ? dot / norm : 0
    }

    /// Normalized mean of several embeddings of the same voice.
    static func centroid(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for e in embeddings {
            for i in sum.indices { sum[i] += e[i] }
        }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? sum.map { $0 / norm } : sum
    }
}

/// One diarized span of a file-local speaker, in seconds relative to the
/// start of that audio file.
struct VoiceSpan: Sendable, Equatable {
    let speaker: Int
    let start: TimeInterval
    let end: TimeInterval
}

extension VoiceSpan {
    /// The file-local speaker of each word: the span that overlaps it most.
    /// A word no span covers (diarization boundaries lag a little) keeps the
    /// previous word's speaker, so a sentence isn't split on a boundary.
    static func speakers(of words: [TimedWord], in spans: [VoiceSpan]) -> [Int?] {
        var previous: Int?
        return words.map { word in
            var best: (speaker: Int, overlap: TimeInterval)?
            for span in spans where span.end > word.start && span.start < word.end {
                let overlap = min(span.end, word.end) - max(span.start, word.start)
                if overlap > (best?.overlap ?? 0) { best = (span.speaker, overlap) }
            }
            if let best { previous = best.speaker }
            return best?.speaker ?? previous
        }
    }

    /// Mic speakers that are really call audio leaking into the mic: nearly
    /// all their speech falls while the other side is talking. On a real
    /// call that leak measured > 98 % overlap; the user's own voice ~7 %.
    /// `offset` shifts these file-relative spans onto the session clock that
    /// `remoteSpeech` uses.
    static func echoSpeakers(
        in spans: [VoiceSpan], offset: TimeInterval,
        remoteSpeech: [(start: TimeInterval, end: TimeInterval)], threshold: Double = 0.9
    ) -> Set<Int> {
        // Remote spans of different speakers overlap; merge them so shared
        // time isn't counted twice.
        var remote: [(start: TimeInterval, end: TimeInterval)] = []
        for r in remoteSpeech.sorted(by: { $0.start < $1.start }) {
            if let last = remote.last, r.start <= last.end {
                remote[remote.count - 1].end = max(last.end, r.end)
            } else {
                remote.append(r)
            }
        }
        var speech: [Int: (total: TimeInterval, overlapped: TimeInterval)] = [:]
        for span in spans {
            let start = span.start + offset, end = span.end + offset
            let overlapped = remote.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
            let current = speech[span.speaker] ?? (0, 0)
            speech[span.speaker] = (current.total + end - start, current.overlapped + overlapped)
        }
        return Set(speech.filter { $0.value.total > 0 && $0.value.overlapped / $0.value.total > threshold }.keys)
    }

    typealias Piece = (start: TimeInterval, end: TimeInterval)

    /// Audio of `speaker` to embed, as clips of one or more pieces: spans
    /// long enough to carry a voice, with nobody else talking over them,
    /// spread across the file, capped at `maxLength` seconds each.
    ///
    /// A speaker who only ever replies in short turns ("yes", "why?") gets
    /// a single clip of those turns end to end instead. It separates them
    /// from the others in the session, but is too thin to recognize them in
    /// another meeting: 3.4 s of fragments scored 0.35 against the same
    /// person's voice, below the match threshold.
    static func embeddingClips(
        of speaker: Int, in spans: [VoiceSpan],
        minLength: TimeInterval = 3, maxLength: TimeInterval = 10, maxCount: Int = 15,
        minPiece: TimeInterval = 0.3, minShortTotal: TimeInterval = 2
    ) -> [[Piece]] {
        let others = spans.filter { $0.speaker != speaker }
        let clean = spans.filter { span in
            span.speaker == speaker
                && !others.contains { min(span.end, $0.end) > max(span.start, $0.start) }
        }
        let long = clean.filter { $0.end - $0.start >= minLength }
        if !long.isEmpty {
            let n = min(maxCount, long.count)
            return (0..<n).map {
                let span = long[$0 * long.count / n]
                return [(span.start, min(span.end, span.start + maxLength))]
            }
        }
        var pieces: [Piece] = []
        var total: TimeInterval = 0
        for span in clean where span.end - span.start >= minPiece && total < maxLength {
            let end = min(span.end, span.start + maxLength - total)
            pieces.append((span.start, end))
            total += end - span.start
        }
        return total >= minShortTotal ? [pieces] : []
    }
}

/// One file-local speaker found by diarization, with its embedding and a
/// short clean excerpt to play back when naming it.
struct DiarizedSpeaker: Sendable {
    let index: Int
    let embedding: [Float]
    let sampleStart: TimeInterval
    let sampleEnd: TimeInterval
}

/// Voices the user has named, shared across sessions at
/// `<recordings root>/.voices/voices.json`. Each person keeps several
/// embeddings (one per naming), since a voice sounds different from one
/// call setup to the next.
struct VoiceDirectory: Codable, Equatable {
    struct Person: Codable, Equatable {
        var name: String
        var embeddings: [[Float]]
    }

    var people: [Person] = []

    /// Oldest embeddings drop out past this, so the file stays small.
    static let maxEmbeddingsPerPerson = 20

    static func url(root: URL) -> URL {
        root.appendingPathComponent(".voices/voices.json")
    }

    static func load(root: URL) throws -> VoiceDirectory {
        let url = url(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return VoiceDirectory() }
        return try JSONDecoder().decode(VoiceDirectory.self, from: Data(contentsOf: url))
    }

    func save(root: URL) throws {
        let url = Self.url(root: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    var names: [String] { people.map(\.name).sorted() }

    /// The named person whose closest embedding clears the threshold.
    func match(_ embedding: [Float]) -> String? {
        var best: (name: String, score: Float)?
        for person in people {
            for e in person.embeddings {
                let score = VoiceMath.cosine(e, embedding)
                if score >= VoiceMath.matchThreshold, score > (best?.score ?? -1) {
                    best = (person.name, score)
                }
            }
        }
        return best?.name
    }

    mutating func enroll(_ name: String, embedding: [Float]) {
        if let i = people.firstIndex(where: { $0.name == name }) {
            people[i].embeddings.append(embedding)
            people[i].embeddings = Array(people[i].embeddings.suffix(Self.maxEmbeddingsPerPerson))
        } else {
            people.append(Person(name: name, embeddings: [embedding]))
        }
    }
}

/// The voices of one session's system track, at `<session>/voices.json`.
/// Transcript segments point at them by `voice_id`. Property names are the
/// JSON schema.
struct SessionVoices: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var file: String
        var start_ms: Int
        var end_ms: Int
    }

    struct Voice: Codable, Equatable {
        var id: Int
        var name: String?
        var ignored: Bool
        var embedding: [Float]
        var sample: Sample
    }

    var voices: [Voice] = []

    static let fileName = "voices.json"

    /// Nil when the session has no voices file (voice identification off, or
    /// recorded before it existed).
    static func read(from dir: URL) throws -> SessionVoices? {
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SessionVoices.self, from: Data(contentsOf: url))
    }

    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    var unnamedCount: Int { voices.filter { $0.name == nil && !$0.ignored }.count }

    /// Map one audio file's diarized speakers onto session voices, returning
    /// file-local speaker index → voice id. A speaker matching a voice already
    /// in the session (the same meeting split by a capture recovery) reuses
    /// it; otherwise it becomes a new voice, named when the directory knows it.
    mutating func assign(
        _ speakers: [DiarizedSpeaker], file: String, directory: VoiceDirectory
    ) -> [Int: Int] {
        var mapping: [Int: Int] = [:]
        for speaker in speakers {
            if let existing = voices.first(where: {
                VoiceMath.cosine($0.embedding, speaker.embedding) >= VoiceMath.matchThreshold
            }) {
                mapping[speaker.index] = existing.id
                continue
            }
            let id = (voices.map(\.id).max() ?? 0) + 1
            voices.append(
                Voice(
                    id: id,
                    name: directory.match(speaker.embedding),
                    ignored: false,
                    embedding: speaker.embedding,
                    sample: Sample(
                        file: file,
                        start_ms: Int(speaker.sampleStart * 1000),
                        end_ms: Int(speaker.sampleEnd * 1000)
                    )
                ))
            mapping[speaker.index] = id
        }
        return mapping
    }
}
