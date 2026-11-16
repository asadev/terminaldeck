import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// MAC-NEXT-7 (6, 7): device cards from the service's reported time; a held-unlisted line is a task only under the
/// stricter trust setting.
extension CloudPageNames2Tests {
    private func window(_ snapshot: CloudAccountSnapshot, moved: [String: Int64]? = [:]) throws -> BackendCloudContents {
        try #require(BackendCloudContentsBuilder.build(contents: contents(thisDevice: Self.book), snapshot: snapshot,
                                                       counts: macBookCounts, positionMovedAt: moved, now: now)).model
    }
    private func withMiniReport(at: Int64?, pulled: UInt64, head: UInt64 = 407) -> CloudAccountSnapshot {
        let base = macBook(coverage: macBookCoverage, head: head, miniPulled: pulled)
        var devices = base.devices
        if let index = devices.firstIndex(where: { $0.deviceId == Self.mini }) { devices[index].lastPulledAt = at }
        return CloudAccountSnapshot(phase: base.phase, gate: base.gate, displayName: base.displayName, devices: devices, coverage: base.coverage,
                                    trust: base.trust, cloudHead: base.cloudHead, fetched: base.fetched)
    }
    private func miniState(_ model: BackendCloudContents) -> String? { model.devices.first { !$0.isThisMac }?.state }

    @Test func aDeviceCardSaysItsNumberOnlyWhenItsReportedPositionIsRecent() throws {
        // Reported 30 s ago: the number against the head.
        let recent = try window(withMiniReport(at: now - 30_000, pulled: 404))
        #expect(miniState(recent) == "Catching up: 3 changes still to fetch")
        // Defect E: "Last seen" follows the reported fetch, not only the service's hourly check-in.
        #expect(recent.devices.first { !$0.isThisMac }?.lastSeen == now - 30_000)
        // Reported 10 minutes ago: catching up, no number (the report is not current), even if this window saw it move.
        #expect(miniState(try window(withMiniReport(at: now - 600_000, pulled: 404), moved: [Self.mini: now - 10_000])) == "Catching up")
        // Its position equals the head: up to date, whatever the age of the report.
        #expect(miniState(try window(withMiniReport(at: now - 3_600_000, pulled: 407))) == BackendCloudContentsWords.upToDate)
        // An older service without the time: the earlier rule (seen moving lately) still works.
        #expect(miniState(try window(withMiniReport(at: nil, pulled: 404), moved: [Self.mini: now - 30_000])) == "Catching up: 3 changes still to fetch")
        #expect(miniState(try window(withMiniReport(at: nil, pulled: 404))) == "Catching up")
    }

    @Test func theDeviceListDecodesWithAndWithoutTheReportedTime() throws {
        let jwk = #"{"kty":"EC","crv":"P-256","x":"x","y":"y"}"#
        func list(_ extra: String, head: String) -> String {
            #"{"devices":[{"deviceId":"d1","label":"Mac","platform":"macos","appVersion":"1","status":"active","secretsApproved":false,"lastSeenAt":5,"registeredAt":1,"lastPulledSeq":"12""#
                + extra + #","signPublicJwk":"# + jwk + #","wrapPublicJwk":"# + jwk + "}]" + head + "}"
        }
        let new = try JSONDecoder().decode(CloudDeviceList.self, from: Data(list(#","lastPulledAt":1794000000000"#, head: #","headSeq":"15""#).utf8))
        #expect(new.devices.first?.lastPulledAt == 1_794_000_000_000)
        #expect(new.headSeq == CloudSequence(15))
        let never = try JSONDecoder().decode(CloudDeviceList.self, from: Data(list(#","lastPulledAt":null"#, head: "").utf8))
        #expect(never.devices.first?.lastPulledAt == nil)
        let old = try JSONDecoder().decode(CloudDeviceList.self, from: Data(list("", head: "").utf8))
        #expect(old.devices.first?.lastPulledSeq == CloudSequence(12) && old.devices.first?.lastPulledAt == nil && old.headSeq == nil)
    }

    @Test func heldChangesFromAnUnlistedDeviceNeedHimOnlyUnderTheStricterSetting() throws {
        let base = macBook(coverage: macBookCoverage)
        let held = CloudAccountSnapshot(phase: base.phase, gate: base.gate, displayName: base.displayName, devices: base.devices, coverage: base.coverage,
                                        trust: base.trust, heldChanges: 5, cloudHead: base.cloudHead, fetched: base.fetched)
        for automatic in [true, false] {
            var input = BackendCloudOverviewInput(snapshot: held, memory: .init(included: true), projects: .init(later: fourProjects, heldChanges: 0),
                                                  bootFiles: .init(filesForFolders: 293), passwords: nil)
            input.automaticTrust = automatic
            input.counts = macBookCounts
            let overview = try #require(BackendCloudOverviewBuilder.build(input))
            let line = BackendCloudOverviewWords.unlisted(5)
            if automatic {
                #expect(!overview.waiting.contains { $0.text == line }, "not something he must do")
                #expect(overview.notices.contains { $0.text == line })
                #expect(overview.standing != .needsYou)
            } else {
                #expect(overview.waiting.map(\.text) == [line])
                #expect(overview.title == BackendCloudOverviewWords.needsYou(1))
            }
        }
    }
}
