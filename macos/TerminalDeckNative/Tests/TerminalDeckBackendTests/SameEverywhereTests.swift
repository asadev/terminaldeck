import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Same everywhere (owner, 15 Nov: "if I have pinned something in my Mac Mini it should be pinned in my MacBook also ...
/// every single setting should be same"). Every setting, the screens' choices (side-panel pins and their order, open
/// sections, page views) and each project's own settings travel on the settings kind's record rule; what names
/// something of one device only stays. Scratch stores and scratch defaults suites only, fixture clocks only.
@Suite("Same everywhere — every setting and the side panel travel; machine-bound items stay; per-device switches")
struct SameEverywhereTests {
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var open: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }
    struct Side {
        let mac: CloudLeanFixtureMac
        let settings: BackendAppSettingsStore
        let state: NativeStateStore
        let defaults: UserDefaults
        let suite: String
        let owner: BackendCloudKindsSettings
        let adapter: CloudBrainRecordAdapter
    }
    static func side(_ device: String, clock: CloudLeanFixture.Clock, gate: Gate) throws -> Side {
        let mac = try CloudLeanFixture.mac(device, clock: clock)
        let settings = BackendAppSettingsStore(userData: mac.root.appendingPathComponent("data"), writable: true)
        let state = NativeStateStore()
        let suite = "terminaldeck.tests.same-everywhere." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let kept = try BackendCloudKindsKept(file: mac.root.appendingPathComponent("kept/replaced-values.json"), now: { 1_000 })
        let owner = BackendCloudKindsSettings(appSettings: settings, state: state, fullAccess: { true }, kept: kept,
            records: mac.store, chosenFile: mac.root.appendingPathComponent("settings-chosen.json"),
            choices: BackendCloudKindsChoices(defaults: defaults), newKindsOpen: { gate.open })
        return .init(mac: mac, settings: settings, state: state, defaults: defaults, suite: suite, owner: owner,
            adapter: try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins))
    }
    static func cleanup(_ sides: Side...) {
        for side in sides {
            side.defaults.removePersistentDomain(forName: side.suite)
            try? FileManager.default.removeItem(at: side.mac.root)
        }
    }
    /// Both ways until neither has anything more to send.
    static func settle(_ a: Side, _ aRun: CloudBrainRecordActivation, _ b: Side, _ bRun: CloudBrainRecordActivation,
                       first: (a: [CloudOperation], b: [CloudOperation])) async throws {
        var fromA = first.a, fromB = first.b
        for _ in 0..<4 {
            try await CloudLeanFixture.deliver(fromA, from: a.mac.device, to: b.adapter)
            try await CloudLeanFixture.deliver(fromB, from: b.mac.device, to: a.adapter)
            fromA = try await CloudLeanFixture.sync(aRun, on: a.mac)
            fromB = try await CloudLeanFixture.sync(bRun, on: b.mac)
            if fromA.isEmpty && fromB.isEmpty { return }
        }
        Issue.record("The two devices never settled")
    }

    @Test func aPinAndItsOrderArriveOnTheSecondDevice() async throws {
        let clock = CloudLeanFixture.Clock(), gate = Gate()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock, gate: gate), b = try Self.side(CloudLeanFixture.deviceB, clock: clock, gate: gate)
        defer { Self.cleanup(a, b) }
        let startA = try await CloudLeanFixture.start([a.adapter], on: a.mac), startB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await Self.settle(a, startA.activation, b, startB.activation, first: (startA.sent, startB.sent))
        // Pinned on the Mac mini, in his order, with a session pinned that the MacBook does not have yet.
        a.defaults.set(["tasks", "memory-page", "agents-all"], forKey: "sidebar.pagePins.v1")
        a.defaults.set(["tab-on-the-mac-mini"], forKey: "sidebar.pinnedTabs.v2")
        a.defaults.set(true, forKey: "chat.sessionPanel.open")
        let sent = try await CloudLeanFixture.sync(startA.activation, on: a.mac)
        #expect(CloudLeanFixture.text(sent).contains("sidebar.pagePins.v1"))
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.adapter)
        #expect(b.defaults.stringArray(forKey: "sidebar.pagePins.v1") == ["tasks", "memory-page", "agents-all"], "the pins and their order")
        #expect(b.defaults.stringArray(forKey: "sidebar.pinnedTabs.v2") == ["tab-on-the-mac-mini"], "kept until that session is here")
        #expect(b.defaults.bool(forKey: "chat.sessionPanel.open"))
        // Echo guard: nothing goes back.
        #expect(try await CloudLeanFixture.sync(startB.activation, on: b.mac).isEmpty)
        // A move on the MacBook goes the other way.
        b.defaults.set(["agents-all", "tasks", "memory-page"], forKey: "sidebar.pagePins.v1")
        let back = try await CloudLeanFixture.sync(startB.activation, on: b.mac)
        try await CloudLeanFixture.deliver(back, from: b.mac.device, to: a.adapter)
        #expect(a.defaults.stringArray(forKey: "sidebar.pagePins.v1") == ["agents-all", "tasks", "memory-page"])
    }

    @Test func theNewestChangeWinsPerSettingNotPerFile() async throws {
        let clock = CloudLeanFixture.Clock(), gate = Gate()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock, gate: gate), b = try Self.side(CloudLeanFixture.deviceB, clock: clock, gate: gate)
        defer { Self.cleanup(a, b) }
        let startA = try await CloudLeanFixture.start([a.adapter], on: a.mac), startB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await Self.settle(a, startA.activation, b, startB.activation, first: (startA.sent, startB.sent))
        _ = try await a.settings.patch(.object([.init("general.whenOpens", .string("hoot")), .init("advanced.debugMode", .bool(true))]))
        let fromA = try await CloudLeanFixture.sync(startA.activation, on: a.mac)
        _ = try await b.settings.patch(.object([.init("general.whenOpens", .string("left-off"))]))   // later, the same setting
        let fromB = try await CloudLeanFixture.sync(startB.activation, on: b.mac)
        try await Self.settle(a, startA.activation, b, startB.activation, first: (fromA, fromB))
        for side in [a, b] {
            #expect(await side.settings.value("general.whenOpens") == .string("left-off"), "the newest change of that setting")
            #expect(await side.settings.value("advanced.debugMode") == .bool(true), "the other setting is untouched")
        }
    }

    @Test func aJoiningDeviceNeverOverwritesWithItsDefaults() async throws {
        let clock = CloudLeanFixture.Clock(), gate = Gate()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock, gate: gate)
        defer { Self.cleanup(a) }
        a.defaults.set(["tasks", "memory-page"], forKey: "sidebar.pagePins.v1")
        let startA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        // The MacBook joins later with the side panel's first pages (with Cloud added): not a choice of his.
        let b = try Self.side(CloudLeanFixture.deviceB, clock: clock, gate: gate)
        defer { Self.cleanup(b) }
        b.defaults.set(Sidebar21Pages.defaults + [Sidebar21Pages.cloudID], forKey: "sidebar.pagePins.v1")
        let startB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        #expect(!CloudLeanFixture.text(startB.sent).contains("sidebar.pagePins.v1"), "defaults are never sent")
        try await Self.settle(a, startA.activation, b, startB.activation, first: (startA.sent, startB.sent))
        #expect(a.defaults.stringArray(forKey: "sidebar.pagePins.v1") == ["tasks", "memory-page"])
        #expect(b.defaults.stringArray(forKey: "sidebar.pagePins.v1") == ["tasks", "memory-page"])
    }

    @Test func aMachineBoundItemNeverLeaves() async throws {
        let clock = CloudLeanFixture.Clock(), gate = Gate()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock, gate: gate)
        defer { Self.cleanup(a) }
        let startA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        a.defaults.set("/Users/fixture/work", forKey: "session-start.lastFolder.v1")
        a.defaults.set([900.0, 600.0], forKey: "settingsWindow.size.v2")
        a.defaults.set("en", forKey: "AppleLanguages")
        _ = try await a.settings.patch(.object([.init("IslandShowOn", .string("main")), .init("remote.enabled", .bool(true)),
            .init("copilot.islandWidth", .number(420)),
            .init("browser.persistSession", .bool(false))]))
        _ = try await a.settings.patchProject("project-1", values: .object([.init("githubRepo", .string("fixture/site")),
            .init("localFolder", .string("/Users/fixture/site"))]))
        let text = CloudLeanFixture.text(try await CloudLeanFixture.sync(startA.activation, on: a.mac))
        for gone in ["lastFolder", "settingsWindow", "AppleLanguages", "IslandShowOn", "remote.enabled", "islandWidth", "localFolder", "/Users/fixture"] {
            #expect(!text.contains(gone), "\(gone) stays on this device")
        }
        #expect(text.contains("browser.persistSession") && text.contains("githubRepo"), "what is about him goes")
    }

    /// Lead's decision (15 Nov): what an AI may do without asking travels like every other setting. Changed on A it
    /// arrives on B; a store that joins with its defaults (a new or reset device) never loosens or tightens A.
    @Test func aPermissionSettingTravelsAndAJoiningDeviceWithDefaultsChangesNothing() async throws {
        let clock = CloudLeanFixture.Clock(), gate = Gate()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock, gate: gate), b = try Self.side(CloudLeanFixture.deviceB, clock: clock, gate: gate)
        defer { Self.cleanup(a, b) }
        let startA = try await CloudLeanFixture.start([a.adapter], on: a.mac), startB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await Self.settle(a, startA.activation, b, startB.activation, first: (startA.sent, startB.sent))
        _ = try await a.settings.patch(.object([.init("hoot.interactive", .bool(false)), .init("routines.maxRunsPerHour", .number(12))]))
        let sent = try await CloudLeanFixture.sync(startA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.adapter)
        #expect(await b.settings.value("hoot.interactive") == .bool(false))
        #expect(await b.settings.value("routines.maxRunsPerHour") == .number(12))
        // A third store joins with the app's defaults written out (on, 60 an hour): nothing of it is sent, A keeps his.
        let c = try Self.side("cccccccc-cccc-4ccc-8ccc-cccccccccccc", clock: clock, gate: gate)
        defer { Self.cleanup(c) }
        _ = try await c.settings.patch(.object([.init("hoot.interactive", .bool(true)), .init("routines.maxRunsPerHour", .number(60))]))
        let startC = try await CloudLeanFixture.start([c.adapter], on: c.mac)
        let fromC = CloudLeanFixture.text(startC.sent)
        #expect(!fromC.contains("hoot.interactive") && !fromC.contains("routines.maxRunsPerHour"), "defaults are never sent")
        try await Self.settle(a, startA.activation, c, startC.activation, first: (sent, startC.sent))
        #expect(await a.settings.value("hoot.interactive") == .bool(false))
        #expect(await a.settings.value("routines.maxRunsPerHour") == .number(12))
        #expect(await c.settings.value("hoot.interactive") == .bool(false), "the joining store takes his choice")
    }

    @Test func theNewSettingsWaitWhileAnOlderBuildIsOnTheAccount() async throws {
        let clock = CloudLeanFixture.Clock(), gate = Gate()
        gate.open = false
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock, gate: gate)
        defer { Self.cleanup(a) }
        let startA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        a.defaults.set(["tasks"], forKey: "sidebar.pagePins.v1")
        _ = try await a.settings.patch(.object([.init("appearance.terminalFontSize", .number(15)), .init("general.whenOpens", .string("hoot"))]))
        let closed = CloudLeanFixture.text(try await CloudLeanFixture.sync(startA.activation, on: a.mac))
        #expect(closed.contains("appearance.terminalFontSize"), "the first settings travel on every build")
        #expect(!closed.contains("sidebar.pagePins") && !closed.contains("general.whenOpens"))
        gate.open = true
        let open = CloudLeanFixture.text(try await CloudLeanFixture.sync(startA.activation, on: a.mac))
        #expect(open.contains("sidebar.pagePins.v1") && open.contains("general.whenOpens"))
    }

    /// A kind switched off on this device: nothing of it starts here (neither sends nor takes), the account's shared
    /// marks keep travelling so no other device waits for it, nothing is deleted, and the choice never leaves the device.
    @Test func aKindSwitchedOffHereStaysHereOnlyAndHoldsNobodyBack() throws {
        let all: Set<String> = ["I01", "I02", "I03", "I04", "I05", "I06", "I09", "I10", "I11", "I12", "I21", "I23", "I24"]
        #expect(CloudSyncChoices().rows(all) == all, "everything on by default")
        let noSettings = CloudSyncChoices().setting(.settings, on: false)
        #expect(!noSettings.rows(all).contains("I21") && noSettings.rows(all).contains("I12"))
        let noMemory = CloudSyncChoices().setting(.memory, on: false)
        #expect(noMemory.rows(all) == all.subtracting(["I01", "I02", "I03", "I04", "I06"]), "I05 carries the marks every gate reads")
        let noneAtAll = CloudSyncChoices(off: Set(CloudSyncKind.allCases))
        #expect(noneAtAll.rows(all) == ["I05"])
        #expect(CloudSyncKind.shown.contains(.sessions), "sessions and chats exist now (lane/mac-chats)")
        #expect(CloudSyncKind.shown.map(\.title) == ["Memory", "Projects", "Agents", "Tasks", "Instruction files", "Settings", "Cloud folder",
                                                    "Artifacts", "Saved passwords and secret files", "Code backup", "Sessions and chats"])
        // Kept in one file of this device, outside every account folder; missing or damaged = everything on.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("same-everywhere-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = CloudSyncChoices.file(cloudFolder: folder)
        #expect(CloudSyncChoices.load(file) == CloudSyncChoices())
        try noSettings.save(file)
        #expect(CloudSyncChoices.load(file) == noSettings)
        try Data("not json".utf8).write(to: file)
        #expect(CloudSyncChoices.load(file).off.isEmpty)
        // The choice itself is never a travelling setting.
        #expect(CloudBrainSettings.rule(.choice, CloudSyncChoices.fileName) == nil)
    }

    /// Switched on again it joins like a device that was off: what it chose while off is kept and sent, what changed
    /// elsewhere arrives, nothing is removed on either side.
    @Test func switchedOnAgainNothingIsLost() async throws {
        let clock = CloudLeanFixture.Clock(), gate = Gate()
        let a = try Self.side(CloudLeanFixture.deviceA, clock: clock, gate: gate)
        defer { Self.cleanup(a) }
        let startA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        a.defaults.set(["tasks", "memory-page"], forKey: "sidebar.pagePins.v1")
        let fromA = try await CloudLeanFixture.sync(startA.activation, on: a.mac)
        // B had Settings switched off: its owner did not run. While off he opened a section there.
        let b = try Self.side(CloudLeanFixture.deviceB, clock: clock, gate: gate)
        defer { Self.cleanup(b) }
        b.defaults.set(true, forKey: "deploy.hootPanel.collapsed")
        _ = try await b.settings.patch(.object([.init("general.copyOnSelect", .bool(true))]))
        let startB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await Self.settle(a, startA.activation, b, startB.activation, first: (startA.sent + fromA, startB.sent))
        for side in [a, b] {
            #expect(side.defaults.stringArray(forKey: "sidebar.pagePins.v1") == ["tasks", "memory-page"])
            #expect(side.defaults.bool(forKey: "deploy.hootPanel.collapsed"))
            #expect(await side.settings.value("general.copyOnSelect") == .bool(true))
        }
    }
}
