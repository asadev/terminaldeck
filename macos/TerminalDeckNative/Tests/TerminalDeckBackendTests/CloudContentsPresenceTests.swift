import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Proof 2 (13 Nov) S8, on the Mac that made the project and agent: "Your Cloud" said "A project not on this Mac" and
/// "An agent not on this Mac" twice, and instruction files "On 1 of 2 devices" although the other Mac had them.
@Suite("Cloud contents — what this Mac holds is named and on this Mac; other devices only as known")
struct CloudContentsPresenceTests {
    let now: Int64 = 1_794_000_000_000
    typealias F = BackendCloudContentsFixture
    typealias Key = CloudSyncContents.Key
    let projectId = "proof-project", agentId = "agent-proof-1"

    func snapshot(proPulled: CloudSequence?, proSeen: Int64) -> CloudAccountSnapshot {
        let base = F.snapshot(now: now)
        let devices = base.devices.filter { $0.deviceId == F.mac || $0.deviceId == F.pro }.map { device -> CloudDevice in
            guard device.deviceId == F.pro else { return device }
            var copy = CloudDevice(deviceId: device.deviceId, label: device.label, platform: device.platform, appVersion: device.appVersion,
                                   status: device.status, secretsApproved: false, lastSeenAt: proSeen, signPublicJwk: device.signPublicJwk,
                                   wrapPublicJwk: device.wrapPublicJwk, registeredAt: device.registeredAt)
            copy.lastPulledSeq = proPulled
            return copy
        }
        return CloudAccountSnapshot(phase: .signedIn, gate: base.gate, displayName: base.displayName, devices: devices,
                                    trust: base.trust.filter { $0.deviceId == F.mac || $0.deviceId == F.pro },
                                    cloudHead: base.cloudHead, fetched: base.fetched)
    }
    func contents() -> CloudSyncContents {
        let at = now - 10 * 60_000
        let items: [CloudSyncContents.Item] = [
            .init(key: Key(domain: "projects", sourceId: "lean-projects", recordId: "project:" + projectId, projectId: projectId),
                  changes: [.init(deviceId: F.mac, at: at)], standing: .inCloud, seq: CloudSequence(7)),
            .init(key: Key(domain: "agents", sourceId: "lean-agents", recordId: "instruction:" + agentId + ".md", projectId: nil),
                  changes: [.init(deviceId: F.mac, at: at)], standing: .inCloud, seq: CloudSequence(8)),
            .init(key: Key(domain: "agents", sourceId: "lean-agents", recordId: "agent:" + agentId, projectId: nil),
                  changes: [.init(deviceId: F.mac, at: at)], standing: .inCloud, seq: CloudSequence(8)),
            .init(key: Key(domain: CloudBootFilesFormat.domain, sourceId: "files/I09/project/x", recordId: "file/CLAUDE.md", projectId: projectId),
                  changes: [.init(deviceId: F.mac, at: at)], standing: .inCloud, seq: CloudSequence(9)),
        ]
        return CloudSyncContents(thisDevice: F.mac, items: items, packs: [], held: [], refused: [])
    }
    let names = BackendCloudContentsNames(projects: ["proof-project": "Proof Project"], agents: ["agent-proof-1": "Proof Agent"])

    @Test func projectsAndAgentsThisMacHoldsAreNamedAndOneAgentIsOneLine() throws {
        // The other Mac read the feed past every change (its "last seen" is an hour old: the service moves it hourly).
        let built = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(proPulled: CloudSequence(9), proSeen: now - 3_600_000),
                                                                  names: names, now: now))
        let projects = built.model.items(.projects)
        #expect(projects.map(\.name) == ["Proof Project"])
        let agents = built.model.items(.agents)
        #expect(agents.map(\.name) == ["Proof Agent"])
        for item in projects + agents + built.model.items(.instructionFiles) {
            #expect(item.presence.first == "On this Mac")
            #expect(item.presence.contains("On MacBook Pro"), "\(item.name)")
        }
    }
    @Test func anotherDeviceIsWaitingOnlyUntilItIsKnownToHaveReadTheChange() throws {
        // Read only up to 8: the project and agent are there, the instruction file (9) waits on it.
        let partly = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(proPulled: CloudSequence(8), proSeen: 0),
                                                                   names: names, now: now))
        #expect(partly.model.items(.projects).first?.presence == ["On this Mac", "On MacBook Pro"])
        #expect(partly.model.items(.instructionFiles).first?.presence == ["On this Mac", "Waiting on MacBook Pro"])
        // Nothing known of it: waiting, never "on".
        let unknown = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(proPulled: nil, proSeen: 0),
                                                                    names: names, now: now))
        #expect(unknown.model.items(.instructionFiles).first?.presence == ["On this Mac", "Waiting on MacBook Pro"])
        // A record this Mac does not know by name still says so.
        let nameless = try #require(BackendCloudContentsBuilder.build(contents: contents(), snapshot: snapshot(proPulled: nil, proSeen: 0), now: now))
        #expect(nameless.model.items(.projects).first?.name == "A project not on this Mac")
    }
    @Test func theServiceReadPositionIsDecodedWhenSentAndOptional() throws {
        let key = #"{"kty":"EC","crv":"P-256","x":"x","y":"y"}"#
        let base = #"{"deviceId":"d","label":"L","platform":"macos","appVersion":"1","status":"active","secretsApproved":false,"lastSeenAt":1,"signPublicJwk":\#(key),"wrapPublicJwk":\#(key)"#
        let with = try JSONDecoder().decode(CloudDevice.self, from: Data((base + #","lastPulledSeq":"12"}"#).utf8))
        #expect(with.lastPulledSeq == CloudSequence(12))
        let without = try JSONDecoder().decode(CloudDevice.self, from: Data((base + "}").utf8))
        #expect(without.lastPulledSeq == nil)
    }
}
