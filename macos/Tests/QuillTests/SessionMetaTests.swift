import XCTest

@testable import quill

/// Schema compatibility: v2 write/read round-trips, and existing v1 sessions
/// produce the same normalized transcription inputs as before.
final class SessionMetaTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent("meta.json"))
    }

    func testV2RoundTripAcrossMultipleSegments() throws {
        let meta = SessionMeta(
            schema_version: 2,
            started: "2026-08-03T19:32:55Z",
            ended: "2026-08-03T20:09:35Z",
            duration_seconds: 2200,
            status: .recovered,
            tracks: [
                SessionMeta.Track(
                    kind: .mic,
                    speaker: "me",
                    status: .recovered,
                    segments: [
                        SessionMeta.Segment(
                            file: "mic.caf", start_offset_ms: 18, end_offset_ms: 1_687_869,
                            frames_written: 81_016_832, sample_rate_hz: 48000, channels: 1
                        ),
                        SessionMeta.Segment(
                            file: "mic-002.caf", start_offset_ms: 1_691_120, end_offset_ms: 2_200_014,
                            frames_written: 24_426_720, sample_rate_hz: 48000, channels: 1
                        ),
                    ],
                    interruptions: [
                        Interruption(
                            detected_offset_ms: 1_690_869, recovered_offset_ms: 1_691_120,
                            reason: "callback_stalled", attempts: 1, error: nil
                        )
                    ],
                    warnings: []
                ),
                SessionMeta.Track(
                    kind: .system,
                    speaker: "them",
                    status: .complete,
                    segments: [
                        SessionMeta.Segment(
                            file: "system.caf", start_offset_ms: 0, end_offset_ms: 2_200_000,
                            frames_written: 105_600_000, sample_rate_hz: 48000, channels: 2
                        )
                    ],
                    interruptions: [],
                    warnings: ["exact digital silence for 520s"]
                ),
            ]
        )
        try meta.write(to: dir)

        let decoded = try JSONDecoder().decode(
            SessionMeta.self,
            from: Data(contentsOf: dir.appendingPathComponent("meta.json"))
        )
        XCTAssertEqual(decoded, meta)

        let (inputs, status) = try SessionMeta.readInputs(from: dir)
        XCTAssertEqual(status, .recovered)
        XCTAssertEqual(
            inputs,
            [
                SessionMeta.TrackInput(file: "mic.caf", speaker: "me", offsetMs: 18),
                SessionMeta.TrackInput(file: "mic-002.caf", speaker: "me", offsetMs: 1_691_120),
                SessionMeta.TrackInput(file: "system.caf", speaker: "them", offsetMs: 0),
            ])
    }

    func testV1SessionNormalizesAsBefore() throws {
        try write(
            """
            {
              "started": "2026-07-30T18:00:00Z",
              "ended": "2026-07-30T18:30:00Z",
              "duration_seconds": 1800,
              "files": {"mic": "mic.caf", "system": "system.caf"},
              "start_offset_ms": {"mic": 42, "system": 0}
            }
            """)
        let (inputs, status) = try SessionMeta.readInputs(from: dir)
        XCTAssertNil(status)
        XCTAssertEqual(
            inputs,
            [
                SessionMeta.TrackInput(file: "mic.caf", speaker: "me", offsetMs: 42),
                SessionMeta.TrackInput(file: "system.caf", speaker: "them", offsetMs: 0),
            ])
    }

    func testV1WithoutOffsetsDefaultsToZero() throws {
        try write(
            """
            {"files": {"mic": "mic.caf"}}
            """)
        let (inputs, _) = try SessionMeta.readInputs(from: dir)
        XCTAssertEqual(
            inputs,
            [
                SessionMeta.TrackInput(file: "mic.caf", speaker: "me", offsetMs: 0)
            ])
    }

    func testUnreadableMetaThrows() throws {
        try write("not json")
        XCTAssertThrowsError(try SessionMeta.readInputs(from: dir))
    }

    func testSegmentFileNaming() {
        XCTAssertEqual(TrackKind.mic.segmentFile(index: 1), "mic.caf")
        XCTAssertEqual(TrackKind.mic.segmentFile(index: 2), "mic-002.caf")
        XCTAssertEqual(TrackKind.system.segmentFile(index: 3), "system-003.caf")
    }
}
