import FluidAudio
import Foundation

/// Splits one system-track file into voices (Nemotron 3 Diarization, offline
/// preset — up to 8 speakers) and computes a WeSpeaker embedding per voice.
/// Both models download once into FluidAudio's cache and are released with
/// the transcription engine when the queue drains.
actor VoiceAnalyzer {
    struct Analysis: Sendable {
        let spans: [VoiceSpan]
        /// Speakers with enough clean speech for an embedding. The others
        /// still own spans, but stay anonymous "them".
        let speakers: [DiarizedSpeaker]
    }

    enum AnalyzerError: Error, CustomStringConvertible {
        case notPrepared

        var description: String { "voice analyzer used before prepare()" }
    }

    private var diarizer: Nemotron3Diarizer?
    private var embedder: DiarizerManager?

    func prepare() async throws {
        guard diarizer == nil else { return }
        let config = Nemotron3Config.offline
        let models = try await Nemotron3Models.loadFromHuggingFace(config: config)
        let embedder = DiarizerManager()
        embedder.initialize(models: try await DiarizerModels.downloadIfNeeded())
        self.diarizer = Nemotron3Diarizer(config: config, models: models)
        self.embedder = embedder
    }

    func analyze(_ audio: URL) throws -> Analysis {
        guard let diarizer, let embedder else { throw AnalyzerError.notPrepared }
        let samples = try AudioConverter().resampleAudioFile(audio)
        let (probabilities, frameCount) = try diarizer.processComplete(samples)
        let spans = Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frameCount)
            .map {
                VoiceSpan(
                    speaker: $0.speakerIndex,
                    start: TimeInterval($0.startSeconds),
                    end: TimeInterval($0.endSeconds)
                )
            }

        let sampleRate = 16_000.0
        var speakers: [DiarizedSpeaker] = []
        for index in Set(spans.map(\.speaker)).sorted() {
            let clips = VoiceSpan.embeddingClips(of: index, in: spans)
            guard !clips.isEmpty else { continue }
            let embeddings = try clips.map { clip in
                let audio = clip.flatMap { piece -> ArraySlice<Float> in
                    let lo = Int(piece.start * sampleRate)
                    let hi = min(samples.count, Int(piece.end * sampleRate))
                    return samples[lo..<hi]
                }
                return try embedder.extractSpeakerEmbedding(from: audio)
            }
            // The longest clean piece is the clearest excerpt to play back.
            let sample = clips.joined().max { $0.end - $0.start < $1.end - $1.start }!
            speakers.append(
                DiarizedSpeaker(
                    index: index,
                    embedding: VoiceMath.centroid(embeddings),
                    sampleStart: sample.start,
                    sampleEnd: sample.end
                ))
        }
        return Analysis(spans: spans, speakers: speakers)
    }

    func release() {
        diarizer = nil
        embedder?.cleanup()
        embedder = nil
    }
}
