import XCTest

@testable import quill

/// Voice identification logic, model-free: word attribution, grouping on voice
/// change, directory matching, and naming that rewrites transcripts across
/// sessions. Embeddings are small hand-built vectors — only their cosine
/// geometry matters here.
final class VoicesTests: XCTestCase {
    private let alice: [Float] = [1, 0, 0, 0]
    private let aliceAgain: [Float] = [0.95, 0.3, 0, 0]  // cosine ≈ 0.95
    private let bob: [Float] = [0, 1, 0, 0]
    private let carol: [Float] = [0, 0, 1, 0]

    private func word(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TimedWord {
        TimedWord(start: start, end: end, text: text)
    }

    // MARK: - Attribution and grouping

    func testWordTakesSpeakerWithMostOverlapAndCarriesAcrossGaps() {
        let spans = [
            VoiceSpan(speaker: 0, start: 0, end: 2.1),
            VoiceSpan(speaker: 1, start: 1.9, end: 4),
        ]
        let words = [
            word(0.2, 0.5, "salut"),
            word(1.8, 2.3, "ça"),  // 0.3 s with speaker 0, 0.4 s with speaker 1
            word(4.2, 4.4, "va"),  // after every span: keeps speaker 1
        ]
        XCTAssertEqual(VoiceSpan.speakers(of: words, in: spans), [0, 1, 1])
    }

    func testGroupingBreaksOnVoiceChange() {
        let words = [word(0, 0.3, "bonjour"), word(0.4, 0.6, "à"), word(0.7, 0.9, "tous")]
        let segments = TranscriptSegment.grouped(words, voices: [1, 1, 2])
        XCTAssertEqual(segments.map(\.text), ["bonjour à", "tous"])
        XCTAssertEqual(segments.map(\.voiceId), [1, 2])
    }

    func testGroupingWithoutVoicesKeepsPunctuationAndGapBreaks() {
        let words = [word(0, 0.3, "oui."), word(0.4, 0.6, "alors"), word(2.0, 2.2, "bon")]
        let segments = TranscriptSegment.grouped(words)
        XCTAssertEqual(segments.map(\.text), ["oui.", "alors", "bon"])
        XCTAssertEqual(segments.map(\.voiceId), [nil, nil, nil])
    }

    func testEmbeddingClipsPreferLongCleanSpans() {
        let spans = [
            VoiceSpan(speaker: 0, start: 0, end: 2),  // short: unused while long spans exist
            VoiceSpan(speaker: 0, start: 10, end: 25),  // clean, capped at 10 s
            VoiceSpan(speaker: 0, start: 30, end: 36),  // overlapped by speaker 1
            VoiceSpan(speaker: 1, start: 35, end: 40),
        ]
        let clips = VoiceSpan.embeddingClips(of: 0, in: spans)
        XCTAssertEqual(clips.map { $0.map(\.start) }, [[10]])
        XCTAssertEqual(clips.map { $0.map(\.end) }, [[20]])
    }

    func testShortTurnSpeakerGetsOneClipOfTurnsEndToEnd() {
        let spans = [
            VoiceSpan(speaker: 0, start: 1.0, end: 1.8),
            VoiceSpan(speaker: 0, start: 3.0, end: 3.1),  // too short to carry a voice
            VoiceSpan(speaker: 0, start: 5.0, end: 6.0),  // overlapped by speaker 1
            VoiceSpan(speaker: 1, start: 5.5, end: 12.0),
            VoiceSpan(speaker: 0, start: 13.0, end: 14.3),
        ]
        let clips = VoiceSpan.embeddingClips(of: 0, in: spans)
        XCTAssertEqual(clips.map { $0.map(\.start) }, [[1.0, 13.0]])
        // 0.8 s + 1.3 s: just over the 2 s floor. One turn less and no clip.
        XCTAssertEqual(VoiceSpan.embeddingClips(of: 0, in: Array(spans.dropLast())).count, 0)
    }

    func testMicSpeakerTalkingOnlyOverRemoteSpeechIsEcho() {
        // Mic file starts 10 s into the session.
        let mic = [
            VoiceSpan(speaker: 0, start: 0, end: 20),  // the user: talks over nobody
            VoiceSpan(speaker: 1, start: 21, end: 25),  // leak: inside remote speech
            VoiceSpan(speaker: 1, start: 30, end: 31),
        ]
        // Two remote speakers overlapping each other (31–36 s and 34–42 s).
        let remote: [(start: TimeInterval, end: TimeInterval)] = [(31, 36), (34, 42)]
        XCTAssertEqual(VoiceSpan.echoSpeakers(in: mic, offset: 10, remoteSpeech: remote), [1])
        // In person there's no call audio: nobody is an echo.
        XCTAssertEqual(VoiceSpan.echoSpeakers(in: mic, offset: 10, remoteSpeech: []), [])
    }

    // MARK: - Matching

    func testDirectoryMatchesAboveThresholdOnly() {
        var directory = VoiceDirectory()
        directory.enroll("Alice", embedding: alice)
        XCTAssertEqual(directory.match(aliceAgain), "Alice")
        XCTAssertNil(directory.match(bob))
    }

    func testEnrollKeepsNewestEmbeddings() {
        var directory = VoiceDirectory()
        for _ in 0..<VoiceDirectory.maxEmbeddingsPerPerson { directory.enroll("Alice", embedding: alice) }
        directory.enroll("Alice", embedding: aliceAgain)
        XCTAssertEqual(directory.people[0].embeddings.count, VoiceDirectory.maxEmbeddingsPerPerson)
        XCTAssertEqual(directory.people[0].embeddings.last, aliceAgain)
    }

    func testAssignReusesSessionVoiceAndNamesKnownPeople() {
        var directory = VoiceDirectory()
        directory.enroll("Bob", embedding: bob)
        var voices = SessionVoices()

        let first = voices.assign(
            [speaker(0, alice), speaker(1, bob)], file: "system.caf", directory: directory)
        // A recovery segment of the same meeting: speaker indices restart.
        let second = voices.assign(
            [speaker(0, bob), speaker(1, aliceAgain), speaker(2, carol)],
            file: "system-002.caf", directory: directory)

        XCTAssertEqual(first, [0: 1, 1: 2])
        XCTAssertEqual(second, [0: 2, 1: 1, 2: 3])
        XCTAssertEqual(voices.voices.map(\.name), [nil, "Bob", nil])
        XCTAssertEqual(voices.voices[2].sample.file, "system-002.caf")
        XCTAssertEqual(voices.unnamedCount, 2)
    }

    // MARK: - Transcript

    func testRenderedTranscriptShowsNamesThenNumberedVoices() {
        var transcript = Transcript(
            engine: "parakeet", model: "test", created_at: "2026-09-29T10:00:00Z",
            segments: [
                Transcript.Segment(speaker: "me", start_ms: 0, end_ms: 1000, text: "salut"),
                Transcript.Segment(speaker: "them", start_ms: 1000, end_ms: 2000, text: "hello", voice_id: 1),
                Transcript.Segment(speaker: "them", start_ms: 2000, end_ms: 3000, text: "coucou", voice_id: 2),
            ])
        transcript.applyNames(SessionVoices(voices: [voice(1, name: "Alice"), voice(2, name: nil)]))
        let md = transcript.rendered(title: "t")
        XCTAssertTrue(md.contains("] me:** salut"))
        XCTAssertTrue(md.contains("] Alice:** hello"))
        XCTAssertTrue(md.contains("] voice 2:** coucou"))
    }

    func testTranscriptWithoutVoicesKeepsOriginalJSONShape() throws {
        let transcript = Transcript(
            engine: "parakeet", model: "test", created_at: "2026-09-29T10:00:00Z",
            segments: [Transcript.Segment(speaker: "them", start_ms: 0, end_ms: 1000, text: "hi")])
        let json = String(decoding: try JSONEncoder().encode(transcript), as: UTF8.self)
        XCTAssertFalse(json.contains("voice"))
    }

    // MARK: - Naming across sessions

    func testNamingRewritesTranscriptAndNamesSamePersonElsewhere() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-voices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let older = try makeSession(root, "2026.09.01-1000", voices: [voice(1, embedding: aliceAgain)])
        let newer = try makeSession(root, "2026.09.29-1000", voices: [voice(1, embedding: alice)])

        XCTAssertEqual(
            VoiceLibrary.sessions(root: root).map(\.lastPathComponent),
            [newer, older].map(\.lastPathComponent))
        XCTAssertEqual(VoiceLibrary.unnamedCount(root: root), 2)

        try VoiceLibrary.setName(" Alice ", voiceId: 1, session: newer, root: root)

        XCTAssertEqual(try VoiceDirectory.load(root: root).names, ["Alice"])
        for dir in [newer, older] {
            XCTAssertEqual(try SessionVoices.read(from: dir)?.voices.first?.name, "Alice")
            XCTAssertEqual(try Transcript.read(from: dir).segments.first?.voice, "Alice")
            let md = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
            XCTAssertTrue(md.contains("] Alice:** hello"))
        }
        XCTAssertEqual(VoiceLibrary.unnamedCount(root: root), 0)
    }

    func testIgnoredVoiceIsNotCountedNorAutoNamed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-voices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ignoredDir = try makeSession(root, "2026.09.01-1000", voices: [voice(1, embedding: aliceAgain)])
        let dir = try makeSession(root, "2026.09.29-1000", voices: [voice(1, embedding: alice)])

        try VoiceLibrary.setIgnored(true, voiceId: 1, session: ignoredDir)
        XCTAssertEqual(VoiceLibrary.unnamedCount(root: root), 1)

        try VoiceLibrary.setName("Alice", voiceId: 1, session: dir, root: root)
        XCTAssertNil(try SessionVoices.read(from: ignoredDir)?.voices.first?.name)
    }

    // MARK: - Fixtures

    private func speaker(_ index: Int, _ embedding: [Float]) -> DiarizedSpeaker {
        DiarizedSpeaker(index: index, embedding: embedding, sampleStart: 1, sampleEnd: 4)
    }

    private func voice(_ id: Int, name: String? = nil, embedding: [Float] = []) -> SessionVoices.Voice {
        SessionVoices.Voice(
            id: id, name: name, ignored: false, embedding: embedding,
            sample: SessionVoices.Sample(file: "system.caf", start_ms: 1000, end_ms: 4000))
    }

    /// A transcribed session folder: v1 meta.json, one "them" segment on
    /// voice 1, and the given voices.
    private func makeSession(_ root: URL, _ name: String, voices: [SessionVoices.Voice]) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"files": {"mic": "mic.caf", "system": "system.caf"}}"#.utf8)
            .write(to: dir.appendingPathComponent("meta.json"))
        try Transcript(
            engine: "parakeet", model: "test", created_at: "2026-09-29T10:00:00Z",
            segments: [Transcript.Segment(speaker: "them", start_ms: 0, end_ms: 1000, text: "hello", voice_id: 1)]
        ).write(to: dir)
        try SessionVoices(voices: voices).write(to: dir)
        return dir
    }
}
