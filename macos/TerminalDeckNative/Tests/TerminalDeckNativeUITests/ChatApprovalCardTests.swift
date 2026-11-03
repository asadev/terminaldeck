import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatApprovalCardTests: XCTestCase {
    func testOperationCardsFitNarrowAndWideChatInBothThemes() throws {
        let examples = [
            #"{"subtype":"item/commandExecution/requestApproval","name":"Run command","input":{"command":"swift test --filter ChatApprovalCardTests","cwd":"/scratch/Terminal Deck","reason":"Run the selected local checks.","availableDecisions":["accept","acceptForSession","decline"]}}"#,
            #"{"subtype":"can_use_tool","name":"Edit","cwd":"/scratch/project","input":{"file_path":"Sources/Welcome.swift","old_string":"Hello","new_string":"Welcome"},"description":"Update the welcome text","permissionSuggestions":[{"type":"addRules","destination":"session","behavior":"allow","rules":[{"toolName":"Edit","ruleContent":"/scratch/project/**"}]}]}"#,
            #"{"subtype":"session/request_permission","name":"Write settings","input":{"toolCall":{"title":"Write settings","rawInput":{"path":"settings.json","content":"fixture"}},"options":[{"kind":"allow_once","optionId":"one","name":"Allow this write"},{"kind":"allow_always","optionId":"remember","name":"Remember this tool"},{"kind":"reject_once","optionId":"no","name":"Deny"}]}}"#,
            #"{"subtype":"item/permissions/requestApproval","name":"Network access","input":{"reason":"Fetch dependencies","permissions":{"network":{"enabled":true}}}}"#
        ]
        for (index, example) in examples.enumerated() {
            let request = try NativeRPCValue.parseJSON(Data(example.utf8)).setting("approvalNonce", .string("fixture-\(index)"))
            for width in [340.0, 620.0] {
                for dark in [false, true] {
                    let host = NSHostingView(rootView: NativeChatApprovalCard(request: request, disabled: false, answer: { _, _ in })
                        .frame(width: width).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 560)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                    XCTAssertGreaterThan(host.fittingSize.height, 100)
                    XCTAssertLessThan(host.fittingSize.height, 620)
                    if let directory = ProcessInfo.processInfo.environment["TD_CONN_RENDER_DIR"] {
                        host.frame.size.height = host.fittingSize.height
                        host.layoutSubtreeIfNeeded()
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let folder = URL(fileURLWithPath: directory)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: folder.appendingPathComponent("approval-\(index)-\(Int(width))-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
