// Render the actual SwiftUI views inside XCTest. No application, window or external driver.
import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

@MainActor final class HOOTSIMRenderingTests: XCTestCase {
    func testActualHootBrowserAndPhoneViewsRenderOffscreenAtBothSizesAndAppearances() throws {
        // Renders only on request (HOOTSIM_OFFSCREEN_XCTEST=1); an ordinary suite run skips them.
        guard ProcessInfo.processInfo.environment["HOOTSIM_OFFSCREEN_XCTEST"] == "1" else { throw XCTSkip("Offscreen renders run only on request.") }
        guard let path = ProcessInfo.processInfo.environment["HOOTSIM_RENDER_OUTPUT"], path.hasSuffix(".noindex"),
              !EngineBridge.shared.isReady else { throw Self.failure("Renders need a .noindex output folder and no engine.") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let picture = Self.samplePicture()
        let phone = NativeSimulatorModel()
        // Root-owned fixture seam: seed device/session/target/shot/note in memory only.
        phone.installHOOTSIMRenderFixture(Self.phoneFixture, image: picture)
        let phoneTools = NativeSimPanelTools.attach(to: phone, widen: { _ in })
        for dark in [false, true] {
            for width in [1440, 1000] {
                let size = CGSize(width: width, height: width == 1440 ? 900 : 700)
                let suffix = "\(dark ? "dark" : "light")-\(width).png"
                // Root-owned initializer bypasses shared AppModel and engine lifecycle.
                try Self.render(NativeHootScreen(fixture: Self.chatFixture), size: size, dark: dark,
                           to: output.appendingPathComponent("HOOTSIM-hoot-" + suffix))
                try Self.render(Self.captureFrame(title: "Browser", source: "portal.example.test/sign-in", picture: picture) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Snip").font(.headline)
                        Text("Sign-in button").foregroundStyle(.secondary)
                        NativeBrowserSendRow(placeholder: "What should change?", needsText: true,
                                             multiline: true, autofocus: false,
                                             fixture: Self.browserFixture,
                                             makeLine: { _ in throw Self.failure("Render fixtures cannot send.") })
                    }.padding(12).frame(width: 330).background(.regularMaterial, in: .rect(cornerRadius: 12))
                }, size: size, dark: dark, to: output.appendingPathComponent("HOOTSIM-send-browser-" + suffix))
                try Self.render(Self.captureFrame(title: "Phone panel", source: "iPhone · stub device", picture: picture) {
                    NativeSimSnipPopup(model: phone, tools: phoneTools)
                }, size: size, dark: dark, to: output.appendingPathComponent("HOOTSIM-send-phone-" + suffix))
                let sessions = [SendTargetButton.Session(id: "display-session", name: "Portal session", project: "Portal", colour: .purple)]
                try Self.render(VStack(alignment: .leading, spacing: 24) {
                    Text("Send to Hoot").font(.title2.bold())
                    SendTargetButton(targetID: .constant("hoot"), sessions: sessions,
                        send: {}, copy: {}).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) {
                        SendTargetButton.HootRow()
                        Divider()
                        Text("A session").font(.caption).foregroundStyle(.secondary)
                        SendTargetButton.SessionRow(session: sessions[0])
                        Divider()
                        Label("Copy as a picture", systemImage: "doc.on.doc")
                    }.padding(16).frame(width: 380).background(AGKITStyle.card, in: .rect(cornerRadius: 12))
                    Spacer()
                }.padding(28), size: size, dark: dark,
                    to: output.appendingPathComponent("HOOTSIM-send-control-" + suffix))
            }
        }
        XCTAssertFalse(EngineBridge.shared.isReady)
        print("HOOTSIM renders: 16 in XCTest; application: not created; windows: not created; engine: disconnected")
    }
    func testFixtureModelMethodsKeepDraftAndCaptureWithoutStartingAnEngine() async throws {
        XCTAssertFalse(EngineBridge.shared.isReady)
        let chat = NativeHootChatModel(fixture: Self.chatFixture)
        let original = chat.draft
        await chat.start()
        await chat.refreshReadiness(force: true)
        chat.send(); chat.stop(); chat.answer("fixture-approval", allowed: true); chat.newChat()
        XCTAssertEqual(chat.draft, original)
        XCTAssertFalse(chat.sending)
        XCTAssertNil(chat.problem)
        let phone = NativeSimulatorModel()
        phone.installHOOTSIMRenderFixture(Self.phoneFixture, image: Self.samplePicture())
        let tools = NativeSimPanelTools.attach(to: phone, widen: { _ in })
        XCTAssertEqual(phone.feedbackTargetID, "hoot")
        XCTAssertNotNil(phone.shot)
        let note = phone.note
        tools.cancelSnip()
        XCTAssertNil(phone.shot)
        XCTAssertEqual(phone.note, note, "Cancelling this capture cannot erase another message")
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    static var chatFixture: NativeRPCValue {
        let route = NativeRPCValue.object([.init("id", .string("a64bf4d4-4abf-46b7-bb3b-24b691b89db3")),
            .init("revision", .string("b51a6224-fda7-4949-87a3-2d85f3b5d6f8")),
            .init("conversationId", .string("hootsim-render")), .init("state", .string("pending")), .init("status", .string("pending")),
            .init("problem", .string("Sign-in button does nothing")), .init("reason", .string("Display fixture only; this is not resolver evidence")),
            .init("target", .object([.init("kind", .string("agent")), .init("id", .string("portal-mechanic")),
                .init("name", .string("Portal agent")), .init("projectId", .string("display-project")), .init("projectName", .string("Portal")),
                .init("icon", .string("sf:globe")), .init("role", .string("Keeps the portal working"))]))])
        let events = [
            HootChatEvent(conversationID: "hootsim-render", turnID: "fixture", sequence: 1, provider: .claude,
                          record: .init(.user, id: "user-1", value: .object([
                            .init("text", .string("The sign-in button does nothing. Give this to the right agent.")),
                            .init("attachmentCount", .number(1)), .init("context", .object([.init("source", .object([
                                .init("kind", .string("browser")), .init("title", .string("Snip from the browser · 1 note")),
                                .init("url", .string("https://portal.example.test/sign-in")),
                                .init("path", .string("/not-approved/source-picture.png"))]))]))]))),
            HootChatEvent(conversationID: "hootsim-render", turnID: "fixture", sequence: 2, provider: .claude,
                          record: .text(.message, id: "hoot-1", "Here is a display example of a routing proposal. Session starts and messages ask first.")),
            HootChatEvent(conversationID: "hootsim-render", turnID: "fixture", sequence: 3, provider: .claude,
                          record: .init(.message, id: "routing:" + route["id"].string!, value: .object([
                            .init("text", .string("")), .init("routing", route)])))
        ]
        return .object([.init("conversationId", .string("hootsim-render")), .init("sequence", .number(3)),
                        .init("events", .array(events.map(\.wireValue))), .init("ready", .bool(true)),
                        .init("alive", .bool(true)), .init("busy", .bool(false)), .init("pending", .array([])),
                        .init("draft", .string("Check the sign-in screen")),
                        .init("options", .object([.init("permissionMode", .string("ask")), .init("model", .string("claude:display-opus")),
                            .init("ready", .bool(true)), .init("models", .array([.object([.init("id", .string("claude:display-opus")),
                                .init("provider", .string("Claude Code")), .init("name", .string("Opus 5.5"))])]))])),
                        .init("mentions", .array(["Portal session", "Display session", "Scratch session"].enumerated().map { index, name in
                            .object([.init("id", .string("display-session-" + String(index))), .init("kind", .string("session")), .init("name", .string(name)),
                                .init("project", .string("Portal")), .init("group", .string("display-project"))])
                        })),
                        .init("projects", .array([PROJProject(id: "display-project", name: "Portal", folders: ["/scratch/portal"], colour: "purple").wireValue])),
                        .init("images", .object([.init("fixture:user-1", .string(samplePNGBase64))]))])
    }
    static var samplePNGBase64: String {
        guard let image = samplePicture().cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "" }
        return data.base64EncodedString()
    }
    static var browserFixture: NativeRPCValue {
        .object([.init("sessions", .array([])), .init("targetId", .string("hoot")),
                 .init("note", .string("The sign-in button does nothing. Check this screen."))])
    }
    static var phoneFixture: NativeRPCValue {
        .object([.init("device", .object([.init("id", .string("ios:HOOTSIM-stub")),
            .init("name", .string("iPhone stub")), .init("platform", .string("ios")), .init("kind", .string("simulator"))])),
                 .init("sessionId", .string("hootsim-render-session")), .init("targetId", .string("hoot")),
                 .init("kind", .string("snip")), .init("note", .string("Check why the sign-in button does nothing."))])
    }
    static func captureFrame<Card: View>(title: String, source: String, picture: NSImage,
                                         @ViewBuilder card: () -> Card) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(title).font(.title2.bold()); Spacer(); Text(source).foregroundStyle(.secondary) }
            ZStack(alignment: .topTrailing) {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                card().padding(20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(28)
    }
    static func samplePicture() -> NSImage {
        NSImage(size: CGSize(width: 960, height: 640), flipped: false) { bounds in
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: NSRect(x: 160, y: 160, width: 520, height: 330), xRadius: 18, yRadius: 18).fill()
            ("Sign in" as NSString).draw(at: CGPoint(x: 200, y: 425), withAttributes: [.font: NSFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: NSColor.labelColor])
            ("Email address" as NSString).draw(at: CGPoint(x: 200, y: 355), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.secondaryLabelColor])
            NSColor.separatorColor.setStroke(); NSBezierPath(roundedRect: NSRect(x: 200, y: 285, width: 400, height: 48), xRadius: 8, yRadius: 8).stroke()
            NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: NSRect(x: 200, y: 205, width: 400, height: 48), xRadius: 8, yRadius: 8).fill()
            ("Sign in" as NSString).draw(at: CGPoint(x: 365, y: 220), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white])
            return true
        }
    }
    static func render<V: View>(_ content: V, size: CGSize, dark: Bool, to output: URL) throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.agkitOffscreenSolid, true)
            .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.bounds = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        XCTAssertEqual(host.bounds.width, size.width)
        XCTAssertEqual(host.bounds.height, size.height)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("Offscreen render unavailable.") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG render unavailable.") }
        try png.write(to: output)
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertEqual(bitmap.pixelsHigh, Int(size.height))
        XCTAssertNil(host.window)
        print("Rendered \(output.lastPathComponent): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }
    static func failure(_ text: String) -> NSError { .init(domain: "HOOTSIMRender", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
