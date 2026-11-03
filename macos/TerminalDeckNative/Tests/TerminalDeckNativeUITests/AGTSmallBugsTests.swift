import Foundation
import Testing
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@Suite("Agents refresh races", .serialized)
@MainActor
struct AGTSmallBugsTests {
    @Test func teamChangeDuringReadIsReadAgain() async {
        let history = AGTTeamChatHistory()
        var reconciliations = 0
        history.reconcileSelection = { reconciliations += 1 }
        var reads = 0
        var resume: CheckedContinuation<Void, Never>?
        history.invoke = { channel in
            if channel == "session:team:list" {
                reads += 1
                if reads == 1 { await withCheckedContinuation { resume = $0 } }
                return [["finished": reads > 1]]
            }
            return [String: String]()
        }
        let first = Task { await history.refresh() }
        while resume == nil { await Task.yield() }
        await history.refresh()
        await history.refresh()
        resume?.resume()
        await first.value
        #expect(reads == 2)
        #expect(reconciliations == 2)
        #expect(history.rows.first?["finished"].bool == true)
    }

    @Test func olderBoardReadCannotOverwriteNewerResult() async {
        let owner = DeckMemoryOwner.role(project: "scratch", role: "builder")
        let store = AGTHandsStore(hands: [.init(seat: owner, number: 1, sessionID: "s", job: "Check", taskID: nil, startedAt: Date())])
        var resume: CheckedContinuation<Void, Never>?
        var reads = 0
        store.readBoard = { _ in
            reads += 1
            let state: DeckMemoryResultState = reads == 1 ? .reported : .verified
            if reads == 1 { await withCheckedContinuation { resume = $0 } }
            return [.init(id: "job", kind: .task, title: "Check", labels: .init(owner: owner, date: Date(), type: "job"), state: state, updatedAt: Date())]
        }
        let older = Task { await store.refreshResults() }
        while resume == nil { await Task.yield() }
        await store.refreshResults()
        resume?.resume()
        await older.value
        #expect(store.result(session: "s") == .verified)
    }

    @Test func codexWatchIncludesMissingDayAndItsParentsAcrossMidnight() {
        let home = "/scratch"
        let before = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59))!
        let after = before.addingTimeInterval(120)
        #expect(AGTDeviceWatch.folderPaths(home: home, date: before).last == home + "/.codex/sessions/2026/12/31")
        #expect(AGTDeviceWatch.folderPaths(home: home, date: after).last == home + "/.codex/sessions/2027/01/01")
        for date in [before, after] {
            let paths = AGTDeviceWatch.folderPaths(home: home, date: date)
            #expect(paths.contains(home))
            #expect(paths.contains(home + "/.codex"))
            #expect(paths.contains(home + "/.codex/sessions"))
            let day = paths.last!
            #expect(paths.contains(URL(fileURLWithPath: day).deletingLastPathComponent().path))
            #expect(paths.contains(URL(fileURLWithPath: day).deletingLastPathComponent().deletingLastPathComponent().path))
        }
    }
}
