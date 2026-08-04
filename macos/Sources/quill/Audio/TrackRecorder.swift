import AVFoundation
import Foundation

/// Health events a recorder reports to the session. Events accelerate
/// detection; the watchdog's telemetry poll remains the authoritative
/// fallback when the OS emits no useful notification.
enum RecorderEvent: Sendable {
    /// A route/config notification affecting this track — suspect, debounced.
    case routeChanged
    /// The capture transport stopped (engine no longer running) — immediate
    /// suspect.
    case transportStopped
    /// A buffer write failed.
    case writeFailed(String)
    /// Mic only: the voice-processing graph delivered its first second as
    /// exact silence. The session rotates to a raw-capture segment; this is a
    /// warning, not an interruption.
    case voiceProcessingSilent
}

/// Result of one finished segment, built from the recorder's telemetry when
/// the segment stops. Offsets are session-clock milliseconds.
struct SegmentStats: Sendable {
    var file: String
    var firstWriteMs: Int?
    var lastBufferEndMs: Int?
    var framesWritten: Int64
    var sampleRateHz: Int
    var channels: Int
}

/// The operations `RecordingSession` needs from a capture path. One start/stop
/// pair is one segment; recovery stops the recorder and starts it again on the
/// next numbered file. Concrete recorders serialize graph/tap construction and
/// teardown on their own control queue so recovery never blocks the main actor
/// on Core Audio, and the real-time callback only writes its own generation's
/// immutable file. Fakes implement this for deterministic session tests.
protocol TrackRecorder: AnyObject {
    var kind: TrackKind { get }

    /// Begin a new segment writing to `url`. `onEvent` may be called from any
    /// queue; the session hops it to the main actor.
    func start(url: URL, clock: SessionClock, onEvent: @escaping @Sendable (RecorderEvent) -> Void) throws

    /// Stop the current segment and return its stats, or nil if no segment
    /// was active. Bounded: a wedged Core Audio teardown must not hang the
    /// caller indefinitely.
    func stop() -> SegmentStats?

    /// Current segment's callback telemetry, for the watchdog.
    func telemetry() -> TelemetrySnapshot
}

/// A boolean shared between an audio callback and a control queue.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }
}

/// One segment's file plus its telemetry, bound together for the lifetime of
/// that segment. The real-time callback captures this object — never the
/// recorder — so a callback from a torn-down generation can only touch its
/// own, already-invalidated file and can never write into a later segment.
final class SegmentFile: @unchecked Sendable {
    let fileName: String
    let sampleRateHz: Int
    let channels: Int
    let telemetry = TrackTelemetry()

    private let lock = NSLock()
    private let clock: SessionClock
    private var file: AVAudioFile?

    init(file: AVAudioFile, fileName: String, sampleRateHz: Int, channels: Int, clock: SessionClock) {
        self.file = file
        self.fileName = fileName
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.clock = clock
    }

    /// Write one buffer and update telemetry on success. `hostTime` is the
    /// buffer's capture timestamp when the driver provided a valid one.
    /// Returns the error message on failure, nil on success or after
    /// invalidation (a stale callback is not an error).
    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0, buffer.format.sampleRate > 0 else { return nil }
        do {
            try file.write(from: buffer)
        } catch {
            let message = "\(error)"
            telemetry.recordError(message)
            return message
        }
        let durationMs = frames * 1000 / Int(buffer.format.sampleRate)
        let startMs = hostTime.map { clock.millis(atHostTime: $0) } ?? max(0, clock.nowMs() - durationMs)
        telemetry.recordWrite(
            nowMs: clock.nowMs(),
            bufferEndMs: startMs + durationMs,
            frames: frames,
            durationMs: durationMs,
            allZero: Self.isAllZero(buffer)
        )
        return nil
    }

    /// Invalidate and release the file (CAF needs no finalization pass), then
    /// return the segment's final telemetry. After this returns, no callback
    /// can touch the file.
    func finish() -> TelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        return telemetry.snapshot()
    }

    /// Final stats for this segment, from its telemetry.
    func stats() -> SegmentStats {
        let snap = telemetry.snapshot()
        return SegmentStats(
            file: fileName,
            firstWriteMs: snap.firstWriteMs,
            lastBufferEndMs: snap.lastBufferEndMs,
            framesWritten: snap.framesWritten,
            sampleRateHz: sampleRateHz,
            channels: channels
        )
    }

    /// Exact-zero check for the silence diagnostic. Early-exits on the first
    /// non-zero sample, so voiced audio costs almost nothing.
    private static func isAllZero(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        let frames = Int(buffer.frameLength)
        // Interleaved buffers expose one pointer covering every channel.
        let planes = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samplesPerPlane =
            buffer.format.isInterleaved
            ? frames * Int(buffer.format.channelCount)
            : frames
        for plane in 0..<planes {
            let data = channels[plane]
            for i in 0..<samplesPerPlane where data[i] != 0 {
                return false
            }
        }
        return true
    }
}
