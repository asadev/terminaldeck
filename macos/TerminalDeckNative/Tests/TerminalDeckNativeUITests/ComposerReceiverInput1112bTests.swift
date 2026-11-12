import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore
import XCTest
@testable import TerminalDeckNative

/// Real Receiver views and model with an inert read closure. Windows stay offscreen;
/// no subscriptions, source windows, requests, app state or saved settings are started.
@MainActor final class ComposerLeak1112bReceiverInputTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @MainActor @Observable final class Fields {
        var auth = RCVAuth(scheme: .hmac, hmac: RCVHMAC(header: "signature", signedPayload: "{timestamp}.{body}", timestampHeader: "time"))
        var addresses = "203.0.113.0/24"
        var reply = RCVReplyChannel(url: "https://example.invalid/reply", headers: [RCVFieldMap("X-Fixture", "own value")])
        var mapping = RCVMapping()
        var conditions = [RCVCondition("fields.chat", .equals, "own chat")]
    }

    private struct SourceFields: View {
        @Bindable var fields: Fields
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    NativeRCVAuthFields(auth: $fields.auth, ipText: $fields.addresses, preset: nil)
                    NativeRCVReplyFields(reply: $fields.reply)
                    NativeRCVMappingFields(mapping: $fields.mapping, suggestions: ["fields.chat"])
                    NativeRCVConditionsEditor(conditions: $fields.conditions, suggestions: ["fields.chat"], addLabel: "Add a condition")
                }.padding()
            }.frame(width: 800, height: 1400)
        }
    }

    private func mount<V: View>(_ root: V) -> (NSHostingView<V>, ScratchWindow) {
        let host = NSHostingView(rootView: root)
        let window = ScratchWindow(contentRect: NSRect(x: -32000, y: -32000, width: 900, height: 1500),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        return (host, window)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testActualCachedReceiverEventsSearchDropsKeyboardAndRejectsHiddenInput() throws {
        let model = NativeRCVModel(sourceEvents: [], read: { _, _ in [:] })
        model.overview = RCVOverview(sources: [], rules: [], events: [], unrouted: 0, held: 0,
                                     relayConnected: false, relayBase: nil, presets: [])
        model.loading = false
        model.query = "own Receiver filter"
        let scope = NativeSessionInputScope()
        let root = NativeRCVScreen(model: model, section: "Events").environment(\.nativeSessionInputScope, scope)
        let (host, window) = mount(root)
        defer { window.contentView = nil; window.close() }
        let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSessionTextControl }
            .first { $0.placeholderString == "Search events" })
        XCTAssertTrue(window.makeFirstResponder(field))
        let retained = try XCTUnwrap(field.currentEditor() as? NativeSessionTextView)
        XCTAssertTrue(window.firstResponder === retained)
        scope.setActive(false)
        retained.insertText("wrong session message", replacementRange: NSRange(location: NSNotFound, length: 0))
        retained.setMarkedText("wrong marked text", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        retained.setAccessibilityValue("wrong accessibility value")
        settle(host)
        XCTAssertFalse(window.firstResponder === retained)
        XCTAssertEqual(model.query, "own Receiver filter")
        XCTAssertEqual(field.stringValue, "own Receiver filter")
        XCTAssertFalse(retained.hasMarkedText())
        scope.setActive(true)
        settle(host)
        XCTAssertTrue(window.makeFirstResponder(field))
        let live = try XCTUnwrap(field.currentEditor() as? NativeSessionTextView)
        live.setSelectedRange(NSRange(location: (live.string as NSString).length, length: 0))
        live.insertText(" restored", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertEqual(model.query, "own Receiver filter restored")
    }

    func testActualReceiverSourceAndConditionHelpersUseProtectedClients() throws {
        let fields = Fields()
        let scope = NativeSessionInputScope()
        let (host, window) = mount(SourceFields(fields: fields).environment(\.nativeSessionInputScope, scope))
        defer { window.contentView = nil; window.close() }
        let controls = descendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertGreaterThanOrEqual(controls.count, 14, "Mount actual auth, numeric tolerance, reply, mapping, and condition helpers")
        var retained: [(NSTextField, NativeSessionTextView, String)] = []
        for control in controls {
            XCTAssertTrue(control is any NativeSessionInputProtected, "Unprotected Receiver helper: \(type(of: control))")
            XCTAssertTrue(window.makeFirstResponder(control))
            let client = try XCTUnwrap(control.currentEditor() as? NativeSessionTextView)
            retained.append((control, client, control.stringValue))
        }
        let beforeAuth = fields.auth
        let beforeReply = fields.reply
        let beforeMapping = fields.mapping
        let beforeConditions = fields.conditions
        scope.setActive(false)
        // AppKit empties a field editor when its editing session ends (moving to the next
        // control, or hiding). So the retained client's own text is compared from after the
        // hide, and each control's visible value is compared with what it showed when focused.
        for (control, client, shown) in retained {
            let detached = client.string
            client.insertText("wrong hidden edit", replacementRange: NSRange(location: NSNotFound, length: 0))
            client.setMarkedText("wrong hidden composition", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            client.setAccessibilityValue("wrong hidden accessibility")
            XCTAssertEqual(client.string, detached)
            XCTAssertFalse(client.hasMarkedText())
            XCTAssertEqual(control.stringValue, shown)
        }
        settle(host)
        XCTAssertEqual(fields.auth, beforeAuth)
        XCTAssertEqual(fields.reply, beforeReply)
        XCTAssertEqual(fields.mapping, beforeMapping)
        XCTAssertEqual(fields.conditions, beforeConditions)
        XCTAssertEqual(fields.addresses, "203.0.113.0/24")
    }
}
