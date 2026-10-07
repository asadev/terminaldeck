import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// These fixture processes are for the single integration test gate only.
/// The worker wrote the tests without executing any child process.
private func mcpTransportFixture(_ script: String) throws -> BackendMcpClientStdioTransport {
    let raw = NativeRPCValue.object([.init("command", .string("/bin/sh")), .init("args", .array([.string("-c"), .string(script)]))])
    let server = try #require(BackendMcpClientConfiguration.parse(name: "fixture", raw: raw, scope: "user", source: "/tmp/fixture", environment: [:]))
    return try BackendMcpClientStdioTransport(server: server, environment: ["PATH": "/bin:/usr/bin"])
}

@Test func backendMcpClientStdioDrainsFinalReplyBeforeProcessExit() async throws {
    let transport = try mcpTransportFixture(#"IFS= read -r frame; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"last":"reply"}}'"#)
    try await transport.start(stderr: { _ in }, closed: {})
    let result = try await transport.request("ping", params: .object([]), timeout: 2_000, label: "Ping fixture")
    #expect(result["last"].string == "reply")
    await transport.close()
}

@Test func backendMcpClientStdioRetainsStderrAndPropagatesRPCError() async throws {
    let transport = try mcpTransportFixture(#"IFS= read -r frame; printf '%s\n' 'a server diagnostic' >&2; printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"missing message"}}'"#)
    try await transport.start(stderr: { _ in }, closed: {})
    do {
        _ = try await transport.request("tools/call", params: .object([]), timeout: 2_000, label: "Calling fixture")
        Issue.record("An RPC error was accepted as a result")
    } catch let error as BackendMcpClientRPCFailure {
        #expect(error.code == -32602 && error.message == "missing message")
    }
    await transport.close()
    #expect(transport.stderrTail.contains("a server diagnostic"))
}
