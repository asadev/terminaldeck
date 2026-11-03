import Foundation
import Testing
@testable import TerminalDeckBackend

// #425: a slow session observer (a phone on a slow link) must not hold back the Mac's own
// status and finish bookkeeping; each observer hears every event, in order, on its own line.
@Suite("Session observer lines")
struct BackendSessionObserverLineTests {
    private actor Heard {
        var names: [String] = []
        func add(_ event: BackendSessionEvent) {
            switch event {
            case .data(_, let text): names.append("data:" + text)
            case .status: names.append("status")
            case .exit: names.append("exit")
            case .removed: names.append("removed")
            }
        }
    }

    @Test func outputIsHandedOverWithoutWaitingAndAnExitWaitsForEverythingBeforeIt() async {
        let heard = Heard()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let line = BackendSessionObserverLine { event in
            if case .data(_, "first") = event { for await _ in gate { break } }
            await heard.add(event)
        }
        // The observer is stuck on the first piece; posting more never waits for it.
        line.post(.data(id: "s", text: "first"))
        line.post(.data(id: "s", text: "second"))
        line.post(.status(id: "s", status: .working))
        #expect(await heard.names.isEmpty)
        open.yield()
        line.post(.exit(id: "s", exitCode: 0))
        await line.drained()
        #expect(await heard.names == ["data:first", "data:second", "status", "exit"])
    }

    @Test func aRemovedObserverHearsNothingMoreAndNeverHoldsAWaiter() async {
        let heard = Heard()
        let line = BackendSessionObserverLine { await heard.add($0) }
        line.post(.data(id: "s", text: "before"))
        await line.drained()
        line.remove()
        line.post(.data(id: "s", text: "after"))
        await line.drained()
        #expect(await heard.names == ["data:before"])
    }
}
