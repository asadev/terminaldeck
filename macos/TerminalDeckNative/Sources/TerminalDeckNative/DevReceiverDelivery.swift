#if DEBUG
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The authenticated dev door reaches the real Receiver owner. It cannot seed
/// another app copy, invent stored rows, or skip a source's authentication.
@MainActor
enum DevReceiverDelivery {
    static func deliver(_ arguments: [Any]) async throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        guard !DevReload.launchToken.isEmpty, Bundle.main.bundleIdentifier == BackendDevCopy.bundleID,
              let named = environment[NativeLaunchSwitches.dataFolder], named.hasPrefix("/"),
              let graph = NativeCompositionRoot.shared.backend else {
            throw NativeRPCError(code: "dev-receiver-unavailable", message: "The isolated dev Receiver is not ready.")
        }
        let data = URL(fileURLWithPath: named).standardizedFileURL.resolvingSymlinksInPath()
        let primary = BackendCompositionSuppliers.primaryDataDirectory(home: FileManager.default.homeDirectoryForCurrentUser).resolvingSymlinksInPath()
        guard data.path.lowercased() != primary.path.lowercased(), graph.dataRoot.standardizedFileURL.resolvingSymlinksInPath() == data,
              arguments.count == 1, let input = arguments.first as? [String: Any],
              let sourceID = input["sourceId"] as? String, BackendRCVWire.isSourceID(sourceID),
              let payload = input["payload"] as? [String: Any],
              let kind = payload["kind"] as? String, !kind.isEmpty, kind.utf8.count <= 128,
              let title = payload["title"] as? String, !title.isEmpty, title.utf8.count <= 1_200,
              let text = payload["text"] as? String, text.utf8.count <= 16_384,
              JSONSerialization.isValidJSONObject(payload) else {
            throw NativeRPCError.invalidArguments("Use an existing scratch Receiver source and a JSON payload with kind, title and text.")
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard body.count <= 65_536 else { throw NativeRPCError.invalidArguments("The dev Receiver payload is too large.") }
        var headers: [String: String] = [:]
        if let raw = input["headers"] {
            guard let fields = raw as? [String: String], fields.count <= 64,
                  fields.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16_384,
                  fields.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value.utf8.count <= 4_096
                      && !$0.key.contains(where: { $0.isNewline }) && !$0.value.contains(where: { $0.isNewline }) }) else {
                throw NativeRPCError.invalidArguments("Use bounded Receiver headers without newlines.")
            }
            headers = fields
        }
        if headers.keys.allSatisfy({ $0.lowercased() != "content-type" }) { headers["content-type"] = "application/json" }
        guard input["pathToken"] == nil || input["pathToken"] is String,
              ((input["pathToken"] as? String)?.utf8.count ?? 0) <= 512,
              let service = await BackendRCVCompositionBox.shared.service,
              let source = try await service.sources().first(where: { $0.id == sourceID }), source.source.origin == .relay,
              source.source.enabled else {
            throw NativeRPCError.invalidArguments("Choose an enabled external source in this dev copy's Receiver.")
        }
        let events = try await service.receiveLocally(sourceID: sourceID,
            opened: .init(headers: headers, pathToken: input["pathToken"] as? String, clientIP: "127.0.0.1", body: body))
        guard !events.isEmpty else { throw NativeRPCError(code: "dev-receiver-empty", message: "The source mapping did not produce a Receiver event.") }
        return ["count": events.count, "eventIds": events.map(\.id), "statuses": events.map { $0.status.rawValue }]
    }
}
#endif
