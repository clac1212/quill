import Foundation

/// A session that has voices, as the naming window lists it. `id` is the
/// session folder name (`2026.09.30-0753`), which sorts chronologically.
public struct VoiceSession: Hashable, Identifiable, Sendable {
    public let id: String
    public let unnamed: Int

    public init(id: String, unnamed: Int) {
        self.id = id
        self.unnamed = unnamed
    }
}

/// One voice of a session, with the excerpt to play when naming it.
public struct VoiceItem: Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String?
    public let ignored: Bool
    public let sampleURL: URL
    public let sampleStart: TimeInterval
    public let sampleEnd: TimeInterval

    public init(
        id: Int, name: String?, ignored: Bool,
        sampleURL: URL, sampleStart: TimeInterval, sampleEnd: TimeInterval
    ) {
        self.id = id
        self.name = name
        self.ignored = ignored
        self.sampleURL = sampleURL
        self.sampleStart = sampleStart
        self.sampleEnd = sampleEnd
    }
}

/// Where the naming window reads and writes voices. quill backs it with the
/// recordings folder; previews and tests with memory.
@MainActor
public protocol VoicesStore: AnyObject {
    /// Newest first.
    func sessions() -> [VoiceSession]
    func voices(in session: String) throws -> [VoiceItem]
    /// Names already given, for picking instead of retyping.
    func knownNames() -> [String]
    /// nil clears the name.
    func setName(_ name: String?, voice: Int, session: String) throws
    func setIgnored(_ ignored: Bool, voice: Int, session: String) throws
}
