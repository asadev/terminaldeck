import AppKit
import Foundation
import Observation
import TerminalDeckNativeCore

/// DEPLOY-PIPELINE: the one deployment record in the app, for the tools and every view that shows it (the project's
/// Deployments card, the side-panel pill, the live strip beside where the person asked). Kept in
/// `<app data>/deployments.json`; live sources (GitHub Actions, Terminal Deck Apps) are read into it when a project's
/// card opens, and read again only while one of their runs is still going.
@MainActor @Observable
final class DeployBoard {
    static let shared = DeployBoard()

    private(set) var ledger = DeployLedger()
    /// A project whose Deployments card should come up (the pill, "Open in project").
    var focus: String?
    /// Projects whose live sources are being read now.
    private(set) var reading: Set<String> = []
    @ObservationIgnored private var file: URL?
    /// U1: false while deployments.json could not be read and no copy of it could be kept; nothing is saved over it.
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private(set) var saveCount = 0
    @ObservationIgnored private var follow: [String: Task<Void, Never>] = [:]

    init(ledger: DeployLedger = DeployLedger()) { self.ledger = ledger }

    func configure(dataRoot: URL) {
        let url = dataRoot.appendingPathComponent(DeployLedgerFile.name)
        guard file != url else { return }
        file = url
        let loaded = DeployLedgerFile.load(url)
        ledger = loaded.ledger; writable = loaded.writable
        if let problem = loaded.problem { NSLog("[deploy] %@", problem) }
        // #492: runs an AI started and never finished are closed when the app starts.
        var closed = ledger
        if closed.closeQuiet(at: Self.now) > 0 { change { $0 = closed } }
    }

    /// Every change updates the screen immediately; nearby saves share one utility write.
    @discardableResult
    func change<T>(_ body: (inout DeployLedger) throws -> T) rethrows -> T {
        var copy = ledger
        let result = try body(&copy)
        ledger = copy
        if let file, writable {
            pendingSave?.cancel()
            pendingSave = Task {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                let snapshot = ledger, previous = writing
                let write = Task.detached(priority: .utility) {
                    await previous?.value
                    do { try DeployLedgerFile.save(snapshot, to: file) }
                    catch { NSLog("[deploy] the record was not saved: %@", error.localizedDescription) }
                }
                writing = write; saveCount += 1
                await write.value
            }
        }
        return result
    }

    func waitForSave() async { await pendingSave?.value }

    static var now: Double { Date().timeIntervalSince1970 }

    // MARK: Opening a project's card

    func open(_ projectID: String) {
        guard let project = SHELLRoutes.registry.first(where: { $0.id == projectID }), let folder = project.folders.first else { return }
        focus = projectID
        AppModel.shared.select(SHELLRoutes.projectPrefix + folder)
    }
    func projectName(_ id: String) -> String { SHELLRoutes.registry.first { $0.id == id }?.name ?? id }

    // MARK: History read once from the project's own board

    /// Terminal Deck's ROUTE.md install lines, once per project (real history, so the card is not empty on first open).
    func importBoards(_ projects: [PROJProject]) async {
        for project in projects where project.id != PROJProjects.independentID && !ledger.imports.contains("route:" + project.id) {
            let places = project.folders.flatMap { folder in DeployRouteLog.places.map { URL(fileURLWithPath: folder).appendingPathComponent($0) } }
            guard let board = places.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            let id = project.id
            let runs = await Task.detached(priority: .utility) { () -> [DeployRun] in
                guard let text = try? String(contentsOf: board, encoding: .utf8) else { return [] }
                return DeployRouteLog.runs(text, projectID: id)
            }.value
            change { ledger in ledger.merge(runs); ledger.imports.append("route:" + id) }
        }
    }

    // MARK: Live sources

    /// GitHub Actions for the project's repository and Terminal Deck Apps on its servers, mapped into the record.
    /// Uses the app's existing GitHub sign-in and server links; nothing new to sign in to. Quiet when not linked.
    func sync(_ project: PROJProject) async {
        guard project.id != PROJProjects.independentID, !reading.contains(project.id) else { return }
        reading.insert(project.id); defer { reading.remove(project.id) }
        let settings = await Self.settings(project.id)
        let repo = await Self.repository(project, settings: settings)
        var found: [DeployRun] = []
        if let repo { found += await githubRuns(repo: repo, projectID: project.id) }
        found += await appsRuns(project, repo: repo, settings: settings)
        change { $0.merge(found) }
        // Read again only while one of them is still going.
        follow[project.id]?.cancel()
        if found.contains(where: \.isLive) {
            follow[project.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.sync(project)
            }
        }
    }

    private static func settings(_ projectID: String) async -> NativeRPCValue {
        guard let raw = try? await EngineBridge.shared.invoke("project-settings:get", [["projectId": projectID]]),
              let value = try? NativeRPCValue.fromFoundation(raw) else { return .missing }
        return value["values"]
    }
    private static func repository(_ project: PROJProject, settings: NativeRPCValue) async -> String? {
        if let linked = settings[PROJSetup.repoKey].string?.trimmingCharacters(in: .whitespaces), linked.contains("/") {
            return linkedRepository(linked)
        }
        guard let folder = project.folders.first, let raw = try? await EngineBridge.shared.invoke("github:auth-status", [folder]) else { return nil }
        let name = GitHubAuthState(json: raw).repo?.ref?.nameWithOwner ?? ""
        return name.isEmpty ? nil : name
    }

    /// owner/name from a linked repository: a web or git@ address loses its prefix and only a
    /// trailing ".git", so "owner/my.github-tools" keeps its name.
    nonisolated static func linkedRepository(_ linked: String) -> String {
        var name = linked
        for prefix in ["https://github.com/", "http://github.com/", "git@github.com:"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        while name.hasSuffix("/") { name.removeLast() }
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
    }

    private func githubRuns(repo: String, projectID: String) async -> [DeployRun] {
        guard let answer = try? await NativeGHBridge.call("actions.runs", ["repo": .string(repo), "perPage": .number(30)]),
              let items = (try? NativeRPCValue.fromFoundation(answer.foundation))?["items"].elements else { return [] }
        var runs: [DeployRun] = []
        for item in items.filter(DeployGitHubActions.isDeploy).prefix(15) {
            guard let id = item["id"].number.map({ Int($0) }) else { continue }
            // Jobs are read for a run still going and for one not seen finished before; a finished run keeps its steps.
            let known = ledger.run(DeployGitHubActions.source + ":\(id)")
            var jobs: [NativeRPCValue]?
            if item["status"].string != "completed" || known == nil || known?.isLive == true {
                if let answer = try? await NativeGHBridge.call("actions.jobs", ["repo": .string(repo), "runId": .number(Double(id))]) {
                    jobs = (try? NativeRPCValue.fromFoundation(answer.foundation))?["items"].elements
                }
            } else if let known, known.state.finished { runs.append(known); continue }
            if let run = DeployGitHubActions.run(item, jobs: jobs, projectID: projectID) { runs.append(run) }
        }
        return runs
    }

    private func appsRuns(_ project: PROJProject, repo: String?, settings: NativeRPCValue) async -> [DeployRun] {
        let named = Set((settings[PROJSetup.serversKey].string ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        guard let raw = try? await EngineBridge.shared.invoke("servers:list"), let servers = (try? NativeRPCValue.fromFoundation(raw))?.elements else { return [] }
        let linked = servers.filter { server in
            server["projectId"].string == project.id || server["projectID"].string == project.id || named.contains((server["name"].string ?? "").lowercased())
        }
        var runs: [DeployRun] = []
        for server in linked {
            guard let serverID = server["id"].string else { continue }
            let serverName = server["name"].string ?? serverID
            guard let list = try? await EngineBridge.shared.invoke("apps:list", [["serverId": serverID]], timeout: 30),
                  let value = try? NativeRPCValue.fromFoundation(list) else { continue }
            let apps = value.elements ?? value["apps"].elements ?? value["items"].elements ?? []
            for app in apps {
                guard let appID = app["id"].string else { continue }
                let appRepo = (app["source"]["repository"].string ?? app["repository"].string)?.lowercased()
                // With a repository known, only its apps; with none, every app on a server linked to the project.
                if let repo, appRepo != repo.lowercased(), (app["name"].string ?? "").lowercased() != project.name.lowercased() { continue }
                guard let history = try? await EngineBridge.shared.invoke("apps:deployments", [["serverId": serverID, "appId": appID]], timeout: 30),
                      let rows = (try? NativeRPCValue.fromFoundation(history))?.elements else { continue }
                runs += rows.prefix(20).compactMap { DeployTDApps.run($0, app: app, serverID: serverID, server: serverName, projectID: project.id) }
            }
        }
        return runs
    }
}
