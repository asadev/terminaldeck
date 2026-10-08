import Foundation
import TerminalDeckNativeCore

public struct BackendAGSHookEvent: Sendable {
    public let id: String, event: String, subjectID: String?, test: Bool
    public init(id: String = UUID().uuidString, event: String, subjectID: String? = nil, test: Bool = false) {
        self.id = id; self.event = event; self.subjectID = subjectID; self.test = test
    }
    public var wireValue: NativeRPCValue { .object([.init("id", .string(id)), .init("event", .string(event)), .init("subjectID", subjectID.map(NativeRPCValue.string) ?? .null), .init("test", .bool(test))]) }
}
public struct BackendAGSHookResult: Sendable, Equatable {
    public let hookID: String, eventID: String, ok: Bool, message: String
    public var wireValue: NativeRPCValue { .object([.init("hookID", .string(hookID)), .init("eventID", .string(eventID)), .init("ok", .bool(ok)), .init("message", .string(message))]) }
}
/// Event-driven; no timer, poller, network connection or process until an event/test.
/// Event data is JSON in TD_HOOK_EVENT, never substituted into a shell command.
public actor BackendAGSHookRunner {
    public typealias Execute = @Sendable (AGSAppHook, BackendAGSHookEvent) async throws -> Void
    private let execute: Execute, report: @Sendable (BackendAGSHookResult) async -> Void
    private var running = 0, stopped = false
    private var jobs: [UUID: Task<Void, Error>] = [:]
    private var seen: [String] = []
    public init(execute: @escaping Execute, report: @escaping @Sendable (BackendAGSHookResult) async -> Void = { _ in }) { self.execute = execute; self.report = report }
    public func deliver(_ event: BackendAGSHookEvent, hooks: [AGSAppHook]) async -> [BackendAGSHookResult] {
        guard !stopped, AGSCapabilities.appEvents.contains(event.event), !seen.contains(event.id) else { return [] }
        seen.append(event.id); if seen.count > 512 { seen.removeFirst(seen.count - 512) }
        var results: [BackendAGSHookResult] = []
        for hook in hooks where hook.enabled && hook.event == event.event {
            let result = await run(hook, event: event); results.append(result); await report(result)
        }
        return results
    }
    /// Caller must secure explicit owner approval before calling, including for disabled hooks.
    public func test(_ hook: AGSAppHook) async -> BackendAGSHookResult {
        let event = BackendAGSHookEvent(event: hook.event, test: true)
        let result = await run(hook, event: event); await report(result); return result
    }
    public func stop() { stopped = true; seen = []; for job in jobs.values { job.cancel() }; jobs = [:] }
    private func run(_ hook: AGSAppHook, event: BackendAGSHookEvent) async -> BackendAGSHookResult {
        guard !stopped, running < 4 else { return .init(hookID: hook.id, eventID: event.id, ok: false, message: "Hook skipped because the runner is stopped or busy.") }
        running += 1; defer { running -= 1 }
        do {
            try BackendAGSValidation.check(hook); try Task.checkCancellation()
            let jobID = UUID(), execute = self.execute
            let job = Task { try await execute(hook, event) }
            jobs[jobID] = job
            defer { jobs[jobID] = nil }
            try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            return .init(hookID: hook.id, eventID: event.id, ok: true, message: "Hook finished.")
        } catch is CancellationError { return .init(hookID: hook.id, eventID: event.id, ok: false, message: "Hook cancelled.") }
        catch { return .init(hookID: hook.id, eventID: event.id, ok: false, message: "Hook failed or timed out. Check its command or webhook.") }
    }
    /// Reuses Terminal Deck's bounded, cancellable process-group primitive.
    /// No inherited secrets and no response/stdout/stderr ever leaves this executor.
    public static func local(workingFolder: String) -> Execute {
        let process = BackendDevProcessExecutor()
        return { hook, event in
            try BackendAGSValidation.check(hook)
            if let command = hook.command {
                let outcome = try await process.run(command: "/bin/zsh", arguments: ["-f", "-c", command],
                    environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TD_HOOK_EVENT": event.wireValue.compact],
                    cwd: workingFolder, timeoutMilliseconds: hook.timeoutSeconds * 1000, maximumBytes: 16 * 1024)
                guard outcome.ok, !outcome.timedOut else { throw NativeRPCError(code: "hook-failed", message: "The command did not finish successfully.") }
            } else if let address = hook.webhook, let url = URL(string: address) {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = Double(hook.timeoutSeconds)
                configuration.timeoutIntervalForResource = Double(hook.timeoutSeconds)
                configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                let session = URLSession(configuration: configuration, delegate: BackendAGSNoRedirect(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: url); request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try event.wireValue.encodedJSON()
                let (_, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw NativeRPCError(code: "hook-failed", message: "The webhook did not accept this event.") }
            }
        }
    }
}
private final class BackendAGSNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
