import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class LoginFollowChipRenderTests: XCTestCase {
    func testPlainRefusalAndSwitchChoicesInBothThemes() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for dark in [false, true] {
            try render(NativeClaudeSignedOutRow(target: "asadiqbalonline@gmail.com", canChoose: true, problem: nil, switchLogin: {}),
                size: CGSize(width: 780, height: 90), dark: dark, name: "refusal")
            try render(NativeClaudeSignedOutRow(target: "asadiqbalonline@gmail.com", canChoose: true, problem: nil, switchLogin: {}),
                size: CGSize(width: 340, height: 120), dark: dark, name: "refusal-small")
            try render(NativeClaudeSignedOutRow(target: nil, canChoose: false, problem: nil, switchLogin: {}),
                size: CGSize(width: 780, height: 90), dark: dark, name: "sign-in")
            try render(NativeClaudeLoginChoice(accounts: [CodingAIAccount(id: "work", name: "Work — asadiqbalonline@gmail.com"),
                                                          CodingAIAccount(id: "personal", name: "Personal — asadiqbalonline@gmail.com")], choose: { _ in }),
                size: CGSize(width: 480, height: 240), dark: dark, name: "switch")
        }
    }
    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        if let folder = ProcessInfo.processInfo.environment["LOGIN_CHIP_RENDER_OUTPUT"], folder.hasSuffix(".noindex") {
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }
}
