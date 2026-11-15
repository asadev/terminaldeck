import Foundation
import TerminalDeckNativeCore

/// What lane F hands lane A (who owns the page, the sheet, the tools' registration and every switch).
/// The row is OFF until lane A's wiring builds a `BackendCloudBootFiles` and calls `start`: nothing in this lane
/// starts itself, watches a folder, or runs at launch. Wiring: `macos/night/codex/cloud-files-wiring.md`.
public enum BackendCloudBootFilesFeature {
    /// One tool, read-only. Accepting a file, or keeping this Mac's, is a press in the app's window on this Mac:
    /// there is deliberately no tool for either.
    public static let contribution = CloudFeatureContribution(owner: "F", tools: [
        CloudToolDefinition(id: "cloud.boot_files", title: "Cloud boot files",
                            description: "List the instruction, agent, skill and command files that wait on this Mac, and why. Read-only: accepting a file is done in the app's window.",
                            inputSchema: CloudValue(.object([
                                .init("type", .string("object")), .init("additionalProperties", .bool(false)),
                                .init("required", .array([.string("action")])),
                                .init("properties", .object([.init("action", .object([.init("type", .string("string")), .init("enum", .array([.string("list")]))]))]))])),
                            mutates: false, inventoryRows: [CloudBootFilesFormat.inventoryRow])
    ], inventoryRows: [CloudBootFilesFormat.inventoryRow], actions: ["boot_files.refresh"])
    /// Never declared as actions (security review S10): anything in `actions` could one day be bound as a tool.
    /// Accept and keep-mine are plain calls (`accept`, `dismiss`) that only lane A's sheet makes.
    public static let neverActions = ["boot_files.accept", "boot_files.keep_mine", "boot_files.dismiss", "boot_files.write"]
}

extension BackendCloudBootFiles {
    /// Joins the signed-in sync core: registers this adapter and starts lane A's pump from the journal to the
    /// outbox. Call `setPlaces` first (or after: files then wait and are placed when it is called).
    public func start(outbox: any CloudOutboxPort, subjectHash: String) async throws {
        guard pump == nil, self.outbox == nil else { return }
        // Set first, so a second call returns above while this one waits.
        self.outbox = outbox
        self.subjectHash = subjectHash
        do {
            try await outbox.register(adapter: self)
            await enter()
            defer { leave() }
            guard pump == nil else { return }
            let engine = try core()
            let made = try BackendCloudBrainFilesPump(engine: engine, outbox: deleteOutbox(outbox), subjectHash: subjectHash)
            await made.start()
            pump = made
        } catch {
            self.outbox = nil
            self.subjectHash = nil
            throw error
        }
    }

    /// Sign-out or a closed gate: nothing is read, sent or written after this returns. Nothing is deleted.
    public func stop() async {
        await enter()
        defer { leave() }
        let running = pump
        pump = nil
        outbox = nil
        subjectHash = nil
        await running?.stop()
    }

    /// The read-only tool `cloud.boot_files`: paths, sizes and reasons. Never a file's text.
    public func tool(arguments: CloudValue) async throws -> CloudValue {
        let value = arguments.raw
        guard let fields = value.fields, Set(fields.map(\.key)) == ["action"], value["action"].string == "list" else { throw CloudFailure.invalidRequest }
        let lines = try items().map { item in
            NativeRPCValue.object([
                .init("id", .string(item.id)), .init("kind", .string(item.kind.rawValue)), .init("place", .string(item.place.rawValue)),
                .init("identity", item.identity.map(NativeRPCValue.string) ?? .null), .init("path", .string(item.relative)),
                .init("bytes", .number(Double(item.bytes))), .init("from", .string(item.originDevice)),
                .init("reasons", .array(item.reasons.map(NativeRPCValue.string))), .init("canAccept", .bool(item.canAccept))])
        }
        return CloudValue(.object([.init("items", .array(lines)), .init("accept", .string("Accepting is done in the app's window on this Mac."))]))
    }
}

/// Boot files own their domain from the start, places or not (13 Nov two-copy proof): a Mac that chooses its project
/// folder after sign-in received the other Mac's boot files as packs waiting for a kind that never registered.
extension BackendCloudBootFiles: CloudDomainWithoutSetup {
    public nonisolated var declaredDomains: Set<String> { [CloudBootFilesFormat.domain] }
}
