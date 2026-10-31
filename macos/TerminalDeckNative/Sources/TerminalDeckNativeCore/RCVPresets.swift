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
    /// A realistic payload (JSON text) this preset reads, for the field preview before anything arrives.
    public var sample: String?
    public init(id: String, name: String, help: String, symbol: String, origin: RCVOrigin = .relay, auth: RCVAuth, mapping: RCVMapping,
                reply: RCVReplyChannel? = nil, examples: [RCVRule] = [], builtIn: Bool = true, sample: String? = nil) {
        self.id = id; self.name = name; self.help = help; self.symbol = symbol; self.origin = origin; self.auth = auth
        self.mapping = mapping; self.reply = reply; self.examples = examples; self.builtIn = builtIn; self.sample = sample
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

    /// "CRM tasks": every field a CRM task carries, by the names the CRM task link sends (camelCase,
    /// CRM-LINK-SPEC.md), with the snake_case and nested (`task.…`) names a CRM webhook or a
    /// `get_task` answer uses as alternatives. Field names decide where values land in a task
    /// (RCVTaskMapping): status/priority/dates/tags/board/type/estimate fill the task's own fields,
    /// the rest become named custom fields. Still reads a plain CRM record (leads, deals) as before.
    public static let crmTasksMapping = RCVMapping(
        kind: "{{kind|header.x-receiver-event|event|type|\"task.changed\"}}", severity: "{{severity|\"info\"}}",
        title: "{{title|task.title|subject|name|record.name}}",
        text: "{{instructions|description|task.description|body|comment.body|message|text|note}}",
        time: "{{at|timestamp|updated_at|createdAt|created_at}}", upstreamId: "{{eventId|event_id|header.x-receiver-delivery|id}}",
        fields: [
            .init("crmTaskId", "{{externalTaskId|task.id|task_id|record.id|record_id|taskId}}"), .init("url", "{{url|task.url|record.url}}"),
            .init("status", "{{status|task.status}}"), .init("priority", "{{priority|task.priority}}"),
            .init("startDate", "{{startDate|start_date|task.start_date}}"), .init("dueDate", "{{dueDate|due_date|task.due_date}}"),
            .init("startTime", "{{startTime|start_time|task.start_time}}"), .init("dueTime", "{{dueTime|due_time|task.due_time}}"),
            .init("labels", "{{labels|tags|task.labels|page.labels}}"), .init("board", "{{board|list|task.board}}"),
            .init("taskType", "{{taskType|task_type|page.type}}"), .init("estimateMinutes", "{{estimateMinutes|time_estimate_minutes|page.time_estimate_minutes}}"),
            .init("recurrence", "{{recurrence|task.recurrence|page.recurrence_rule}}"),
            .init("assignedTo", "{{assignee|task.assignee.name|people.main.name|owner|user}}"),
            .init("requestedBy", "{{createdByName|requestedBy|author|creator|task.created_by}}"), .init("changedBy", "{{changedByName|changedBy}}"),
            .init("people", "{{people|task.people}}"), .init("followers", "{{followers}}"), .init("related", "{{related|task.related}}"),
            .init("subtasks", "{{subtasks}}"), .init("checklists", "{{checklists}}"), .init("dependencies", "{{dependencies}}"),
            .init("attachments", "{{attachments}}"), .init("customFields", "{{customFields|fields}}"),
            .init("comment", "{{comment.body|body}}"), .init("comments", "{{comments}}"), .init("mentions", "{{mentions}}"),
            .init("project", "{{project|projectId}}"),
            .init("createdAt", "{{createdAt|task.created_at}}"), .init("archivedAt", "{{archivedAt|task.archived_at}}"),
            .init("timeLogged", "{{timeLogged|page.time_logged}}"),
        ])

    /// One CRM task as the CRM task link sends it (CRM-LINK-SPEC.md): what the field preview shows before anything arrives.
    public static let crmTasksSample = #"""
    {"kind":"task.created","eventId":"iloop:create:7f3a:1","externalTaskId":"7f3a1c2e","title":"Call the Al Barari owner back","instructions":"He asked for the new valuation before Friday.","url":"https://app.iloop.ae/tasks?task=7f3a1c2e","status":"To-Do","priority":"High","startDate":"2026-10-12","dueDate":"2026-10-14","dueTime":"16:00","labels":["landlord","follow-up"],"board":"Follow-ups","taskType":"task","estimateMinutes":30,"recurrence":null,"assignee":"agent:crm-lead","requestedBy":"user:00cce220-13b4-4571-af81-662fc7198d09","people":{"main":{"id":"00cce220","name":"Asad Iqbal"},"others":[{"id":"fa155d7b","name":"Abdulbosit Pozilov"}]},"followers":[{"id":"13f86b77","name":"Abdurashid Mutalibov"}],"related":[{"area":"landlord","id":"L-1066","label":"Villa 12, Al Barari","href":"/landlords"}],"subtasks":[{"id":"s1","title":"Pull last valuation","done":true}],"checklists":[{"id":"c1","title":"Before the call","items":[{"title":"Check the tenancy end date","done":false}]}],"dependencies":[],"attachments":[{"id":"a1","fileName":"valuation.pdf","mimeType":"application/pdf","sizeBytes":182044,"url":"https://app.iloop.ae/f/a1"}],"customFields":[{"id":"f1","label":"Budget","kind":"money","value":2500000,"shown":"AED 2,500,000"}],"comments":[{"id":"m1","by":"Asad Iqbal","at":"2026-10-12T08:10:00Z","body":"Please prepare the numbers first."}],"createdAt":"2026-10-12T08:00:00Z"}
    """#

    public static let crm = RCVPreset(
        id: "crm", name: "CRM tasks", help: "In your CRM’s webhook settings, paste the address and send the secret as “Authorization: Bearer …”. Send each task with the field names in CRM-LINK-SPEC.md.",
        symbol: "person.2", auth: .init(scheme: .token), mapping: crmTasksMapping,
        reply: .init(via: .http, method: "POST", url: "https://PASTE-YOUR-CRM/receiver-reply",
                     headers: [.init("Authorization", "Bearer {{secret.reply}}"), .init("Content-Type", "application/json")],
                     body: "{\"recordId\":\"{{fields.crmTaskId}}\",\"text\":\"{{reply}}\"}"),
        sample: crmTasksSample)

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
                                .init("task", "{{task}}"), .init("project", "{{project}}"), .init("projectId", "{{projectId}}")]),
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

    /// How a built-in source reads its payload when it is first made. The Tasks source carries tasks
    /// from task links (the CRM), so it reads them with the CRM tasks fields; the rest pass
    /// Terminal Deck's own envelopes through.
    public static func internalMapping(_ sourceID: String) -> RCVMapping { sourceID == "terminaldeck.tasks" ? crmTasksMapping : terminalDeck.mapping }

    /// The payload a source's field preview uses before anything has arrived.
    public static func sample(for source: RCVSource, custom: [RCVPreset] = []) -> String? {
        source.id == "terminaldeck.tasks" ? crmTasksSample : named(source.preset, custom: custom)?.sample
    }
}
