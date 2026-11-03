import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// PHONE2 (9 Oct 2026). Asad: "i opened a link it opened in mac terminal deck but not in my phone".
/// A link an agent opens from a session goes to the phone he is driving that session from: attached,
/// typed into it more recently than anyone touched the Mac (and within half an hour), and able to take
/// `link.open`. Every other case picks nobody, so the Mac's own browser opens it as before.
@Suite("PHONE2 a session's link opens on the phone")
struct PHONE2LinkToPhoneTests {
    private typealias Row = BackendRemoteHost.LinkCandidate
    private let now = 1_000_000_000.0
    private let session = "s1"
    private func pick(_ rows: [Row], mac: Double?) -> [UUID] {
        BackendRemoteHost.linkTargets(rows, sessionID: session, now: now, macLastInput: mac)
    }

    @Test func thePhoneHeIsTypingFromGetsTheLink() {
        let phone = UUID()
        #expect(pick([Row(id: phone, claims: ["link.open"], attached: [session], typed: now - 5_000)], mac: now - 60_000) == [phone])
        // Unknown Mac activity counts as not newer.
        #expect(pick([Row(id: phone, claims: ["link.open"], attached: [session], typed: now - 5_000)], mac: nil) == [phone])
    }

    @Test func theMacTouchedSinceKeepsItOnTheMac() {
        #expect(pick([Row(id: UUID(), claims: ["link.open"], attached: [session], typed: now - 60_000)], mac: now - 5_000).isEmpty)
    }

    @Test func anOlderPhoneAWatcherAnotherSessionOrAnOldTouchPicksNobody() {
        #expect(pick([Row(id: UUID(), claims: ["device.access"], attached: [session], typed: now - 1_000)], mac: nil).isEmpty)
        #expect(pick([Row(id: UUID(), claims: ["link.open"], attached: [session], typed: nil)], mac: nil).isEmpty)
        #expect(pick([Row(id: UUID(), claims: ["link.open"], attached: ["s2"], typed: now - 1_000)], mac: nil).isEmpty)
        let stale = now - BackendRemoteHost.linkActiveWindowMilliseconds - 1
        #expect(pick([Row(id: UUID(), claims: ["link.open"], attached: [session], typed: stale)], mac: nil).isEmpty)
    }

    @Test func twoPhonesTheOneThatTypedLastIsFirst() {
        let earlier = UUID(), later = UUID()
        let rows = [Row(id: earlier, claims: ["link.open"], attached: [session], typed: now - 9_000),
                    Row(id: later, claims: ["link.open"], attached: [session], typed: now - 2_000)]
        #expect(pick(rows, mac: now - 60_000) == [later, earlier])
    }

    @Test func theFrameCarriesTheAddressAndTheSession() throws {
        #expect(throws: (any Error).self) { try BackendRemoteServerMessage(.linkOpen, fields: [.init("url", .string("https://example.com"))]) }
        let frame = try BackendRemoteServerMessage(.linkOpen, fields: [.init("url", .string("https://example.com")), .init("session", .string(session))])
        #expect(frame.value["t"].string == "link.open")
        #expect(frame.value["url"].string == "https://example.com")
    }

    @Test func aHostWithNoPhoneOpensNothingOnAPhone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PHONE2L-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
                                     state: NativeStateStore(), home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [])
        try await host.start()
        #expect(await host.openLinkOnPhone("https://example.com", sessionID: session, macLastInput: nil) == nil)
        await host.stop()
        await trust.close()
    }
}
