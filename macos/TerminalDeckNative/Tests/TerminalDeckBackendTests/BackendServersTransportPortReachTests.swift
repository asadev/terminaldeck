import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Complete TS forward/reach rules — fake bindings and streams")
struct BackendServersTransportPortReachTests {
    @Test func forwardingEmptyPortAllowListAndThreeStates() async {
        #expect(BackendServersForward.deadPort([1, 2, 4, 8000]) == 3)
        #expect(await BackendServersForward.askWhetherItForwards({ _, _ in .refused(.unreachable, message: "connect failed") }).known == "yes")
        let open = BackendServersForwardTestChannel()
        #expect(await BackendServersForward.askWhetherItForwards({ _, _ in .opened(open) }).known == "yes")
        #expect(open.closed == 1)
        let calls = BackendServersForwardTestCalls()
        let permit = await BackendServersForward.askWhetherItForwards({ host, port in calls.add(host, port); return port == 8000 ? .opened(BackendServersForwardTestChannel()) : .refused(.prohibited, message: "policy") }, listening: [8000, 8080])
        #expect(permit.known == "yes" && calls.ports == [1, 8000])
        let denied = await BackendServersForward.askWhetherItForwards({ _, _ in .refused(.prohibited, message: "policy") }, listening: [8000])
        #expect(denied == .init(known: "no", why: BackendServersForward.willNotForward))
        let unknown = await BackendServersForward.askWhetherItForwards({ _, _ in .refused(.unknown, message: "cannot ask") })
        #expect(unknown == .init(known: "cannot", why: "cannot ask"))
    }
    @Test func listenerFactsCollapseNamesUnknownOwnersAndNonPages() {
        let source: [BackendServersListenerFact] = [.init(address: "0.0.0.0", port: 8000, program: "docker-proxy"), .init(address: "[::]", port: 8000, program: "docker-proxy"), .init(address: "*", port: 6001), .init(address: "*", port: 22, program: "sshd"), .init(address: "*", port: 53, program: "systemd-resolve")]
        let ports = BackendServersReach.portsFrom(source)
        #expect(ports.map(\.port) == [8000, 6001] && ports.allSatisfy { !$0.ours })
        #expect(ports.last?.process == "" && ports.last?.guessed == true)
        let preferred = BackendServersReach.portsFrom([.init(address: "*", port: 8000), .init(address: "::", port: 8000, program: "nginx")])
        #expect(preferred.first?.process == "nginx" && preferred.first?.guessed == false)
        #expect(BackendServersReach.portsFrom([.init(address: "*", port: 3306, program: "node")]).first?.port == 3306)
    }
    @Test func portQuestionsReleaseHoldRefusePolicyAndPreserveThirdState() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        app.client.forwarder = { _, _ in .refused(.unreachable, message: "connect failed") }
        let reach = makeReach(app, listeners: .yes([.init(address: "*", port: 8000, program: "nginx")], measuredAt: 1, how: "fixture"))
        let result = await reach.ports("one")
        #expect(result["ok"].bool == true && result["cannot"] == .null && result["ports"].elements?.count == 1)
        #expect(!(await app.pool.isOpen("one")))
        app.dialer.next.forwarder = { _, _ in .refused(.prohibited, message: "policy") }
        #expect(await reach.ports("one")["message"].string == BackendServersForward.willNotForward)
        app.dialer.next.forwarder = { _, _ in .refused(.unreachable, message: "connect failed") }
        let cannot = makeReach(app, listeners: .cannot(measuredAt: 1, why: "this server has no tool installed for listing what is listening"))
        #expect(await cannot.ports("one") == .object([.init("ok", .bool(true)), .init("ports", .array([])), .init("cannot", .string("this server has no tool installed for listing what is listening"))]))
        await reach.stop(); await cannot.stop()
    }
    @Test func failedUnknownAndMalformedServerRequestsNeverBind() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let network = BackendServersTransportPortNetwork(), reach = makeReach(app, network: network)
        app.dialer.failure = .init("no-answer", "That address did not answer.")
        #expect(await reach.ports("one")["message"].string == "That address did not answer.")
        #expect(await reach.ports("nobody")["message"].string == "This app does not know that server.")
        #expect(app.dialer.clients.isEmpty && network.open.isEmpty)
        let room = BackendServersCoordinator(store: app.store, connections: app.pool, grants: .init(assistantName: "fixture"), journal: BackendServersFileJournal(storageDirectory: app.root, policy: .init(mayRead: true, mayWrite: true)), storageDirectory: app.root, authorize: { _, _ in }, download: nil, now: { 1000 })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "fixture")
        let channels = BackendServersReachChannels(room: room, reach: reach, resolve: { _ in .init(kind: .nativeUI, attended: true, context: context) })
        #expect(try await channels.invoke("servers:ports", arguments: [.number(7)], context: context)["message"].string == "That is not a server.")
        for arguments in [[NativeRPCValue.number(7), .number(8000)], [.string("one"), .string("8000")]] {
            #expect(try await channels.invoke("servers:reach", arguments: arguments, context: context)["message"].string == "That is not a server and a port.")
            #expect(try await channels.invoke("servers:reach:close", arguments: arguments, context: context).bool == false)
        }
        await reach.stop()
    }
    @Test func reachShapeSamePortTwoPortsTwoTabsAndGivingPortsBack() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let network = BackendServersTransportPortNetwork(), reach = makeReach(app, network: network)
        async let first = reach.reach("one", port: 8000); async let second = reach.reach("one", port: 8000)
        let answers = await (first, second)
        #expect(answers.0 == answers.1 && answers.0["ok"].bool == true)
        #expect(answers.0.fields?.map(\.key).sorted() == ["localPort", "ok", "port", "sameNumber", "url"])
        #expect(answers.0["url"].string == "http://127.0.0.1:8000/" && answers.0["localPort"].number == 8000 && answers.0["sameNumber"].bool == true)
        _ = await reach.reach("one", port: 8080)
        #expect(app.dialer.clients.count == 1 && network.open == [8000, 8080])
        #expect(await reach.closeReach("one", port: 8000)); #expect(await reach.openPorts("one") == [8080])
        #expect(await reach.closeReach("one", port: 8000)); #expect(await reach.closeReach("nobody", port: 8000))
        await reach.stop(); let reachPorts = await reach.openPorts("one"); #expect(network.open.isEmpty && reachPorts.isEmpty)
    }
    @Test func forwardingRefusalNeverBindsAndEmptyServiceGetsItsOwnSentence() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        app.client.forwarder = { _, _ in .refused(.prohibited, message: "policy") }
        let network = BackendServersTransportPortNetwork(), reach = makeReach(app, network: network)
        #expect(await reach.ports("one")["message"].string == BackendServersForward.willNotForward)
        app.dialer.next.forwarder = { _, _ in .refused(.prohibited, message: "policy") }
        #expect(await reach.reach("one", port: 8000)["message"].string == BackendServersForward.willNotForward)
        #expect(network.open.isEmpty)
        await reach.closeServer("one")
        app.dialer.next.forwarder = { _, _ in .refused(.unreachable, message: "connect failed") }
        #expect(await reach.reach("one", port: 8000)["message"].string == "Nothing is answering on port 8000 on the box.")
        #expect(network.open.isEmpty); await reach.stop()
    }
    private func makeReach(_ app: BackendServersTransportPortFixture, network: BackendServersTransportPortNetwork = .init(), listeners: BackendServersFact<[BackendServersListenerFact]> = .yes([], measuredAt: 1, how: "fixture")) -> BackendServersReach {
        .init(connections: app.pool, ownPorts: .init(), servers: { try app.store.list() }, facts: { id in var facts = BackendServersFacts(serverId: id, measuredAt: 1); facts.listeners = listeners; return facts }, tunnelsDropped: { _ in }, network: network.network)
    }
    private func open(_ id: String, _ port: Int) -> NativeRPCValue { .object([.init("t", .string("tunnel.open")), .init("id", .string(id)), .init("port", .number(Double(port)))]) }
    private func data(_ ch: String, _ bytes: Data) -> NativeRPCValue { .object([.init("t", .string("net.data")), .init("ch", .string(ch)), .init("data", .string(bytes.base64EncodedString()))]) }
}
