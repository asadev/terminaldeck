import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Web origins and HTTP headers")
struct WEBOriginPolicyTests {
    @Test func originsAreExactAndBootstrapIsLocalBrowserOnly() {
        let hosts: Set<String> = ["localhost:18443", "127.0.0.1:18443", "deck.example.ts.net:8443"]
        for origin in ["http://localhost:18443", "http://127.0.0.1:18443", "https://terminaldeck.app", "https://deck.example.ts.net:8443"] {
            #expect(BackendRemoteWebPolicy.permits(origin: origin, hosts: hosts))
        }
        for origin in ["null", "https://terminaldeck.app.evil.test", "http://terminaldeck.app", "http://evil.test", "http://localhost:18444", "https://localhost:18443", "http://localhost:18443/", "http://localhost:18443@evil.test", "https://app.terminaldeck.dev.evil.test",
                       "https://app.terminaldeck.dev" /* regression guard: the retired address (removed 3 Nov) stays refused */] {
            #expect(!BackendRemoteWebPolicy.permits(origin: origin, hosts: hosts))
        }
        #expect(BackendRemoteWebPolicy.permits(origin: nil, hosts: hosts))
        #expect(BackendRemoteWebPolicy.localBootstrap(origin: "http://localhost:18443", host: "localhost:18443"))
        #expect(!BackendRemoteWebPolicy.localBootstrap(origin: nil, host: "localhost:18443"))
        #expect(!BackendRemoteWebPolicy.localBootstrap(origin: "https://app.terminaldeck.dev", host: "localhost:18443"))
        #expect(!BackendRemoteWebPolicy.localBootstrap(origin: "http://localhost:18443", host: "deck.example.ts.net:8443"))
    }

    @Test func servedAssetsHaveCSPAndCrossOriginRequestsAreForbidden() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WEBHeaders-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = directory.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Fixture</title>".utf8).write(to: web.appendingPathComponent("index.html"))
        let trust = BackendRemoteTrustStore(directory: directory.appendingPathComponent("remote"))
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
            state: NativeStateStore(), home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [])
        let listener = BackendRemoteHostListener(host: host, allowedHosts: ["localhost:18443"], webRoot: web)
        let port = try await listener.start(port: 0)
        let session = URLSession(configuration: .ephemeral)
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
            request.setValue("localhost:18443", forHTTPHeaderField: "Host")
            request.setValue("http://localhost:18443", forHTTPHeaderField: "Origin")
            request.timeoutInterval = 5
            let (_, raw) = try await session.data(for: request)
            let response = try #require(raw as? HTTPURLResponse)
            #expect(response.statusCode == 200)
            #expect(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true)
            #expect(response.value(forHTTPHeaderField: "X-Frame-Options") == "DENY")
            #expect(response.value(forHTTPHeaderField: "Referrer-Policy") == "no-referrer")
            #expect(response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            request.setValue("https://evil.test", forHTTPHeaderField: "Origin")
            let (_, refused) = try await session.data(for: request)
            #expect((refused as? HTTPURLResponse)?.statusCode == 403)
            session.invalidateAndCancel(); await listener.stop(); await trust.close()
        } catch { session.invalidateAndCancel(); await listener.stop(); await trust.close(); throw error }
    }
}
