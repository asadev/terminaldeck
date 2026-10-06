import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// The native "Your own devices" section's rules, mirroring `remote-clock.test.ts`,
/// `RemoteSection.test.tsx`, `DeviceApproval.test.tsx`, `PendingApproval.test.tsx`
/// and the Device* tests.
@Suite("Remote clock")
struct RemoteClockTests {
    let now = 1_791_000_000_000.0
    let minute = 60_000.0

    func state(devices: [RemoteDevice] = [], connections: [RemoteConnection] = [], relay: RemoteRelay? = nil) -> RemoteState {
        RemoteState(running: true, relay: relay, devices: devices, connections: connections)
    }

    @Test func asksForNoTimerWhenNothingDependsOnTheClock() {
        #expect(RemoteRules.nextClockChange(nil, nil, now: now) == nil)
        #expect(RemoteRules.nextClockChange(state(), nil, now: now) == nil)
    }

    @Test func daysTickDailyAndAFixedDateNever() throws {
        let old = state(devices: [RemoteDevice(id: "d", name: "iPhone", state: .approved, lastSeenAt: now - 40 * 3_600_000)])
        let at = try #require(RemoteRules.nextClockChange(old, nil, now: now))
        #expect(at > now && at - now <= 86_400_000)
        let ancient = state(devices: [RemoteDevice(id: "d", name: "iPhone", state: .approved, lastSeenAt: now - 60 * 86_400_000)])
        #expect(RemoteRules.nextClockChange(ancient, nil, now: now) == nil)
    }

    @Test func landsOnTheSecondTheCountdownChanges() throws {
        let pairing = RemotePairing(token: "123456", expiresAt: now + 42_300, findable: true)
        let at = try #require(RemoteRules.nextClockChange(nil, pairing, now: now))
        #expect(RemoteRules.codeSecondsLeft(expiresAt: now + 42_300, now: at - 1) == 43)
        #expect(RemoteRules.codeSecondsLeft(expiresAt: now + 42_300, now: at) == 42)
        #expect(RemoteRules.nextClockChange(nil, RemotePairing(token: "t", expiresAt: now - 1), now: now) == nil)
        #expect(RemoteRules.nextClockChange(nil, RemotePairing(token: "t", expiresAt: nil), now: now) == nil)
    }

    @Test func landsOnTheMinuteTheLabelsChange() throws {
        let seen = now - 4 * minute - 12_000
        let at = try #require(RemoteRules.nextClockChange(state(devices: [RemoteDevice(id: "d", name: "x", state: .approved, lastSeenAt: seen)]), nil, now: now))
        #expect(RemoteRules.whenSeen(seen, now: at - 1) == RemoteRules.whenSeen(seen, now: now))
        #expect(RemoteRules.whenSeen(seen, now: at) != RemoteRules.whenSeen(seen, now: now))

        let since = now - 7 * minute - 3000
        let attached = try #require(RemoteRules.nextClockChange(state(connections: [RemoteConnection(id: "c", deviceName: "x", connectedAt: since)]), nil, now: now))
        #expect(RemoteRules.attachedFor(since: since, now: attached - 1) == RemoteRules.attachedFor(since: since, now: now))
        #expect(RemoteRules.attachedFor(since: since, now: attached) != RemoteRules.attachedFor(since: since, now: now))

        let opened = now - 6 * minute - 45_000
        let tunnelAt = try #require(RemoteRules.nextClockChange(state(connections: [RemoteConnection(id: "c", deviceName: "x", connectedAt: now - 30_000,
                                                                                                      tunnels: [RemoteTunnel(id: "t", port: 5173, streams: 1, openedAt: opened)])]), nil, now: now))
        #expect(RemoteRules.attachedFor(since: opened, now: tunnelAt) != RemoteRules.attachedFor(since: opened, now: now))
        #expect(RemoteRules.nextClockChange(state(connections: [RemoteConnection(id: "c", deviceName: "x", tunnels: [RemoteTunnel(id: "t", port: 1)])]), nil, now: now) == nil)
    }

    @Test func landsOnTheSecondTheRetryNoteChangesAndNeverSpins() throws {
        let retryAt = now + 18_400
        let at = try #require(RemoteRules.nextClockChange(state(relay: RemoteRelay(connected: false, retryAt: retryAt)), nil, now: now))
        #expect(RemoteRules.retryNote(retryAt, now: at - 1) == RemoteRules.retryNote(retryAt, now: now))
        #expect(RemoteRules.retryNote(retryAt, now: at) != RemoteRules.retryNote(retryAt, now: now))
        let close = try #require(RemoteRules.nextClockChange(state(relay: RemoteRelay(connected: false, retryAt: now + 600)), nil, now: now))
        #expect(close >= now + 250)
    }
}

@Suite("Remote words and reading")
struct RemoteWordsTests {
    let now = 1_791_000_000_000.0

    @Test func readsTheEnginesState() throws {
        let state = try #require(RemoteRead.state(status: [
            "running": true, "url": NSNull(), "address": NSNull(), "reason": NSNull(),
            "relay": ["url": "wss://r", "hostId": "h", "publicKey": "k", "fingerprint": "ab cd", "connected": true, "channels": 2, "reason": NSNull(), "retryAt": NSNull()],
            "connections": [["id": "c1", "deviceId": "d1", "platform": "ios", "address": "1.2.3.4", "connectedAt": now, "sessionIds": ["s1"],
                             "tunnels": [["id": "t1", "port": 5173, "streams": 2, "openedAt": now], ["id": "bad", "port": -1]]]],
        ], devices: [
            ["id": "d1", "name": "Asad_iPhone", "status": "approved", "addedAt": now, "lastSeenAt": now, "fingerprint": "11 22"],
            ["id": "d2", "name": "sdk_gphone64_arm64", "approved": false, "revoked": true],
            ["id": "d3", "name": " ", "approved": true],
            ["name": "no id"],
        ] as [Any]))
        #expect(state.running && state.relay?.channels == 2 && state.relay?.connected == true)
        #expect(state.devices.map(\.name) == ["Asad iPhone", "Android emulator", "Unnamed device"])
        #expect(state.devices.map(\.state) == [.approved, .revoked, .approved])
        #expect(state.connections.first?.deviceName == "Asad iPhone" && state.connections.first?.tunnels.count == 1)
        #expect(RemoteRead.state(status: "nonsense", devices: nil) == nil)
        #expect(RemoteRead.pairing(["token": "123456", "expiresAt": now, "findable": false]) == RemotePairing(token: "123456", expiresAt: now, findable: false))
        #expect(RemoteRead.pairing(["token": ""]) == nil)
        #expect(RemoteRead.kinds([["deviceId": "d1", "kind": "mine"], ["deviceId": "d2", "kind": "boss"]] as [Any]) == ["d1": .mine])
        #expect(RemoteRead.stateAfter([["id": "d1", "status": "revoked"]] as [Any], id: "d1") == .revoked)
    }

    @Test func wordsTimesAsAPersonReadsThem() {
        #expect(RemoteRules.whenSeen(nil, now: now) == "never")
        #expect(RemoteRules.whenSeen(now - 20_000, now: now) == "just now")
        #expect(RemoteRules.whenSeen(now - 5 * 60_000, now: now) == "5 minutes ago")
        #expect(RemoteRules.whenSeen(now - 3 * 3_600_000, now: now) == "3 hours ago")
        #expect(RemoteRules.whenSeen(now - 2 * 86_400_000, now: now) == "2 days ago")
        #expect(RemoteRules.attachedFor(since: now - 30_000, now: now) == "less than a minute")
        #expect(RemoteRules.attachedFor(since: now - 61 * 60_000, now: now) == "1 hour")
        #expect(RemoteRules.retryNote(nil, now: now) == nil)
        #expect(RemoteRules.retryNote(now + 12_000, now: now) == "Trying again in 12s.")
        #expect(RemoteRules.retryNote(now + 125_000, now: now) == "Trying again in 2 minutes.")
        #expect(RemoteRules.retryNote(now - 5, now: now) == "Trying again now.")
    }

    @Test func notesForAnAttachmentAndAPage() {
        let connection = RemoteConnection(id: "c", deviceName: "iPhone", platform: "ios", address: "100.64.0.9", connectedAt: now - 5 * 60_000, sessionIds: ["a"])
        #expect(RemoteRules.connectionNote(connection, now: now) == "attached for 5 minutes · ios · 100.64.0.9 · 1 session open")
        #expect(RemoteRules.connectionNote(RemoteConnection(id: "c", deviceName: "x"), now: now) == "attached · no session open")
        #expect(RemoteRules.tunnelNote(RemoteTunnel(id: "t", port: 3000, streams: 2, openedAt: now - 2 * 60_000), now: now) == "open for 2 minutes · carrying 2 sockets")
        #expect(RemoteRules.tunnelNote(RemoteTunnel(id: "t", port: 3000), now: now) == "open")
    }

    @Test func codesAreMintedOnlyWhenSomethingIsUp() {
        #expect(!RemoteRules.canMintCode(nil))
        #expect(!RemoteRules.canMintCode(RemoteState(running: false, url: "http://x")))
        #expect(RemoteRules.canMintCode(RemoteState(running: true, relay: RemoteRelay(connected: true))))
        #expect(RemoteRules.canMintCode(RemoteState(running: true, url: "http://100.64.0.1:7777")))
        #expect(!RemoteRules.canMintCode(RemoteState(running: true, relay: RemoteRelay(connected: false))))
        #expect(RemoteRules.codeShown("123456") == "123456")
        #expect(RemoteRules.codeShown("123-456") == "123456")
        #expect(RemoteRules.codeShown("abc") == "abc")
        #expect(RemoteRules.unsettled(nil, RemotePairing(token: "t")))
        #expect(RemoteRules.unsettled(RemoteState(running: true, relay: RemoteRelay(connected: false)), nil))
        #expect(!RemoteRules.unsettled(RemoteState(running: true, relay: RemoteRelay(connected: false, retryAt: 1)), nil))
    }

    @Test func approvalStepsAndWords() {
        #expect(RemoteRules.steps(.mine) == [.check, .kind, .confirm])
        #expect(RemoteRules.steps(nil) == [.check, .kind, .folders, .accounts, .confirm])
        #expect(RemoteRules.nextStep(.kind, kind: .mine) == .confirm)
        #expect(RemoteRules.nextStep(.kind, kind: .guest) == .folders)
        #expect(RemoteRules.nextStep(.confirm, kind: .guest) == .confirm)
        #expect(RemoteRules.previousStep(.check, kind: nil) == nil)
        #expect(RemoteRules.previousStep(.confirm, kind: .mine) == .kind)
        var approval = RemoteApproval(device: RemoteDevice(id: "d", name: "iPad", state: .pending))
        approval.addFolder("/a"); approval.addFolder("/a"); approval.toggleAccount("acc", on: true)
        #expect(approval.folders == ["/a"] && approval.accountMode == .selected && approval.accounts == ["acc"])
        approval.pick(.mine)
        #expect(approval.step == .confirm && approval.folders.isEmpty && approval.accountMode == .all && approval.accounts.isEmpty)
        #expect(RemoteRules.approvedNotice("iPad", kind: .mine, folders: 0, accountMode: .all, accounts: 0) == "iPad has full access.")
        #expect(RemoteRules.approvedNotice("iPad", kind: .guest, folders: 0, accountMode: .all, accounts: 0) == "iPad is in, and can open nothing until you choose a folder for it.")
        #expect(RemoteRules.approvedNotice("iPad", kind: .guest, folders: 2, accountMode: .selected, accounts: 0) == "iPad can open 2 folders, with none of your logins.")
        #expect(RemoteRules.approvedNotice("iPad", kind: .guest, folders: 1, accountMode: .selected, accounts: 1) == "iPad can open one folder, with one of your logins.")
        #expect(RemoteRules.confirmLede("iPad", kind: .mine, folders: 0) == "iPad will have full access to this Mac.")
        #expect(RemoteRules.confirmLogins(mode: .selected, accounts: 0) == "It gets none of your logins, and no account chip at all.")
    }

    @Test func thePendingApprovalSaysWhyItIsGone() {
        #expect(RemoteRules.goneBecause(nil)?.hasPrefix("That device is not in the list any more.") == true)
        let approved = RemoteDevice(id: "d", name: "iPad", state: .approved)
        #expect(RemoteRules.goneBecause(approved) == "iPad has already been let in — nothing left to do here.")
        #expect(RemoteRules.goneBecause(RemoteDevice(id: "d", name: "iPad", state: .pending)) == nil)
        #expect(RemoteRules.approvalFailure([["id": "d", "status": "approved"]] as [Any], device: approved) == nil)
        #expect(RemoteRules.approvalFailure([["id": "d", "status": "pending"]] as [Any], device: approved) == "iPad is still waiting, so that did not take. Try again from Settings → Remote.")
        #expect(RemoteRules.approvalFailure(nil, device: approved) == nil)
        #expect(RemoteRules.didNotTake(approved, after: .pending) == "iPad is still listed as waiting for you, so that did not take.")
    }

    @Test func whoThePerDeviceListsAreFor() {
        let devices = [RemoteDevice(id: "a", name: "A", state: .approved), RemoteDevice(id: "b", name: "B", state: .approved),
                       RemoteDevice(id: "c", name: "C", state: .pending)]
        #expect(RemoteRules.grantable(devices, kinds: ["a": .mine]).map(\.id) == ["b"])
        #expect(RemoteRules.grantable(devices, kinds: nil).map(\.id) == ["a", "b"])
        #expect(RemoteRules.sessionDevices(devices).map(\.id) == ["a", "b"])
        #expect(RemoteRules.kindNote(.guest) == "Guest — only the folders you chose. Never Hoot.")
    }
}

@Suite("Remote per-device lists")
struct RemoteGrantsTests {
    @Test func foldersAreReadAndSummed() {
        let grants = RemoteGrants.folders([["deviceId": "a", "folders": ["/x", "", 3]], ["deviceId": "b"], ["deviceId": "", "folders": []]] as [Any])
        #expect(grants == ["a": ["/x"]])
        #expect(RemoteGrants.folderSummary(nil, loaded: false) == "Reading…")
        #expect(RemoteGrants.folderSummary(nil, loaded: true) == "Approved before this existed — can open nothing")
        #expect(RemoteGrants.folderSummary([], loaded: true) == "No folders. This device cannot start a session.")
        #expect(RemoteGrants.folderSummary(["/a", "/b"], loaded: true) == "2 folders")
        #expect(RemoteGrants.folderName("/Users/me/shop/") == "shop")
    }

    @Test func theConfinementGrantIsReadAndExplained() {
        let confine = RemoteGrants.Confine(json: ["confining": false, "canGrant": true, "folders": ["/opt/homebrew"], "note": "Once."])
        #expect(confine?.canGrant == true && !RemoteGrants.holdsSessions(confine) && RemoteGrants.holdsSessions(nil))
        #expect(RemoteGrants.grantNote(confine!) == "The permission is on the folders holding node, git and the agent tools. It would cover this folder: /opt/homebrew. Nothing else on the disk is touched. Once.")
        let failed = RemoteGrants.grantOutcome(["result": ["ok": false, "detail": ""], "state": ["confining": false]])
        #expect(failed.problem == "That did not go through, and this machine did not say why." && failed.state?.confining == false)
        #expect(RemoteGrants.grantOutcome(["result": ["ok": true], "state": ["confining": true]]).problem == nil)
    }

    @Test func sessionsLoginsAndWindowsAreRead() {
        let sessions = RemoteGrants.choices([["deviceId": "a", "mode": "all", "sessions": ["s1"]], ["deviceId": "b", "mode": "x", "sessions": ["s1", ""]]] as [Any], listKey: "sessions")
        #expect(sessions["a"] == .all && sessions["b"] == RemoteGrants.Choice(mode: .selected, ids: ["s1"]))
        let logins = RemoteGrants.choices([["deviceId": "a", "mode": "selected", "accounts": ["p1"]]] as [Any], listKey: "accounts")
        #expect(logins["a"]?.ids == ["p1"])
        #expect(RemoteGrants.toggled(RemoteGrants.Choice(mode: .selected, ids: ["s1"]), id: "s2", on: true) == ["s1", "s2"])
        #expect(RemoteGrants.toggled(RemoteGrants.Choice(mode: .selected, ids: ["s1"]), id: "s1", on: false).isEmpty)
        let running = RemoteGrants.running([["id": "s1", "title": "", "cwd": "/p", "exitCode": NSNull()], ["id": "s2", "exitCode": 0], ["id": "s3", "title": "Fix"]] as [Any])
        #expect(running.map(\.title) == ["s1", "Fix"])
        #expect(RemoteGrants.windows(["a", "", 3, "b"] as [Any]) == ["a", "b"])
    }
}
