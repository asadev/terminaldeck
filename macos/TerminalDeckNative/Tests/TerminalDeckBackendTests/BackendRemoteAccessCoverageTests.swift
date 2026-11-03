import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Remote listener security", .serialized)
struct BackendRemoteAccessCoverageTests {
    @Test func listenerRejectsForeignHostAndOriginAndStopsCleanly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
            state: NativeStateStore(), home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [])
        let listener = BackendRemoteHostListener(host: host, allowedHosts: ["deck.test"], webRoot: nil)
        let port = try await listener.start(port: 0)
        let again = try await listener.start(port: 0)
        #expect(port == again)
        let session = URLSession(configuration: .ephemeral)
        for (named, origin, expected) in [("foreign.test", "http://deck.test", 403),
                                          ("deck.test", "https://foreign.test", 403),
                                          ("deck.test", "https://deck.test", 404)] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
            request.timeoutInterval = 5
            request.setValue(named, forHTTPHeaderField: "Host")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            let (_, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == expected)
        }
        session.invalidateAndCancel()
        await listener.stop()
        #expect(await listener.state().listening == false)
        #expect(await host.connections().isEmpty)
        await trust.close()
    }

    @Test func unpairedSocketCannotReadSessionsOrInvokeAFeature() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let capture = Capture()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
            state: NativeStateStore(), home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [])
        try await host.register(.init(capability: "settings", messageTypes: ["settings.read"], policy: .grantedDevice) { _, _ in
            await capture.called(); return []
        })
        try await host.start()
        for text in ["{\"t\":\"list\"}", "{\"t\":\"settings.read\",\"rid\":\"unpaired-read\"}",
                     "{\"t\":\"hello\",\"protocol\":1,\"token\":\"not-paired\",\"device\":{\"name\":\"Test\",\"platform\":\"ios\"},\"capabilities\":[\"settings\"]}"] {
            guard case .message = BackendRemoteProtocol.parseClientMessage(text) else { Issue.record("The test needs a valid client frame"); continue }
            if let id = await host.accept(.init(address: "test", send: { try await capture.receive($0) }, close: { _, _ in })) {
                await host.receive(id, text: text)
                await host.closed(id)
            }
        }
        let errors = await capture.frames.filter { $0["t"].string == "error" }
        #expect(errors.map { $0["code"].string } == ["unauthenticated", "unauthenticated", "unauthorized"])
        #expect(await capture.calls == 0)
        #expect(await capture.frames.allSatisfy { $0["t"].string != "welcome" && $0["t"].string != "sessions" })
        #expect(await capture.frames.contains { $0["t"].string == "error" })
        #expect(await host.connections().isEmpty)
        await host.stop(); await trust.close()
    }

    @Test func dockerFramingCannotBeOverriddenByCallers() throws {
        for headers in [["Host": "evil"], ["Content-Length": "0"], ["Transfer-Encoding": "chunked"],
                        ["X-Test": "ok\r\nInjected: yes"], ["X-Test": "a", "x-test": "b"]] {
            #expect(throws: (any Error).self) {
                try BackendDockerHTTP.encode(.init(path: "/version", headers: headers), limits: .init(), hijack: false)
            }
        }
        for path in ["//evil/path", "/version\r\nX: bad", "/version#fragment"] {
            #expect(throws: (any Error).self) {
                try BackendDockerHTTP.encode(.init(path: path), limits: .init(), hijack: false)
            }
        }
        let encoded = try BackendDockerHTTP.encode(.init(path: "/version"), limits: .init(), hijack: false)
        #expect(String(decoding: encoded, as: UTF8.self).contains("host: docker\r\n"))
        #expect(throws: (any Error).self) { try BackendDockerHTTP.head(Data("HTTP/1.1 200 OK\r\nX: one\r\nx: two".utf8)) }
    }

    private actor Capture {
        var calls = 0
        var frames: [NativeRPCValue] = []
        func called() { calls += 1 }
        func receive(_ text: String) throws { frames.append(try .parseJSON(Data(text.utf8))) }
    }
}
