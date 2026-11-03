import Foundation
import Observation
import TerminalDeckNativeCore

/// One app's server duties: scheduled jobs and automatic deploys (SRV1's
/// channels). Secrets shown here come only from the two native-window
/// channels and live only in this model while the page is open.
@MainActor
@Observable
final class NativeAppsSRV2AppServerModel {
    enum Part: String, Sendable { case jobs, autodeploy, link }

    struct JobLast: Decodable, Equatable {
        var startedAt: Double?
        var finishedAt: Double?
        var exitCode: Double?
        var ok: Bool?
    }

    struct Job: Decodable, Equatable, Identifiable {
        var id: String
        var name: String?
        var schedule: String
        var command: String
        var timeoutSeconds: Double?
        var enabled: Bool?
        var last: JobLast?
        var nextRun: String?
        var title: String { (name?.isEmpty == false ? name : nil) ?? id }
    }

    /// The job editor. `jobID` is nil for a new job (made from the name).
    struct JobDraft: Equatable {
        var jobID: String?
        var name = ""
        var command = ""
        var schedule = NativeAppsSRV2Schedule(preset: .daily, time: "03:00")
        var timeoutSeconds = 600
        var enabled = true
    }

    struct AutoDeploy: Decodable, Equatable {
        var enabled: Bool?
        var hasWebhookSecret: Bool?
        var hasDeployLink: Bool?
        var webhookUrl: String?
        var deployLinkUrl: String?
        var deployKey: String?
    }

    struct DeployLink: Equatable { var url: String; var token: String; var usage: String? }

    let serverID: String
    let appID: String

    private(set) var jobs: [Job] = []
    private(set) var jobsLoading = true
    private(set) var jobsProblem: String?
    /// The server has no helper set yet; both sections say so plainly.
    private(set) var notInstalled: String?
    var editing: JobDraft?
    private(set) var jobLogs: [String: String] = [:]

    private(set) var autoDeploy: AutoDeploy?
    private(set) var autoDeployProblem: String?
    /// Read from the native-only channel on Show or Copy; cleared on Hide.
    private(set) var webhookSecret: String?
    /// Shown once, right after a new link is made (the server keeps only a hash).
    private(set) var newLink: DeployLink?
    private(set) var deployLog: String?
    private(set) var deployRunning: String?

    let changes = NativeAppsChangeRunner<Part>()
    var busy: String? { changes.busy }
    var resultPart: Part? { changes.resultPart }
    var note: String? { changes.note }
    var problem: String? { changes.problem }

    @ObservationIgnored private let transport: NativeAppsSRV2Transport
    @ObservationIgnored private var started = false
    @ObservationIgnored private var readTask: Task<Void, Never>?

    init(serverID: String, appID: String, transport: NativeAppsSRV2Transport? = nil) {
        self.serverID = serverID
        self.appID = appID
        self.transport = transport ?? { try await NativeAppsSRV2Engine.invoke($0, $1) }
    }

    private func call(_ channel: String, _ additional: [String: Any] = [:]) async throws -> NativeRPCValue {
        var payload = additional
        payload["serverId"] = serverID
        payload["appId"] = appID
        return try await transport(channel, payload)
    }

    // MARK: reading

    func loadIfNeeded() { if !started { load() } }

    func load() {
        started = true
        readTask?.cancel()
        let mine = changes.advance()
        jobsLoading = true
        readTask = Task { [weak self] in
            guard let self else { return }
            async let jobsRead = readJobs()
            async let autoRead = readAutoDeploy()
            async let logRead = readDeployLog()
            let (jobsResult, autoResult, logResult) = await (jobsRead, autoRead, logRead)
            guard !Task.isCancelled, changes.isCurrent(mine) else { return }
            notInstalled = nil
            switch jobsResult {
            case .success(let rows): jobs = rows; jobsProblem = nil
            case .failure(let error):
                jobs = []
                if NativeAppsSRV2Engine.notInstalled(error) { notInstalled = NativeAppsSRV2Engine.problem(error); jobsProblem = nil }
                else { jobsProblem = NativeAppsSRV2Engine.problem(error) }
            }
            switch autoResult {
            case .success(let value): autoDeploy = value; autoDeployProblem = nil
            case .failure(let error):
                autoDeploy = nil
                if NativeAppsSRV2Engine.notInstalled(error) { notInstalled = NativeAppsSRV2Engine.problem(error); autoDeployProblem = nil }
                else { autoDeployProblem = NativeAppsSRV2Engine.problem(error) }
            }
            if case .success(let (log, running)) = logResult { deployLog = log; deployRunning = running }
            jobsLoading = false
        }
    }

    private func readJobs() async -> Result<[Job], Error> {
        do { return .success(try NativeAppsSRV2Engine.decode([Job].self, try await call("apps:server:jobs:list"), what: "its scheduled jobs")) }
        catch { return .failure(error) }
    }

    private func readAutoDeploy() async -> Result<AutoDeploy, Error> {
        do { return .success(try NativeAppsSRV2Engine.decode(AutoDeploy.self, try await call("apps:server:autodeploy:read"), what: "its automatic deploy settings")) }
        catch { return .failure(error) }
    }

    private func readDeployLog() async -> Result<(String, String?), Error> {
        do {
            let value = try await call("apps:server:deploy:log")
            return .success((String((value["log"].string ?? "").suffix(65_536)), value["running"].string))
        } catch { return .failure(error) }
    }

    func refreshDeployLog() {
        Task {
            if case .success(let (log, running)) = await readDeployLog() { deployLog = log; deployRunning = running }
        }
    }

    /// A read: the job's last output, secret values masked by the engine.
    func readJobLog(_ id: String) {
        Task {
            do {
                let value = try await call("apps:server:jobs:log", ["jobId": id])
                jobLogs[id] = String((value["log"].string ?? "").suffix(65_536))
            } catch {
                jobLogs[id] = nil
                changes.report(.jobs, NativeAppsSRV2Engine.problem(error))
            }
        }
    }

    func hideJobLog(_ id: String) { jobLogs[id] = nil }

    // MARK: jobs

    func newJob() { editing = JobDraft() }

    func edit(_ job: Job) {
        editing = JobDraft(jobID: job.id, name: job.name ?? job.id, command: job.command,
                           schedule: NativeAppsSRV2Schedule(calendar: job.schedule),
                           timeoutSeconds: NativeNumber.clamped(job.timeoutSeconds, to: 10...86_400, fallback: 600), enabled: job.enabled ?? true)
    }

    /// A short ID from the name: lowercase letters, numbers and dashes, unique.
    func jobID(for name: String) -> String {
        var slug = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty || !(slug.first?.isLetter ?? false) { slug = "job" + (slug.isEmpty ? "" : "-" + slug) }
        slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let taken = Set(jobs.map(\.id))
        var candidate = slug, number = 2
        while taken.contains(candidate) { candidate = slug + "-\(number)"; number += 1 }
        return candidate
    }

    func jobProblem(_ draft: JobDraft) -> String? {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "Give the job a name." }
        guard name.count <= 80, !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return "Use a short job name on one line." }
        let command = draft.command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return "Enter the command to run." }
        guard command.utf8.count <= 4096, !command.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            return "Use a command on one line, up to 4096 characters."
        }
        if let message = draft.schedule.problem { return message }
        guard (10...86_400).contains(draft.timeoutSeconds) else { return "Choose a time limit between 10 and 86400 seconds." }
        return nil
    }

    func saveJob(writesDisabled: Bool) {
        guard let draft = editing else { return }
        if let message = jobProblem(draft) { changes.report(.jobs, message); return }
        let id = draft.jobID ?? jobID(for: draft.name)
        let payload: [String: Any] = ["jobId": id, "name": draft.name.trimmingCharacters(in: .whitespaces),
                                      "command": draft.command.trimmingCharacters(in: .whitespaces),
                                      "schedule": draft.schedule.calendar ?? "", "timeoutSeconds": draft.timeoutSeconds, "enabled": draft.enabled]
        changes.run(.jobs, "Saving the job", writesDisabled: writesDisabled) { [self] in
            jobs = try NativeAppsSRV2Engine.decode([Job].self, try await call("apps:server:jobs:save", payload), what: "its scheduled jobs")
            editing = nil
            return "Job saved. It runs on the server, even when this Mac is off."
        }
    }

    func removeJob(_ id: String, writesDisabled: Bool) {
        changes.run(.jobs, "Removing the job", writesDisabled: writesDisabled) { [self] in
            jobs = try NativeAppsSRV2Engine.decode([Job].self, try await call("apps:server:jobs:remove", ["jobId": id]), what: "its scheduled jobs")
            jobLogs[id] = nil
            if editing?.jobID == id { editing = nil }
            return "Job removed."
        }
    }

    func runJob(_ id: String, writesDisabled: Bool) {
        changes.run(.jobs, "Starting the job", writesDisabled: writesDisabled) { [self] in
            let reply = try await call("apps:server:jobs:run", ["jobId": id])
            guard reply["started"].bool == true else { throw NativeRPCError.malformed("The job did not start.") }
            return "The job started on the server. Read again to see its result."
        }
    }

    // MARK: automatic deploys

    func setAutoDeploy(_ enabled: Bool, deployKey: Bool = false, writesDisabled: Bool) {
        changes.run(.autodeploy, enabled ? "Turning on automatic deploys" : "Turning off automatic deploys", writesDisabled: writesDisabled) { [self] in
            autoDeploy = try NativeAppsSRV2Engine.decode(AutoDeploy.self, try await call("apps:server:autodeploy:apply", ["enabled": enabled, "deployKey": deployKey]),
                                                         what: "its automatic deploy settings")
            if deployKey { return "Deploy key made. Add it to the repository as a read-only deploy key." }
            return enabled ? "Automatic deploys are on. Add the webhook to GitHub to finish." : "Automatic deploys are off."
        }
    }

    /// Native window only: reads the webhook secret to show or copy it.
    func revealWebhookSecret(then: (@MainActor (String) -> Void)? = nil) {
        if let webhookSecret { then?(webhookSecret); return }
        changes.run(.autodeploy, "Reading the webhook secret") { [self] in
            let value = try await call("apps:server:autodeploy:reveal")
            guard let secret = value["secret"].string, !secret.isEmpty else { throw NativeRPCError.malformed("The secret was not returned.") }
            webhookSecret = secret
            then?(secret)
            return nil
        }
    }

    func hideWebhookSecret() { webhookSecret = nil }

    /// Makes a new CI deploy link; the old one stops working at once.
    func makeDeployLink(writesDisabled: Bool) {
        changes.run(.link, "Making a new deploy link", writesDisabled: writesDisabled) { [self] in
            let value = try await call("apps:server:autodeploy:link")
            guard let url = value["url"].string, let token = value["token"].string, !token.isEmpty else {
                throw NativeRPCError.malformed("The new link was not returned.")
            }
            newLink = DeployLink(url: url, token: token, usage: value["usage"].string)
            if var current = autoDeploy { current.hasDeployLink = true; current.deployLinkUrl = url; autoDeploy = current }
            return "New deploy link made. Copy its secret now; it is shown only here and only until you leave this page."
        }
    }

    func forgetSecrets() { webhookSecret = nil; newLink = nil }

    /// For INT2: the server's own deploy pipeline (Traefik servers, Mac off).
    func deployOnServer(writesDisabled: Bool) {
        changes.run(.autodeploy, "Starting a deploy on the server", writesDisabled: writesDisabled) { [self] in
            let reply = try await call("apps:server:deploy:run")
            guard reply["started"].bool == true else { throw NativeRPCError.malformed("The deploy did not start.") }
            return "The deploy started on the server."
        } after: { [self] in refreshDeployLog() }
    }
}
