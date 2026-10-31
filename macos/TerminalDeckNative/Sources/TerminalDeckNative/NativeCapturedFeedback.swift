import Foundation
import TerminalDeckNativeCore

@MainActor enum NativeCapturedFeedback {
    static func chatSource(_ source: NativeRPCValue, sender: String = DeckOwner.name) throws -> NativeRPCValue {
        _ = try source.requireObject("capture source")
        // Keep the wire compatible with the persistent host's strict source schema.
        let name = source["senderName"].string ?? sender
        let fields = (source.fields ?? []).filter { !["senderName", "window"].contains($0.key) }
        let title = source["title"].string.map { " - " + $0 } ?? ""
        return NativeRPCValue.object(fields).setting("title", .string(DeckOwner.title(name) + title))
    }

    static func deliveryContext(_ context: NativeRPCValue?) throws -> NativeRPCValue? {
        guard let context, context["source"]["senderName"].string != nil || context["source"]["window"].string != nil else { return context }
        return try context.setting("source", chatSource(context["source"]))
    }

    @discardableResult static func send(sessionID: String, text: String, chatText: String? = nil, paths: [String], source: NativeRPCValue,
                                       validate: @MainActor () async throws -> Void = {}) async throws -> String? {
        let raw = try await EngineBridge.shared.invoke("session:list")
        guard let rows = raw as? [[String: Any]], let row = rows.first(where: { $0["id"] as? String == sessionID }),
              !(row["exitCode"] is NSNumber) else {
            throw NativeRPCError.invalidArguments("That session closed. Keep the capture and choose another session.")
        }
        try await validate()
        if row["chat"] as? Bool == true {
            let name = HootChatSource.session(sessionID, provider: row["provider"] as? String ?? "").agentName
            let model = NativeHootChatModel.forSession(sessionID, name: name)
            await model.start()
            return try await model.queueCapture(text: chatText ?? text, paths: paths, source: source, validate: validate)
        }
        for (index, data) in Handoff.terminalWrites(text).enumerated() {
            if index > 0 { try await Task.sleep(for: .milliseconds(Handoff.submitGapMilliseconds)) }
            try await validate()
            let result = await NativeSessionInput.send(tabId: sessionID, text: data)
            guard result.ok else { throw NativeRPCError(code: "capture-send", message: result.message ?? "The terminal refused the capture.") }
        }
        return nil
    }
}
