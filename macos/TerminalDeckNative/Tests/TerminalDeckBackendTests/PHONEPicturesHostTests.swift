import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Install #7 (28 Oct): the Mac answered every phone `pictures` request with "Pictures on the phone stopped." The
/// endpoint's feature holds the adapter weakly and the composition kept only the endpoint's lease, so the adapter was
/// freed as start-up returned. The unit tests kept their own adapter and passed. This test goes through the installer
/// the composition uses, over a real host and a paired phone, and keeps only what the composition keeps.
@Suite("Phone pictures over the real host", .serialized)
struct PHONEPicturesHostTests {
    private actor Wire {
        var frames: [NativeRPCValue] = []
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
        func rows(_ type: String) -> [NativeRPCValue] { frames.filter { $0["t"].string == type } }
    }

    @Test func theInstalledAdapterServesUntilItsInstallationIsDropped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PICTURES-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trust = BackendRemoteTrustStore(directory: dir.appendingPathComponent("remote"))
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Phone", address: "fixture", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .look)
        let clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: dir.path, hostName: "Fixture", appVersion: "test", privateRoots: [], sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        let source = BackendPhonePictures.Source(
            projects: { [] }, logos: dir.appendingPathComponent("project-logos"),
            agents: { [.init(id: "commander", name: "Commander", icon: "sf:star@pink")] },
            sessionAgents: { _ in [:] }, visibleSessions: { _ in [] })

        // The installer the composition uses. The test holds only what the composition holds: the installation.
        var installation: BackendPhonePictures.Installation? = try await BackendPhonePictures.install(on: host, source: source)
        weak let adapter = installation?.pictures
        try await host.start()
        defer { Task { await host.stop(); await trust.close() } }

        let wire = Wire()
        let timer = clock.scheduled.value() + 1
        let id = try #require(await host.accept(.init(address: "fixture", send: { try await wire.receive($0) }, close: { _, _ in })))
        await clock.scheduled.wait(timer)
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Phone")), .init("platform", .string("ios"))])), .init("capabilities", .array([]))])
        await host.receive(id, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        try await waitFor { await wire.rows("welcome").count == 1 }
        let offered = await wire.rows("welcome").first?["capabilities"].elements ?? []
        #expect(offered.contains(.string("pictures")), "the Mac offers pictures to the phone")

        // Asked after start-up has returned, as the phone asks: the adapter is still there to answer.
        await host.receive(id, text: #"{"t":"pictures","rid":"p1"}"#)
        try await waitFor {
            let answered = await wire.rows("pictures"), refused = await wire.rows("error")
            return !answered.isEmpty || !refused.isEmpty
        }
        let errors = await wire.rows("error").compactMap { $0["message"].string }
        #expect(errors.isEmpty, "no refusal such as \"Pictures on the phone stopped.\": \(errors)")
        let answer = try #require(await wire.rows("pictures").first)
        #expect(answer["rid"].string == "p1")
        #expect(answer["agents"].elements?.first?["name"].string == "Commander")
        #expect(adapter != nil)

        // The adapter lives exactly as long as its installation: drop it and the adapter goes with it.
        installation = nil
        #expect(adapter == nil, "nothing but the installation keeps the adapter, so the composition must keep it")
    }

    private func waitFor(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NativeRPCError(code: "fixture-timeout", message: "The host did not answer.")
    }
}
