import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 4 Nov (Asad's recording of install #26): the Claude Code accounts as his Mac has them after the fix. This Mac's
/// own login is signed out, so it says what it is and who was last signed in; the copy that carried another
/// login's name is renamed and folded into that login's row. Fixed rows, offscreen window, both appearances.
@MainActor @Test
func Accounts27RenderTheClaudeCodeAccountsOffscreen() throws {
    let accounts = [
        CodingAIAccount(id: "system", name: "Default", provider: "claude", configDir: "/Users/imatch/.claude", system: true),
        CodingAIAccount(id: "sherzod", name: "sherzod.davlatov@gmail.com", provider: "claude", configDir: "/x/1", lastUsedAt: 3, keptBy: .app, keptSignedIn: true),
        CodingAIAccount(id: "api-key-0123456789abcdef01234567", name: "Imza Premium API", provider: "claude", configDir: "/x/2", color: "--status-waiting",
                        authentication: "api-key", apiConfigured: true, apiCheckState: "valid"),
        CodingAIAccount(id: "app-imatch", name: "app.imatch.ae@gmail.com", provider: "claude", configDir: "/x/3", lastUsedAt: 2, keptBy: .app, keptSignedIn: true),
        CodingAIAccount(id: "imza", name: "app.imatch.ae@gmail.com (second copy)", provider: "claude", configDir: "/x/4", lastUsedAt: 1, keptBy: .app, keptSignedIn: true),
        CodingAIAccount(id: "asad", name: "asadiqbalonline@gmail.com", provider: "claude", configDir: "/x/5", lastUsedAt: 2, keptBy: .app, keptSignedIn: true),
    ]
    let signIn: [String: CodingAISignIn] = [
        "system": CodingAISignIn(state: .signedOut, detail: "Not logged in", remembered: "asadiqbalonline@gmail.com"),
        "sherzod": CodingAISignIn(state: .signedIn, account: "sherzod.davlatov@gmail.com"),
        "api-key-0123456789abcdef01234567": CodingAISignIn(state: .signedIn, plan: "API key"),
        "app-imatch": CodingAISignIn(state: .signedIn, account: "app.imatch.ae@gmail.com"),
        "imza": CodingAISignIn(state: .signedIn, account: "app.imatch.ae@gmail.com"),
        "asad": CodingAISignIn(state: .signedIn, account: "asadiqbalonline@gmail.com"),
    ]
    let snapshot = CodingAIAccountsSnapshot(accounts: accounts, defaultId: nil)
    let rows = CodingAIProviders.rows(detected: CodingAIJSON.parse(#"{"claude": true, "codex": true, "gemini": false}"#), fromMain: [])
    let shown = CodingAILogins.oneRowPerEmail(accounts, signIn: signIn)
    #expect(shown.map(\.id) == ["system", "sherzod", "api-key-0123456789abcdef01234567", "app-imatch", "asad"])
    let models = shown.map { account in
        (account, CodingAIAccountRowModel.make(account: account, snapshot: snapshot, signIn: signIn, history: [:], providerRows: rows,
                                               sessionTitles: account.id == "system" ? ["Deck Dev", "Deck Dev"] : nil, canStartSessions: true, canSignOut: true))
    }
    #expect(models[0].1.label == "This Mac’s own Claude Code login")
    #expect(models[0].1.offersSignIn && models[0].1.lastLogin == "Last signed in here as asadiqbalonline@gmail.com" && !models[0].1.showsUsage)
    for dark in [false, true] {
        try Accounts27Frame(Accounts27Rows(models: models), dark: dark, name: "claude-accounts")
    }
}

@MainActor private struct Accounts27Rows: View {
    let models: [(CodingAIAccount, CodingAIAccountRowModel)]
    @State private var renaming: String?
    @State private var text = ""
    @State private var removing: CodingAIAccount?
    var body: some View {
        Form {
            Section("Claude Code") {
                ForEach(models, id: \.0.id) { pair in
                    NativeCodingAIAccountRow(store: NativeCodingAIStore.shared, account: pair.0, model: pair.1,
                                             renamingId: $renaming, renameText: $text, removing: $removing)
                }
            }
        }.formStyle(.grouped)
    }
}

@MainActor
private func Accounts27Frame<V: View>(_ view: V, dark: Bool, name: String) throws {
    let size = NSSize(width: 640, height: 620)
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    host.appearance = appearance
    host.frame = NSRect(origin: .zero, size: size)
    // A real window that is never ordered on screen: same layout path as the app.
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let source = URL(fileURLWithPath: #filePath)
    let macos = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let out = macos.appendingPathComponent("design-2026-10-10/built.noindex")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try png.write(to: out.appendingPathComponent("ACCOUNTS27-\(name)-\(dark ? "dark" : "light").png"), options: .atomic)
}
