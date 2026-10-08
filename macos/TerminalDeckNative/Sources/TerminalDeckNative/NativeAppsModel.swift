import Foundation
import Observation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Per-visible-server UI cache. The server owns every durable record and secret.
@MainActor
@Observable
final class NativeAppsModel {
    let serverID: String
    private(set) var capabilities = NativeAppsCapabilities()
    private(set) var checkingCapabilities = false
    private(set) var capabilityReadProblem: String?
    private(set) var apps: [NativeAppsSummary] = []
    private(set) var loading = true
    private(set) var problem: String?
    private(set) var operationProblem: String?
    private(set) var notice: String?
    private(set) var busy: String?
    private(set) var operationAppID: String?
    private(set) var operationAppName: String?
    private(set) var selectedID: String?
    private(set) var detail: NativeAppsDetail?
    private(set) var detailLoading = false
    private(set) var sectionLoading = false
    private(set) var sectionProblem: String?
    private(set) var logs: [String] = []
    private(set) var logsLive = false
    private(set) var activeTab = NativeAppsTab.overview
    private(set) var draftAddressCheck: NativeAppsAddress?
    private(set) var dataBackupSettings: NativeAppsDataBackupSettings?
    private(set) var dataDatabaseConnection: NativeAppsDataDatabaseConnection?
    private(set) var dataDatabaseLoading = false
    private(set) var dataDatabaseProblem: String?
    private(set) var repositories: [NativeAppsRepository] = []
    private(set) var templates: [NativeAppsTemplate] = []
    private(set) var catalogLoading = false
    private(set) var catalogProblem: String?
    var showingNewApp = false
    var search = ""

    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var sectionTask: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var databaseTask: Task<Void, Never>?
    @ObservationIgnored private var catalogGeneration = 0
    @ObservationIgnored private var streamID: String?
    @ObservationIgnored private var endedStreamID: String?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var activeDeploymentID: String?
    @ObservationIgnored private var savedDomains: [String]?
    @ObservationIgnored private var capabilitiesTask: Task<Void, Never>?
    @ObservationIgnored private var capabilitiesLoaded = false

    init(serverID: String) { self.serverID = serverID }

    var selectedApp: NativeAppsSummary? { apps.first { $0.id == selectedID } ?? detail?.app }
    var displayProblem: String? { operationProblem ?? problem }
    var canChange: Bool { capabilities.canChange && !checkingCapabilities }
    var writesUnavailableReason: String? {
        checkingCapabilities ? "Checking whether this server supports changes…" : capabilityReadProblem ?? capabilities.unavailableMessage
    }
    var filteredApps: [NativeAppsSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.address?.localizedCaseInsensitiveContains(query) == true) }
    }

    private func call(_ channel: String, _ additional: [String: Any] = [:]) async throws -> NativeRPCValue {
        if BackendAppsChannels.writeChannels.contains(channel) || BackendAppsDataChannels.writeChannels.contains(channel) {
            guard canChange else { throw NativeRPCError(code: "unavailable", message: "Changes are unavailable on this server.") }
        }
        var payload = additional
        payload["serverId"] = serverID
        let result = try await EngineBridge.shared.invoke(channel, [payload], timeout: 90)
        return try NativeRPCValue.fromFoundation(result)
    }

    func start() {
        guard !visible else { return }
        visible = true
        subscriptions = [
            EngineBridge.shared.on("apps:changed") { [weak self] args in self?.changed(args) },
            EngineBridge.shared.on("apps:deployment") { [weak self] args in self?.deploymentChanged(args) },
            EngineBridge.shared.on("apps:logs") { [weak self] args in self?.receivedLogs(args) },
            EngineBridge.shared.on("apps:logs:end") { [weak self] args in self?.logsEnded(args) }
        ]
        if !capabilitiesLoaded { refreshCapabilities() }
        refresh()
        if selectedID != nil { refreshDetail() }
        if showingNewApp { loadCatalog() }
    }

    func stop() {
        visible = false
        generation += 1
        capabilitiesTask?.cancel(); capabilitiesTask = nil; checkingCapabilities = false
        readTask?.cancel(); detailTask?.cancel(); sectionTask?.cancel()
        databaseTask?.cancel(); databaseTask = nil; dataDatabaseLoading = false
        catalogTask?.cancel(); catalogTask = nil; catalogGeneration += 1; catalogLoading = false
        stopLogs()
        subscriptions.forEach { $0.cancel() }; subscriptions = []
    }

    func refresh() {
        guard visible else { return }
        readTask?.cancel()
        loading = true
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await call("apps:list")
                let next = try NativeAppsContract.records(result).map(NativeAppsContract.summary)
                guard !Task.isCancelled, visible else { return }
                apps = next
                problem = nil
                if let id = selectedID, !apps.contains(where: { $0.id == id }) { backToList() }
            } catch {
                guard !Task.isCancelled, visible else { return }
                problem = NativeAppsContract.problem(error)
            }
            if !Task.isCancelled { loading = false }
        }
    }

    /// One read per server mount; an explicit retry may recheck support.
    /// This is availability only. Every supported write still asks the backend
    /// consent path and keeps its existing transaction/caller checks.
    func refreshCapabilities() {
        guard visible, !checkingCapabilities else { return }
        capabilitiesTask?.cancel()
        capabilities = NativeAppsCapabilities()
        capabilityReadProblem = nil
        checkingCapabilities = true
        capabilitiesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await call("apps:capabilities")
                let next = try NativeAppsContract.capabilities(value)
                guard !Task.isCancelled, visible else { return }
                capabilities = next
                capabilitiesLoaded = true
                checkingCapabilities = false
            } catch {
                guard !Task.isCancelled, visible else { return }
                capabilities = NativeAppsCapabilities()
                capabilityReadProblem = "Server support could not be checked. " + NativeAppsContract.problem(error)
                capabilitiesLoaded = true
                checkingCapabilities = false
            }
        }
    }

    private func requireChanges() -> Bool {
        guard canChange else {
            operationProblem = writesUnavailableReason ?? "Changes are unavailable on this server."
            return false
        }
        return true
    }

    func select(_ app: NativeAppsSummary) {
        generation += 1
        stopLogs()
        selectedID = app.id; detail = nil; activeTab = .overview
        savedDomains = nil; activeDeploymentID = nil
        dataBackupSettings = nil
        databaseTask?.cancel(); dataDatabaseConnection = nil; dataDatabaseProblem = nil; dataDatabaseLoading = false
        notice = nil; problem = nil; operationProblem = nil; sectionProblem = nil; logs = []; draftAddressCheck = nil
        refreshDetail()
    }

    func backToList() {
        generation += 1
        detailTask?.cancel(); sectionTask?.cancel(); stopLogs()
        selectedID = nil; detail = nil; sectionProblem = nil; dataBackupSettings = nil
        databaseTask?.cancel(); dataDatabaseConnection = nil; dataDatabaseProblem = nil; dataDatabaseLoading = false
    }

    func refreshDetail() {
        guard visible, let id = selectedID else { return }
        detailTask?.cancel()
        let mine = generation
        detailLoading = true
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await call("apps:read", ["appId": id])
                let next = try NativeAppsContract.detail(record)
                guard next.app.id == id else { throw NativeRPCError.malformed("The app reply does not match this request.") }
                guard !Task.isCancelled, visible, selectedID == id, generation == mine else { return }
                // Cache only the validated fields this screen needs. Do not
                // retain an entire reply that might contain a misplaced secret.
                savedDomains = record["domains"].elements?.compactMap(\.string)
                activeDeploymentID = record["activeDeploymentId"].string
                detail = next
                if let index = apps.firstIndex(where: { $0.id == id }) { apps[index] = next.app }
                detailLoading = false; problem = nil
                showTab(activeTab)
            } catch {
                guard !Task.isCancelled, selectedID == id, generation == mine else { return }
                problem = NativeAppsContract.problem(error); detailLoading = false
            }
        }
    }

    func showTab(_ tab: NativeAppsTab) {
        activeTab = tab
        sectionTask?.cancel(); stopLogs()
        databaseTask?.cancel(); dataDatabaseLoading = false
        sectionProblem = nil; sectionLoading = false
        guard visible, let id = selectedID, detail != nil else { return }
        if tab == .overview, ["postgres", "mysql", "redis", "mongodb"].contains(detail?.app.kind ?? "") {
            refreshDatabaseConnection(); return
        }
        if tab == .logs { startLogs(appID: id); return }
        let channel: String
        switch tab {
        case .deploys: channel = "apps:deployments"
        case .settings: channel = "apps:env:read"
        case .backups:
            guard detail?.app.kind != "app" else { return }
            dataBackupSettings = nil
            channel = "apps:backups:list"
        default: return
        }
        let mine = generation
        sectionLoading = true
        sectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled, selectedID == id, activeTab == tab, generation == mine { sectionLoading = false } }
            do {
                let result = try await call(channel, ["appId": id])
                guard !Task.isCancelled, visible, selectedID == id, activeTab == tab, generation == mine else { return }
                switch tab {
                case .deploys: detail?.deployments = try NativeAppsContract.deployments(result, activeID: activeDeploymentID)
                case .settings: detail?.environment = try NativeAppsContract.environments(result)
                case .backups:
                    detail?.backups = try NativeAppsContract.backups(result)
                    let policy = try await call("apps:backups:policy:read", ["appId": id])
                    guard !Task.isCancelled, visible, selectedID == id, activeTab == tab, generation == mine else { return }
                    let settings = try NativeAppsDataBackupSettings.read(policy)
                    detail?.backupSchedule = settings.schedule
                    dataBackupSettings = settings
                default: break
                }
            } catch {
                if !Task.isCancelled, selectedID == id, activeTab == tab, generation == mine { sectionProblem = NativeAppsContract.problem(error) }
            }
        }
    }

    func newApp() { showingNewApp = true; problem = nil; operationProblem = nil; catalogProblem = nil; loadCatalog() }

    func loadCatalog() {
        guard visible, showingNewApp, !catalogLoading else { return }
        catalogTask?.cancel(); catalogGeneration += 1
        let mine = catalogGeneration
        let project = DeckProject.current
        catalogLoading = true
        catalogProblem = nil
        repositories = []; templates = []
        catalogTask = Task { [weak self] in
            guard let self else { return }
            // Both independent catalogues start together. Only this visit may
            // publish them; old access choices are discarded on read failure.
            async let templateLoad = loadTemplates()
            async let repositoryLoad = loadRepositories(project: project)
            let (templateResult, repositoryResult) = await (templateLoad, repositoryLoad)
            guard !Task.isCancelled, visible, showingNewApp, catalogGeneration == mine, DeckProject.current == project else {
                if catalogGeneration == mine {
                    catalogLoading = false
                    if visible, showingNewApp, DeckProject.current != project {
                        repositories = []; templates = []
                        catalogProblem = "The project changed while checking your choices. Try again."
                    }
                }
                return
            }
            var failures: [String] = []
            switch templateResult {
            case .success(let next): templates = next
            case .failure(let error): templates = []; failures.append(error.message)
            }
            switch repositoryResult {
            case .success(let next): repositories = next
            case .failure(let error): repositories = []; failures.append(error.message)
            }
            catalogProblem = failures.isEmpty ? nil : failures.joined(separator: " ")
            catalogLoading = false
        }
    }

    func cancelCatalog() {
        catalogTask?.cancel(); catalogTask = nil; catalogGeneration += 1
        catalogLoading = false
    }

    func refreshDatabaseConnection() {
        guard visible, activeTab == .overview, let id = selectedID, let kind = detail?.app.kind,
              ["postgres", "mysql", "redis", "mongodb"].contains(kind) else { return }
        databaseTask?.cancel()
        let mine = generation
        dataDatabaseLoading = true; dataDatabaseProblem = nil
        databaseTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled, selectedID == id, generation == mine, activeTab == .overview { dataDatabaseLoading = false }
            }
            do {
                let value = try await call("apps:databases:connection", ["appId": id])
                let connection = try NativeAppsDataDatabaseConnection.read(value)
                guard connection.kind == kind, NativeAppsRules.databaseHostMatches(host: connection.host, appID: id) else {
                    throw NativeRPCError.malformed("The connection reply does not match this database.")
                }
                guard !Task.isCancelled, visible, selectedID == id, generation == mine, activeTab == .overview else { return }
                dataDatabaseConnection = connection
            } catch {
                guard !Task.isCancelled, visible, selectedID == id, generation == mine, activeTab == .overview else { return }
                dataDatabaseConnection = nil
                dataDatabaseProblem = NativeAppsContract.problem(error)
            }
        }
    }

    private func loadTemplates() async -> Result<[NativeAppsTemplate], NativeRPCError> {
        do { return .success(try NativeAppsContract.templates(try await call("apps:templates:list"))) }
        catch { return .failure(NativeRPCError(code: "unavailable", message: "The template list could not be read. " + NativeAppsContract.problem(error))) }
    }

    private func loadRepositories(project: String?) async -> Result<[NativeAppsRepository], NativeRPCError> {
        do {
            let args: [Any?] = project.map { [$0] } ?? []
            let auth = GitHubAuthState(json: try await EngineBridge.shared.invoke("github:auth-status", args))
            if auth.connected, case .list(let access)? = auth.access {
                return .success(access.repos.filter { !$0.archived }.map {
                    NativeAppsRepository(id: $0.nameWithOwner, name: $0.nameWithOwner, url: $0.url, defaultBranch: "main")
                })
            }
            return .failure(NativeRPCError(code: "unavailable", message: auth.connected
                ? "GitHub could not list repositories. You can enter an owner/repository below."
                : "Connect GitHub in the existing GitHub page to use your repositories."))
        } catch {
            return .failure(NativeRPCError(code: "unavailable", message: "GitHub access could not be checked. Use the existing GitHub page to connect."))
        }
    }

    func create(_ draft: NativeAppsDraft) {
        guard visible else { return }
        guard requireChanges() else { return }
        guard draft.validationMessage == nil else { problem = draft.validationMessage; return }
        var payload: [String: Any] = ["name": draft.name.trimmingCharacters(in: .whitespacesAndNewlines), "appId": draft.resolvedAppID]
        let channel: String
        switch draft.source {
        case .github:
            channel = "apps:create"
            payload["source"] = ["kind": "github", "repository": draft.normalizedRepository, "branch": draft.resolvedBranch,
                                 "build": "auto", "port": draft.port] as [String: Any]
        case .template: channel = "apps:templates:deploy"; payload["templateId"] = draft.templateID
        case .database: channel = "apps:databases:create"; payload["kind"] = draft.databaseEngine
        }
        guard busy == nil else { return }
        busy = "Creating app"; problem = nil; operationProblem = nil; notice = nil
        operationAppID = draft.resolvedAppID; operationAppName = draft.name
        let mine = generation
        Task {
            defer { busy = nil; operationAppID = nil; operationAppName = nil }
            var saved: NativeAppsSummary?
            var deployProblem: String?
            do {
                let result = try await call(channel, payload)
                if channel == "apps:create" || result.has("name") {
                    saved = try NativeAppsContract.scopedSummary(result, appID: draft.resolvedAppID)
                } else {
                    _ = try result["id"].requireString("created item id", nonempty: true)
                }
                guard visible, generation == mine else {
                    showingNewApp = false
                    notice = "\(draft.name): creation finished. Open it again to check its status."
                    return
                }
                if channel == "apps:create" {
                    busy = "Deploying app"
                    do {
                        let deployed = try await call("apps:deploy", ["appId": draft.resolvedAppID])
                        _ = try deployed["id"].requireString("deploy id", nonempty: true)
                    }
                    catch { deployProblem = NativeAppsContract.problem(error) }
                }
                guard visible, generation == mine else {
                    showingNewApp = false
                    notice = "\(draft.name): " + (deployProblem ?? "Creation finished. Open it again to check its status.")
                    operationProblem = deployProblem.map { draft.name + ": " + $0 }
                    return
                }
                // Template deploy currently returns a deploy record. Read the
                // authoritative app after all create variants rather than guessing.
                let record = try await call("apps:read", ["appId": draft.resolvedAppID])
                saved = try NativeAppsContract.scopedSummary(record, appID: draft.resolvedAppID)
                guard visible, generation == mine, let saved else { return }
                showingNewApp = false
                if let index = apps.firstIndex(where: { $0.id == saved.id }) { apps[index] = saved } else { apps.append(saved) }
                select(saved)
                if let deployProblem {
                    operationProblem = draft.name + ": app saved. " + deployProblem
                    problem = operationProblem; notice = operationProblem
                }
                refresh()
            } catch {
                let failure = draft.name + ": " + NativeAppsContract.problem(error)
                if let saved, visible, generation == mine {
                    showingNewApp = false
                    if !apps.contains(where: { $0.id == saved.id }) { apps.append(saved) }
                    select(saved)
                    operationProblem = draft.name + ": app saved. " + NativeAppsContract.problem(error)
                    problem = operationProblem; notice = operationProblem
                } else {
                    operationProblem = failure; notice = failure
                    if visible { problem = failure }
                }
            }
        }
    }

    func restartApp() { action("Restarting app", channel: "apps:restart") }
    func deployApp() { action("Deploying app", channel: "apps:deploy") }
    func rollback(_ deploymentID: String) { action("Rolling back", channel: "apps:rollback", payload: ["deploymentId": deploymentID]) }

    func saveEnvironment(key: String, value: String, remove: Bool) {
        if NativeAppsRules.isDatabaseLoginKey(kind: selectedApp?.kind ?? "app", key: key) {
            operationProblem = "Changing these database login settings is unavailable here. The saved login values stay in place."
            problem = operationProblem; return
        }
        guard NativeAppsRules.validEnvironmentKey(key) else { problem = "Use a setting name with letters, numbers and underscores."; return }
        guard value.utf8.count <= 65_536, !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
            problem = "Keep each setting value on one line."; return
        }
        // The patch contract preserves every untouched value on the server.
        action(remove ? "Removing setting" : "Saving setting", channel: "apps:env:patch",
               payload: ["set": remove ? [:] as [String: String] : [key: value], "remove": remove ? [key] : []])
    }

    func addAddress(_ hostname: String) {
        guard NativeAppsRules.validHostname(hostname) else { problem = "Enter a domain name without a web prefix, path or port."; return }
        guard var domains = savedDomains else { problem = "The server did not return the saved addresses. Refresh before changing them."; return }
        if !domains.contains(hostname) { domains.append(hostname) }
        action("Saving address", channel: "apps:domains:apply", payload: ["domains": domains])
    }

    func removeAddress(_ hostname: String) {
        guard let domains = savedDomains else { problem = "The server did not return the saved addresses. Refresh before changing them."; return }
        action("Removing address", channel: "apps:domains:apply", payload: ["domains": domains.filter { $0 != hostname }])
    }

    func checkAddress(_ hostname: String) {
        guard visible, let id = selectedID, busy == nil else { return }
        guard NativeAppsRules.validHostname(hostname) else { problem = "Enter a domain name without a web prefix, path or port."; return }
        let mine = generation
        busy = "Checking DNS"
        operationProblem = nil; problem = nil
        operationAppID = id; operationAppName = selectedApp?.name
        Task {
            defer { busy = nil; operationAppID = nil; operationAppName = nil }
            do {
                let result = try await call("apps:domains:check", ["appId": id, "domain": hostname])
                guard visible, selectedID == id, generation == mine else { return }
                guard let pointsHere = result["pointsHere"].bool else { throw NativeRPCError.malformed("DNS check did not answer.") }
                let expected = result["expected"].string ?? result["expected"].elements?.compactMap(\.string).joined(separator: ", ")
                let instructions = result["instructions"].string
                if let index = detail?.addresses.firstIndex(where: { $0.hostname == hostname }) {
                    detail?.addresses[index].dnsReady = pointsHere
                    detail?.addresses[index].expectedAddress = expected
                    detail?.addresses[index].instructions = instructions
                } else {
                    draftAddressCheck = NativeAppsAddress(hostname: hostname, dnsReady: pointsHere, expectedAddress: expected, instructions: instructions)
                }
                notice = result["pointsHere"].bool == true ? "DNS is pointing here." : "DNS is not pointing here yet."
            } catch { if visible, selectedID == id, generation == mine { problem = NativeAppsContract.problem(error) } }
        }
    }

    func saveBackupSchedule(_ schedule: NativeAppsBackupSchedule) {
        if !schedule.enabled {
            action("Turning off scheduled backups", channel: "apps:backups:policy", payload: ["enabled": false]); return
        }
        let pieces = schedule.time.split(separator: ":")
        guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]), (0...23).contains(hour), (0...59).contains(minute), (1...365).contains(schedule.retentionCount) else {
            problem = "Choose a time from 00:00 to 23:59 and keep the latest 1–365 backups."; return
        }
        action("Saving backup schedule", channel: "apps:backups:policy", payload: ["enabled": true, "schedule": String(format: "*-*-* %02d:%02d:00", hour, minute), "retention": schedule.retentionCount])
    }

    func backupNow() { action("Creating backup", channel: "apps:backups:create") }

    func saveBackupUpload(_ change: NativeAppsDataBackupUploadChange) {
        guard let settings = dataBackupSettings else {
            problem = "Refresh the backup policy before changing its upload settings."
            return
        }
        do {
            let value = try change.policyPayload(settings: settings)
            guard let payload = value.foundation as? [String: Any] else {
                throw NativeRPCError.malformed("The backup upload settings are unreadable.")
            }
            action("Saving backup storage", channel: "apps:backups:policy", payload: payload)
        } catch { problem = NativeAppsContract.problem(error) }
    }
    func restoreBackup(_ backupID: String, confirmationName: String) {
        guard let app = selectedApp, NativeAppsRules.matchesConfirmation(typed: confirmationName, name: app.name) else { problem = "Type the app’s exact name to restore this backup."; return }
        action("Restoring backup", channel: "apps:backups:restore", payload: ["backupId": backupID, "confirmation": confirmationName])
    }
    func removeApp(confirmationName: String) {
        guard let app = selectedApp, NativeAppsRules.matchesConfirmation(typed: confirmationName, name: app.name) else { problem = "Type the app’s exact name to remove it."; return }
        action("Removing app", channel: "apps:remove", payload: ["confirmation": confirmationName], removed: true)
    }

    private func action(_ label: String, channel: String, payload: [String: Any] = [:], removed: Bool = false) {
        guard visible, let id = selectedID else { return }
        guard requireChanges() else { return }
        var next = payload; next["appId"] = id
        mutate(label, channel: channel, payload: next, removed: removed)
    }

    private func mutate(_ label: String, channel: String, payload: [String: Any], removed: Bool = false) {
        guard visible, busy == nil else { return }
        guard requireChanges() else { return }
        let targetID = payload["appId"] as? String
        let targetName = apps.first(where: { $0.id == targetID })?.name ?? selectedApp?.name ?? "App"
        operationAppID = targetID; operationAppName = targetName
        busy = label + " — " + targetName; problem = nil; operationProblem = nil; notice = nil
        Task {
            defer { busy = nil; operationAppID = nil; operationAppName = nil }
            do {
                // Every mutation stays on the registered approval-controlled channel.
                let result = try await call(channel, payload)
                if removed, result["removed"].bool != true { throw NativeRPCError.malformed("Removal was not confirmed.") }
                if channel == "apps:backups:restore", result["restored"].bool != true { throw NativeRPCError.malformed("Restore was not confirmed.") }
                switch channel {
                case "apps:restart", "apps:domains:apply":
                    guard let targetID else { throw NativeRPCError.malformed("The app request is missing its identity.") }
                    _ = try NativeAppsContract.scopedSummary(result, appID: targetID)
                case "apps:env:patch": _ = try NativeAppsContract.environments(result)
                case "apps:backups:policy": _ = try NativeAppsDataBackupSettings.read(result)
                case "apps:deploy", "apps:rollback", "apps:backups:create": _ = try result["id"].requireString("saved item id", nonempty: true)
                default: break
                }
                switch channel {
                    case "apps:restart": notice = "App restarted."
                    case "apps:deploy": notice = "Deploy finished."
                    case "apps:rollback": notice = "Rollback finished."
                    case "apps:env:patch": notice = "Settings saved."
                    case "apps:domains:apply": notice = "Addresses saved."
                    case "apps:backups:policy": notice = "Backup settings saved."
                    case "apps:backups:create": notice = "Backup created."
                    case "apps:backups:restore": notice = "Backup restored."
                    case "apps:remove": notice = result["dataPreserved"].bool == true ? "App removed. Its saved data and backups were kept for recovery." : "App removed."
                    default: notice = "Change saved."
                }
                if let resultText = notice { notice = targetName + ": " + resultText }
                if visible {
                    if selectedID == targetID {
                        if removed { backToList() } else { refreshDetail() }
                    }
                    refresh()
                }
            } catch {
                let failure = targetName + ": " + NativeAppsContract.problem(error)
                operationProblem = failure; notice = failure
                if visible { problem = failure }
            }
        }
    }

    private func changed(_ args: [Any]) {
        guard visible, let event = try? NativeRPCValue.fromFoundation(args.first), event["serverId"].string == serverID else { return }
        if let id = event["appId"].string, let record = try? NativeAppsContract.scopedSummary(event["record"], appID: id) {
            if let index = apps.firstIndex(where: { $0.id == record.id }) { apps[index] = record } else { apps.append(record) }
        } else { refresh() }
        if selectedID == event["appId"].string, busy == nil { refreshDetail() }
    }

    private func deploymentChanged(_ args: [Any]) {
        guard visible, let event = try? NativeRPCValue.fromFoundation(args.first), event["serverId"].string == serverID, event["appId"].string == selectedID else { return }
        // Do not show untrusted build text; phase has a fixed plain-language mapping.
        notice = "Deploy: " + NativeAppsRules.friendlyStatus(event["phase"].string ?? "unknown")
        if activeTab == .deploys, busy == nil { showTab(.deploys) }
    }

    private func startLogs(appID: String) {
        let stream = UUID().uuidString
        streamID = stream; endedStreamID = nil; logs = []; sectionLoading = true
        logTask = Task { [weak self] in
            guard let self else { return }
            do {
                let initial = try await call("apps:logs:read", ["appId": appID, "tail": 200])
                guard !Task.isCancelled, visible, streamID == stream, activeTab == .logs else { return }
                let text = try initial["text"].requireString("log text")
                if !text.isEmpty { appendLogs(text) }
                let result = try await call("apps:logs:watch", ["appId": appID, "streamId": stream])
                guard result["streamId"].string == stream else { throw NativeRPCError.malformed("Logs did not start.") }
                guard !Task.isCancelled, visible, streamID == stream, activeTab == .logs else {
                    _ = try? await call("apps:logs:unwatch", ["streamId": stream]); return
                }
                if endedStreamID != stream { logsLive = true; sectionLoading = false }
            } catch {
                _ = try? await call("apps:logs:unwatch", ["streamId": stream])
                if streamID == stream, endedStreamID != stream { logsLive = false; sectionLoading = false; sectionProblem = NativeAppsContract.problem(error) }
            }
        }
    }

    private func stopLogs() {
        logTask?.cancel(); logTask = nil; logsLive = false
        guard let stream = streamID else { return }
        streamID = nil; endedStreamID = nil
        Task { _ = try? await call("apps:logs:unwatch", ["streamId": stream]) }
    }

    private func receivedLogs(_ args: [Any]) {
        guard visible, activeTab == .logs, let event = try? NativeRPCValue.fromFoundation(args.first),
              event["serverId"].string == serverID, event["appId"].string == selectedID,
              event["streamId"].string == streamID, endedStreamID != streamID, let text = event["text"].string else { return }
        appendLogs(text)
    }

    private func logsEnded(_ args: [Any]) {
        guard visible, activeTab == .logs, let event = try? NativeRPCValue.fromFoundation(args.first),
              event["serverId"].string == serverID, event["appId"].string == selectedID,
              let stream = event["streamId"].string, stream == streamID else { return }
        endedStreamID = stream
        logsLive = false; sectionLoading = false
        let reason = event["reason"].string ?? "error"
        let text = NativeAppsRules.logEndMessage(reason)
        if ["closed", "eof"].contains(reason) { notice = text }
        else { sectionProblem = text }
    }

    private func appendLogs(_ text: String) {
        // The Apps contract redacts secret values before this seam. Bound the UI cache.
        logs.append(contentsOf: text.components(separatedBy: .newlines).map { String($0.prefix(4096)) })
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
    }
}
