import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("APE observed status: demand reads, Swift fakes only")
struct BackendAppsObservedStatusTests {
    @Test func readShowsStoppedWithoutRewritingPersistedRunningState() async throws {
        let fixture = BackendAppsObservedStatusFixture(records: [record("td-test-one", id: id("a"), status: "running")])
        await fixture.setInspectionReplies([.init(status: 200, value: inspection(app: "td-test-one", running: false))])
        let result = try await fixture.service().invoke("apps:read", request: request("td-test-one"), context: context)
        #expect(result["status"].string == "stopped")
        #expect(result["observedAt"].number == 7777)
        #expect(result["updatedAt"].number == 10)
        let saved = await fixture.saved("td-test-one")
        #expect(saved["status"].string == "running")
        #expect(await fixture.stateWrites == 0)
        let calls = await fixture.calls
        #expect(calls.count == 1 && calls[0].method == "GET")
        #expect(calls[0].path == "/containers/\(id("a"))/json")
    }

    @Test func listUsesOneReadAndOnlyExactOwnedActiveServices() async throws {
        let fixture = BackendAppsObservedStatusFixture(records: [
            record("td-test-one", id: id("a"), status: "running"),
            record("td-test-two", id: id("b"), status: "running"),
            record("td-test-three", id: id("c"), status: "running")
        ])
        await fixture.setListRows([
            row(id: id("d"), app: "td-test-one", state: "running", status: "Up (healthy)"), // retained old candidate
            row(id: id("e"), app: "td-test-one", state: "running", status: "Up", managed: "false"),
            row(id: id("a"), app: "td-test-one", state: "exited", status: "Exited (0)"),
            row(id: id("b"), app: "td-test-two", state: "running", status: "Up (unhealthy)"),
            row(id: id("c"), app: "td-test-foreign", state: "running", status: "Up (healthy)")
        ])
        let result = try await fixture.service().invoke("apps:list", request: request(nil), context: context)
        let rows = try #require(result.elements)
        #expect(rows.first { $0["id"].string == "td-test-one" }?["status"].string == "stopped")
        #expect(rows.first { $0["id"].string == "td-test-two" }?["status"].string == "failed")
        #expect(rows.first { $0["id"].string == "td-test-three" }?["status"].string == "stopped")
        #expect(rows.allSatisfy { $0["observedAt"].number == 7777 })
        #expect(await fixture.stateWrites == 0)
        let calls = await fixture.calls
        #expect(calls.count == 1)
        #expect(calls[0].method == "GET" && calls[0].path.hasPrefix("/containers/json?all=true&filters="))
        #expect(calls[0].path.removingPercentEncoding?.contains("io.terminaldeck.managed=true") == true)
    }

    @Test func restartChecksOwnershipThenSavesPostRestartStatusAndTime() async throws {
        let fixture = BackendAppsObservedStatusFixture(records: [record("td-test-one", id: id("a"), status: "stopped")])
        await fixture.setInspectionReplies([
            .init(status: 200, value: inspection(app: "td-test-one", running: false)),
            .init(status: 200, value: inspection(app: "td-test-one", running: true))
        ])
        let result = try await fixture.service().invoke("apps:restart", request: request("td-test-one"), context: context)
        #expect(result["status"].string == "running")
        #expect(result["updatedAt"].number == 7777)
        let saved = await fixture.saved("td-test-one")
        #expect(saved["status"].string == "running" && saved["updatedAt"].number == 7777)
        #expect(await fixture.stateWrites == 1)
        let calls = await fixture.calls
        #expect(calls.map(\.method) == ["GET", "POST", "GET"])
        #expect(calls[0].path == "/containers/\(id("a"))/json")
        #expect(calls[1].path == "/containers/\(id("a"))/restart?t=10")
        #expect(calls[2].path == "/containers/\(id("a"))/json")
    }

    @Test func foreignOwnershipPreventsRestartPostAndStateWrite() async throws {
        let fixture = BackendAppsObservedStatusFixture(records: [record("td-test-one", id: id("a"), status: "running")])
        await fixture.setInspectionReplies([.init(status: 200, value: inspection(app: "td-test-foreign", running: true))])
        do {
            _ = try await fixture.service().invoke("apps:restart", request: request("td-test-one"), context: context)
            Issue.record("A service owned by another app was restarted")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        #expect(await fixture.stateWrites == 0)
        #expect((await fixture.calls).allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: [404, 500])
    func missingOrFailedPostRestartInspectionCannotReturnSavedSuccess(status: Int) async throws {
        let fixture = BackendAppsObservedStatusFixture(records: [record("td-test-one", id: id("a"), status: "stopped")])
        await fixture.setInspectionReplies([
            .init(status: 200, value: inspection(app: "td-test-one", running: false)),
            .init(status: status, value: .object([]))
        ])
        do {
            _ = try await fixture.service().invoke("apps:restart", request: request("td-test-one"), context: context)
            Issue.record("Restart returned stale state after a failed inspection")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(await fixture.stateWrites == 0)
        let saved = await fixture.saved("td-test-one")
        #expect(saved["status"].string == "stopped" && saved["updatedAt"].number == 10)
        #expect((await fixture.calls).map(\.method) == ["GET", "POST", "GET"])
    }

    @Test(arguments: [200, 500])
    func failedOrMalformedReadInspectionCannotReturnStaleRunning(status: Int) async throws {
        let fixture = BackendAppsObservedStatusFixture(records: [record("td-test-one", id: id("a"), status: "running")])
        await fixture.setInspectionReplies([.init(status: status, value: inspection(app: "td-test-one", running: nil))])
        do {
            _ = try await fixture.service().invoke("apps:read", request: request("td-test-one"), context: context)
            Issue.record("A failed or malformed inspection returned saved running state")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(await fixture.stateWrites == 0)
        #expect((await fixture.calls).allSatisfy { $0.method == "GET" })
    }

    @Test func absentReadServiceIsObservedStoppedWithoutARepairWrite() async throws {
        let fixture = BackendAppsObservedStatusFixture(records: [record("td-test-one", id: id("a"), status: "running")])
        await fixture.setInspectionReplies([.init(status: 404, value: .object([]))])
        let value = try await fixture.service().invoke("apps:read", request: request("td-test-one"), context: context)
        #expect(value["status"].string == "stopped" && value["observedAt"].number == 7777)
        #expect(await fixture.stateWrites == 0)
        let saved = await fixture.saved("td-test-one")
        #expect(saved["status"].string == "running")
    }

    @Test(arguments: ["missing", "teleporting"])
    func matchedActiveListSummaryRequiresKnownState(state: String) async throws {
        let fixture = BackendAppsObservedStatusFixture(records: [record("td-test-one", id: id("a"), status: "running")])
        var summary = row(id: id("a"), app: "td-test-one", state: state, status: "Up")
        if state == "missing" { summary = summary.removing("State") }
        await fixture.setListRows([summary])
        do {
            _ = try await fixture.service().invoke("apps:list", request: request(nil), context: context)
            Issue.record("Malformed active service summary was silently converted to stopped")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(await fixture.stateWrites == 0)
        let saved = await fixture.saved("td-test-one")
        #expect(saved["status"].string == "running")
    }

    @Test(arguments: ["apps:read", "apps:list"])
    func malformedSavedServiceIdentityCannotReturnStaleSuccess(channel: String) async throws {
        let fixture = BackendAppsObservedStatusFixture(records: [record("td-test-one", id: "../foreign", status: "running")])
        do {
            _ = try await fixture.service().invoke(channel, request: request("td-test-one"), context: context)
            Issue.record("Malformed saved service ID returned stale running state")
        } catch let error as NativeRPCError { #expect(["invalid-arguments", "state-failed", "unavailable"].contains(error.code)) }
        #expect(await fixture.stateWrites == 0)
        #expect((await fixture.calls).allSatisfy { $0.method == "GET" })
    }

    private var context: NativeRPCContext { .init(caller: .nativeApp, ownerID: "td-test-status-window") }
    private func request(_ app: String?) -> NativeRPCValue {
        var value = BackendAppsValidation.object([("serverId", .string("td-test-server"))])
        if let app { value = value.setting("appId", .string(app)) }
        return value
    }
    private func id(_ character: String) -> String { String(repeating: character, count: 64) }
    private func record(_ app: String, id: String, status: String) -> NativeRPCValue {
        BackendAppsValidation.object([("id", .string(app)), ("name", .string(app)), ("kind", .string("app")), ("status", .string(status)), ("containerId", .string(id)), ("createdAt", .number(1)), ("updatedAt", .number(10))])
    }
    private func inspection(app: String, running: Bool?) -> NativeRPCValue {
        var state = BackendAppsValidation.object([("Health", BackendAppsValidation.object([("Status", .string("healthy"))]))])
        if let running { state = state.setting("Running", .bool(running)) }
        return BackendAppsValidation.object([("Config", BackendAppsValidation.object([("Labels", BackendAppsValidation.object([("io.terminaldeck.app", .string(app)), ("io.terminaldeck.managed", .string("true"))]))])), ("State", state)])
    }
    private func row(id: String, app: String, state: String, status: String, managed: String = "true") -> NativeRPCValue {
        BackendAppsValidation.object([("Id", .string(id)), ("Labels", BackendAppsValidation.object([("io.terminaldeck.app", .string(app)), ("io.terminaldeck.managed", .string(managed))])), ("State", .string(state)), ("Status", .string(status))])
    }
}

private actor BackendAppsObservedStatusFixture {
    struct Reply: Sendable { let status: Int; let value: NativeRPCValue }
    struct Call: Sendable { let method: String; let path: String }
    private var records: [String: NativeRPCValue]
    private var inspectionReplies: [Reply] = []
    private var listRows: [NativeRPCValue] = []
    private(set) var calls: [Call] = []
    private(set) var stateWrites = 0
    init(records: [NativeRPCValue]) { self.records = Dictionary(uniqueKeysWithValues: records.map { ($0["id"].string ?? "", $0) }) }
    nonisolated func service() -> BackendAppsChannels {
        let runtime = BackendAppsRuntime(execute: { [self] _, command, input, _, _ in try await execute(command, input) },
            docker: { [self] _, method, path, _ in try await docker(method, path) },
            privateNetwork: "td-test-apps", resourcePrefix: "td-test", stateRoot: "/var/lib/td-test-apps", now: { 7777 })
        return BackendAppsChannels(runtime: runtime, authorize: { _, _ in })
    }
    func setInspectionReplies(_ replies: [Reply]) { inspectionReplies = replies }
    func setListRows(_ rows: [NativeRPCValue]) { listRows = rows }
    func saved(_ app: String) -> NativeRPCValue { records[app] ?? .missing }
    private func execute(_ command: String, _ input: Data?) throws -> BackendServersRunResult {
        if let input, command.contains("mv -f --"), command.contains("/state.json") {
            let value = try NativeRPCValue.parseJSON(input)
            guard let app = value["id"].string else { throw NativeRPCError(code: "state-failed", message: "The status fixture received invalid saved state.") }
            records[app] = value; stateWrites += 1
            return .init(code: 0, stdout: "")
        }
        if command.contains("find "), command.contains("-name state.json") {
            return .init(code: 0, stdout: records.keys.sorted().map { "/var/lib/td-test-apps/" + $0 + "\n" }.joined())
        }
        for (app, record) in records where command.contains("/\(app)/state.json") && command.contains("cat --") {
            return .init(code: 0, stdout: record.compact)
        }
        // Token-matched lock acquisition/release is modelled without a shell or filesystem.
        return .init(code: 0, stdout: "")
    }
    private func docker(_ method: String, _ path: String) throws -> BackendAppsHTTPResponse {
        calls.append(Call(method: method, path: path))
        if method == "POST" { return .init(status: 204) }
        if path.hasPrefix("/containers/json?") { return .init(status: 200, body: try NativeRPCValue.array(listRows).encodedJSON()) }
        guard method == "GET", !inspectionReplies.isEmpty else {
            throw NativeRPCError(code: "unavailable", message: "The status fixture received an unexpected inspection.")
        }
        let reply = inspectionReplies.removeFirst()
        return .init(status: reply.status, body: try reply.value.encodedJSON())
    }
}
