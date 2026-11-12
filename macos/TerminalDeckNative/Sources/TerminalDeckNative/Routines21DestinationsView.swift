import SwiftUI
import TerminalDeckNativeCore

struct Routines21Destination: Identifiable {
    var id = UUID().uuidString.lowercased()
    var kind = "webhook"
    var label = "Webhook"
    var url = ""
    var connectionID = ""
    var chatID = ""
    var secretHeader = "Authorization"
    var hasSecret = false
    var replacementSecret = ""
    init(kind: String = "webhook") { self.kind = kind; label = Self.title(kind) }
    init(_ value: CodingAIJSON) {
        id = value["id"].text ?? UUID().uuidString.lowercased()
        kind = value["kind"].text ?? "webhook"; label = value["label"].text ?? Self.title(kind)
        url = value["url"].text ?? ""; connectionID = value["connectionId"].text ?? ""
        chatID = value["chatId"].text ?? ""; secretHeader = value["secretHeader"].text ?? "Authorization"
        hasSecret = value["hasSecret"].isTrue
    }
    static func title(_ kind: String) -> String { ["webhook": "Webhook", "whatsapp": "WhatsApp", "telegram": "Telegram", "hoot": "Hoot"][kind] ?? kind }
    var wire: [String: Any] {
        var out: [String: Any] = ["id": id, "kind": kind, "label": label]
        if kind == "webhook" {
            out["url"] = url
            if !secretHeader.isEmpty { out["secretHeader"] = secretHeader }
            if !replacementSecret.isEmpty { out["secret"] = replacementSecret }
        }
        if kind == "whatsapp" || kind == "telegram" {
            out["connectionId"] = connectionID
            if !chatID.isEmpty { out["chatId"] = chatID }
        }
        return out
    }
    var problem: String? {
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this destination a name." }
        if kind == "webhook", URL(string: url)?.host == nil || !["http", "https"].contains(URL(string: url)?.scheme ?? "") { return "Enter a full webhook address, starting with https://." }
        if kind == "webhook", !replacementSecret.isEmpty && secretHeader.isEmpty { return "Enter a header name for the webhook secret." }
        if kind == "whatsapp" || kind == "telegram" {
            if connectionID.isEmpty { return "Choose a \(Self.title(kind)) connection." }
            if chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose or enter the chat or group to send to." }
        }
        return nil
    }
}

struct Routines21Connection: Identifiable {
    struct Chat: Identifiable { let id: String; let name: String }
    let id: String
    let kind: String
    let label: String
    let chatID: String
    let chats: [Chat]
    let ready: Bool
    var defaultChatID: String { chatID.isEmpty ? chats.first?.id ?? "" : chatID }
    init(_ value: CodingAIJSON) {
        id = value["id"].text ?? ""; kind = value["kind"].text ?? ""; label = value["label"].text ?? Routines21Destination.title(kind)
        chatID = value["chatId"].text ?? ""
        ready = value["hasSecret"].isTrue
        chats = (value["chats"].array ?? []).compactMap { chat in
            guard let id = chat["id"].text, !id.isEmpty else { return nil }
            return Chat(id: id, name: chat["name"].text ?? id)
        }
    }
}

@MainActor @Observable final class Routines21DestinationsModel {
    var destinations: [Routines21Destination] = []
    var connections: [Routines21Connection] = []
    var loading = true
    var loadFailed = false
    var problem: String?
    var testStatus: [String: String] = [:]
    var testing: String?
    var adding = false
    var newLabel = "Telegram"
    var newToken = ""
    var newChatID = ""
    var fixture = false
    let routineID: String
    @ObservationIgnored var call: @MainActor (String, [Any?]) async throws -> CodingAIJSON
    init(routineID: String, call: @escaping @MainActor (String, [Any?]) async throws -> CodingAIJSON) { self.routineID = routineID; self.call = call }
    func load(existing: Bool) async {
        guard !fixture else { return }
        problem = nil; loadFailed = false
        do {
            connections = ((try await call("routines:connections", [])).array?.map(Routines21Connection.init) ?? []).filter(\.ready)
            if existing { destinations = (try await call("routines:destinations", [routineID])).array?.map(Routines21Destination.init) ?? [] }
            loading = false
        } catch { loading = false; loadFailed = true; problem = "Couldn’t read result destinations. Try again." }
    }
    func add(_ kind: String) {
        if kind == "hoot", destinations.contains(where: { $0.kind == "hoot" }) { return }
        var next = Routines21Destination(kind: kind)
        if let connection = connections.first(where: { $0.kind == kind }) { next.connectionID = connection.id; next.chatID = connection.defaultChatID }
        destinations.append(next)
    }
    func addTelegram() async {
        guard !newToken.isEmpty, !newChatID.isEmpty, !adding else { return }
        adding = true; problem = nil; defer { adding = false }
        do {
            let raw = try await call("routines:add-connection", [["kind": "telegram", "label": newLabel, "botToken": newToken, "chatId": newChatID]])
            let connection = Routines21Connection(raw)
            guard !connection.id.isEmpty else { problem = "The Telegram connection did not save."; return }
            connections.append(connection)
            for index in destinations.indices where destinations[index].kind == "telegram" && destinations[index].connectionID.isEmpty {
                destinations[index].connectionID = connection.id; destinations[index].chatID = newChatID
            }
            newToken = ""; newChatID = ""
        } catch { newToken = ""; problem = "The Telegram connection did not save. Try again." }
    }
    func test(_ destination: Routines21Destination) async {
        guard testing == nil else { return }
        if let reason = destination.problem { testStatus[destination.id] = reason; return }
        testing = destination.id; defer { testing = nil }
        do {
            let saved = try await call("routines:set-destinations", [routineID, destinations.map(\.wire)])
            guard saved["ok"].bool != false else { testStatus[destination.id] = "Result destinations did not save. The test was not sent."; return }
            let result = try await call("routines:test-destination", [routineID, destination.id])
            testStatus[destination.id] = result["status"].text == "sent" ? "Test message sent." : "Not sent: " + (result["message"].text ?? "Try again later.")
            for index in destinations.indices { if !destinations[index].replacementSecret.isEmpty { destinations[index].hasSecret = true; destinations[index].replacementSecret = "" } }
        } catch { testStatus[destination.id] = "The test message could not be sent." }
    }
}

struct Routines21DestinationsView: View {
    @Bindable var model: Routines21DestinationsModel
    var canTest = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Send results to").font(.headline)
                Spacer()
                Menu("Add destination") {
                    NativeSessionButton("Webhook") { model.add("webhook") }
                    if model.connections.contains(where: { $0.kind == "whatsapp" }) { NativeSessionButton("WhatsApp") { model.add("whatsapp") } }
                    // Telegram is always offered: with no connection yet, its row carries the form that adds one.
                    NativeSessionButton("Telegram") { model.add("telegram") }
                }.controlSize(.small)
            }
            Text("Every run stays in its report chat. Choose any extra places to send it.").font(.callout).foregroundStyle(.secondary)
            Toggle("Report to Hoot when done", isOn: Binding(get: { model.destinations.contains { $0.kind == "hoot" } }, set: { on in if on { model.add("hoot") } else { model.destinations.removeAll { $0.kind == "hoot" } } }))
            if model.loading { ProgressView("Reading connections…").controlSize(.small) }
            else if model.destinations.isEmpty { Text("None selected. Use Add destination to send reports elsewhere.").font(.caption).foregroundStyle(.secondary) }
            ForEach($model.destinations) { $destination in
                if destination.kind != "hoot" { destinationRow($destination) }
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(ROUTINESKit.bad) }
        }
    }
    private func destinationRow(_ binding: Binding<Routines21Destination>) -> some View {
        let destination = binding.wrappedValue
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Routines21Destination.title(destination.kind)).font(.callout.weight(.semibold))
                Spacer()
                NativeSessionButton { model.destinations.removeAll { $0.id == destination.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Remove destination").accessibilityLabel("Remove \(destination.label)")
            }
            NativeSessionTextField("Destination name", text: binding.label).textFieldStyle(.roundedBorder)
            if destination.kind == "webhook" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Webhook address").font(.caption).foregroundStyle(.secondary)
                    NativeSessionTextField("https://…", text: binding.url).textFieldStyle(.roundedBorder)
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Secret header name").font(.caption).foregroundStyle(.secondary)
                        NativeSessionTextField("Authorization", text: binding.secretHeader).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Secret (optional)").font(.caption).foregroundStyle(.secondary)
                        NativeSessionSecureField(destination.hasSecret ? "Saved · enter to replace" : "Enter secret", text: binding.replacementSecret).textFieldStyle(.roundedBorder)
                    }
                }
                if destination.hasSecret { Text("Secret saved · ••••••••").font(.caption).foregroundStyle(.secondary) }
            } else {
                let choices = model.connections.filter { $0.kind == destination.kind }
                if choices.isEmpty, destination.kind == "telegram" {
                    telegramConnectionForm
                } else if choices.isEmpty {
                    Text("Add a Whapi connection in Receiver first, then reopen this routine.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Connection", selection: binding.connectionID) {
                        if destination.connectionID.isEmpty { Text("Choose a connection").tag("") }
                        ForEach(choices) { connection in Text(connection.label).tag(connection.id) }
                    }.onChange(of: destination.connectionID) { _, id in
                        if let connection = choices.first(where: { $0.id == id }) { binding.wrappedValue.chatID = connection.defaultChatID }
                    }
                    chatPicker(destination, binding: binding, connections: choices)
                }
            }
            if canTest {
                HStack { NativeSessionButton(model.testing == destination.id ? "Sending…" : "Send test message") { Task { await model.test(destination) } }.disabled(model.testing != nil); if let status = model.testStatus[destination.id] { Text(status).font(.caption).foregroundStyle(.secondary) } }
                Text("Sending a test also saves these result destinations.").font(.caption).foregroundStyle(.secondary)
            } else { Text("Save the routine before sending a test message.").font(.caption).foregroundStyle(.secondary) }
        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
    private var telegramConnectionForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a Telegram connection").font(.caption.weight(.semibold))
            NativeSessionTextField("Connection name", text: $model.newLabel).textFieldStyle(.roundedBorder)
            NativeSessionSecureField("Bot token (from @BotFather)", text: $model.newToken).textFieldStyle(.roundedBorder)
            NativeSessionTextField("Telegram chat ID", text: $model.newChatID).textFieldStyle(.roundedBorder)
            NativeSessionButton(model.adding ? "Adding…" : "Add connection") { Task { await model.addTelegram() } }
                .controlSize(.small).disabled(model.adding || model.newToken.isEmpty || model.newChatID.isEmpty)
        }
    }
    @ViewBuilder private func chatPicker(_ destination: Routines21Destination, binding: Binding<Routines21Destination>, connections: [Routines21Connection]) -> some View {
        let chats = connections.first { $0.id == destination.connectionID }?.chats ?? []
        if !chats.isEmpty {
            Picker("Chat or group", selection: binding.chatID) {
                ForEach(chats) { chat in Text(chat.name).tag(chat.id) }
                if !destination.chatID.isEmpty, !chats.contains(where: { $0.id == destination.chatID }) { Text("Other chat ID").tag(destination.chatID) }
                Text("Enter another chat ID…").tag("")
            }
        }
        if chats.isEmpty || !chats.contains(where: { $0.id == destination.chatID }) {
            NativeSessionTextField(destination.kind == "whatsapp" ? "Chat or group ID" : "Telegram chat ID", text: binding.chatID)
        }
    }
}
