import XCTest

@testable import QuillUI

/// The naming window's state, against the in-memory store the previews use.
@MainActor
final class VoicesModelTests: XCTestCase {
    func testReloadLandsOnNewestSessionWithUnnamedVoices() {
        let model = VoicesModel(store: PreviewVoicesStore())
        model.reload()
        XCTAssertEqual(model.selected, "2026.09.30-0753")
        XCTAssertEqual(model.voices.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(model.drafts[1], "César")
        XCTAssertEqual(model.drafts[2], "")
    }

    func testSavingANameUpdatesCountsAndKnownNames() {
        let model = VoicesModel(store: PreviewVoicesStore())
        model.reload()
        let voice = model.voices[1]
        model.drafts[voice.id] = "  Firas "
        XCTAssertTrue(model.hasChanges(voice))

        model.save(voice)

        XCTAssertEqual(model.voices[1].name, "Firas")
        XCTAssertFalse(model.hasChanges(model.voices[1]))
        XCTAssertEqual(model.sessions.first?.unnamed, 1)
        XCTAssertTrue(model.knownNames.contains("Firas"))
    }

    func testClearingANameMakesTheVoiceUnnamedAgain() {
        let model = VoicesModel(store: PreviewVoicesStore())
        model.reload()
        model.drafts[1] = ""
        model.save(model.voices[0])
        XCTAssertNil(model.voices[0].name)
        XCTAssertEqual(model.sessions.first?.unnamed, 3)
    }

    func testIgnoringTogglesAndLeavesTheCount() {
        let model = VoicesModel(store: PreviewVoicesStore())
        model.reload()
        model.toggleIgnored(model.voices[2])
        XCTAssertTrue(model.voices[2].ignored)
        XCTAssertEqual(model.sessions.first?.unnamed, 1)
    }

    func testNoSessions() {
        let model = VoicesModel(store: PreviewVoicesStore(empty: true))
        model.reload()
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.voices, [])
    }
}
