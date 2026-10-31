import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Counts how often the window's own registered handler is reached.
private actor BackendDeckToolsS2MachinesCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Lane S2 (Machines): machine-area.test.ts, against the actual Swift composition
/// (BackendDeckToolsMachinesComposition.area — machines, server room, remote and GitHub)
/// with fakes behind every channel and service. Nothing here is listened on or slept.
final class BackendDeckToolsS2MachinesAreaTests: XCTestCase {
    typealias V = NativeRPCValue
    private struct Built { let area: BackendDeckCoreToolArea; let definitions: [BackendDeckToolsDefinition] }

    /// createMachineArea().tools({ servers, userData }): the real composition, plus the
    /// same definitions in the same order (their index lines are what tools.describe lists).
    private func built(serverRoom: Bool = true) async throws -> Built {
        let clock = BackendDeckToolsMachinesPortClockFake(), channels = BackendDeckToolsMachinesPortChannels()
        let environment = BackendDeckToolsMachinesPortEnvironment()
        let machines = BackendDeckToolsMachinesPortMachineArea(channels, clock: clock)
        let remote = BackendDeckToolsMachinesRemote(channels: channels)
        let servers: BackendDeckToolsMachinesServers? = serverRoom
            ? BackendDeckToolsMachinesServers(channels: channels, shells: BackendDeckCoreTestPortSessionsShells(),
                                              dataRoot: URL(fileURLWithPath: "/nowhere"), home: URL(fileURLWithPath: "/fixture/home"),
                                              sleep: { clock.sleep($0) })
            : nil
        let github = try BackendDeckToolsAppGitHub.definitions(service: BackendDeckCoreTestPortToolsApplicationFake(),
                                                               access: BackendDeckCoreTestPortToolsFixture.access(.init()), clock: clock)
        let area = try await BackendDeckToolsMachinesComposition.area(machines: machines, remote: remote, servers: servers,
                                                                      github: github, environment: environment)
        var definitions = try await machines.definitions(environment: environment)
        if let servers { definitions += try await servers.definitions(environment: environment) }
        definitions += try await remote.definitions(environment: environment)
        definitions += github
        XCTAssertEqual(area.tools.map(\.id), definitions.map(\.spec.id))
        return .init(area: area, definitions: definitions)
    }

    /// actions/machines.ts's checklist: every tool id a machines-area entry names.
    private var checklistTools: [String] {
        BackendDeckCoreCatalogueCoverageLiterals.sourceRows.filter { $0.area == "machines" }.flatMap { $0.tools ?? [] }
    }

    // TSCASE machine-area.test.ts:24
    func testEveryToolIDTheChecklistNamesHasARealTool() async throws {
        let areaIDs = try await built().area.tools.map(\.id)
        let serverIDs = try BackendServersTools.definitions().map(\.id)
        let ids = Set(areaIDs + serverIDs), named = checklistTools
        XCTAssertFalse(named.isEmpty)
        XCTAssertEqual(named.filter { !ids.contains($0) }, [])
    }

    // TSCASE machine-area.test.ts:39
    func testAreaUsesEveryToolItAdds() async throws {
        let named = Set(checklistTools), tools = try await built().area.tools
        XCTAssertEqual(tools.map(\.id).filter { !named.contains($0) }, [])
    }

    // TSCASE machine-area.test.ts:48
    func testEveryWireNameIsTheDottedIDWithUnderscoresOnce() async throws {
        let tools = try await built().area.tools
        for tool in tools { XCTAssertEqual(tool.wireName, tool.id.replacingOccurrences(of: ".", with: "_")) }
        XCTAssertEqual(Set(tools.map(\.wireName)).count, tools.count)
    }

    // TSCASE machine-area.test.ts:54
    func testEveryToolIsHeldBehindDescribeWithOneIndexLineOf160AtMost() async throws {
        let definitions = try await built().definitions
        XCTAssertEqual(definitions.filter { $0.index == nil }.map(\.spec.id), [])
        for definition in definitions {
            XCTAssertLessThanOrEqual(definition.index?.utf16.count ?? 0, 160, "\(definition.spec.id)'s index line")
        }
    }

    // TSCASE machine-area.test.ts:60 — the area adds no advertised tool, fewer than 500
    // estimated tokens, and the whole listing stays inside the shared ceiling.
    func testAreaCostsTheSharedCatalogueUnder500TokensAndStaysInsideTheCeiling() async throws {
        let area = try await built().definitions.map(\.catalogueMetadata)
        let serverRoom = try BackendDeckCoreSupplementMetadata.entries(specs: BackendServersTools.definitions())
        let describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] }).metadata
        let without = BackendDeckCoreCatalogueCost.measure(try BackendDeckCoreCatalogueDescribe.advertised(serverRoom + describe))
        let withArea = BackendDeckCoreCatalogueCost.measure(try BackendDeckCoreCatalogueDescribe.advertised(serverRoom + area + describe))
        XCTAssertEqual(withArea.tools, without.tools)
        XCTAssertLessThan(withArea.tokens - without.tokens, 500)
        XCTAssertLessThanOrEqual(withArea.tokens, BackendDeckCoreCatalogueRules.maxCatalogueTokens)
    }

    // TSCASE machine-area.test.ts:76 — machines:list is answered by the handler the
    // window registered on the channel registry, reached through the actual gate.
    func testDispatcherReachesTheVeryHandlerTheWindowRegistered() async throws {
        let registry = NativeChannelRegistry(), counter = BackendDeckToolsS2MachinesCounter(), clock = BackendDeckToolsMachinesPortClockFake()
        try await registry.register("machines:list", ownerID: "machines-window", handler: { _, _ in
            await counter.bump()
            return BackendDeckToolsMachinesPortObject(["machines": .array([]), "links": .array([]), "here": .string("Mac mini"), "blocked": .null])
        })
        let watch = BackendDeckToolsMachinesWatch(clock: clock)
        let area = BackendDeckToolsMachinesArea(channels: BackendDeckToolsMachinesRegistry(registry: registry),
                                                stateWaiter: .init(registry: registry, clock: clock), watch: watch,
                                                dataRoot: URL(fileURLWithPath: "/fixture/data"), home: URL(fileURLWithPath: "/fixture/home"),
                                                sleep: { clock.sleep($0) })
        let gated = try await BackendDeckCoreTestPortSessionsMachineFixtureSupport.call(id: "machines.look", arguments: .object([]),
            prepare: { try await area.policy($0, $1, $2) }, run: { try await area.run($0, $1, $2) })
        let asked = await counter.count
        await watch.dispose()
        XCTAssertTrue(gated.result.ok, gated.result.error ?? "refused")
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(gated.result.value["thisComputer"], .string("Mac mini"))
        XCTAssertEqual(gated.result.value["machines"], .array([]))
    }

    // TSCASE machine-area.test.ts:105 — compile-time, as in the source: the actual server
    // room's shells pass straight into the server-room tools' seam, and no room is nil.
    func testTakesTheServerRoomShellsAsTheyAre() {
        let fits: (BackendServersShells?) -> (any BackendDeckToolsMachinesServerShells)? = { $0.map { $0 as any BackendDeckToolsMachinesServerShells } }
        XCTAssertNil(fits(nil))
    }

    // TSCASE machine-area.test.ts:111
    func testServerRoomToolsAreLeftOutWhenTheServerRoomWasNeverBuilt() async throws {
        let ids = try await built(serverRoom: false).area.tools.map(\.id)
        XCTAssertFalse(ids.contains { $0.hasPrefix("servers.") })
        XCTAssertTrue(ids.contains("machines.look"))
    }
}
