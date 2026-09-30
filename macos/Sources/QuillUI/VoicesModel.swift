import AVFoundation
import Foundation

/// State of the naming window: the selected session, its voices, the names
/// being typed, and which excerpt is playing.
@MainActor
public final class VoicesModel: ObservableObject {
    @Published public private(set) var sessions: [VoiceSession] = []
    @Published public var selected: String? {
        didSet { loadVoices() }
    }
    @Published public private(set) var voices: [VoiceItem] = []
    @Published public var drafts: [Int: String] = [:]
    @Published public private(set) var knownNames: [String] = []
    @Published public private(set) var playing: Int?
    @Published public private(set) var error: String?

    private let store: VoicesStore
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    public init(store: VoicesStore) {
        self.store = store
    }

    /// Refresh everything and land on the newest session that still has
    /// unnamed voices, else the newest one.
    public func reload() {
        sessions = store.sessions()
        knownNames = store.knownNames()
        selected = sessions.first { $0.unnamed > 0 }?.id ?? sessions.first?.id
    }

    public func save(_ voice: VoiceItem) {
        guard let session = selected else { return }
        let draft = drafts[voice.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        perform { try store.setName(draft.isEmpty ? nil : draft, voice: voice.id, session: session) }
    }

    public func toggleIgnored(_ voice: VoiceItem) {
        guard let session = selected else { return }
        perform { try store.setIgnored(!voice.ignored, voice: voice.id, session: session) }
    }

    /// Whether the typed name differs from the saved one.
    public func hasChanges(_ voice: VoiceItem) -> Bool {
        (drafts[voice.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != (voice.name ?? "")
    }

    public func togglePlay(_ voice: VoiceItem) {
        let wasPlaying = playing == voice.id
        stopPlayback()
        guard !wasPlaying else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: voice.sampleURL)
            player.currentTime = voice.sampleStart
            player.play()
            self.player = player
            playing = voice.id
            let duration = voice.sampleEnd - voice.sampleStart
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.stopPlayback()
            }
        } catch {
            self.error = "Can't play \(voice.sampleURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: -

    /// Run a write, then refresh: a name can land in other sessions too, so
    /// the unnamed counts and known names change beyond this one voice.
    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = "\(error)"
        }
        sessions = store.sessions()
        knownNames = store.knownNames()
        loadVoices()
    }

    private func loadVoices() {
        stopPlayback()
        guard let selected else {
            voices = []
            return
        }
        do {
            voices = try store.voices(in: selected)
        } catch {
            voices = []
            self.error = "Can't read voices of \(selected): \(error)"
        }
        drafts = Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0.name ?? "") })
    }

    private func stopPlayback() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playing = nil
    }
}
