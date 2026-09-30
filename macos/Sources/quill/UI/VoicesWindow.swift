import AppKit
import QuillUI
import SwiftUI

/// The one window quill has: pick a session, play each of its voices, type a
/// name. Opened from the menu bar; closing it just hides it. The view lives in
/// QuillUI so Xcode can preview it (previews don't run in executable targets).
@MainActor
final class VoicesWindowController {
    private let model: VoicesModel
    private var window: NSWindow?

    init(root: URL) {
        model = VoicesModel(store: RecordingsVoicesStore(root: root))
    }

    func show() {
        model.reload()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: VoicesView(model: model)))
            window.title = "quill — voices"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 360))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The naming window's view of the recordings folder.
@MainActor
final class RecordingsVoicesStore: VoicesStore {
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    func sessions() -> [VoiceSession] {
        VoiceLibrary.sessions(root: root).map { dir in
            // An unreadable voices.json still lists the session; opening it
            // reports the error.
            VoiceSession(id: dir.lastPathComponent, unnamed: (try? SessionVoices.read(from: dir))?.unnamedCount ?? 0)
        }
    }

    func voices(in session: String) throws -> [VoiceItem] {
        let dir = root.appendingPathComponent(session)
        return (try SessionVoices.read(from: dir)?.voices ?? []).map {
            VoiceItem(
                id: $0.id, name: $0.name, ignored: $0.ignored,
                sampleURL: dir.appendingPathComponent($0.sample.file),
                sampleStart: TimeInterval($0.sample.start_ms) / 1000,
                sampleEnd: TimeInterval($0.sample.end_ms) / 1000
            )
        }
    }

    func knownNames() -> [String] {
        // Same as above: a broken directory file shouldn't block naming.
        (try? VoiceDirectory.load(root: root).names) ?? []
    }

    func setName(_ name: String?, voice: Int, session: String) throws {
        try VoiceLibrary.setName(name, voiceId: voice, session: root.appendingPathComponent(session), root: root)
    }

    func setIgnored(_ ignored: Bool, voice: Int, session: String) throws {
        try VoiceLibrary.setIgnored(ignored, voiceId: voice, session: root.appendingPathComponent(session))
    }
}
