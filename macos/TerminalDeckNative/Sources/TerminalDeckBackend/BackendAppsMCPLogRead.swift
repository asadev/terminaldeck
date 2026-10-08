import Foundation
import TerminalDeckNativeCore

/// The MCP result is a bounded read, never a stream that outlives its call.
enum BackendAppsMCPLogRead {
    static func read(registry: NativeChannelRegistry, context: NativeRPCContext, caller: BackendMCPCallContext,
                     arguments: NativeRPCValue, windowMilliseconds: Int) async throws -> NativeRPCValue {
        guard (1...5_000).contains(windowMilliseconds), await registry.has("apps:logs:unwatch") else {
            throw NativeRPCError(code: "unavailable", message: "Live app logs require an owned stream cleanup operation.")
        }
        let complete = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let batch = BackendAppsMCPLogBatch(ownerID: context.ownerID, arguments: arguments, completed: complete.continuation)
        let subscription = try await registry.subscribe("apps:logs", ownerID: context.ownerID) { event in await batch.receive(event) }
        let endSubscription: NativeRPCSubscription
        do {
            endSubscription = try await registry.subscribe("apps:logs:end", ownerID: context.ownerID) { event in await batch.receive(event) }
        } catch {
            await subscription.cancelAndWait()
            complete.continuation.finish()
            throw error
        }
        // Even a failing watch can have acquired a stream before its error.
        // Attempt cleanup in every exit path, and await listener teardown.
        do {
            let started = try await registry.invoke("apps:logs:watch", context: context, arguments: [arguments])
            guard started["streamId"] == arguments["streamId"] else {
                throw NativeRPCError(code: "unavailable", message: "The app log stream did not return its requested identity.")
            }
            try await BackendDockerMCPAccess.cancellable(caller.cancellation) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await Task.sleep(for: .milliseconds(windowMilliseconds)) }
                    group.addTask { for await _ in complete.stream { return } }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            }
            // An owned end event confirms the engine has already released
            // the stream. A second unwatch would wrongly reject normal EOF.
            if await batch.endReason() == nil { try await stop(registry: registry, context: context, arguments: arguments) }
            await subscription.cancelAndWait()
            await endSubscription.cancelAndWait()
            complete.continuation.finish()
            return await batch.value()
        } catch {
            // A cancelled parent task cannot run an RPC invoke. The detached
            // cleanup has the SAME authenticated ticket and no new authority.
            // Composition must permit owner release after ticket cancellation.
            let ended = await batch.endReason()
            if ended == nil { try? await stop(registry: registry, context: context, arguments: arguments) }
            await subscription.cancelAndWait()
            await endSubscription.cancelAndWait()
            complete.continuation.finish()
            // The engine can finish a very short stream before returning its
            // watch acknowledgement, then reject that acknowledgement as
            // cancelled because its stream was already released. A matching
            // owned end event is still a real result; caller cancellation wins.
            if ended != nil, (error as? NativeRPCError)?.code == "cancelled",
               !caller.cancellation.isCancelled, !Task.isCancelled { return await batch.value() }
            throw error
        }
    }

    private static func stop(registry: NativeChannelRegistry, context: NativeRPCContext, arguments: NativeRPCValue) async throws {
        let cleanup = Task.detached {
            try await registry.invoke("apps:logs:unwatch", context: context,
                                      arguments: [.object([.init("serverId", arguments["serverId"]), .init("streamId", arguments["streamId"])])])
        }
        let result = try await cleanup.value
        guard result["stopped"].bool == true else {
            throw NativeRPCError(code: "unavailable", message: "The app log stream cleanup was not confirmed.")
        }
    }
}

private actor BackendAppsMCPLogBatch {
    private let ownerID: String
    private let arguments: NativeRPCValue
    private let completed: AsyncStream<Void>.Continuation
    private var lines: [String] = []
    private var bytes = 0
    private var truncated = false
    private var ended: String?
    init(ownerID: String, arguments: NativeRPCValue, completed: AsyncStream<Void>.Continuation) {
        self.ownerID = ownerID; self.arguments = arguments; self.completed = completed
    }
    func receive(_ event: NativeRPCEvent) {
        guard event.ownerID == ownerID, let payload = event.arguments.first,
              payload["serverId"] == arguments["serverId"], payload["appId"] == arguments["appId"],
              payload["streamId"] == arguments["streamId"] else { return }
        if event.channel == "apps:logs:end" {
            guard ended == nil, let reason = payload["reason"].string, ["closed", "eof", "error", "overflow"].contains(reason) else { return }
            ended = reason
            if reason == "overflow" { truncated = true }
            completed.yield(())
            completed.finish()
            return
        }
        guard event.channel == "apps:logs", ended == nil, let raw = payload["text"].string else { return }
        guard lines.count < 40, bytes < 64_000 else { truncated = true; return }
        let text = BackendDockerMCPMasker.text(raw)
        let remaining = 64_000 - bytes
        var kept = String(decoding: text.utf8.prefix(remaining), as: UTF8.self)
        // A partial multibyte character becomes a replacement character;
        // trim that last character if it would exceed the byte limit.
        while kept.utf8.count > remaining { kept.removeLast() }
        lines.append(kept)
        bytes += kept.utf8.count
        if kept != text { truncated = true }
        if lines.count == 40 || bytes >= 64_000 { truncated = true; completed.yield(()); completed.finish() }
    }
    func endReason() -> String? { ended }
    func value() -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("streamId", arguments["streamId"]), .init("text", .string(lines.joined())),
                                             .init("events", .number(Double(lines.count))), .init("truncated", .bool(truncated)), .init("stopped", .bool(true))]
        if let ended {
            fields.append(.init("endReason", .string(ended)))
            if ended == "error" || ended == "overflow" {
                fields.append(.init("failed", .bool(true)))
                fields.append(.init("error", .object([.init("code", .string("unavailable")),
                                                       .init("message", .string(ended == "overflow" ? "The live app log stream exceeded its safe buffer limit." : "The live app log connection ended unexpectedly."))])))
            }
        }
        return .object(fields)
    }
}
