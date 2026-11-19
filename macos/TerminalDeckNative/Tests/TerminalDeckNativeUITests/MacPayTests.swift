import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

@Suite("MacPayTests — native navigation and complete offer inventory", .serialized)
@MainActor struct MacPayTests {
    private static let inventory: [(CloudPaidPlace, String, String)] = [
        (.sidebarCloud, "TerminalDeckNative/NativeCloudAccount.swift", "payment.offers(.sidebarCloud"),
        (.settingsCloud, "TerminalDeckNative/NativeCloudSettings.swift", "NativeCloudOffers.shows(.settingsCloud)"),
        (.settingsCloud, "TerminalDeckNative/NativeProfileSettings.swift", "model.snapshot.subscription.offers(.settingsCloud)"),
        (.devices, "TerminalDeckNative/NativeDevicesSettings.swift", "NativeCloudOffers.shows(.devices)"),
        (.devices, "TerminalDeckNative/MACHINESDevicesScreen.swift", "NativeCloudOffers.shows(.devices)"),
        (.devices, "TerminalDeckNative/NativeSettingsKit.swift", "gate.offers(.devices)"),
        (.phoneAndWebReach, "TerminalDeckNative/NativeMacReachSettings.swift", "NativeCloudOffers.shows(.phoneAndWebReach)"),
        (.pairing, "TerminalDeckNative/NativeJoinRemoteDialog.swift", "NativeCloudOffers.shows(.pairing)"),
        (.otherComputerSessions, "TerminalDeckNative/SidebarView.swift", "NativeCloudOffers.shows(.otherComputerSessions)"),
        (.otherComputerSessions, "TerminalDeckNative/NativeCloudChatsViews.swift", "NativeCloudOffers.shows(.otherComputerSessions)"),
        (.sessionMove, "TerminalDeckNative/NativeCloudChatsMove.swift", "NativeCloudOffers.shows(.sessionMove)"),
        (.sessionMove, "TerminalDeckNative/NativeCloudChatsViews.swift", "NativeCloudOffers.shows(.sessionMove)"),
        (.fileManager, "TerminalDeckNative/NativeCloudContents.swift", "NativeCloudOffers.shows(.fileManager)"),
        (.fileManager, "TerminalDeckNative/NativeCloudManager.swift", "NativeCloudOffers.shows(.fileManager)"),
        (.fileManager, "TerminalDeckNative/SHELLRoutes.swift", "NativeCloudOffers.shows(.fileManager)"),
        (.syncSwitches, "TerminalDeckNative/NativeCloudSyncChoices.swift", "NativeCloudOffers.shows(.syncSwitches)"),
        (.syncSwitches, "TerminalDeckNative/NativeCloudStatusLine.swift", "NativeCloudOffers.shows(.syncSwitches)"),
        (.savedPasswords, "TerminalDeckNative/NativeCloudSecrets.swift", "NativeCloudOffers.shows(.savedPasswords)"),
        (.phonesCopy, "TerminalDeckNative/NativeCloudSettings.swift", "NativeCloudOffers.shows(.phonesCopy)"),
        (.aiAppsInternet, "TerminalDeckNative/NativeAiAppsSettings.swift", "NativeCloudOffers.shows(.aiAppsInternet)"),
        (.remoteMachineChoices, "TerminalDeckNative/NativeBrowserBRMachines.swift", "NativeCloudOffers.shows(.remoteMachineChoices)"),
        (.remoteMachineChoices, "TerminalDeckNative/NativeCopilotMachines.swift", "NativeCloudOffers.shows(.remoteMachineChoices)"),
        // 19 Nov free plan: starting a session on another computer is a session feature (a free account keeps it).
        (.otherComputerSessions, "TerminalDeckNative/NativeNewSessionDialog.swift", "NativeCloudOffers.shows(.otherComputerSessions)"),
        (.remoteMachineChoices, "TerminalDeckNative/NativeServerHost.swift", "NativeCloudOffers.shows(.phoneAndWebReach)"),
        (.remoteMachineChoices, "TerminalDeckNative/NativeCodingAIStore.swift", "NativeCloudOffers.shows(.remoteMachineChoices)"),
        (.remoteMachineChoices, "TerminalDeckNative/NativeScrapingSettings.swift", "NativeCloudOffers.shows(.remoteMachineChoices)"),
        (.remoteMachineChoices, "TerminalDeckNative/NativeRemoteMacs.swift", "NativeCloudOffers.shows(.remoteMachineChoices)"),
        (.cloudTools, "TerminalDeckBackend/BackendCloudAccountTools.swift", "snapshot.subscription.offers(.cloudTools)"),
        (.cloudTools, "TerminalDeckBackend/BackendDeckCoreSecurityControl.swift", "CloudSubscriptionOffers.shared.showsTool("),
        (.cloudTools, "TerminalDeckBackend/BackendMCPTools.swift", "CloudSubscriptionOffers.shared.showsTool("),
        (.projectCloudActions, "TerminalDeckNative/NativeCodeBackupPage.swift", "NativeCloudOffers.shows(.projectCloudActions)"),
        (.pairing, "TerminalDeckNative/AppCommands.swift", "CloudSubscriptionOffers.shared.showsCommand("),
        (.pairing, "TerminalDeckNative/NativeCommandPalette.swift", "CloudSubscriptionOffers.shared.showsCommand("),
        (.otherComputerSessions, "TerminalDeckNative/NativeTerminalScreen.swift", "NativeCloudOffers.showsSession(SessionTarget(tabId: sessionId))"),
        (.otherComputerSessions, "TerminalDeckNative/NativeTerminalScreen.swift", "NativeCloudOffers.showsSession(session.target)"),
        (.remoteMachineChoices, "TerminalDeckNative/NativeRemoteMacs.swift", "struct NativeRemoteMacViewer: View"),
        (.artifactCloudActions, "TerminalDeckNative/NativeArtifactsCatalogModel.swift", "NativeCloudOffers.shows(.artifactCloudActions)"),
        (.artifactCloudActions, "TerminalDeckNative/NativeArtifactsCatalogCards.swift", "NativeCloudOffers.showsArtifact(cloudOnly: row.cloudPath != nil)"),
        (.artifactCloudActions, "TerminalDeckNative/NativeArtifactsCatalogCards.swift", "struct NativeArtifactsCatalogPreview: View"),
        (.artifactCloudActions, "TerminalDeckNative/NativeArtifactsCatalogScreen.swift", "NativeCloudOffers.shows(.artifactCloudActions)"),
    ]
    @Test func everyStepOnePlaceIsWiredAndOffIsAnIdentityForBothCapabilityValues() throws {
        #expect(Set(Self.inventory.map { $0.0 }) == Set(CloudPaidPlace.allCases))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        for (place, path, anchor) in Self.inventory {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains(anchor), "Missing paid-place wiring: \(path)")
            for available in [false, true] {
                let off = CloudSubscriptionSnapshot(lastAnswer: .init(paywall: .off, state: .none), available: available)
                for existing in [false, true] { #expect(off.offers(place, existing: existing) == existing, "\(path)") }
                for state in [CloudSubscription.State.none, .lapsed, .paid, .gift] {
                    let on = CloudSubscriptionSnapshot(lastAnswer: .init(paywall: .on, state: state), available: true)
                    #expect(on.offers(place) == (state == .paid || state == .gift || CloudPaidPlace.freeAccountPlaces.contains(place)), "\(path)")
                }
            }
        }
    }
    private func apply(_ answer: CloudSubscription?) {
        var snapshot = CloudAccountSnapshot(phase: .signedIn,
            gate: .init(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false, revision: .zero, expiresAt: nil))
        snapshot.subscription.received(answer)
        NativeCloudDisplayGate.shared.offer(true)
        NativeCloudAccount.shared.fixture(snapshot)
    }
    @Test func nativeNavigationOffIsUnchangedAndNoneOrLapsedRemovesAllPaidDestinations() {
        let old = NativeCloudAccount.shared.snapshot
        defer { NativeCloudAccount.shared.fixture(old); NativeCloudDisplayGate.shared.offer(false) }
        apply(nil)
        let baselineItems = NativeSettingsNavigation.items.map(\.id)
        let baselineProfile = NativeSettingsNavigation.profilePages.map(\.id)
        let baselineSearch = NativeSettingsNavigation.matching("cloud").map(\.id)
        for state in [CloudSubscription.State.none, .lapsed, .paid] {
            apply(.init(paywall: .off, state: state))
            #expect(NativeSettingsNavigation.items.map(\.id) == baselineItems)
            #expect(NativeSettingsNavigation.profilePages.map(\.id) == baselineProfile)
            #expect(NativeSettingsNavigation.matching("cloud").map(\.id) == baselineSearch)
            #expect(!NativeCloudOffers.showsSubscription)
        }
        // 19 Nov: with the paywall off, a gift's plan row is the one thing that is new.
        apply(.init(paywall: .off, state: .gift, source: .gift, tier: .paid, canBuyStorage: true))
        #expect(NativeSettingsNavigation.items.map(\.id) == baselineItems)
        #expect(NativeSettingsNavigation.profilePages.map(\.id) == baselineProfile + [NativeSettingsNavigation.planID])
        #expect(NativeCloudOffers.showsSubscription)
        for place in CloudPaidPlace.allCases { #expect(NativeCloudOffers.shows(place)) }
        for state in [CloudSubscription.State.none, .lapsed] {
            apply(.init(paywall: .on, state: state))
            #expect(!NativeCloudAccount.shared.visible)
            #expect(!NativeCloudDisplayGate.shared.shows)
            #expect(NativeCloudDisplayGate.shared.accountShows)
            #expect(!NativeScreens.registered.contains("settings:cloud"))
            #expect(!Sidebar21Pages.catalogue(nil, cloud: NativeCloudDisplayGate.shared.shows).contains { $0.id == Sidebar21Pages.cloudID })
            // 19 Nov free plan: a free account keeps its devices and its other computers' sessions; the rest goes.
            for place in CloudPaidPlace.allCases { #expect(NativeCloudOffers.shows(place) == CloudPaidPlace.freeAccountPlaces.contains(place), "\(place)") }
            #expect(NativeSettingsNavigation.canonical("cloud") == "general")
            #expect(NativeSettingsNavigation.canonical("devices") != "general")
            #expect(!NativeSettingsNavigation.profilePages.contains { $0.id == "cloud" })
            #expect(NativeSettingsNavigation.profilePages.contains { $0.id == "devices" })
            #expect(CloudSubscriptionOffers.shared.showsCommand("devices") && !CloudSubscriptionOffers.shared.showsCommand("app.join"))
            #expect(NativeSettingsNavigation.profilePages.contains { $0.id == NativeSettingsNavigation.planID })
            #expect(NativeSettingsNavigation.items.contains { $0.id == "profile" })
            #expect(NativeSettingsNavigation.profilePages.contains { $0.id == "profile.sign-in" })
        }
        // 19 Nov free plan: the sign-in screen helper is told "closed" for a free account, his own setting otherwise.
        apply(.init(paywall: .on, state: .none, tier: .free))
        #expect(!NativeMacReach.helperAllowed)
        apply(.init(paywall: .off, state: .none, tier: .free))
        #expect(NativeMacReach.helperAllowed == NativeMacScreenSetting.allowed)
        for state in [CloudSubscription.State.paid, .gift] {
            apply(.init(paywall: .on, state: state))
            #expect(NativeMacReach.helperAllowed == NativeMacScreenSetting.allowed)
            for place in CloudPaidPlace.allCases { #expect(NativeCloudOffers.shows(place)) }
            #expect(NativeCloudAccount.shared.visible)
            #expect(NativeCloudDisplayGate.shared.shows)
            #expect(NativeSettingsNavigation.profilePages.contains { $0.id == "cloud" })
            #expect(NativeSettingsNavigation.profilePages.contains { $0.id == NativeSettingsNavigation.planID })
        }
    }
    @Test func subscriptionToolDiscoveryAndExistingLocalAndWhatsAppToolsUseTheSameRule() async throws {
        let old = NativeCloudAccount.shared.snapshot
        defer { NativeCloudAccount.shared.fixture(old); NativeCloudDisplayGate.shared.offer(false) }
        let server = BackendNativeMCPServer()
        for id in ["machines.look", "cloud.status", "sessions.list", "whatsapp.agents", "devices.list", "cloud.subscription"] {
            let tool = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: "Synthetic Mac payment fixture", inputSchema: .object([.init("type", .string("object"))]), tier: .read)
            try await server.registerTool(tool) { _, _ in .value(.null) }
        }
        apply(.init(paywall: .off, state: .none))
        let all = try await server.catalogue().map(\.id)
        #expect(all.count == 5)
        apply(.init(paywall: .on, state: .lapsed))
        // 19 Nov free plan: the tools for other computers' sessions stay with a free account.
        #expect(try await server.catalogue().map(\.id) == ["cloud.subscription", "devices.list", "machines.look", "sessions.list", "whatsapp.agents"])
        apply(.init(paywall: .on, state: .gift))
        #expect(try await server.catalogue().map(\.id) == (all + ["cloud.subscription"]).sorted())
    }
    @Test func aFreeAccountsSidePanelListsItsOtherComputersSessionsFromTheirLiveLinks() throws {
        let raw: [String: Any] = ["machines": [["id": "reach-pc", "name": "Office PC"]], "links": [
            ["id": "reach-pc", "state": "online", "sessions": [
                ["id": "s1", "title": "Build", "cwd": "/w/app", "provider": "claude", "status": "working"],
                ["id": "s2", "title": "", "cwd": "/w/site", "provider": "codex", "status": "idle", "chat": true],
                ["id": "s3", "title": "Old", "cwd": "/w", "provider": "claude", "status": "exited", "exitCode": 0]]],
            ["id": "reach-off", "state": "offline", "sessions": [["id": "s9", "title": "Gone", "cwd": "/", "provider": "claude", "status": "idle"]]],
            ["id": "paired-mac", "state": "online", "sessions": [["id": "p1", "title": "Paired", "cwd": "/", "provider": "claude", "status": "idle"]]]]]
        let links = try #require(MachinesSnapshot.decode(raw))
        let open = MachinesRules.tabId(machineId: "reach-pc", sessionId: "s1")
        // Only his account's computers that are on, only sessions still running, one row each, none already open here.
        let rows = NativeRemoteSessionRows.liveOthers(links: links, shown: [])
        #expect(rows.map(\.id) == [open, MachinesRules.tabId(machineId: "reach-pc", sessionId: "s2")])
        #expect(rows.map(\.title) == ["Build", "site"])
        #expect(NativeRemoteSessionRows.chat(rows[1].id, links: links))
        #expect(NativeRemoteSessionRows.liveOthers(links: links, shown: [open]).map(\.id) == [rows[1].id])
        // The rows are drawn only for a free account, and a press opens the live session there.
        let sidebar = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckNative/SidebarView.swift"), encoding: .utf8)
        #expect(sidebar.contains("let free = NativeCloudAccount.shared.snapshot.subscription.limitsRemoteToSessions"))
        #expect(sidebar.contains("NativeCloudOffers.shows(.otherComputerSessions) && !free ? cloud.others : []"))
        #expect(sidebar.contains("guard free else { return lines }"))
        #expect(sidebar.contains("sessionRow(item, agents: sessionAgents, press: livePress(line))"))
        #expect(sidebar.contains("return { NativeMachineSessionRoute.open(tabId: item.id) }"))
    }
    @Test func freshUnpaidSignInRemainsDiscoverableAtNextLaunchWithoutCloudStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-pay-launch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!NativeCloudLaunch.used(dataRoot: root))
        NativeCloudLaunch.recordSession(.signedIn, dataRoot: root)
        #expect(NativeCloudLaunch.used(dataRoot: root))
        #expect(!NativeCloudLaunch.isDormant(dataRoot: root))
        #expect(!FileManager.default.fileExists(atPath: NativeCloudLaunch.signedOutMarker(root).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: NativeCloudLaunch.folder(root).path).isEmpty)
    }

    @Test func openSessionSurfacesHideOnlyRelayTargetsAndKeepLocalAndSSHAvailable() {
        let old = NativeCloudAccount.shared.snapshot
        defer { NativeCloudAccount.shared.fixture(old); NativeCloudDisplayGate.shared.offer(false) }
        let relay = SessionTarget.machine(machineId: "fixture-machine", sessionId: "fixture-session")
        let local = SessionTarget.local("fixture-local")
        let ssh = SessionTarget.server(serverId: "fixture-server", shellKey: "fixture-shell")
        for state in [CloudSubscription.State.none, .lapsed, .paid, .gift] {
            apply(.init(paywall: .on, state: state))
            #expect(NativeCloudOffers.showsSession(relay), "a free account keeps its other computers' sessions")
            #expect(NativeCloudOffers.showsSession(local))
            #expect(NativeCloudOffers.showsSession(ssh))
            #expect(NativeCloudOffers.showsArtifact(cloudOnly: false))
            #expect(NativeCloudOffers.showsArtifact(cloudOnly: true) == (state == .paid || state == .gift))
            apply(.init(paywall: .off, state: state))
            #expect(NativeCloudOffers.showsSession(relay))
            #expect(NativeCloudOffers.showsArtifact(cloudOnly: true))
        }
    }

}
