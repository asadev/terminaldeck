import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Remote listener WebSocket")
struct RemoteListenerWebSocketTests {
    @Test func websocketUpgradeDoesNotGrantAnUnpairedPhoneSessionAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
            state: NativeStateStore(), home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [])
        try await host.start()
        let listener = BackendRemoteHostListener(host: host, allowedHosts: ["deck.test"], webRoot: nil)
        let port = try await listener.start(port: 0)
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        request.setValue("deck.test", forHTTPHeaderField: "Host")
        request.timeoutInterval = 5
        let socket = session.webSocketTask(with: request)
        socket.resume()
        do {
            let reply = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await socket.send(.string("{\"t\":\"list\"}"))
                    switch try await socket.receive() {
                    case .string(let text): return text
                    case .data: throw NativeRPCError.malformed("Expected a JSON refusal")
                    @unknown default: throw NativeRPCError.malformed("Unknown WebSocket message")
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    socket.cancel(with: .goingAway, reason: nil)
                    throw NativeRPCError(code: "timeout", message: "No refusal arrived")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            let frame = try NativeRPCValue.parseJSON(Data(reply.utf8))
            #expect(frame["t"].string == "error")
            #expect(frame["code"].string == "unauthenticated")
            #expect(await host.connections().isEmpty)
        } catch {
            socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
            await listener.stop(); await host.stop(); await trust.close()
            throw error
        }
        socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
        await listener.stop(); await host.stop(); await trust.close()
        #expect(await listener.state().listening == false)
    }
}
