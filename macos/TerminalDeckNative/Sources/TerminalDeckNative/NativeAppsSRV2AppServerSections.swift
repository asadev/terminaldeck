import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// SRV2: the app page's "Scheduled jobs" and "Automatic deploys" sections
/// (SRV1's server duties), for the settings tab's existing Form.
struct NativeAppsSRV2AppServerSections: View {
    let serverID: String
    let appID: String
    let appName: String
    /// Automatic deploys on push need a GitHub source; the deploy link works for any app.
    var isGitHub = true
    var writesDisabled = false
    /// False once the person has left this page while the sections stay built.
    var shown = true
    @State private var holder = NativeAppsSRV2AppServerHolder()

    var body: some View {
        NativeAppsSRV2AppServerSectionList(model: holder.model(serverID: serverID, appID: appID), appName: appName,
                                           isGitHub: isGitHub, writesDisabled: writesDisabled, shown: shown)
    }
}

@MainActor
final class NativeAppsSRV2AppServerHolder {
    private var current: NativeAppsSRV2AppServerModel?

    func model(serverID: String, appID: String) -> NativeAppsSRV2AppServerModel {
        if let current, current.serverID == serverID, current.appID == appID { return current }
        current?.forgetSecrets()
        let next = NativeAppsSRV2AppServerModel(serverID: serverID, appID: appID)
        current = next
        return next
    }
}

struct NativeAppsSRV2AppServerSectionList: View {
    @Bindable var model: NativeAppsSRV2AppServerModel
    let appName: String
    var isGitHub = true
    var writesDisabled = false
    var shown = true
    @State private var removingJob: NativeAppsSRV2AppServerModel.Job?
    @State private var confirmingNewLink = false
    @State private var showLinkSecret = false
    @State private var copied: String?

    private typealias Model = NativeAppsSRV2AppServerModel
    private var controlsDisabled: Bool { writesDisabled || model.busy != nil }
    private var loadKey: String { model.serverID + "/" + model.appID }

    var body: some View {
        jobs
            .task(id: loadKey) { model.loadIfNeeded() }
        autoDeploys
            // A new secret is shown only until the person leaves this page, on purpose
            // rather than because the page happens to be rebuilt (scrolling keeps it).
            .onChange(of: shown) { if !shown { model.forgetSecrets(); showLinkSecret = false } }
    }

    // MARK: Scheduled jobs

    private var jobs: some View {
        Section("Scheduled jobs") {
            if model.jobsLoading, model.jobs.isEmpty, model.notInstalled == nil {
                NativePageNote("Reading scheduled jobs…", busy: true).frame(height: 28)
            } else if let notInstalled = model.notInstalled {
                NativeSettingsProse(text: notInstalled)
            } else if let problem = model.jobsProblem {
                NativeCodingAINotice(tone: .error, text: problem)
                NativeSessionButton("Read again", action: model.load).disabled(model.busy != nil)
            } else {
                NativeSettingsProse(text: "Commands that run inside \(appName) on a schedule. The server runs them, even when this Mac is off.")
                if model.jobs.isEmpty, model.editing == nil {
                    NativePageNote("No scheduled jobs yet.").frame(height: 28)
                }
                ForEach(model.jobs) { job in
                    if model.editing?.jobID == job.id {
                        editor
                    } else {
                        jobRow(job)
                    }
                }
                if model.editing != nil, model.editing?.jobID == nil {
                    editor
                } else if model.editing == nil {
                    NativeSessionButton("Add a job…", action: model.newJob).disabled(controlsDisabled)
                }
                NativeAppsSRV2ResultLine(busy: model.busy, problem: model.problem, note: model.note, shown: model.resultPart == .jobs)
            }
        }
        .alert("Remove \(removingJob?.title ?? "this job")?", isPresented: Binding(get: { removingJob != nil }, set: { if !$0 { removingJob = nil } })) {
            NativeSessionButton("Cancel", role: .cancel) { removingJob = nil }
            NativeSessionButton("Remove job", role: .destructive) {
                if let job = removingJob { model.removeJob(job.id, writesDisabled: writesDisabled) }
                removingJob = nil
            }
        } message: {
            Text("It stops running on the server, and its saved output is deleted.")
        }
    }

    private func jobRow(_ job: Model.Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(job.title)
                    Text(NativeAppsSRV2Schedule.words(job.schedule) + (job.enabled == false ? " · Paused" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                NativeSessionButton("Run now") { model.runJob(job.id, writesDisabled: writesDisabled) }
                NativeSessionButton("Edit") { model.edit(job) }.disabled(model.editing != nil)
                NativeSessionButton("Remove…", role: .destructive) { removingJob = job }
            }
            .disabled(controlsDisabled)
            Text(job.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail).textSelection(.enabled).help(job.command)
            HStack(spacing: 8) {
                Text(lastWords(job)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if model.jobLogs[job.id] == nil {
                    NativeSessionButton("Show last output") { model.readJobLog(job.id) }.disabled(job.last == nil)
                } else {
                    NativeSessionButton("Hide output") { model.hideJobLog(job.id) }
                }
            }
            if let log = model.jobLogs[job.id] {
                NativeAppsSRV2LogView(text: log.isEmpty ? "The job printed nothing." : log, label: "Last output of \(job.title)")
            }
        }
        .padding(.vertical, 4)
    }

    private func lastWords(_ job: Model.Job) -> String {
        var words: String
        if let last = job.last {
            let when = NativeAppsSRV2Engine.date(last.finishedAt ?? last.startedAt).map { " · \($0)" } ?? ""
            if last.ok == true { words = "Last run worked" + when }
            else {
                switch NativeNumber.integer(last.exitCode, in: Int(Int32.min)...Int(Int32.max)) ?? -1 {
                case 3: words = "Last run failed: the app was not running" + when
                case 124: words = "Last run stopped at its time limit" + when
                case let code: words = "Last run failed (code \(code))" + when
                }
            }
        } else {
            words = "Not run yet"
        }
        if let next = NativeAppsSRV2Engine.systemdDate(job.nextRun), job.enabled != false { words += " · Next: \(next)" }
        return words
    }

    @ViewBuilder private var editor: some View {
        if model.editing != nil {
            let draft = Binding(get: { model.editing ?? Model.JobDraft() }, set: { model.editing = $0 })
            VStack(alignment: .leading, spacing: 8) {
                Text(draft.wrappedValue.jobID == nil ? "New job" : "Edit job").font(.callout.weight(.medium))
                NativeSettingRow(label: "Name") {
                    NativeSessionTextField("Name", text: draft.name, prompt: Text("Nightly report")).textFieldStyle(.roundedBorder).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                }
                NativeSettingRow(label: "Command", help: "Runs inside the app, on one line, for example npm run report.") {
                    NativeSessionTextField("Command", text: draft.command, prompt: Text("npm run report")).textFieldStyle(.roundedBorder).labelsHidden()
                        .font(.callout.monospaced()).frame(minWidth: 160, maxWidth: 260)
                }
                NativeAppsSRV2ScheduleEditor(schedule: draft.schedule)
                NativeSettingRow(label: "Time limit", help: "The job is stopped after this long.") {
                    NativeAppsSRV2NumberField(label: "Time limit", value: draft.timeoutSeconds, range: 10...86_400, unit: "seconds")
                }
                NativeSettingRow(label: "Run on schedule", help: "Turn off to pause the job without removing it.") {
                    Toggle("Run on schedule", isOn: draft.enabled).labelsHidden().toggleStyle(.switch)
                }
                HStack(spacing: 8) {
                    NativeSessionButton("Save job") { model.saveJob(writesDisabled: writesDisabled) }
                        .disabled(controlsDisabled)
                    NativeSessionButton("Cancel") { model.editing = nil }
                }
                if let problem = model.jobProblem(draft.wrappedValue), !draft.wrappedValue.name.isEmpty || !draft.wrappedValue.command.isEmpty {
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Automatic deploys

    private var autoDeploys: some View {
        Section("Automatic deploys") {
            if model.jobsLoading, model.autoDeploy == nil, model.notInstalled == nil {
                NativePageNote("Reading automatic deploys…", busy: true).frame(height: 28)
            } else if let notInstalled = model.notInstalled {
                NativeSettingsProse(text: notInstalled)
            } else if let problem = model.autoDeployProblem {
                NativeCodingAINotice(tone: .error, text: problem)
                NativeSessionButton("Read again", action: model.load).disabled(model.busy != nil)
            } else if let auto = model.autoDeploy {
                if isGitHub {
                    NativeSettingRow(label: "Deploy when you push", help: "The server deploys each new commit by itself, even when this Mac is off.") {
                        Toggle("Deploy when you push", isOn: Binding(get: { auto.enabled == true },
                                                                     set: { model.setAutoDeploy($0, writesDisabled: writesDisabled) }))
                            .labelsHidden().toggleStyle(.switch)
                            .disabled(controlsDisabled)
                    }
                    if auto.enabled == true {
                        webhook(auto)
                    }
                } else {
                    NativeSettingsProse(text: "Deploys on push work for apps from GitHub. Other tools can still use a deploy link below.")
                }
                deployLink(auto)
                NativeAppsSRV2ResultLine(busy: model.busy, problem: model.problem, note: model.note,
                                         shown: model.resultPart == .autodeploy || model.resultPart == .link)
                lastDeploy
            }
        }
        .alert("Make a new deploy link?", isPresented: $confirmingNewLink) {
            NativeSessionButton("Cancel", role: .cancel) {}
            NativeSessionButton("Make new link") { showLinkSecret = false; model.makeDeployLink(writesDisabled: writesDisabled) }
        } message: {
            Text("The current link stops working at once. Update it wherever you use it, such as your build service.")
        }
    }

    @ViewBuilder private func webhook(_ auto: Model.AutoDeploy) -> some View {
        if let url = auto.webhookUrl {
            NativeSettingRow(label: "Webhook address") {
                HStack(spacing: 8) {
                    Text(url).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(url)
                    NativeSessionButton("Copy") { copy(url, what: "Webhook address") }
                }
            }
            NativeSettingRow(label: "Webhook secret", help: "Paste it into GitHub with the address.") {
                NativeAppsSRV2SecretValue(value: model.webhookSecret, busy: model.busy != nil,
                                          onShow: { model.revealWebhookSecret() }, onHide: model.hideWebhookSecret,
                                          onCopy: { model.revealWebhookSecret { copy($0, what: "Webhook secret", secret: true) } })
            }
            NativeSettingsProse(text: "In GitHub, open the repository’s Settings, then Webhooks, then Add webhook. Paste the address and the secret, choose application/json, and send only push events.")
                .font(.callout)
        } else {
            NativeSettingsProse(text: "This server has no public address for deploys yet. Run server setup again once it has one.")
        }
        if let key = auto.deployKey, !key.isEmpty {
            NativeSettingRow(label: "Deploy key", help: "For private repositories: add it to the repository’s deploy keys, read-only.") {
                HStack(spacing: 8) {
                    Text(key).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    NativeSessionButton("Copy") { copy(key, what: "Deploy key") }
                }
            }
        } else {
            NativeSettingRow(label: "Private repository?", help: "Make a read-only deploy key so the server can fetch your code.") {
                NativeSessionButton("Make a deploy key") { model.setAutoDeploy(true, deployKey: true, writesDisabled: writesDisabled) }
                    .disabled(controlsDisabled)
            }
        }
        if let copied { Text(copied).font(.callout).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func deployLink(_ auto: Model.AutoDeploy) -> some View {
        NativeSettingRow(label: "Deploy link", help: "Lets a build service start a deploy with a secret link.") {
            NativeSessionButton(auto.hasDeployLink == true || model.newLink != nil ? "Make a new link…" : "Make a deploy link") {
                if auto.hasDeployLink == true || model.newLink != nil { confirmingNewLink = true }
                else { showLinkSecret = false; model.makeDeployLink(writesDisabled: writesDisabled) }
            }
            .disabled(controlsDisabled)
        }
        if let link = model.newLink {
            NativeSettingRow(label: "Link address") {
                HStack(spacing: 8) {
                    Text(link.url).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(link.url)
                    NativeSessionButton("Copy") { copy(link.url, what: "Link address") }
                }
            }
            NativeSettingRow(label: "Link secret", help: "Shown only now. Keep it in your build service’s secret settings.") {
                NativeAppsSRV2SecretValue(value: showLinkSecret ? link.token : nil, busy: false,
                                          onShow: { showLinkSecret = true }, onHide: { showLinkSecret = false },
                                          onCopy: { copy(link.token, what: "Link secret", secret: true) })
            }
            if let usage = link.usage { NativeSettingsProse(text: usage).font(.callout) }
        } else if auto.hasDeployLink == true {
            NativeSettingsProse(text: "A deploy link is set. Its secret was shown once, when it was made. Make a new link if you no longer have it.")
                .font(.callout)
        }
    }

    @ViewBuilder private var lastDeploy: some View {
        NativeSettingRow(label: "Last deploy on the server", help: runningWords) {
            NativeSessionButton("Read again", action: model.refreshDeployLog)
        }
        if let log = model.deployLog, !log.isEmpty {
            NativeAppsSRV2LogView(text: log, label: "Last server deploy log")
        }
    }

    private var runningWords: String {
        switch model.deployRunning {
        case "active"?, "activating"?: return "A deploy is running now."
        case "failed"?: return "The last deploy failed. Its log is below."
        case _ where (model.deployLog ?? "").isEmpty: return "No deploy has run on the server yet."
        default: return "The last deploy finished. Its log is below."
        }
    }

    private func copy(_ text: String, what: String, secret: Bool = false) {
        copied = NativeAppsSRV2Clipboard.copy(text, secret: secret) ? "\(what) copied." : "\(what) could not be copied."
    }
}

/// A read-only log, as the app page's Logs tab shows it.
struct NativeAppsSRV2LogView: View {
    let text: String
    let label: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
        }
        .frame(minHeight: 80, maxHeight: 200)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .accessibilityLabel(label)
    }
}
