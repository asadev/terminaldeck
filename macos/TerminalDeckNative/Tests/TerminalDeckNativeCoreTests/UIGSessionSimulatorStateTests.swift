import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite
struct UIGSessionSimulatorStateTests {
    @Test func perSessionKeysCannotSharePreferences() {
        #expect(UIGSessionSimulatorState.storageKey(sessionID: "a") != UIGSessionSimulatorState.storageKey(sessionID: "b"))
        #expect(UIGSessionSimulatorState.storageKey(sessionID: "a/b") != UIGSessionSimulatorState.storageKey(sessionID: "a_b"))
    }
    @Test func restoresOpenAndWidthWithoutAnAttachment() throws {
        let state = UIGSessionSimulatorState(isOpen: true, width: 510)
        let data = try JSONEncoder().encode(state)
        #expect(UIGSessionSimulatorState.restored(from: data) == state)
        #expect(!String(decoding: data, as: UTF8.self).contains("attachmentToken"))
    }
    @Test func clampsCorruptAndNonfiniteWidths() {
        #expect(UIGSessionSimulatorState(width: .nan).width == 420)
        #expect(UIGSessionSimulatorState(width: .infinity).width == 420)
        #expect(UIGSessionSimulatorState(width: -20).width == 280)
        #expect(UIGSessionSimulatorState(width: 5_000).width == 800)
        #expect(UIGSessionSimulatorState.restored(from: Data("broken".utf8)) == .init())
    }
    @Test func resizingNeverPushesOutsideTheSessionPane() {
        let state = UIGSessionSimulatorState(isOpen: true, width: 800)
        #expect(state.fittedWidth(in: 600) == 440)
        #expect(state.fittedWidth(in: 200) == 100)
        #expect(state.fittedWidth(in: .nan) == 0)
    }
    @Test func hiddenPanelKeepsItsSavedWidth() {
        var state = UIGSessionSimulatorState(isOpen: true, width: 480)
        state.isOpen = false
        #expect(state.width == 480)
        state.resize(to: 320)
        #expect(state.width == 320 && !state.isOpen)
    }
    @Test func ticketRejectsSpoofedSessionAndStaleFrames() throws {
        let first = UUID().uuidString, second = UUID().uuidString
        let a = try #require(UIGSessionSimulatorTicket(value: ["sessionId": "a", "attachmentToken": first, "deviceId": "ios:one"], for: "a"))
        let b = UIGSessionSimulatorTicket(value: ["sessionId": "a", "attachmentToken": second, "deviceId": "ios:one"], for: "a")
        #expect(UIGSessionSimulatorTicket(value: a.arguments, for: "b") == nil)
        #expect(a.acceptsFrame(ticket: a, deviceID: "ios:one"))
        #expect(!a.acceptsFrame(ticket: b, deviceID: "ios:one"))
        #expect(!a.acceptsFrame(ticket: a, deviceID: "ios:two"))
    }
}
