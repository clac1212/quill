import XCTest

@testable import quill

/// Deterministic tests for the pure per-track health reducer. Time is plain
/// integers on the session clock; no audio devices, TCC, or real-time sleeps.
final class CaptureHealthTests: XCTestCase {
    /// Short thresholds so scenarios read in round numbers.
    private let policy: CapturePolicy = {
        var p = CapturePolicy()
        p.startupGraceMs = 5000
        p.staleThresholdMs = 3000
        p.routeDebounceMs = 750
        p.retryDelaysMs = [0, 500, 2000]
        p.stabilityWindowMs = 5000
        p.finalTailToleranceMs = 3000
        p.silenceWarningMs = 15000
        return p
    }()

    private func machine(startMs: Int = 0) -> TrackHealthMachine {
        TrackHealthMachine(kind: .mic, policy: policy, startMs: startMs)
    }

    private func writing(first: Int, last: Int) -> TelemetrySnapshot {
        var t = TelemetrySnapshot()
        t.firstWriteMs = first
        t.lastWriteMs = last
        t.lastBufferEndMs = last
        t.framesWritten = Int64(last - first) * 48
        return t
    }

    // MARK: startup

    func testStartupGraceKeepsStartingWithoutBuffers() {
        var m = machine()
        XCTAssertNil(m.tick(nowMs: 4000, telemetry: TelemetrySnapshot()))
        XCTAssertEqual(m.state, .starting)
    }

    func testFirstBufferMovesStartingToHealthy() {
        var m = machine()
        XCTAssertNil(m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900)))
        XCTAssertEqual(m.state, .healthy)
    }

    func testStartupGraceExpiryTriggersRecovery() {
        var m = machine()
        let cmd = m.tick(nowMs: 6000, telemetry: TelemetrySnapshot())
        XCTAssertEqual(cmd, .restart(attempt: 1, delayMs: 0))
        XCTAssertEqual(m.state, .recovering)
    }

    // MARK: healthy progress and stalls

    func testRecentBufferKeepsHealthy() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        XCTAssertNil(m.tick(nowMs: 3000, telemetry: writing(first: 500, last: 2900)))
        XCTAssertEqual(m.state, .healthy)
    }

    func testStalledCallbackOpensEpisodeExactlyOnce() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        let stalled = writing(first: 500, last: 1000)
        let cmd = m.tick(nowMs: 5000, telemetry: stalled)
        XCTAssertEqual(cmd, .restart(attempt: 1, delayMs: 0))
        XCTAssertEqual(m.interruptions.count, 1)
        XCTAssertEqual(m.interruptions[0].reason, "callback_stalled")
        XCTAssertEqual(m.interruptions[0].detected_offset_ms, 5000)
        // Further ticks while the restart is in flight issue nothing.
        XCTAssertNil(m.tick(nowMs: 6000, telemetry: stalled))
        XCTAssertEqual(m.interruptions.count, 1)
    }

    // MARK: route events

    func testRouteEventAloneDoesNotRotateHealthyTrack() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        m.routeEvent(atMs: 2000)
        XCTAssertEqual(m.state, .suspect)
        // Callbacks continue through the debounce window.
        XCTAssertNil(m.tick(nowMs: 2900, telemetry: writing(first: 500, last: 2800)))
        XCTAssertEqual(m.state, .healthy)
        XCTAssertTrue(m.interruptions.isEmpty)
    }

    func testRouteEventWithStaleCallbacksRecoversAfterDebounce() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        m.routeEvent(atMs: 2000)
        let stalled = writing(first: 500, last: 1000)
        // Inside the debounce window: no action yet.
        XCTAssertNil(m.tick(nowMs: 2500, telemetry: stalled))
        let cmd = m.tick(nowMs: 5000, telemetry: stalled)
        XCTAssertEqual(cmd, .restart(attempt: 1, delayMs: 0))
        XCTAssertEqual(m.interruptions[0].reason, "route_change")
    }

    func testRouteEventBurstCoalesces() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        m.routeEvent(atMs: 2000)
        m.routeEvent(atMs: 2400)
        m.routeEvent(atMs: 2600)
        let stalled = writing(first: 500, last: 1000)
        // Debounce measured from the burst's last event.
        XCTAssertNil(m.tick(nowMs: 3000, telemetry: stalled))
        XCTAssertNotNil(m.tick(nowMs: 4100, telemetry: stalled))
        XCTAssertEqual(m.interruptions.count, 1)
    }

    // MARK: recovery

    func testSuccessfulRecoveryNeedsStabilityWindow() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        _ = m.tick(nowMs: 5000, telemetry: writing(first: 500, last: 1000))
        m.restartSucceeded(atMs: 5100)
        // New segment writing, but stability window not yet elapsed.
        XCTAssertNil(m.tick(nowMs: 8000, telemetry: writing(first: 5300, last: 7900)))
        XCTAssertEqual(m.state, .recovering)
        XCTAssertNil(m.tick(nowMs: 10400, telemetry: writing(first: 5300, last: 10300)))
        XCTAssertEqual(m.state, .healthy)
        XCTAssertTrue(m.didRecover)
        XCTAssertEqual(m.interruptions[0].recovered_offset_ms, 5300)
        XCTAssertEqual(m.interruptions[0].attempts, 1)
    }

    func testFailedRestartsFollowRetryScheduleThenDegrade() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        _ = m.tick(nowMs: 5000, telemetry: writing(first: 500, last: 1000))

        var cmd = m.restartFailed(atMs: 5100, error: "no device")
        XCTAssertEqual(cmd, .restart(attempt: 2, delayMs: 500))
        cmd = m.restartFailed(atMs: 5700, error: "no device")
        XCTAssertEqual(cmd, .restart(attempt: 3, delayMs: 2000))
        cmd = m.restartFailed(atMs: 7800, error: "no device")
        XCTAssertEqual(cmd, .declareDegraded)
        XCTAssertEqual(m.state, .degraded)
        XCTAssertEqual(m.interruptions[0].attempts, 3)
        XCTAssertEqual(m.interruptions[0].error, "no device")
        // Degraded is quiet: repeated ticks issue no further commands.
        XCTAssertNil(m.tick(nowMs: 9000, telemetry: TelemetrySnapshot()))
        XCTAssertNil(m.tick(nowMs: 10000, telemetry: TelemetrySnapshot()))
    }

    func testStallDuringStabilizationConsumesAnotherAttempt() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        _ = m.tick(nowMs: 5000, telemetry: writing(first: 500, last: 1000))
        m.restartSucceeded(atMs: 5100)
        // Replacement segment wrote briefly, then stalled.
        let cmd = m.tick(nowMs: 10000, telemetry: writing(first: 5300, last: 6000))
        XCTAssertEqual(cmd, .restart(attempt: 2, delayMs: 500))
    }

    func testRepeatedIncidentsGetFreshRetryBudget() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        _ = m.tick(nowMs: 5000, telemetry: writing(first: 500, last: 1000))
        m.restartSucceeded(atMs: 5100)
        _ = m.tick(nowMs: 10400, telemetry: writing(first: 5300, last: 10300))
        XCTAssertEqual(m.state, .healthy)

        // Second incident starts at attempt 1 again.
        let cmd = m.tick(nowMs: 15000, telemetry: writing(first: 5300, last: 11000))
        XCTAssertEqual(cmd, .restart(attempt: 1, delayMs: 0))
        XCTAssertEqual(m.interruptions.count, 2)
    }

    // MARK: stop and final status

    func testStopPreventsFurtherCommands() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        m.stopped()
        XCTAssertNil(m.tick(nowMs: 20000, telemetry: TelemetrySnapshot()))
    }

    func testFinalStatusCompleteWithinTailTolerance() {
        var m = machine()
        let t = writing(first: 500, last: 9000)
        _ = m.tick(nowMs: 1000, telemetry: t)
        let status = m.finalize(stopMs: 10000, telemetry: t, sessionLastBufferEndMs: 9000)
        XCTAssertEqual(status, .complete)
    }

    func testFinalStatusIncompleteOnLongTail() {
        var m = machine()
        let t = writing(first: 500, last: 5000)
        _ = m.tick(nowMs: 1000, telemetry: t)
        let status = m.finalize(stopMs: 10000, telemetry: t, sessionLastBufferEndMs: 5000)
        XCTAssertEqual(status, .incomplete)
    }

    func testFinalStatusRecoveredKeepsInterruptionEvidence() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        _ = m.tick(nowMs: 5000, telemetry: writing(first: 500, last: 1000))
        m.restartSucceeded(atMs: 5100)
        let t = writing(first: 5300, last: 11900)
        _ = m.tick(nowMs: 10400, telemetry: t)
        let status = m.finalize(stopMs: 12000, telemetry: t, sessionLastBufferEndMs: 11900)
        XCTAssertEqual(status, .recovered)
        XCTAssertEqual(m.interruptions[0].recovered_offset_ms, 5300)
    }

    func testStopDuringUnstabilizedRecoveryCountsAsRecoveredIfWriting() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        _ = m.tick(nowMs: 5000, telemetry: writing(first: 500, last: 1000))
        m.restartSucceeded(atMs: 5100)
        let t = writing(first: 5300, last: 6900)
        let status = m.finalize(stopMs: 7000, telemetry: t, sessionLastBufferEndMs: 6900)
        XCTAssertEqual(status, .recovered)
    }

    func testDegradedFinalizesIncomplete() {
        var m = machine()
        _ = m.tick(nowMs: 1000, telemetry: writing(first: 500, last: 900))
        _ = m.tick(nowMs: 5000, telemetry: writing(first: 500, last: 1000))
        _ = m.restartFailed(atMs: 5100, error: "x")
        _ = m.restartFailed(atMs: 5700, error: "x")
        _ = m.restartFailed(atMs: 7800, error: "x")
        let status = m.finalize(
            stopMs: 9000,
            telemetry: TelemetrySnapshot(),
            sessionLastBufferEndMs: 1000
        )
        XCTAssertEqual(status, .incomplete)
    }

    // MARK: silence diagnostic

    func testExactSilenceWarnsWithoutChangingTransportState() {
        var m = machine()
        var t = writing(first: 500, last: 900)
        _ = m.tick(nowMs: 1000, telemetry: t)
        t.lastWriteMs = 15900
        t.lastBufferEndMs = 15900
        t.zeroRunMs = 15500
        XCTAssertNil(m.tick(nowMs: 16000, telemetry: t))
        XCTAssertEqual(m.state, .healthy)
        XCTAssertTrue(m.signalWarningActive)
        XCTAssertEqual(m.warnings.count, 1)

        // Signal returns: the warning clears but stays in the record.
        t.zeroRunMs = 0
        t.lastWriteMs = 16900
        XCTAssertNil(m.tick(nowMs: 17000, telemetry: t))
        XCTAssertFalse(m.signalWarningActive)
        XCTAssertEqual(m.warnings.count, 1)
    }
}
