import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Settings → Connect an AI app, native. Mirrors ai-apps-setup.test.ts: the same
// setups, the same lines, the same narrowing of what the engine sends.

private let key = "tdk_live_abc123"
private let base = "https://relay.example/mcp/host-1"
private let local = "http://127.0.0.1:47820/mcp"

private func setup(_ app: AiApp, where place: AiSetupWhere = .thisMac, internet: String? = base, bridge: String? = nil) -> AiSetup {
    AiAppsSetup.setup(app, key: key, name: "My app", internetBase: internet, localURL: local, where: place, channelBridge: bridge)
}

@Test func aiAppsOffersEveryAppAndTheThreeLevels() {
    #expect(AiApp.allCases.map(\.label) == ["Claude", "ChatGPT", "Claude Code", "Codex", "Gemini CLI", "Cursor", "VS Code"])
    #expect(AiAccessLevel.allCases.map(\.label) == ["Look only", "Work", "Full control"])
    #expect(AiAccessLevel.work.help.contains("close to full trust"))
}

@Test func aiAppsWebAppsGetTheSecretLink() {
    for app in [AiApp.claudeWeb, .chatgpt] {
        let made = setup(app)
        #expect(made.snippet == "\(base)/\(key)")
        #expect(made.needsInternet)
        #expect(made.steps.joined(separator: " ").contains("My app"))
    }
    #expect(setup(.chatgpt).after == AiAppsCopy.chatgptPushSentence)
    let none = setup(.claudeWeb, internet: nil)
    #expect(none.snippet == nil)
    #expect(none.missing == "This Mac is not connected to a relay, so there is no internet link to give yet.")
}

@Test func aiAppsCommandLineAndFilesInEachAppsShape() throws {
    let claude = try #require(setup(.claudeCode).snippet)
    #expect(claude.contains("claude mcp add --scope user --transport http terminaldeck"))
    #expect(claude.contains(local))
    #expect(claude.contains("--header \"Authorization: Bearer \(key)\""))
    #expect(claude.split(separator: "\n").dropLast().allSatisfy { $0.hasSuffix(" \\") })

    #expect(setup(.codex).snippet?.split(separator: "\n").map(String.init) == [
        "[mcp_servers.terminaldeck]",
        "url = \"\(local)\"",
        "http_headers = { \"Authorization\" = \"Bearer \(key)\" }",
    ])

    // JSON.stringify(value, null, 2), key for key.
    #expect(setup(.cursor).snippet == """
    {
      "mcpServers": {
        "terminaldeck": {
          "url": "\(local)",
          "headers": {
            "Authorization": "Bearer \(key)"
          }
        }
      }
    }
    """)
    let gemini = try #require(setup(.gemini).snippet)
    #expect(gemini.contains("\"httpUrl\": \"\(local)\""))
    let vscode = try #require(setup(.vscode).snippet)
    #expect(vscode.hasPrefix("{\n  \"servers\": {"))
    #expect(vscode.contains("\"type\": \"http\""))
}

@Test func aiAppsElsewhereUsesTheInternetAddress() {
    let made = setup(.codex, where: .elsewhere)
    #expect(made.needsInternet)
    #expect(made.snippet?.contains(base) == true)
    let none = setup(.codex, where: .elsewhere, internet: nil)
    #expect(none.missing == "This Mac is not connected to a relay, so there is no internet address to give yet.")
}

@Test func aiAppsClaudeCodeChannelOnlyOnThisMac() throws {
    let extra = try #require(setup(.claudeCode, bridge: "/app/notify.js").extra)
    #expect(extra.snippet.contains("claude mcp add --scope user terminaldeck-notify \\"))
    #expect(extra.snippet.contains("-e NOTIFY_KEY=\(key)"))
    #expect(extra.caution.hasPrefix("Channels are a Claude Code preview"))
    #expect(setup(.claudeCode, where: .elsewhere, bridge: "/app/notify.js").extra == nil)
    #expect(setup(.claudeCode).after == AiAppsCopy.idleSentence)
}

@Test func aiAppsReadsTheStateStrictly() throws {
    let state = try #require(AiAppsState.from(CodingAIJSON.parse(#"""
    {"keys": [
       {"id": "k1", "name": "Claude", "level": "full", "askFirst": false, "tasks": true, "folders": ["/w/api"],
        "notify": {"mode": "webhook", "url": "https://hook", "hasSecret": true}, "lastUsedAt": 5, "lastVia": "internet"},
       {"id": "k2", "name": "Cursor", "level": "work", "notify": {"mode": "bogus"}},
       {"id": "k3", "name": "Bad", "level": "admin"}],
     "internet": {"on": 1, "connected": true, "relayHost": "relay.example"},
     "local": {"url": "http://127.0.0.1:1/mcp", "movedFrom": 47820},
     "folders": ["/w/api", 3],
     "delivery": {"k1": {"state": "delivered", "at": 1, "via": "webhook", "outstanding": 2}, "k2": {"state": "nope", "at": 1}},
     "subscriptions": {"k1": [{"id": "s1", "event": "session.exited", "host": "chatgpt.com", "refreshBefore": 99}, {"id": "bad"}]}}
    """#)))
    #expect(state.keys.map(\.id) == ["k1", "k2"])
    #expect(state.keys[0].askFirst == false)
    #expect(state.keys[1].askFirst == true)
    #expect(state.keys[1].notifyMode == .wait)
    #expect(state.internetOn == false)
    #expect(state.connected == true)
    #expect(state.folders == ["/w/api"])
    #expect(state.delivery.keys.sorted() == ["k1"])
    #expect(state.subscriptions["k1"]?.map(\.id) == ["s1"])
    #expect(AiAppsState.from(CodingAIJSON.parse(#"{"internet":{}}"#)) == nil)

    let refused = AiAppsResult.from(CodingAIJSON.parse(#"{"ok":false}"#))
    #expect(refused.message == "That did not go through, and the app did not say why.")
    #expect(AiAppsResult.from(.null).ok == false)
}

@Test func aiAppsLinesSayItPlainly() throws {
    let now = 10_000_000.0
    let used = AiAccessKey(id: "a", name: "A", level: .look, askFirst: true, folders: nil, tasks: false, createdAt: 0,
                           lastUsedAt: now - 240_000, lastApp: "claude-ai 0.1.0", lastVia: "internet",
                           notifyMode: .wait, notifyURL: nil, hasSecret: false)
    #expect(AiAppsLines.used(used, now: now) == "Last used 4 minutes ago by claude-ai 0.1.0 over the internet")
    #expect(AiAppsLines.ago(now - 10_000, now: now) == "just now")
    #expect(AiAppsLines.ago(now - 26 * 3_600_000, now: now) == "yesterday")
    #expect(AiAppsLines.folders(nil) == "Sessions in any project")
    #expect(AiAppsLines.folders(["/w/api", "/w/web/"]) == "Sessions only in api, web")
    #expect(AiAppsLines.delivery(AiDelivery(state: "delivered", at: now, via: "webhook", error: nil, outstanding: 1), now: now)
            == "Last notification delivered just now by webhook · 1 the app has not marked as handled")
    #expect(AiAppsLines.delivery(AiDelivery(state: "failed", at: now, via: nil, error: "timeout", outstanding: 0), now: now)
            == "Last delivery failed just now, trying again: timeout")
    let sub = AiSubscription(id: "s", keyId: "a", event: "session.needs_input", host: "chatgpt.com", sessionId: "x",
                             refreshBefore: now + 3_600_000, lastDelivery: nil)
    #expect(AiAppsLines.pushes([sub]) == "Pushed to chatgpt.com when a session needs an answer")
    #expect(AiAppsLines.subscription(sub, now: now).hasPrefix("Pushes to chatgpt.com when a session needs an answer (one session) · ends at "))
    let state = try #require(AiAppsState.from(CodingAIJSON.parse(#"{"keys":[],"internet":{"on":true,"connected":false}}"#)))
    #expect(AiAppsLines.internetHelp(state) == "On, but this Mac is not connected to the relay right now. Unlike your phone’s connection, this traffic can be read at the relay.")
    #expect(AiAppsLines.tasksHelp(true, limited: true) == "This app can read and change your tasks whose project folder is one of its folders.")
}
