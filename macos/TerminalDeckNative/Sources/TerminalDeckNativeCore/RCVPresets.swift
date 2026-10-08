import Foundation

/// A starting point for a source: how the sender proves itself, how its payload
/// maps onto the envelope, an optional way to reply, and example rules. Presets
/// are data. Every value is copied into the source and stays editable there;
/// the owner can also save any source as a new preset.
public struct RCVPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// One plain sentence on where to paste the address.
    public var help: String
    public var symbol: String
    public var origin: RCVOrigin
    public var auth: RCVAuth
    public var mapping: RCVMapping
    public var reply: RCVReplyChannel?
    /// Example rules; their `sourceIds` are filled in when the source is made.
    public var examples: [RCVRule]
    public var builtIn: Bool
    public init(id: String, name: String, help: String, symbol: String, origin: RCVOrigin = .relay, auth: RCVAuth, mapping: RCVMapping,
                reply: RCVReplyChannel? = nil, examples: [RCVRule] = [], builtIn: Bool = true) {
        self.id = id; self.name = name; self.help = help; self.symbol = symbol; self.origin = origin; self.auth = auth
        self.mapping = mapping; self.reply = reply; self.examples = examples; self.builtIn = builtIn
    }
}

public enum RCVPresets {
    /// The generic webhook: the product. Everything else is a thin variation.
    public static let generic = RCVPreset(
        id: "webhook", name: "Any webhook (JSON)", help: "Paste the address into any service that can send a webhook. Send the secret as “Authorization: Bearer …” or use the address with the secret built in.",
        symbol: "arrow.down.circle", auth: .init(scheme: .token),
        mapping: .init(kind: "{{header.x-receiver-event|event|type|\"event\"}}", severity: "{{severity|level|\"info\"}}",
                       title: "{{title|subject|summary|name}}", text: "{{message|text|body|description}}",
                       time: "{{timestamp|time|created_at}}", upstreamId: "{{header.x-receiver-delivery|header.idempotency-key|id}}"))

    public static let whapi = RCVPreset(
        id: "whapi", name: "WhatsApp (Whapi)", help: "In Whapi, open your channel’s settings and paste the address with the secret built in as the webhook URL. Choose the messages event.",
        symbol: "message", auth: .init(scheme: .token),
        mapping: .init(split: "messages", kind: "{{event.type|\"messages\"}}", severity: "{{\"info\"}}",
                       title: "{{item.from_name|item.from}}", text: "{{item.text.body|item.image.caption|item.document.caption|item.type}}",
                       time: "{{item.timestamp}}", upstreamId: "{{item.id}}",
                       fields: [.init("chat", "{{item.chat_id}}"), .init("sender", "{{item.from}}"), .init("senderName", "{{item.from_name}}"),
                                .init("messageType", "{{item.type}}"), .init("messageId", "{{item.id}}")],
                       // Our own messages come back as webhooks too; never route them.
                       ignore: [.init("item.from_me", .equals, "true")]),
        reply: .init(via: .http, method: "POST", url: "https://gate.whapi.cloud/messages/text",
                     headers: [.init("Authorization", "Bearer {{secret.reply}}"), .init("Content-Type", "application/json")],
                     body: "{\"to\":\"{{fields.chat}}\",\"body\":\"{{reply}}\"}"),
        examples: [RCVRule(id: "example-whapi-group", name: "Messages in one WhatsApp group go to a task agent",
                           conditions: [.init("fields.chat", .equals, "PASTE-GROUP-ID@g.us")],
                           target: .init(kind: .agent, id: "", threadKey: "{{fields.chat}}"),
                           instruction: "New WhatsApp message from {{fields.senderName}} in the group:\n{{text}}\n\nDo what it asks if it is part of your job, and reply in the group with receiver_reply.")])

    public static let github = RCVPreset(
        id: "github", name: "GitHub", help: "In the repository’s Settings → Webhooks, paste the address as the Payload URL, choose application/json, and paste the secret into Secret.",
        symbol: "chevron.left.forwardslash.chevron.right",
        auth: .init(scheme: .hmac, hmac: .init(header: "x-hub-signature-256", algorithm: .sha256, encoding: .hex, prefix: "sha256=")),
        mapping: .init(kind: "{{header.x-github-event}}", severity: "{{\"info\"}}",
                       title: "{{issue.title|pull_request.title|head_commit.message|zen}}",
                       text: "{{comment.body|review.body|issue.body|pull_request.body|head_commit.message}}",
                       upstreamId: "{{header.x-github-delivery}}",
                       fields: [.init("action", "{{action}}"), .init("repo", "{{repository.full_name}}"), .init("sender", "{{sender.login}}"),
                                .init("number", "{{issue.number|pull_request.number}}"),
                                .init("url", "{{comment.html_url|issue.html_url|pull_request.html_url|compare}}")]),
        reply: .init(via: .github, body: "{{reply}}", repository: "{{fields.repo}}", number: "{{fields.number}}"),
        examples: [RCVRule(id: "example-github-issue", name: "New issues become tasks",
                           conditions: [.init("kind", .equals, "issues"), .init("fields.action", .equals, "opened")],
                           target: .init(kind: .newTask, id: ""),
                           instruction: "A new issue was opened in {{fields.repo}} by {{fields.sender}}: {{title}}\n{{text}}\n{{fields.url}}\n\nLook into it and answer on the issue with receiver_reply.")])

    /// Sentry's integration-platform webhooks, as the worked example of a signed preset.
    public static let sentry = RCVPreset(
        id: "sentry", name: "Sentry", help: "In Sentry, create an internal integration, paste the address as its Webhook URL, turn on the issue and error alerts you want, and paste its Client Secret here as the secret.",
        symbol: "exclamationmark.triangle",
        auth: .init(scheme: .hmac, hmac: .init(header: "sentry-hook-signature", algorithm: .sha256, encoding: .hex, prefix: "")),
        mapping: .init(kind: "{{header.sentry-hook-resource|\"issue\"}}",
                       severity: "{{data.issue.level|data.event.level|data.error.level|\"error\"}}",
                       title: "{{data.issue.title|data.event.title|data.error.title|data.metric_alert.title}}",
                       text: "{{data.issue.culprit|data.event.culprit|data.event.message|data.error.message|data.description_text}}",
                       time: "{{data.issue.lastSeen|data.event.datetime|data.error.datetime}}",
                       upstreamId: "{{header.request-id}}",
                       fields: [.init("action", "{{action}}"), .init("project", "{{data.issue.project.slug|data.event.project|data.error.project}}"),
                                .init("issueId", "{{data.issue.id|data.event.issue_id|data.error.issue_id}}"),
                                .init("url", "{{data.issue.web_url|data.event.web_url|data.error.web_url}}"),
                                .init("rule", "{{data.triggered_rule}}")]),
        examples: [RCVRule(id: "example-sentry-new-error", name: "New error in a project → task for an agent",
                           conditions: [.init("kind", .equals, "issue"), .init("fields.action", .equals, "created"),
                                        .init("fields.project", .equals, "PASTE-PROJECT-SLUG")],
                           target: .init(kind: .newTask, id: ""),
                           instruction: "Sentry reported a new {{severity}} in {{fields.project}}: {{title}}\n{{text}}\n{{fields.url}}\n\nFind the cause in this project and propose a fix.",
                           dedupeMinutes: 60)])

    public static let crm = RCVPreset(
        id: "crm", name: "CRM", help: "In your CRM’s webhook settings, paste the address and send the secret as “Authorization: Bearer …”.",
        symbol: "person.2", auth: .init(scheme: .token),
        mapping: .init(kind: "{{event|type|\"crm\"}}", severity: "{{priority|\"info\"}}",
                       title: "{{title|subject|name|record.name}}", text: "{{message|description|body|text|note}}",
                       time: "{{timestamp|updated_at|created_at}}", upstreamId: "{{header.x-receiver-delivery|id|event_id}}",
                       fields: [.init("recordId", "{{record.id|record_id|task_id|id}}"), .init("owner", "{{owner|assignee|user}}")]),
        reply: .init(via: .http, method: "POST", url: "https://PASTE-YOUR-CRM/receiver-reply",
                     headers: [.init("Authorization", "Bearer {{secret.reply}}"), .init("Content-Type", "application/json")],
                     body: "{\"recordId\":\"{{fields.recordId}}\",\"text\":\"{{reply}}\"}"))

    /// A server or monitor posting with curl: plain text or JSON both work.
    public static let server = RCVPreset(
        id: "server", name: "Server alert", help: "From the server, send: curl -X POST -H \"Authorization: Bearer <secret>\" -d '{\"title\":\"Disk full\",\"severity\":\"error\"}' <address>",
        symbol: "server.rack", auth: .init(scheme: .token),
        mapping: .init(kind: "{{event|type|\"alert\"}}", severity: "{{severity|level|status|\"warning\"}}",
                       title: "{{title|subject|alertname|\"Server alert\"}}", text: "{{message|text|description|body}}",
                       time: "{{timestamp|time}}", upstreamId: "{{id|fingerprint}}",
                       fields: [.init("host", "{{host|hostname|instance|meta.clientIp}}"), .init("service", "{{service|job|check}}")]))

    /// Terminal Deck's own events: no address, no setup. Already envelopes, so the mapping passes them through.
    public static let terminalDeck = RCVPreset(
        id: "terminaldeck", name: "Terminal Deck", help: "Built in. Terminal Deck reports its own events here: crashed or unhealthy apps and containers, Stays Fixed results, finished tasks and servers it cannot reach.",
        symbol: "macwindow", origin: .terminalDeck, auth: .init(scheme: .none),
        mapping: .init(kind: "{{kind}}", severity: "{{severity}}", title: "{{title}}", text: "{{text}}", time: "{{time}}", upstreamId: "{{id}}",
                       fields: [.init("server", "{{server}}"), .init("app", "{{app}}"), .init("container", "{{container}}"),
                                .init("task", "{{task}}"), .init("project", "{{project}}")]),
        examples: [RCVRule(id: "example-td-crash", name: "A crashed app tells Hoot",
                           conditions: [.init("kind", .oneOf, "docker.container.died, docker.container.unhealthy, apps.deploy.failed, server.unreachable")],
                           target: .init(kind: .hoot), instruction: "{{title}}\n{{text}}\n\nCheck what happened and tell me in one line.",
                           dedupeMinutes: 30)])

    public static let all: [RCVPreset] = [generic, whapi, github, sentry, crm, server, terminalDeck]
    public static func named(_ id: String, custom: [RCVPreset] = []) -> RCVPreset? { (all + custom).first { $0.id == id } }

    /// The built-in sources for Terminal Deck's own events, made once and never deleted (only paused).
    public static let internalSources: [(id: String, name: String)] = [
        ("terminaldeck.servers", "Servers and apps"), ("terminaldeck.tasks", "Tasks"), ("terminaldeck.staysfixed", "Stays Fixed"),
    ]
    public static func isInternal(_ sourceID: String) -> Bool { sourceID.hasPrefix("terminaldeck.") }
}
