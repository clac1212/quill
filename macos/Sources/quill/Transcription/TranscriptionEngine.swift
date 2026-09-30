import Foundation

/// One timed span of recognized speech from a single track, relative to that
/// track's own start. `voiceId` is set on the system track when voice
/// identification ran and attributed the span to a session voice.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    var voiceId: Int? = nil
}

/// One recognized word (or, when the engine has no word timings, the whole
/// utterance) with its timing relative to the track's start.
struct TimedWord: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// A speech-to-text engine quill can run locally. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so quill never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TimedWord]
    func release() async
}

extension TranscriptSegment {
    /// Group words into readable segments: break on sentence-ending
    /// punctuation (parakeet ultra emits punctuation), a silence gap, a hard
    /// length cap so a run-on speaker still wraps, or a change of voice.
    /// `voices`, parallel to `words`, is the voice attributed to each word;
    /// nil when voice identification didn't run on this track.
    static func grouped(_ words: [TimedWord], voices: [Int?]? = nil) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [TimedWord] = []
        var currentVoice: Int?

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(
                TranscriptSegment(
                    start: first.start,
                    end: last.end,
                    text: current.map(\.text).joined(separator: " "),
                    voiceId: currentVoice
                ))
            current = []
        }

        for (i, word) in words.enumerated() {
            let voice = voices?[i]
            if let last = current.last,
                word.start - last.end > 1.0 || voice != currentVoice
            {
                flush()
            }
            currentVoice = voice
            current.append(word)
            let endsSentence =
                word.text.hasSuffix(".")
                || word.text.hasSuffix("?")
                || word.text.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
