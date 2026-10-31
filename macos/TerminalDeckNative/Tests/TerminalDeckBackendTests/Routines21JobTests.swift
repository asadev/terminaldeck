import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

struct Routines21JobTests {
    @Test func followUpInputsAreSeparateJobsWithoutResume() throws {
        let routine = BackendRoutinesRoutine(id: "daily", name: "Daily report", triggers: [.manual],
            folder: "/tmp/routines21-tests", prompt: "Report", unknown: ["agent-id": ["reviewer"]])
        let agent = NativeRPCValue.object([.init("id", .string("reviewer")), .init("name", .string("Reviewer")),
            .init("provider", .string("codex")), .init("account", .string("saved-account")),
            .init("model", .string("saved-model")), .init("effort", .string("high"))])
        let one = try BackendRoutines21TaskWaiter.freshFollowUpInput(routine: routine, agent: agent, jobID: "question-one")
        let two = try BackendRoutines21TaskWaiter.freshFollowUpInput(routine: routine, agent: agent, jobID: "question-two")
        #expect(one.teamJob?.title != two.teamJob?.title)
        #expect(one.teamJob?.fromID == "me")
        #expect(one.teamJob?.fromName == "You")
        #expect(one.teamJob?.agentID == "reviewer")
        #expect(one.chat == true && two.chat == true)
        #expect(one.resume == false && two.resume == false)
        #expect(one.resumeConversationId == nil && two.resumeConversationId == nil)
        #expect(one.tabKey == nil && two.tabKey == nil)
        #expect(one.profileId == "saved-account" && one.model == "saved-model" && one.effort == "high")
        var longRoutine = routine
        longRoutine.name = String(repeating: "🦉", count: 400)
        longRoutine.prompt = String(repeating: "🦉", count: 11_000)
        let task = BackendRoutines21TaskWaiter.taskInput(request: .init(routine: longRoutine, runId: "long",
            cause: .manual(by: "user"), chain: []), agent: agent)
        #expect((task["title"].string?.utf16.count ?? 0) <= 300)
        #expect((task["instructions"].string?.utf16.count ?? 0) <= 20_000)
        #expect(task["assignee"].string == "reviewer" && task["project"].string == routine.folder)
    }

    @Test func reportThatFinishesDuringLaunchIsNotMissed() async throws {
        let fake = Routines21JobFake(), changes = BackendCompositionChangeHub()
        let answer = try await BackendRoutines21TaskWaiter.run(start: {
            await fake.complete("first", .init(ok: true, output: "Everything is ready."))
            await changes.fire() // This change arrives before start returns the id.
            return "first"
        }, read: { await fake.read($0) }, subscribe: { await changes.observe($0) })
        #expect(answer.output == "Everything is ready.")
        #expect(answer.ok)
        #expect(await fake.reads == 1)
    }

    @Test func waitsForReportAndStopsReadingAfterCompletion() async throws {
        let fake = Routines21JobFake(), changes = BackendCompositionChangeHub()
        let job = Task {
            try await BackendRoutines21TaskWaiter.run(start: { "second" }, read: { await fake.read($0) },
                subscribe: { await changes.observe($0) })
        }
        await fake.waitForFirstRead()
        #expect(await fake.reads == 1)
        await fake.complete("second", .init(ok: true, output: "Found three changes."))
        await changes.fire()
        let result = try await job.value
        #expect(result.output == "Found three changes.")
        #expect(await fake.reads == 2)
        await changes.fire()
        #expect(await fake.reads == 2)
    }

    @Test func independentQuestionJobsKeepTheirOwnAnswers() async throws {
        let fake = Routines21JobFake(), changes = BackendCompositionChangeHub()
        await fake.complete("one", .init(ok: true, sessionIds: ["one"], output: "First answer"))
        await fake.complete("two", .init(ok: true, sessionIds: ["two"], output: "Second answer"))
        let first = try await BackendRoutines21TaskWaiter.run(start: { "one" }, read: { await fake.read($0) }, subscribe: { await changes.observe($0) })
        let second = try await BackendRoutines21TaskWaiter.run(start: { "two" }, read: { await fake.read($0) }, subscribe: { await changes.observe($0) })
        #expect(first.sessionIds == ["one"] && second.sessionIds == ["two"])
        #expect(first.output == "First answer" && second.output == "Second answer")
    }

    @Test func changeDuringAReadTriggersAnotherRead() async throws {
        let fake = Routines21JobFake(), changes = BackendCompositionChangeHub()
        await fake.holdFirstRead()
        let job = Task {
            try await BackendRoutines21TaskWaiter.run(start: { "racing-job" }, read: { await fake.read($0) },
                subscribe: { await changes.observe($0) })
        }
        await fake.waitForFirstRead()
        await fake.complete("racing-job", .init(ok: true, output: "The final report arrived during the read."))
        await changes.fire()
        await fake.releaseFirstRead()
        let answer = try await job.value
        #expect(answer.output == "The final report arrived during the read.")
        #expect(await fake.reads == 2)
    }

    @Test func taskOutcomeRequiresAnswerAndKeepsFailureOrStop() throws {
        let waiting = NativeRPCValue.object([.init("id", .string("task")), .init("sessionId", .string("session")), .init("result", .null)])
        #expect(BackendRoutines21TaskWaiter.taskOutcome(waiting) == nil)
        let completed = waiting.setting("result", .object([.init("answer", .string("Read all the reports.")), .init("check", .null)]))
        let good = try #require(BackendRoutines21TaskWaiter.taskOutcome(completed))
        #expect(good.ok && good.output == "Read all the reports.")
        #expect(good.sessionIds == ["session"])
        let failed = completed.setting("result", completed["result"].setting("check", .string("The check failed.")))
        #expect(BackendRoutines21TaskWaiter.taskOutcome(failed)?.ok == false)
        #expect(BackendRoutines21TaskWaiter.taskOutcome(failed)?.error == "The check failed.")
        #expect(BackendRoutines21TaskWaiter.taskOutcome(completed.setting("stopped", .bool(true)))?.ok == false)
    }

    @Test func cancellationStopsOnlyItsJobAndRemovesObserver() async throws {
        let fake = Routines21JobFake(), changes = BackendCompositionChangeHub(), cancellation = BackendMCPCancellation()
        let job = Task {
            try await BackendRoutines21TaskWaiter.run(start: { "cancelled-job" }, read: { await fake.read($0) },
                subscribe: { await changes.observe($0) }, cancellation: cancellation, stop: { await fake.stopped($0) })
        }
        await fake.waitForFirstRead()
        cancellation.cancel()
        do { _ = try await job.value; Issue.record("A cancelled job returned a report.") }
        catch { #expect(error is CancellationError) }
        #expect(await fake.stops == ["cancelled-job"])
        await changes.fire()
        #expect(await fake.reads == 1)
    }

    @Test func deadlineStopsItsJobAndRemovesObserver() async throws {
        let fake = Routines21JobFake(), changes = BackendCompositionChangeHub()
        do {
            _ = try await BackendRoutines21TaskWaiter.run(start: { "late-job" }, read: { await fake.read($0) },
                subscribe: { await changes.observe($0) }, timeoutNanoseconds: 10_000_000, stop: { await fake.stopped($0) })
            Issue.record("An unfinished job returned a report.")
        } catch { #expect((error as? NativeRPCError)?.code == "routine-job-timeout") }
        #expect(await fake.stops == ["late-job"])
        await changes.fire()
        #expect(await fake.reads == 1)
    }

    // U66: a routine's agent past the hour keeps working; its answer is handed over when it lands.
    @Test func deadlineWithLateKeepsTheJobAndHandsOverItsAnswer() async throws {
        let fake = Routines21JobFake(), changes = BackendCompositionChangeHub()
        let (landed, landing) = AsyncStream<BackendRoutinesRunOutcome>.makeStream()
        let report = try await BackendRoutines21TaskWaiter.run(start: { "long-job" }, read: { await fake.read($0) },
            subscribe: { await changes.observe($0) }, timeoutNanoseconds: 10_000_000, stop: { await fake.stopped($0) },
            late: { landing.yield($0) })
        #expect(report == BackendRoutines21TaskWaiter.stillRunning("long-job"))
        await fake.complete("long-job", .init(ok: true, output: "Reviewed the week."))
        await changes.fire()
        var answers = landed.makeAsyncIterator()
        #expect(await answers.next()?.output == "Reviewed the week.")
        #expect(await fake.stops.isEmpty)
    }
}

private actor Routines21JobFake {
    var outcomes: [String: BackendRoutinesRunOutcome] = [:]
    var reads = 0
    var stops: [String] = []
    var firstRead: CheckedContinuation<Void, Never>?
    var hold = false
    var heldRead: CheckedContinuation<Void, Never>?
    func complete(_ id: String, _ outcome: BackendRoutinesRunOutcome) { outcomes[id] = outcome }
    func read(_ id: String) async -> BackendRoutinesRunOutcome? {
        let snapshot = outcomes[id]
        reads += 1; firstRead?.resume(); firstRead = nil
        if hold, reads == 1 { await withCheckedContinuation { heldRead = $0 } }
        return snapshot
    }
    func holdFirstRead() { hold = true }
    func releaseFirstRead() { heldRead?.resume(); heldRead = nil }
    func stopped(_ id: String) { stops.append(id) }
    func waitForFirstRead() async {
        if reads > 0 { return }
        await withCheckedContinuation { firstRead = $0 }
    }
}
