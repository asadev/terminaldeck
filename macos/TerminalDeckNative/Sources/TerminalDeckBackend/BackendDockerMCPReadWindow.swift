import Foundation
import TerminalDeckNativeCore

/// Bounded agent reads consume the same push stream the screen uses. Subscribe
/// before opening to retain early frames, and close on every exit path.
enum BackendDockerMCPReadWindow {
    static func read(tool: String, arguments: NativeRPCValue, channel: String,
                     rpc: NativeRPCContext, registry: NativeChannelRegistry) async throws -> NativeRPCValue {
        let target = try arguments["target"].requireString("target", nonempty: true)
        let stats = tool == "docker.stats" || tool == "docker.stats.open"
        let logs = tool == "docker.logs" || tool == "docker.logs.open"
        let dataChannel = logs ? "docker:logs:data" : stats ? "docker:stats:data" : "docker:events:data"
        let pair = AsyncThrowingStream<NativeRPCEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let subscription = try await registry.subscribe("*", ownerID: rpc.ownerID) { event in
            guard event.ownerID == rpc.ownerID, event.channel == dataChannel || event.channel == "docker:stream:end",
                  event.arguments.first?["target"].string == target else { return }
            if case .dropped = pair.continuation.yield(event) {
                pair.continuation.finish(throwing: NativeRPCError(code: "docker-stream-overflow", message: "The Docker read could not consume its event stream quickly enough."))
            }
        }
        defer { pair.continuation.finish(); subscription.cancel() }
        let request = arguments.removing("limit").removing("waitMilliseconds")
        let opened: NativeRPCValue
        do { opened = try await registry.invoke(channel, context: rpc, arguments: [request]) }
        catch { await subscription.cancelAndWait(); throw error }
        guard let streamID = opened["streamId"].string, !streamID.isEmpty else {
            await subscription.cancelAndWait()
            throw NativeRPCError(code: "unavailable", message: "The Docker read did not return an owned stream.")
        }
        let close: @Sendable () async throws -> Void = {
            // Cleanup is not cancelled with the read. It uses the same receipt
            // and owner, and the registry restores its TaskLocal RPC context.
            let cleanup = Task {
                let value = try await registry.invoke("docker:stream:close", context: rpc,
                                                      arguments: [.object([.init("target", .string(target)), .init("streamId", .string(streamID))])])
                guard value["ok"].bool == true else { throw NativeRPCError(code: "unavailable", message: "The temporary Docker stream could not be closed.") }
            }
            try await cleanup.value
        }
        do {
            let limit = stats ? 1 : Int(arguments["limit"].number ?? 200)
            let wait = Int(arguments["waitMilliseconds"].number ?? (!logs && !stats ? 1000 : 2000))
            let buffer = BackendDockerMCPReadBuffer(limit: limit)
            let reason = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    for try await event in pair.stream {
                        try Task.checkCancellation()
                        // Refuse broadcast events: contract streams belong to
                        // their authenticated owner, never every MCP caller.
                        guard event.ownerID == rpc.ownerID, let value = event.arguments.first,
                              value["target"].string == target, value["streamId"].string == streamID else { continue }
                        if event.channel == "docker:stream:end" {
                            if value["reason"].string == "error" {
                                throw NativeRPCError(code: value["error"]["code"].string ?? "docker-stream",
                                                     message: BackendDockerMCPMasker.text(value["error"]["message"].string ?? "The Docker stream failed."))
                            }
                            return "ended"
                        }
                        if event.channel == dataChannel, try await buffer.append(value) { return "limit" }
                    }
                    return "ended"
                }
                group.addTask { try await Task.sleep(for: .milliseconds(wait)); return "window" }
                defer { group.cancelAll() }
                return try await group.next() ?? "ended"
            }
            let records = await buffer.records()
            if stats, records.isEmpty { throw NativeRPCError(code: "unavailable", message: "The Docker engine did not provide a stats sample in the requested window.") }
            try await close()
            await subscription.cancelAndWait()
            return .object([.init("target", .string(target)), .init("records", .array(records)),
                            .init("finishedBecause", .string(reason)), .init("streamClosed", .bool(true))])
        } catch {
            try? await close()
            await subscription.cancelAndWait()
            throw error
        }
    }
}

private actor BackendDockerMCPReadBuffer {
    private let limit: Int
    private var bytes = 0
    private var values: [NativeRPCValue] = []
    init(limit: Int) { self.limit = max(1, min(256, limit)) }
    func append(_ value: NativeRPCValue) throws -> Bool {
        let safe = BackendDockerMCPMasker.value(value)
        let size = try safe.encodedJSON().count
        guard bytes + size <= 256 * 1024 else { throw NativeRPCError(code: "docker-stream-overflow", message: "The bounded Docker read exceeded its supported size. Request fewer log lines.") }
        bytes += size; values.append(safe)
        return values.count >= limit
    }
    func records() -> [NativeRPCValue] { values }
}
