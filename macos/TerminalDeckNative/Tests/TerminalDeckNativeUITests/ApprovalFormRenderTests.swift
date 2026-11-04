import AppKit
import SwiftUI
import Vision
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ApprovalFormRenderTests: XCTestCase {
    private func form(_ schema: String, permission: Bool = false) throws -> NativeRPCValue {
        try .parseJSON(Data(#"{"subtype":"mcpServer/elicitation/request","input":{"mode":"form","serverName":"Calendar","message":"Choose how to continue.","requestedSchema":\#(schema),"_meta":\#(permission ? #"{"codex_approval_kind":"mcp_tool_call"}"# : "{}")}}"#.utf8))
    }
    func testEmptyPermissionRendersOnlyClearDecisionButtons() throws {
        try render(form(#"{"type":"object","properties":{}}"#, permission: true), name: "empty", words: ["Permission", "Allow", "Don't allow"])
    }
    func testEnumRendersVisibleChoiceButtons() throws {
        try render(form(#"{"type":"object","properties":{"color":{"title":"Color","type":"string","enum":["Blue","Green"]}}}"#), name: "enum", words: ["Question from Calendar", "Color", "Blue", "Green", "Send answer"])
    }
    func testBooleanRendersAllowAndDontAllow() throws {
        try render(form(#"{"type":"object","properties":{"enabled":{"title":"Enable sharing","type":"boolean"}}}"#), name: "boolean", words: ["Enable sharing", "Allow", "Don't allow", "Send answer"])
    }
    func testStringRendersOneLabelledTextField() throws {
        try render(form(#"{"type":"object","required":["name"],"properties":{"name":{"title":"Your name","type":"string","default":"Sample name"}}}"#), name: "string", words: ["Your name", "Sample name", "Send answer"])
    }
    func testNumberRendersLabelledFieldWithoutLosingZero() throws {
        try render(form(#"{"type":"object","properties":{"limit":{"title":"Event limit","type":"integer","default":0}}}"#), name: "number", words: ["Event limit", "Send answer"])
    }
    func testMultipleChoicesRenderEachLabel() throws {
        try render(form(#"{"type":"object","properties":{"scopes":{"title":"Access","type":"array","items":{"enum":["Read calendar","Edit calendar"]}}}}"#), name: "multiple", words: ["Access", "Read calendar", "Edit calendar"])
    }
    func testClaudeAndCodexQuestionsUseSharedVisibleChoices() throws {
        for claude in [false, true] {
            let request = try NativeRPCValue.parseJSON(Data((claude
                ? #"{"name":"AskUserQuestion","input":{"questions":[{"header":"Destination","question":"Where should it go?","options":[{"label":"Dubai","description":"Local office"},{"label":"London","description":"UK office"}]}]}}"#
                : #"{"subtype":"item/tool/requestUserInput","input":{"questions":[{"id":"place","header":"Destination","question":"Where should it go?","options":[{"label":"Dubai","description":"Local office"},{"label":"London","description":"UK office"}]}]}}"#).utf8))
            try render(request, name: claude ? "claude" : "codex", words: ["Question", "Destination", "Where should it go?", "Dubai", "London", "Your own answer"])
        }
    }
    func testSignInRendersClearContinueAction() throws {
        let request = try NativeRPCValue.parseJSON(Data(#"{"subtype":"mcpServer/elicitation/request","input":{"mode":"url","serverName":"Calendar","message":"Sign in to connect.","url":"https://example.test/connect"}}"#.utf8))
        try render(request, name: "sign-in", words: ["Question from Calendar", "Open sign-in page", "Continue"])
    }
    func testUnsupportedSchemaExplainsProblemWithoutRawJSON() throws {
        try render(form(#"{"type":"object","properties":{"settings":{"type":"object","properties":{"limit":{"type":"integer"}}}}}"#), name: "unsupported", words: ["cannot display yet", "Don't allow"])
    }

    private func render(_ request: NativeRPCValue, name: String, words: [String]) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for (width, dark) in [(CGFloat(340), false), (CGFloat(720), true)] {
            let host = NSHostingView(rootView: NativeChatQuestionsCard(request: request, disabled: false, answer: { _, _ in })
                .frame(width: width).environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .active))
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            let size = host.fittingSize
            XCTAssertEqual(size.width, width, accuracy: 1)
            XCTAssertLessThan(size.height, 600)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            var folder = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 { folder.deleteLastPathComponent() }
            folder.appendPathComponent("design-2026-10-10/built.noindex/codex-approval-form")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(name + (dark ? "-dark" : "-light") + ".png"))
            let scan = VNRecognizeTextRequest()
            scan.recognitionLevel = .accurate
            // Render tests must not depend on GPU/Neural Engine services or personal contact dictionaries.
            scan.usesCPUOnly = true
            scan.usesLanguageCorrection = false
            scan.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: png).perform([scan])
            let visible = (scan.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                .replacingOccurrences(of: "’", with: "'").lowercased()
            for word in words { XCTAssertTrue(visible.contains(word.lowercased()), "Missing visible text: \(word); rendered: \(visible)") }
            for forbidden in ["Form answers", "Requested format", "Submit answers", "properties", "requestedSchema"] {
                XCTAssertFalse(visible.contains(forbidden.lowercased()), "Raw/ambiguous form text: \(forbidden)")
            }
        }
    }
}
