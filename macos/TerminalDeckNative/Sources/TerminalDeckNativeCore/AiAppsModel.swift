import Foundation

/// Settings → Connect an AI app, as data: a port of
/// `src/renderer/settings/sections/ai-apps-setup.ts` (what `ai-apps:state` answers,
/// the levels, the setup for each app, and the lines under each key) plus the pure
/// parts of `AiAppsSection.tsx`. Same narrowing, same words.
public enum AiAppsCopy {
    /// `BRAND.id`.
    public static let brandId = "terminaldeck"
    /// `CHANNEL_SERVER`.
    public static let channelServer = "\(brandId)-notify"
    /// `SERVER_KEY`.
    public static let serverKey = brandId

    public static let chatgptPushSentence =
        "Live push updates work in ChatGPT Work chats, on the web and in the desktop app (with Cloud selected), and may need a connector that signs in. To try it, say in a Work chat: “watch my sessions and tell me when one finishes”. Where ChatGPT does not offer it, ask it to call notifications_wait."

    public static let idleSentence =
        "Then tell the agent: when you are idle, call notifications_wait instead of polling sessions_wait in a loop."

    public static let unreadable = "The app answered with something this page cannot read."
}

// MARK: - What the engine sends

public enum AiAccessLevel: String, Sendable, CaseIterable, Identifiable {
    case look, work, full
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .look: return "Look only"
        case .work: return "Work"
        case .full: return "Full control"
        }
    }

    public var help: String {
        switch self {
        case .look: return "Can read your sessions, projects and changes. Cannot start or change anything."
        case .work: return "Can also start sessions and talk to them. A session can run any command on this Mac, so this is close to full trust."
        case .full: return "Can also change settings and stop sessions."
        }
    }
}

public enum AiNotifyMode: String, Sendable, CaseIterable, Identifiable {
    case off, wait, webhook
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .wait: return "When it asks"
        case .webhook: return "Webhook"
        }
    }

    public var help: String {
        switch self {
        case .off: return "Nothing is kept for this app. It has to look for itself."
        case .wait: return "Kept until the app collects it — it is handed over the moment the app is waiting."
        case .webhook: return "Also posted to an address you give, signed so the receiver can check it came from this Mac."
        }
    }
}

public struct AiAccessKey: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let level: AiAccessLevel
    public let askFirst: Bool
    public let folders: [String]?
    public let tasks: Bool
    public let createdAt: Double
    public let lastUsedAt: Double?
    public let lastApp: String?
    public let lastVia: String?
    public let notifyMode: AiNotifyMode
    public let notifyURL: String?
    public let hasSecret: Bool
}

public struct AiDelivery: Equatable, Sendable {
    public let state: String
    public let at: Double
    public let via: String?
    public let error: String?
    public let outstanding: Int
}

public struct AiSubscription: Equatable, Sendable, Identifiable {
    public let id: String
    public let keyId: String
    public let event: String
    public let host: String
    public let sessionId: String?
    public let refreshBefore: Double
    public let lastDelivery: (at: Double, ok: Bool, error: String?)?

    public static func == (a: AiSubscription, b: AiSubscription) -> Bool {
        a.id == b.id && a.keyId == b.keyId && a.event == b.event && a.host == b.host && a.sessionId == b.sessionId
            && a.refreshBefore == b.refreshBefore && a.lastDelivery?.at == b.lastDelivery?.at
            && a.lastDelivery?.ok == b.lastDelivery?.ok && a.lastDelivery?.error == b.lastDelivery?.error
    }
}

public struct AiAppsState: Equatable, Sendable {
    public let keys: [AiAccessKey]
    public let internetOn: Bool
    public let internetBase: String?
    public let relayHost: String?
    public let connected: Bool
    public let reason: String?
    public let localURL: String?
    public let movedFrom: Double?
    public let folders: [String]
    public let problem: String?
    public let delivery: [String: AiDelivery]
    public let channelBridge: String?
    public let subscriptions: [String: [AiSubscription]]

    /// `toAiAppsState`: nil for anything without a key list.
    public static func from(_ raw: CodingAIJSON) -> AiAppsState? {
        guard raw.isObject, let keys = raw["keys"].array else { return nil }
        let internet = raw["internet"]
        let local = raw["local"]
        return AiAppsState(
            keys: keys.compactMap(key),
            internetOn: internet["on"].isTrue,
            internetBase: internet["base"].text,
            relayHost: internet["relayHost"].text,
            connected: internet["connected"].isTrue,
            reason: internet["reason"].text,
            localURL: local["url"].text,
            movedFrom: local["movedFrom"].number,
            folders: (raw["folders"].array ?? []).compactMap(\.string),
            problem: raw["problem"].text,
            delivery: delivery(raw["delivery"]),
            channelBridge: raw["channelBridge"].text,
            subscriptions: subscriptions(raw["subscriptions"])
        )
    }

    private static func key(_ raw: CodingAIJSON) -> AiAccessKey? {
        guard raw.isObject, let id = raw["id"].text, let name = raw["name"].text,
              let level = AiAccessLevel(rawValue: raw["level"].string ?? "") else { return nil }
        let notify = raw["notify"]
        let mode: AiNotifyMode = notify["mode"].string == "off" ? .off : notify["mode"].string == "webhook" ? .webhook : .wait
        return AiAccessKey(
            id: id,
            name: name,
            level: level,
            askFirst: raw["askFirst"].bool != false,
            folders: raw["folders"].array.map { $0.compactMap(\.string) },
            tasks: raw["tasks"].isTrue,
            createdAt: raw["createdAt"].number ?? 0,
            lastUsedAt: raw["lastUsedAt"].number,
            lastApp: raw["lastApp"].text,
            lastVia: ["this-mac", "internet"].contains(raw["lastVia"].string ?? "") ? raw["lastVia"].string : nil,
            notifyMode: mode,
            notifyURL: notify["url"].text,
            hasSecret: notify["hasSecret"].isTrue
        )
    }

    private static func delivery(_ raw: CodingAIJSON) -> [String: AiDelivery] {
        var out: [String: AiDelivery] = [:]
        for (id, value) in raw.object ?? [:] {
            guard value.isObject, let state = value["state"].string,
                  ["pending", "delivered", "undelivered", "failed"].contains(state),
                  let at = value["at"].number else { continue }
            let via = value["via"].string
            out[id] = AiDelivery(
                state: state,
                at: at,
                via: ["wait", "webhook", "list", "event"].contains(via ?? "") ? via : nil,
                error: value["error"].text,
                outstanding: Int(value["outstanding"].number ?? 0)
            )
        }
        return out
    }

    private static func subscriptions(_ raw: CodingAIJSON) -> [String: [AiSubscription]] {
        var out: [String: [AiSubscription]] = [:]
        for (keyId, value) in raw.object ?? [:] {
            guard let list = value.array else { continue }
            let rows: [AiSubscription] = list.compactMap { item in
                guard item.isObject, let id = item["id"].text, let event = item["event"].text,
                      let host = item["host"].text, let refresh = item["refreshBefore"].number else { return nil }
                let last = item["lastDelivery"]
                return AiSubscription(
                    id: id, keyId: keyId, event: event, host: host,
                    sessionId: item["sessionId"].text,
                    refreshBefore: refresh,
                    lastDelivery: last.isObject && last["at"].number != nil
                        ? (at: last["at"].number!, ok: last["ok"].isTrue, error: last["error"].text)
                        : nil
                )
            }
            if !rows.isEmpty { out[keyId] = rows }
        }
        return out
    }
}

/// `toAiAppsResult`.
public struct AiAppsResult: Equatable, Sendable {
    public let ok: Bool
    public let message: String?
    public let state: AiAppsState?
    public let key: String?
    public let id: String?
    public let secret: String?

    public static func from(_ raw: CodingAIJSON) -> AiAppsResult {
        let ok = raw["ok"].isTrue
        return AiAppsResult(
            ok: ok,
            message: raw["message"].text ?? (ok ? nil : "That did not go through, and the app did not say why."),
            state: AiAppsState.from(raw["state"]),
            key: raw["key"].text,
            id: raw["id"].text,
            secret: raw["secret"].text
        )
    }
}

// MARK: - The lines on screen

public enum AiAppsLines {
    /// `ago`.
    public static func ago(_ at: Double, now: Double) -> String {
        let seconds = max(0, ((now - at) / 1000).rounded())
        if seconds < 45 { return "just now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "a minute ago" : "\(minutes) minutes ago" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return hours == 1 ? "an hour ago" : "\(hours) hours ago" }
        let days = Int((Double(hours) / 24).rounded())
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days) days ago" }
        return format(at, template: "yMd")
    }

    /// `usedLine`.
    public static func used(_ key: AiAccessKey, now: Double) -> String {
        guard let last = key.lastUsedAt else { return "Not used yet" }
        var parts = ["Last used \(ago(last, now: now))"]
        if let app = key.lastApp { parts.append("by \(app)") }
        if key.lastVia == "internet" { parts.append("over the internet") } else if key.lastVia == "this-mac" { parts.append("on this Mac") }
        return parts.joined(separator: " ")
    }

    /// `folderSummary`.
    public static func folders(_ folders: [String]?) -> String {
        guard let folders, !folders.isEmpty else { return "Sessions in any project" }
        let names = folders.map { folder in
            folder.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? folder
        }
        return "Sessions only in \(names.joined(separator: ", "))"
    }

    /// The second line under a key: where it may work, and for Full control whether it asks first.
    public static func scope(_ key: AiAccessKey) -> String {
        folders(key.folders) + (key.level == .full ? (key.askFirst ? " · Asks before big changes" : " · Big changes without asking") : "")
    }

    /// `deliveryLine`.
    public static func delivery(_ last: AiDelivery?, now: Double) -> String? {
        guard let last else { return nil }
        let when = ago(last.at, now: now)
        let waiting = last.outstanding == 1 ? "1 the app has not marked as handled" : "\(last.outstanding) the app has not marked as handled"
        switch last.state {
        case "delivered":
            let by = last.via == "webhook" ? " by webhook" : last.via == "event" ? ", pushed to the app" : ""
            return "Last notification delivered \(when)\(by)\(last.outstanding > 0 ? " · \(waiting)" : "")"
        case "pending":
            return "A notification is waiting to be collected (\(when))"
        case "failed":
            return "Last delivery failed \(when), trying again\(last.error.map { ": \($0)" } ?? "")"
        default:
            return "Not delivered after four tries (\(when)) — kept until the app collects it"
        }
    }

    /// `EVENT_LABELS`.
    public static func event(_ name: String) -> String {
        switch name {
        case "session.turn_finished": return "a turn finishes"
        case "session.needs_input": return "a session needs an answer"
        case "session.exited": return "a session exits"
        default: return name
        }
    }

    /// `subscriptionLine`.
    public static func subscription(_ row: AiSubscription, now: Double) -> String {
        let which = row.sessionId == nil ? "" : " (one session)"
        let time = format(row.refreshBefore, template: "hhmm")
        let sameDay = Calendar.current.isDate(date(row.refreshBefore), inSameDayAs: date(now))
        let renews = sameDay ? time : "\(format(row.refreshBefore, template: "EEE")) \(time)"
        var parts = ["Pushes to \(row.host) when \(event(row.event))\(which)", "ends at \(renews) unless the app renews it"]
        if let last = row.lastDelivery {
            parts.append(last.ok
                ? "last push \(ago(last.at, now: now))"
                : "last push failed \(ago(last.at, now: now))\(last.error.map { ": \($0)" } ?? "")")
        }
        return parts.joined(separator: " · ")
    }

    /// `pushSummary`.
    public static func pushes(_ rows: [AiSubscription]) -> String? {
        guard !rows.isEmpty else { return nil }
        let hosts = unique(rows.map(\.host)).joined(separator: ", ")
        let what = unique(rows.map { event($0.event) })
        return "Pushed to \(hosts) when \(what.joined(separator: ", or when "))"
    }

    /// The Internet reach row's help line.
    public static func internetHelp(_ state: AiAppsState) -> String {
        let relay = state.relayHost ?? "the relay"
        let status = !state.internetOn
            ? "Off. Only apps on this Mac can connect."
            : state.connected
                ? "On. Apps on the web reach this Mac through \(relay)."
                : "On, but this Mac is not connected to the relay right now."
        return "\(status) Unlike your phone’s connection, this traffic can be read at the relay."
    }

    /// The Internet reach row's ⓘ.
    public static func internetMore(_ state: AiAppsState) -> String {
        let relay = state.relayHost ?? "the relay"
        return "Claude and ChatGPT on the web can only reach this Mac through the relay at \(relay), the same one your phone uses. "
            + "Unlike your phone’s connection, this one is not sealed end to end: the relay can read what an app asks and what comes back. "
            + "If that matters to you, run your own relay and point this app at it. Turning this off stops every internet key at once; keys on this Mac keep working."
    }

    public static func askFirstHelp(_ on: Bool) -> String {
        on ? "Your Mac and your phone show the question. No answer in 45 seconds means no."
           : "Off: big changes run without asking. Each one is still in the activity log."
    }

    public static let askFirstMore = "Big changes are things like changing a setting or stopping a session. Your phone shows the question while the app is open on it."

    public static func tasksHelp(_ on: Bool, limited: Bool) -> String {
        on ? (limited ? "This app can read and change your tasks whose project folder is one of its folders." : "This app can read and change your tasks.")
           : "This app cannot see your tasks."
    }

    public static let tasksMore = "What it may change still follows what this key may do and whether it asks first. Deleting puts a task in the Trash; nothing is removed for good."

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    private static func format(_ ms: Double, template: String) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date(ms))
    }
}

// MARK: - Setting a key up in an app

public enum AiApp: String, Sendable, CaseIterable, Identifiable {
    case claudeWeb = "claude-web", chatgpt, claudeCode = "claude-code", codex, gemini, cursor, vscode
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .claudeWeb: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        }
    }

    public var web: Bool { self == .claudeWeb || self == .chatgpt }
}

public enum AiSetupWhere: String, Sendable { case thisMac = "this-mac", elsewhere }

public struct AiSetup: Equatable, Sendable {
    public struct Extra: Equatable, Sendable {
        public let title: String
        public let steps: [String]
        public let snippet: String
        public let caution: String
    }
    public let steps: [String]
    public let snippet: String?
    public let missing: String?
    public let needsInternet: Bool
    public let after: String?
    public let extra: Extra?
}

public enum AiAppsSetup {
    public static func secretLink(_ internetBase: String, key: String) -> String { "\(internetBase)/\(key)" }

    /// `setupFor`.
    public static func setup(_ app: AiApp, key: String, name: String, internetBase: String?, localURL: String?,
                             where place: AiSetupWhere, channelBridge: String?) -> AiSetup {
        let bearer = "Bearer \(key)"
        if app.web {
            let link = internetBase.map { secretLink($0, key: key) }
            let missing = link == nil ? "This Mac is not connected to a relay, so there is no internet link to give yet." : nil
            if app == .claudeWeb {
                return AiSetup(
                    steps: [
                        "In Claude on the web or in the Claude desktop app, open Settings, then Connectors, and choose Add custom connector.",
                        "Name it “\(name)” and paste the link below as the server URL. Leave the advanced settings empty.",
                        "In a chat, switch it on from the tools menu.",
                    ],
                    snippet: link, missing: missing, needsInternet: true, after: nil, extra: nil)
            }
            return AiSetup(
                steps: [
                    "In ChatGPT, open Settings, then Security and login, and turn on Developer mode.",
                    "Go to ChatGPT Plugins (chatgpt.com/plugins) and select the plus button. Name it “\(name)”, paste the link below as the MCP server URL, and choose No Authentication.",
                    "Create it and check the tools it found. In a chat, choose Developer mode from the plus menu and pick this app.",
                ],
                snippet: link, missing: missing, needsInternet: true, after: AiAppsCopy.chatgptPushSentence, extra: nil)
        }

        let url: String?
        let needsInternet: Bool
        let missing: String?
        if place == .elsewhere {
            url = internetBase
            needsInternet = true
            missing = internetBase == nil ? "This Mac is not connected to a relay, so there is no internet address to give yet." : nil
        } else {
            url = localURL
            needsInternet = false
            missing = localURL == nil ? "The tools are not running on this Mac right now. Restart the app." : nil
        }
        let server = AiAppsCopy.serverKey
        func made(_ steps: [String], _ snippet: String?, extra: AiSetup.Extra? = nil) -> AiSetup {
            AiSetup(steps: steps, snippet: snippet, missing: missing, needsInternet: needsInternet,
                    after: AiAppsCopy.idleSentence, extra: extra)
        }
        switch app {
        case .claudeCode:
            var extra: AiSetup.Extra?
            if place == .thisMac, let bridge = channelBridge, let url {
                extra = AiSetup.Extra(
                    title: "Optional: let Claude Code hear about your sessions on its own",
                    steps: ["Add the notification channel, then start Claude Code with the second line. Messages about your sessions then arrive in the conversation by themselves."],
                    snippet: [
                        "claude mcp add --scope user \(AiAppsCopy.channelServer) \\",
                        "  -e NOTIFY_URL=\(url) \\",
                        "  -e NOTIFY_KEY=\(key) \\",
                        bridge.hasSuffix("/TerminalDeckNativeHelper")
                            ? "  -- \"\(bridge)\" --notify-channel"
                            : "  -- node \"\(bridge)\"",
                        "claude --dangerously-load-development-channels server:\(AiAppsCopy.channelServer)",
                    ].joined(separator: "\n"),
                    caution: "Channels are a Claude Code preview: it shows a warning when it starts, needs a Claude account login, and a work or school organisation has to allow them. Without it, notifications_wait still works.")
            }
            return made(
                ["Run this in a terminal. It adds the tools for every folder you open Claude Code in."],
                url.map { ["claude mcp add --scope user --transport http \(server) \\", "  \($0) \\", "  --header \"Authorization: \(bearer)\""].joined(separator: "\n") },
                extra: extra)
        case .codex:
            return made(
                ["Add this to ~/.codex/config.toml, then start Codex again."],
                url.map { ["[mcp_servers.\(server)]", "url = \"\($0)\"", "http_headers = { \"Authorization\" = \"\(bearer)\" }"].joined(separator: "\n") })
        case .gemini:
            return made(
                ["Add this to ~/.gemini/settings.json. If the file already has an mcpServers block, add just the inner entry to it."],
                url.map { JSPretty.text(.object([("mcpServers", .object([(server, .object([("httpUrl", .string($0)), ("headers", .object([("Authorization", .string(bearer))]))]))]))])) })
        case .cursor:
            return made(
                ["Add this to ~/.cursor/mcp.json, or paste it under Cursor Settings, then MCP."],
                url.map { JSPretty.text(.object([("mcpServers", .object([(server, .object([("url", .string($0)), ("headers", .object([("Authorization", .string(bearer))]))]))]))])) })
        case .vscode:
            return made(
                ["Add this to .vscode/mcp.json in a project, or to your user MCP configuration for every project."],
                url.map { JSPretty.text(.object([("servers", .object([(server, .object([("type", .string("http")), ("url", .string($0)), ("headers", .object([("Authorization", .string(bearer))]))]))]))])) })
        case .claudeWeb, .chatgpt:
            return AiSetup(steps: [], snippet: nil, missing: missing, needsInternet: needsInternet, after: nil, extra: nil)
        }
    }
}

/// `JSON.stringify(value, null, 2)` for an object of strings, keys in the order written.
public enum JSPretty {
    public indirect enum Value {
        case string(String)
        case object([(String, Value)])
    }

    public static func text(_ value: Value, indent: Int = 0) -> String {
        switch value {
        case .string(let text): return quote(text)
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            let pad = String(repeating: "  ", count: indent + 1)
            let close = String(repeating: "  ", count: indent)
            let body = pairs.map { "\(pad)\(quote($0.0)): \(text($0.1, indent: indent + 1))" }.joined(separator: ",\n")
            return "{\n\(body)\n\(close)}"
        }
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
