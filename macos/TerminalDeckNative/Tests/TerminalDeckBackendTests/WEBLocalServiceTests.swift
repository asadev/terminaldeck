import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Independent local web listener", .serialized)
struct WEBLocalServiceTests {
    private actor Listener: BackendRemoteServeHostServiceListening {
        private var running = false
        var starts = 0
        func start(port: UInt16) -> UInt16 { running = true; starts += 1; return port }
        func state() -> BackendRemoteServeHostServiceListenerState { .init(listening: running) }
        func stop() { running = false }
    }
    private actor Tailnet: BackendRemoteServeHostServiceDirectAccess {
        var calls: [String] = []
        func plan(port: UInt16) throws -> BackendRemoteServeHostServiceDirectPlan {
            calls.append("plan")
            throw BackendRemoteServeHostServiceFailure(message: "Fixture tailnet unavailable")
        }
        func serve(port: UInt16) -> String { calls.append("serve"); return "https://fixture.invalid" }
        func stop(port: UInt16) { calls.append("stop") }
    }
    private func withService(preview: Bool, compatibleBundle: Bool = true, run: (BackendRemoteHostService, BackendRemoteTrustStore, Listener, Tailnet, BackendDevOwnPorts) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WEBService-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = directory.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Fixture</title>".utf8).write(to: web.appendingPathComponent("index.html"))
        if compatibleBundle {
            try Data(#"{"client":"terminaldeck-web","bootstrap":1}"#.utf8).write(to: web.appendingPathComponent("build.json"))
        }
        let trust = BackendRemoteTrustStore(directory: directory.appendingPathComponent("remote"))
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
            state: NativeStateStore(), home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [])
        let listener = Listener(), actual = Tailnet(), ports = BackendDevOwnPorts()
        let gated = BackendCompositionPreviewDirect(preview: preview, relayAvailable: false, actual: actual)
        let service = BackendRemoteHostService(endpoint: host, ownPorts: ports, relayURL: nil, webRoot: web,
            tailnet: gated, hostName: "Test", localPort: 18443, makeListener: { _, _, _ in listener })
        do { try await run(service, trust, listener, actual, ports); await service.stop(); await trust.close() }
        catch { await service.stop(); await trust.close(); throw error }
    }

    @Test func devCopyStartsWithoutRelayOrAnyRealTailnetOperation() async throws {
        try await withService(preview: true) { service, trust, listener, tailnet, ports in
            let status = try await service.start()
            #expect(status.running && status.localURL == "http://localhost:18443/")
            #expect(status.directURL == nil && status.relay == nil)
            #expect(await tailnet.calls.isEmpty)
            #expect(await listener.starts == 1)
            #expect(await ports.ports().contains(18443))
            let address = try await service.openWebVersion()
            let url = try #require(URLComponents(string: address))
            #expect(url.scheme == "http" && url.host == "localhost" && url.port == 18443)
            #expect(url.query == nil)
            let fields = URLComponents(string: "?" + (url.fragment ?? ""))?.queryItems ?? []
            let token = try #require(fields.first { $0.name == "pair" }?.value)
            #expect(fields.first { $0.name == "endpoint" }?.value == "ws://localhost:18443/ws")
            #expect(token.utf8.count == 43)
            _ = try await trust.redeemLocalWeb(token, name: "Test browser")
            #expect(await listener.starts == 1)
            await service.stop()
            #expect(await ports.ports().isEmpty)
            #expect(await tailnet.calls.isEmpty)
        }
    }

    @Test func tailnetFailureLeavesTheLocalWebListenerRunningAndNeverWithdrawsServe() async throws {
        try await withService(preview: false) { service, _, _, tailnet, _ in
            let status = try await service.start()
            #expect(status.running && status.localURL != nil)
            #expect(status.directURL == nil)
            #expect(await tailnet.calls == ["plan"])
            await service.stop()
            #expect(await tailnet.calls == ["plan"])
        }
    }

    @Test func legacyIndexWithoutBootstrapMarkerIsRefusedBeforeStartupOrPairing() async throws {
        try await withService(preview: true, compatibleBundle: false) { service, trust, listener, tailnet, ports in
            do { _ = try await service.openWebVersion(); Issue.record("An old web bundle accepted one-click pairing") }
            catch let error as NativeRPCError { #expect(error.code == "web-unavailable") }
            #expect(await listener.starts == 0)
            #expect(await tailnet.calls.isEmpty)
            #expect(await ports.ports().isEmpty)
            #expect(await trust.listDevices().isEmpty)
            #expect(await service.status().running == false)
        }
    }
}
