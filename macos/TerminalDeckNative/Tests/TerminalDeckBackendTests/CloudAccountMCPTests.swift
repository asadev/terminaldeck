import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud account — actual app MCP door")
struct CloudAccountMCPTests {
    @Test func catalogueGrantAndCallsUseTheRegisteredNativeDispatcher() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let server = BackendNativeMCPServer()
        let entries = try await BackendCloudAccountTools.registrations(service: f.account, now: f.clock.now(), signin: { _ in })
        try await server.replaceTools(ownerID: BackendCloudAccountTools.owner, tools: entries)
        let endpoint = try await server.start()
        // The HTTP door matches a call by the name the caller sends (the wire name), so a session's grant lists both forms.
        let granted = Set(BackendCloudAccountTools.ids + BackendCloudAccountTools.ids.map { $0.replacingOccurrences(of: ".", with: "_") })
        let registration = try await server.register(token: String(repeating: "c", count: 64), grant: .init(attended: true, allowedTools: granted, allowedTiers: [.read, .act, .alter]))
        try await server.bind(registration, sessionID: "fixture-session", machineID: "fixture-machine")
        do {
            let list = try await rpc(endpoint.url, token: String(repeating: "c", count: 64), method: "tools/list", params: .object([]))
            let names = Set((list["result"]["tools"].elements ?? []).compactMap { $0["name"].string })
            #expect(names == Set(BackendCloudAccountTools.ids.map { $0.replacingOccurrences(of: ".", with: "_") }))
            let status = try await rpc(endpoint.url, token: String(repeating: "c", count: 64), method: "tools/call", params: .object([.init("name", .string("cloud_status")), .init("arguments", .object([]))]))
            #expect(status["result"]["isError"].bool != true)
            #expect(!status.compact.contains("fixture-refresh"))
            let retry = try await rpc(endpoint.url, token: String(repeating: "c", count: 64), method: "tools/call", params: .object([.init("name", .string("cloud_sync")), .init("arguments", .object([.init("action", .string("retry"))]))]))
            #expect(retry["result"]["isError"].bool != true)
            #expect(await f.outbox.flushes == 1)
            let readOnly = try await server.register(token: String(repeating: "d", count: 64), grant: .init(attended: true, allowedTools: granted, allowedTiers: [.read]))
            try await server.bind(readOnly, sessionID: "fixture-readonly", machineID: "fixture-machine")
            let refused = try await rpc(endpoint.url, token: String(repeating: "d", count: 64), method: "tools/call", params: .object([.init("name", .string("cloud_sync")), .init("arguments", .object([.init("action", .string("pause"))]))]))
            #expect(refused["result"]["isError"].bool == true || refused["error"].fields != nil)
            // Refused by its tier (pause is an "alter" action), not because the name was unknown.
            #expect(!refused.compact.contains("No tool called"))
            #expect(await f.outbox.paused == false)
            await f.server.set("gate", false)
            try await f.account.refresh()
            try await server.replaceTools(ownerID: BackendCloudAccountTools.owner, tools: BackendCloudAccountTools.registrations(service: f.account, now: f.clock.now(), signin: { _ in }))
            #expect(try await server.catalogue().isEmpty)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }
    private func rpc(_ url: URL, token: String, method: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        guard url.host == "127.0.0.1" || url.host == "localhost" else { throw CloudFailure.unsafeConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .number(1)), .init("method", .string(method)), .init("params", params)]).encodedJSON()
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try NativeRPCValue.parseJSON(data)
    }
}
