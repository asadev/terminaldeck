#if DEBUG
import Foundation

/// Isolated QA fixture for the actual phone screens; never connects a socket,
/// stores a credential, or appears in the Release build.
@MainActor enum IOSAlignmentPreview {
    static func model() -> DeckModel {
        fixture().0
    }
    static func fixture() -> (DeckModel, IOSPreviewTransport) {
        let credentials = Credentials()
        let host = IOSPreviewTransport()
        let model = DeckModel(credentials: credentials, device: .init(name: "QA phone", platform: "ios"),
                              alerts: Alerts(), makeTransport: { _, _, _ in host })
        return (model, host)
    }

    private final class Credentials: CredentialStore {
        let record = StoredCredential(endpoint: .direct(url: URL(string: "ws://127.0.0.1:1")!),
            token: "fixture", kind: .device, deviceId: "qa", deviceName: "QA phone", pairedAt: Date(), nickname: "QA Mac")
        func all() -> [StoredCredential] { [record] }
        func load(_ hostId: String) -> StoredCredential? { hostId == record.hostId ? record : nil }
        func save(_ credential: StoredCredential) {}
        func remove(_ hostId: String) {}
        func clearAll() {}
        func deviceKeys() -> StaticKeyPair { .generate() }
    }

    private final class Alerts: AlertPresenting {
        func permission() async -> AlertPermission { .allowed }
        func request() async -> AlertPermission { .allowed }
        func present(_ alert: SessionAlert) {}
    }
}

@MainActor final class IOSPreviewTransport: Transport {
    var state = ConnectionState.offline
    let capabilities: Set<String> = ["panels", "panels.tasks", "panels.goals", "panels.memory", "device.access", "copilot", "hoot.events", "create", "close", "upload"]
    var onEvent: ((TransportEvent) -> Void)?
    private(set) var sent: [ClientMessage] = []
    private var tasks = ["Review phone layout", "Send build to release worker"]
    private var sequence = 0
    private var history: [[String: Any]] = []

    func start() {
        state = .init(phase: .online, detail: "Connected to QA fixture.", retryAt: nil, attempts: 0)
        onEvent?(.state(state))
        emit(.welcome(protocolVersion: 1, deviceId: "qa", deviceName: "QA phone", token: nil,
                      sessions: [], capabilities: capabilities, hostPlatform: .mac, hostName: "QA Mac", folders: ["/Projects/Phone", "/Projects/Deck"],
                      copilot: .init(stated: true, linked: true, open: false, grant: .init(read: true, act: true, alter: true)), appVersion: "0.19.1", hostKind: .desktop))
        emit(.phoneAccess(.init(level: .full)))
    }
    func stop() { state = .offline; onEvent?(.state(state)) }
    func resume() {}
    func emit(_ message: ServerMessage) { onEvent?(.message(message, activity: [:])) }

    @discardableResult func send(_ message: ClientMessage) -> Bool {
        sent.append(message)
        guard state.isLive else { return false }
        // A real transport is asynchronous. This also catches state code that
        // accidentally relies on the fixture replying inside send().
        Task { [weak self] in self?.answer(message) }
        return true
    }

    private func answer(_ message: ClientMessage) {
        switch message {
        case .copilotHello:
            emit(.copilotGrant(.init(stated: true, linked: true, open: true, grant: .init(read: true, act: true, alter: true))))
        case .copilotAttach:
            emit(.copilotState(.init(desk: "running", run: "chat", profile: "QA", signedIn: true, tools: 12, turnTokens: 120,
                pending: 0, grant: nil, available: true, reason: nil, interactive: true)))
            if history.isEmpty {
                append("message", id: "welcome", value: ["text": "I’m Hoot. You can review your work and talk to me here."])
                append("toolCall", id: "tool", value: ["name": "tasks_list", "input": ["project": "/Projects/Phone"]])
                append("toolResult", id: "tool", value: ["output": "2 tasks are ready to review."])
                append("completed", id: "", value: [:])
            }
            replay()
        case let .copilotSay(text):
            let previous = sequence
            append("user", id: "user:\(sequence)", value: ["text": text])
            append("message", id: "reply:\(sequence)", value: ["text": "I received your message: \(text)"])
            append("completed", id: "", value: [:])
            publish(Array(history.filter { ($0["sequence"] as? Int ?? 0) > previous }), reset: false)
            if text == "Ask a form" {
                let row: [String: Any] = ["id": "broker-form", "tool": "hoot.cli", "summary": "Tell Hoot your name", "tier": "alter", "mine": true,
                    "expiresAt": Date().timeIntervalSince1970 * 1000 + 120_000,
                    "args": ["subtype": "mcpServer/elicitation/request", "input": ["mode": "form", "requestedSchema": ["type": "object", "required": ["name"], "properties": ["name": ["type": "string", "title": "Name", "minLength": 2]]]]]]
                emit(.copilotPending([WireCodec.copilotQuestion(row)!]))
            }
        case let .copilotAnswer(id, approved, answers):
            guard id == "broker-form" else { return }
            emit(.copilotSettled(.init(id: id, granted: approved && answers?.object["name"] as? String == "Asad", by: "device:qa", reason: nil)))
            emit(.copilotPending([]))
        case .copilotPending: emit(.copilotPending([]))
        case .copilotSessions: emit(.copilotSessions([]))
        case let .panelRead(panel, path, _, _): panelRows(panel, path: path)
        case let .panelAct(panel, action, path, id, fields):
            if panel == "tasks" {
                if action == "add", let title = fields["title"], !title.isEmpty { tasks.append(title) }
                if action == "done", let id, let index = Int(id), tasks.indices.contains(index) { tasks.remove(at: index) }
            }
            panelRows(panel, path: path)
        default: break
        }
    }

    private func panelRows(_ name: String, path: String?) {
        guard let panel = PanelKind(rawValue: name) else { return }
        let rows = panel == .tasks ? tasks.enumerated().map { index, title in
            PanelRow(title: title, detail: "Ready", index: index, key: String(index), actions: [
                .init(id: "done", label: "Done"),
                .init(id: "move", label: "Move to project", fields: [.init(id: "project", label: "Project", choices: ["/Projects/Phone", "/Projects/Deck"])])
            ])
        } : [PanelRow(title: panel == .goals ? "Finish phone alignment" : "Phone decisions", detail: "From the host", index: 0)]
        let actions: [PanelAction] = panel == .tasks ? [.init(id: "add", label: "Add task", fields: [.init(id: "title", label: "Title", required: true)])] : []
        emit(.panelRows(.init(panel: panel, path: path ?? "/Projects/Phone", actions: actions, rows: rows)))
    }

    private func append(_ kind: String, id: String, value: [String: Any]) {
        sequence += 1
        history.append(["version": 1, "id": "chat:\(sequence)", "conversationId": "chat", "turnId": "turn", "sequence": sequence,
                        "provider": "claude", "kind": kind, "messageId": id, "value": value, "at": Date().timeIntervalSince1970 * 1000])
    }
    private func replay() { publish(history, reset: true) }
    private func publish(_ events: [[String: Any]], reset: Bool) {
        if let batch = HootEventBatch.decode(["conversationId": "chat", "reset": reset, "events": events]) { emit(.hootEvents(batch)) }
    }
}
#endif
