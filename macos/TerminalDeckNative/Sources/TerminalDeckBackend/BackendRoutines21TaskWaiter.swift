import Foundation
import TerminalDeckNativeCore

/// Reads the owner's saved result when it announces a change. The subscription is installed before starting
/// the job; a second read after its id arrives catches jobs that finish during their launch.
public enum BackendRoutines21TaskWaiter {
    public typealias Read = @Sendable (String) async throws -> BackendRoutinesRunOutcome?
    public typealias Subscribe = @Sendable (@escaping @Sendable () async -> Void) async throws -> NativeRPCSubscription

    /// U66 (18 Oct): with `late`, the hour stops the waiting, never the work. A routine's agent may need longer:
    /// the run reports `stillRunning` at once, the task goes on, and `late` gets its real outcome when it lands
    /// (watched for a day more; after that the answer is still on the task). Without `late` the deadline stops the job.
    public static let lateNanoseconds: UInt64 = 86_400_000_000_000
    public static func stillRunning(_ id: String) -> BackendRoutinesRunOutcome {
        .init(ok: true, output: "Still running: the agent is still working on task \(id) after an hour. The routine stopped waiting but did not stop the task; the agent's answer replaces this note when the task is done.")
    }

    public static func run(start: @escaping @Sendable () async throws -> String,
                           read: @escaping Read, subscribe: @escaping Subscribe,
                           cancellation: BackendMCPCancellation? = nil,
                           timeoutNanoseconds: UInt64 = 3_600_000_000_000,
                           stop: @escaping @Sendable (String) async -> Void = { _ in },
                           late: (@Sendable (BackendRoutinesRunOutcome) async -> Void)? = nil) async throws -> BackendRoutinesRunOutcome {
        let latch = Completion(read: read)
        let subscription = try await subscribe { await latch.changed() }
        let observer = cancellation?.observe { Task { await latch.fail(CancellationError()) } }
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            if late != nil { await latch.expire() }
            else { await latch.fail(NativeRPCError(code: "routine-job-timeout", message: "The agent did not finish its report within an hour.")) }
        }
        var id: String?
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if cancellation?.isCancelled == true { throw CancellationError() }
                let created = try await start()
                id = created
                await latch.activate(created)
                return try await latch.wait()
            } onCancel: { Task { await latch.fail(CancellationError()) } }
            deadline.cancel()
            if let observer { cancellation?.removeObserver(observer) }
            await subscription.cancelAndWait()
            if let late, let id, await latch.expired {
                // The job goes on with no deadline that could stop it; its own outcome is handed over when it lands.
                Task {
                    guard let outcome = try? await Self.run(start: { id }, read: read, subscribe: subscribe, timeoutNanoseconds: Self.lateNanoseconds) else { return }
                    await late(outcome)
                }
            }
            return result
        } catch {
            deadline.cancel()
            if let observer { cancellation?.removeObserver(observer) }
            await subscription.cancelAndWait()
            if let id { await stop(id) }
            throw error
        }
    }

    public static func taskInput(request: BackendRoutinesRunRequest, agent: NativeRPCValue) -> NativeRPCValue {
        .object([
            .init("title", .string(BackendTaskBriefComposition.utf16Prefix("Routine: " + request.routine.name, 300))),
            .init("instructions", .string(BackendTaskBriefComposition.utf16Prefix(
                "This task comes from the routine \"\(request.routine.name)\". Why it ran: \(request.cause.description)\n\n" + request.routine.prompt, 20_000))),
            .init("assignee", agent["id"]), .init("project", .string(request.routine.folder))])
    }

    public static func taskOutcome(_ value: NativeRPCValue) -> BackendRoutinesRunOutcome? {
        let sessions = value["sessionId"].string.map { [$0] } ?? []
        let answer = value["result"]["answer"].string
        if value["stopped"].bool == true {
            return .init(ok: false, sessionIds: sessions, error: "The agent's task was stopped before it finished.", output: answer)
        }
        if let reason = value["result"]["check"].string {
            return .init(ok: false, sessionIds: sessions, error: reason, output: answer)
        }
        if value["failed"].bool == true || value["process"].string == "failed" {
            return .init(ok: false, sessionIds: sessions, error: value["error"].string ?? "The agent's task failed.", output: answer)
        }
        guard let answer else { return nil }
        return .init(ok: true, sessionIds: sessions, output: answer, tokens: value["tokenUsage"].number)
    }

    /// Each follow-up gets a new session and team-job history. Nothing can resume an earlier question.
    public static func freshFollowUpInput(routine: BackendRoutinesRoutine, agent: NativeRPCValue,
                                         jobID: String, specs: BackendTaskPersistence? = nil) throws -> BackendCreateSessionInput {
        var input = try BackendAgentSessionInput.make(agent: agent, folder: routine.folder,
            projectID: routine.projectID, chat: true, specs: specs)
        input.resume = false; input.resumeConversationId = nil; input.tabKey = nil
        input.origin = .copilot
        input.originRoutineId = routine.id
        input.originRunId = jobID
        input.teamJob = .init(fromID: "me", fromName: "You", agentID: agent["id"].string ?? "agent",
            agentName: agent["name"].string ?? "Agent", title: "Routine: " + routine.name + " · " + jobID)
        return input
    }

    private actor Completion {
        let read: Read
        var id: String?
        var reading = false, dirty = false, pastDeadline = false
        /// True only when the report given back is "still running" (the job goes on).
        var expired = false
        var result: Result<BackendRoutinesRunOutcome, Error>?
        var continuation: CheckedContinuation<BackendRoutinesRunOutcome, Error>?
        init(read: @escaping Read) { self.read = read }
        func activate(_ id: String) async {
            self.id = id; await changed()
            if pastDeadline { expire() }
        }
        /// The deadline passed while the job still runs: report it as still running, without stopping it.
        func expire() {
            guard result == nil else { return }
            pastDeadline = true
            guard let id else { return }
            expired = true
            resolve(.success(BackendRoutines21TaskWaiter.stillRunning(id)))
        }
        func changed() async {
            guard result == nil else { return }
            dirty = true
            guard !reading, let id else { return }
            reading = true
            defer { reading = false }
            while dirty, result == nil {
                dirty = false
                do { if let outcome = try await read(id) { resolve(.success(outcome)) } }
                catch { resolve(.failure(error)) }
            }
        }
        func fail(_ error: Error) { resolve(.failure(error)) }
        func resolve(_ value: Result<BackendRoutinesRunOutcome, Error>) {
            guard result == nil else { return }
            result = value; continuation?.resume(with: value); continuation = nil
        }
        func wait() async throws -> BackendRoutinesRunOutcome {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }
}
