import AppKit
import CoreImage
import SwiftUI
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Called from the actual view test target, with inert models only.
@MainActor
enum MACHINESRenderEvidence {
    static func fixtureModel() -> NativeServersModel {
        let model = NativeServersModel.shared
        model.setFixture(servers: MACHINESFixtures.servers)
        for (index, server) in model.servers.enumerated() {
            model.remember(MACHINESFixtures.serverState(server.id, index: index))
        }
        return model
    }
    static func focusedChecks() async throws -> Int {
        try await MACHINESFocusedChecks.run(model: fixtureModel())
    }
    static func renderAll(to out: URL) throws {
        let model = fixtureModel()
        guard let server = model.servers.first, let state = model.states[server.id] else {
            throw MACHINESFocusedChecks.failure("Missing render fixture.")
        }
        let access = NativeServerAccessModel(fixture: server.id, lookOnly: true, sshAlias: "imza-server",
            keys: MACHINESFixtures.aiKeys, allowed: ["fixture-imatch"])
        let remote = MACHINESFixtures.remoteModel()
        let duties = try MACHINESFixtures.serverDuties(server.id)
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            func save<V: View>(_ view: V, _ name: String, _ width: CGFloat, _ height: CGFloat) throws {
                try MACHINESHiddenRender.render(view, dark: dark, size: CGSize(width: width, height: height),
                    to: out.appendingPathComponent("MACHINES-\(name)-\(theme).png"))
            }
            try save(NativeMACHINESServersDashboard(model: model, route: .constant(.list), live: false,
                fixtureProjects: MACHINESFixtures.projects), "servers", 1120, 840)
            try save(NativeServerPage(model: model, server: server, route: .constant(.list),
                accessFixture: access, live: false, fixtureState: state, projectId: "imatch"), "server-detail", 1120, 840)
            for tab in ["Coding AIs", "Websites", "Health"] {
                try save(NativeServerPage(model: model, server: server, route: .constant(.list),
                    accessFixture: access, live: false, fixtureState: state, projectId: "imatch", initialView: tab),
                    "server-" + tab.lowercased().replacingOccurrences(of: " ", with: "-"), 1120, 840)
            }
            try save(MACHINESServerSettingsContent(model: model, server: server,
                accessFixture: access, live: false), "server-settings", 560, 520)
            for tab in ["Sign-in", "Apps setup", "Alerts", "Advanced"] {
                try save(MACHINESServerSettingsContent(model: model, server: server,
                    accessFixture: access, live: false, initialTab: tab, serverFixture: duties),
                    "server-settings-" + tab.lowercased().replacingOccurrences(of: " ", with: "-"), 560, 520)
            }
            try save(MACHINESDevicesScreen(model: remote, fixture: true), "devices", 1120, 840)
            try save(MACHINESDevicesScreen(model: remote, fixture: true), "devices-window", 760, 560)
            try save(MACHINESDevicesPairSheet(model: remote, machines: MachinesHalfModel(), fixture: true, close: {})
                .background(MACHINESTokens.page), "pairing", 640, 560)
            // #27: Someone else's opens the guest steps (folders first) for the waiting device.
            let guest = MACHINESFixtures.remoteModel()
            if let waiting = guest.state?.devices.first(where: { $0.state == .pending }) {
                var approval = RemoteApproval(device: waiting); approval.pick(.guest); guest.approving = approval
            }
            try save(MACHINESDevicesPairSheet(model: guest, machines: MachinesHalfModel(), fixture: true, whose: .guest, close: {})
                .background(MACHINESTokens.page), "pairing-guest", 640, 760)
            try save(MACHINESDevicesAccessContent(model: remote, fixture: true), "device-access", 560, 520)
            try save(MACHINESAddServerSheet(model: model, route: .constant(.list), cancel: {}, fixtureAliases: MACHINESFixtures.aliases),
                "add-server", 600, 550)
        }
    }
}

@MainActor
enum MACHINESFixtures {
    static let projects = ["fixture-imatch": "imatch", "fixture-crm": "crm"]
    static var servers: CodingAIJSON {
        CodingAIJSON([
            ["id": "fixture-imatch", "name": "iMatch production", "address": "imza-server", "username": "admin", "lookOnly": true],
            ["id": "fixture-crm", "name": "CRM server", "address": "46.28.44.154", "username": "root", "lookOnly": true],
            ["id": "fixture-independent", "name": "Example server", "address": "example.invalid", "username": "deploy", "lookOnly": true],
        ])
    }
    static var aiKeys: [AiAccessKey] {
        AiAppsState.from(CodingAIJSON(["keys": [
            ["id": "fixture-imatch", "name": "ClaudeiMatch", "level": "look"],
            ["id": "fixture-dot", "name": "Dot", "level": "look"],
        ]]))?.keys ?? []
    }
    static var aliases: [ServerSSHAlias] {
        ServerSSHAlias.parse(CodingAIJSON(["ok": true, "aliases": [
            ["alias": "imza-server", "hostname": "imza-server", "user": "admin", "port": 22, "ready": true, "keyNames": ["id_ed25519"], "serverId": "fixture-imatch"],
            ["alias": "imza-vps", "hostname": "46.28.44.154", "user": "root", "port": 22, "ready": true, "keyNames": ["id_ed25519"], "serverId": "fixture-crm"],
        ]])) ?? []
    }
    static func serverDuties(_ id: String) throws -> NativeAppsSRV2ServerModel {
        let status = try JSONDecoder().decode(NativeAppsSRV2ServerModel.Status.self, from: Data(#"{"hostname":"fixture-server","administrator":true,"supported":true,"docker":"28.0","installedVersion":"1","helperVersion":"1","router":"caddy","routerSummary":"Web addresses use HTTPS.","diskPercent":70,"memoryMB":16384}"#.utf8))
        let plan = try JSONDecoder().decode(NativeAppsSRV2ServerModel.Plan.self, from: Data(#"{"steps":[{"title":"Apps","detail":"Keep apps running on this server."},{"title":"Web addresses","detail":"Set up HTTPS through the existing server connection."}],"version":"1","upgrade":false}"#.utf8))
        return NativeAppsSRV2ServerModel(fixtureServerID: id, serverName: "iMatch production", status: status, plan: plan)
    }
    static func serverState(_ id: String, index: Int) -> ServerRoomState {
        let names = ["supabase-auth", "supabase-kong", "realtime-dev", "soketi", "supabase-minio", "supabase-analytics"]
        let images = ["supabase/gotrue:v2.186.0", "kong/kong:3.9.1", "supabase/realtime:v2.76.5", "coollabsio/coolify-realtime:1.0.11", "coollabsio/minio:2025-10-15", "supabase/logflare:1.31.2"]
        let cards: [[String: Any]] = zip(names, images).enumerated().map { i, values in
            ["id": "fixture-app-\(i)", "kind": "app", "name": values.0, "detail": values.1,
             "running": index == 0 ? ![2, 4].contains(i) : true]
        }
        func fact(_ value: Any) -> [String: Any] { ["known": "yes", "value": value] }
        let totalDisk = 160.0 * 1_048_576
        let totalMemory = 16.0 * 1_048_576
        var state = ServerRoomState(id: id, link: .ready)
        state.view = ServerView.parse(CodingAIJSON([
            "cards": cards, "measuredAt": Date().timeIntervalSince1970 * 1000 - 60_000,
            "facts": [
                "disk": fact(["usedKb": totalDisk * [0.70, 0.38, 0.22][index], "totalKb": totalDisk]),
                "memory": fact(["usedKb": totalMemory * [0.43, 0.61, 0.30][index], "totalKb": totalMemory]),
                "cpus": fact(4), "load": fact([0.42, 2.6, 0.08][index]),
                "uptimeSeconds": fact([167, 41, 12][index] * 86400),
                "agents": fact([["id": "claude", "path": "/fixture/claude", "version": "2.1", "signedIn": "yes", "account": "fixture@example.invalid"],
                    ["id": "codex", "path": "/fixture/codex", "version": "1.0", "signedIn": index == 1 ? "yes" : "no"]]),
            ],
        ]))
        return state
    }
    static let pairingURL = "terminaldeck://pair?v=1&r=wss://example.invalid&h=fixture&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&t=123456"
    static func remoteModel() -> RemoteSectionModel {
        let now = Date().timeIntervalSince1970 * 1000
        let model = RemoteSectionModel()
        model.setRenderFixture(state: RemoteState(running: true, relay: RemoteRelay(connected: true), devices: [
            RemoteDevice(id: "fixture-phone", name: "Asad’s iPhone", state: .approved, addedAt: now - 86_400_000, lastSeenAt: now),
            RemoteDevice(id: "fixture-simulator", name: "TD Hoot Edition", state: .approved, addedAt: now - 21_600_000, lastSeenAt: now - 21_600_000),
            RemoteDevice(id: "fixture-pc", name: "Office PC", state: .approved, addedAt: now - 30 * 86_400_000, lastSeenAt: now - 4 * 86_400_000),
            RemoteDevice(id: "fixture-request", name: "iPhone 17 Pro", state: .pending, addedAt: now),
            RemoteDevice(id: "fixture-revoked", name: "Revoked device", state: .revoked),
        ], connections: [RemoteConnection(id: "fixture-connection", deviceId: "fixture-phone", deviceName: "Asad’s iPhone", platform: "iOS", connectedAt: now)]),
            pairing: RemotePairing(token: "123456", expiresAt: now + 48_000, findable: true), pairingURL: pairingURL)
        return model
    }
}

@MainActor
enum MACHINESFocusedChecks {
    static func failure(_ message: String) -> NSError {
        NSError(domain: "MACHINESFocusedChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func run(model: NativeServersModel) async throws -> Int {
        var count = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw failure(message) }
            count += 1
            print("PASS MACHINES: \(message)")
        }
        let rows = model.servers
        try expect(rows.count == 3 && rows[1].address == "46.28.44.154", "Fixtures preserve the CRM address")
        try expect(NativeMACHINESServersDashboard.filtered(rows, project: "all", links: MACHINESFixtures.projects).count == 3, "All projects includes independent servers")
        try expect(NativeMACHINESServersDashboard.filtered(rows, project: "imatch", links: MACHINESFixtures.projects).map(\.id) == ["fixture-imatch"], "iMatch filter excludes CRM")
        try expect(NativeMACHINESServersDashboard.filtered(rows, project: "crm", links: MACHINESFixtures.projects).map(\.id) == ["fixture-crm"], "CRM filter excludes iMatch")
        try expect(NativeMACHINESServersDashboard.filtered(rows, project: "independent", links: MACHINESFixtures.projects).map(\.id) == ["fixture-independent"], "Unlinked server stays independent")
        try expect(NativeMACHINESServersDashboard.filtered(rows, project: "missing", links: MACHINESFixtures.projects).isEmpty, "Unknown project has no unrelated servers")
        try expect(NativeMACHINESServersDashboard.stopped(model.states["fixture-imatch"]) == 2 && NativeMACHINESServersDashboard.stopped(nil) == 0, "Attention count uses measured stopped apps")

        let accepted = MACHINESFixtures.remoteModel()
        let request = accepted.state!.devices.first { $0.state == .pending }!
        var calls: [(String, [Any?])] = []
        let allowed = await accepted.letIn(request, access: "look", invoke: { channel, arguments in
            calls.append((channel, arguments))
            return [["id": request.id, "status": "approved", "access": "look"]]
        }, refreshAfter: false)
        try expect(allowed && calls.count == 1 && calls[0].0 == "remote:device:approve-access" && calls[0].1[1] as? String == "look", "Pairing submits access with approval in one operation")
        try expect(accepted.pairing == nil && accepted.pairingURL == nil && accepted.highlightedDeviceID == request.id && accepted.state?.devices.first(where: { $0.id == request.id })?.state == .approved, "Confirmed approval closes code and highlights the approved row")
        // #27: Work, offered by the sheet's picker, lets the device in (it was refused without a word).
        let working = MACHINESFixtures.remoteModel()
        let workAllowed = await working.letIn(request, access: "work", invoke: { channel, arguments in
            [["id": request.id, "status": "approved", "access": arguments[1] as? String ?? ""]]
        }, refreshAfter: false)
        try expect(workAllowed && working.state?.devices.first(where: { $0.id == request.id })?.state == .approved, "Work from the picker lets the device in")
        try expect(MACHINESDevicesPairSheet.mineNote.contains("every login") && MACHINESDevicesPairSheet.guestNote.contains("folders and logins you choose"),
                    "My device says it gets every login; Someone else's says only what you choose")
        let refused = MACHINESFixtures.remoteModel()
        let no = await refused.letIn(request, access: "full", invoke: { _, _ in [["id": request.id, "status": "pending"]] }, refreshAfter: false)
        try expect(!no && refused.pairing != nil && refused.highlightedDeviceID == nil && refused.notice?.ok == false, "Refused approval preserves the same sheet and shows an error")
        let broken = MACHINESFixtures.remoteModel()
        let failed = await broken.letIn(request, access: "hoot", invoke: { _, _ in throw failure("Fixture refusal") }, refreshAfter: false)
        try expect(!failed && broken.busy == nil && broken.pairing != nil && broken.state?.devices.first(where: { $0.id == request.id })?.state == .pending, "Transport error never approves or clears the code")
        var invalidCalls = 0
        let invalid = await broken.letIn(request, access: "owner", invoke: { _, _ in invalidCalls += 1; return [] }, refreshAfter: false)
        try expect(!invalid && invalidCalls == 0, "Unknown access is refused before transport")
        let malformed = MACHINESFixtures.remoteModel()
        let malformedAccepted = await malformed.letIn(request, access: "look", invoke: { _, _ in ["ok": true] }, refreshAfter: false)
        try expect(!malformedAccepted && malformed.pairing != nil && malformed.highlightedDeviceID == nil, "Success without an approved device is refused")
        let wrong = MACHINESFixtures.remoteModel()
        let wrongAccepted = await wrong.letIn(request, access: "look", invoke: { _, _ in [["id": request.id, "status": "approved", "access": "full"]] }, refreshAfter: false)
        try expect(!wrongAccepted && wrong.pairing != nil && wrong.highlightedDeviceID == nil
            && wrong.state?.devices.first(where: { $0.id == request.id })?.state == .pending,
            "A different approved access level never closes the sheet or approves the row")
        let missing = MACHINESFixtures.remoteModel()
        let missingAccepted = await missing.letIn(request, access: "look", invoke: { _, _ in [["id": request.id, "status": "approved"]] }, refreshAfter: false)
        try expect(!missingAccepted && missing.pairing != nil && missing.highlightedDeviceID == nil,
            "Approval without a confirmed access level keeps the sheet open")
        try expect(MACHINESDevicesQR.image(MACHINESFixtures.pairingURL) != nil, "QR image uses the real pairing payload")
        return count
    }
}
