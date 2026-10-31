import Foundation
import Observation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// #189 / #73: the team list is built once per change of what it is built from, not on every read,
/// and the diary looks its writers' names up once per render, not once per row.
@Suite("AGT directory cache", .serialized)
@MainActor
struct AGTDirectoryCacheTests {
    private final class Flag: @unchecked Sendable { var on = false }

    @Test func theTeamListIsBuiltOncePerChangeAndStillRedraws() {
        let store = AGTAgentsStore.shared
        let savedState = store.fixture, savedLive = store.live, savedSettings = store.fixtureAgentSettings
        defer { store.fixture = savedState; store.live = savedLive; store.fixtureAgentSettings = savedSettings }
        store.fixture = TasksState(agents: [AgentProfile(id: "cache-a", name: "Alpha", role: "Checks")])
        store.live = []; store.fixtureAgentSettings = [:]
        let first = store.agents, second = store.agents
        #expect(first == second)
        // Both reads hold the same storage: the second one reused the first build.
        #expect(first.withUnsafeBufferPointer { $0.baseAddress } == second.withUnsafeBufferPointer { $0.baseAddress })
        // A read answered from the cache still tells a view to redraw when an input changes.
        let changed = Flag()
        withObservationTracking { _ = store.agents } onChange: { changed.on = true }
        store.fixture?.agents.append(AgentProfile(id: "cache-b", name: "Bravo", role: "Builds"))
        #expect(changed.on)
        #expect(store.agents.contains { $0.profileID == "cache-b" })
        // A model chosen in the agent's settings shows on the next read.
        store.fixtureAgentSettings = ["cache-a": AGSAgentSettings(model: "Sonnet 5.5")]
        #expect(store.agent("cache-a")?.model == "Sonnet 5.5")
    }

    @Test func diaryRowsNameTheirWriterFromOneLookup() {
        let store = AGTAgentsStore.shared
        let savedState = store.fixture
        defer { store.fixture = savedState }
        store.fixture = TasksState(agents: [AgentProfile(id: "mt-builder", name: "MT Builder", role: "Builds")])
        func row(_ id: Int64, agent: String?) -> DeckMemoryDiaryEntry {
            .init(id: id, labels: .init(owner: .role(project: "nowhere", role: "gone"), agent: agent, date: Date(), type: "message"),
                  role: .assistant, text: "Done", author: .agent)
        }
        let rows = [row(1, agent: "mt-builder"), row(2, agent: "left-agent"), row(3, agent: nil)]
        let writers = NativeMemoryDiaryPart.Writers(rows)
        #expect(writers.name(rows[0]) == "MT Builder")
        #expect(writers.name(rows[1]) == "left-agent")
        #expect(writers.name(rows[2]) == nil)
    }
}
