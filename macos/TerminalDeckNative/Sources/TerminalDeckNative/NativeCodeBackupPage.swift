import AppKit
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// L5: the app's one live Code model, built once at start from the existing owners (the project list, Git, the GitHub
/// sign-in). Reading it never changes a repository; slice 2's actions (`BackendCodeBackupActions`) are the only writers.
enum NativeCodeBackupLive {
    static func install(registry: NativeChannelRegistry, authority: BackendCompositionAuthority, auth: BackendGitHubAuthenticator,
                        environment: [String: String], dataRoot: URL, home: String,
                        loginPath: @escaping @Sendable () async throws -> String) async {
        guard let context = try? authority.localContext() else { return }
        let runner = BackendGitRunner(inheritedEnvironment: BackendCodeBackupGitReader.environment(environment, home: NSHomeDirectory()),
                                      loginPath: loginPath)
        let ledger = BackendCodeBackupLedger(file: dataRoot.appendingPathComponent(BackendCodeBackupLedger.fileName))
        let service = BackendCodeBackupProjects(
            projects: { try await NativeCompositionProduction.registeredProjects(registry: registry, context: authority.localContext()) },
            reader: BackendCodeBackupGitReader(runner: runner, context: context, githubHost: auth.host, coverage: { ledger.coverage($0) }),
            github: BackendCodeBackupGitHub.live(auth))
        let account = BackendCodeBackupLiveAccount(auth: auth, tools: BackendGitHubNativeTools(home: home, loginPath: loginPath), environment: environment)
        let actions = BackendCodeBackupActions(projects: service, ledger: ledger, account: account,
            git: BackendCodeBackupGitWriter(inheritedEnvironment: environment, home: NSHomeDirectory(), loginPath: loginPath), host: auth.host)
        await BackendCodeBackupHolder.shared.install(service, actions: actions)
        // Automatic looks every 5 minutes; never inside the test runner.
        // Same everywhere (15 Nov): "Code backup" switched off on this Mac = no automatic backups here (by hand still works).
        if NSClassFromString("XCTestCase") == nil, NativeCloudSyncChoices.isOn(.codeBackup, dataRoot: dataRoot) { await actions.start() }
    }
}

/// What the page shows; reads on the model's own actor, never on the main thread.
@MainActor @Observable
final class NativeCodeBackupPageModel {
    /// One model for both places that show it (the Code page and the Cloud page's "Code"), so a running backup, its
    /// Undo line and the rows are the same in both.
    static let shared = NativeCodeBackupPageModel()
    private(set) var report: BackendCodeBackupReport?
    private(set) var loading = false
    private(set) var unavailable = false
    var opened: Set<String> = []
    /// Slice 2: a row's running action ("Backing up · sending to …") and its 5-second Undo line.
    private(set) var working: [String: String] = [:]
    private(set) var waiting: [String: String] = [:]
    @ObservationIgnored private var undo: [String: Task<Void, Never>] = [:]
    var now = Date()
    /// Delete rule (L3): the project secret files' names and folders, and whether every Mac took the rule (no delete
    /// button for a secret file while an older Mac exists: its removal would not travel). One line per project.
    private(set) var secretStatus: BackendProjectSecretFilesStatus?
    private(set) var secretGateOpen = false
    private(set) var secretLine: [String: String] = [:]
    let fixture: Bool
    @ObservationIgnored private var generation = 0

    init(fixture: BackendCodeBackupReport? = nil, opened: Set<String> = [], now: Date = Date()) {
        report = fixture; self.fixture = fixture != nil; self.opened = opened; self.now = now
    }

    /// On opening the page and on Refresh only; never on a timer.
    func load(refresh: Bool) {
        guard !fixture else { return }
        generation += 1
        let mine = generation
        loading = true
        Task {
            // The Git facts first; private/public fills in when GitHub answers (never waited for).
            guard let service = await BackendCodeBackupHolder.shared.service else {
                if mine == generation { unavailable = report == nil; loading = false }
                return
            }
            let actions = await BackendCodeBackupHolder.shared.actions
            var facts = await service.report(refresh: refresh)
            if let actions { facts = await actions.decorate(facts) }
            // Project secret files: the held-back ones that travel with his saved passwords say so.
            let secrets = await BackendProjectSecretFilesHolder.shared.store?.status()
            facts = BackendProjectSecretFilesWords.decorate(facts, status: secrets)
            let gate = await BackendProjectSecretFilesHolder.shared.store?.canDeleteEverywhere() ?? false
            guard mine == generation else { return }
            secretStatus = secrets; secretGateOpen = gate
            report = facts; unavailable = false; now = Date(); loading = false
            var filled = await service.withGitHub(facts)
            if let actions { filled = await actions.decorate(filled) }
            filled = BackendProjectSecretFilesWords.decorate(filled, status: secrets)
            // An older look never overwrites a newer one.
            guard mine == generation else { return }
            report = filled
        }
    }

    // MARK: Slice 2 actions

    /// Back up now: what is sent cannot be taken back, so the row first shows what will happen for 5 seconds with Undo
    /// (no question, no sheet), then sends.
    func backUp(_ project: BackendCodeBackupProject) {
        guard !fixture, working[project.id] == nil, waiting[project.id] == nil else { return }
        let id = project.id
        waiting[id] = "Backing up"
        undo[id] = Task {
            guard let actions = await BackendCodeBackupHolder.shared.actions else { self.waiting[id] = nil; return }
            let target = await actions.target(projectID: id)
            if let address = target?.address, self.waiting[id] != nil {
                self.waiting[id] = target?.newHome == true ? "Making a private home \(address)"
                    : target?.organisation.map { "Sending to \(address) (organisation: everyone in \($0) can see backups)" } ?? "Sending to \(address)"
            }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self.waiting[id] = nil
            self.working[id] = "Backing up"
            _ = await actions.backUp(projectID: id, byHand: true) { text in Task { @MainActor in if self.working[id] != nil { self.working[id] = text } } }
            self.working[id] = nil
            self.undo[id] = nil
            self.load(refresh: false)
        }
    }

    func cancel(_ id: String) {
        undo[id]?.cancel(); undo[id] = nil; waiting[id] = nil
    }

    /// Get the code: his click is the whole decision (it adds his own code to his own folder and keeps what is there).
    func getCode(_ project: BackendCodeBackupProject) {
        guard !fixture, working[project.id] == nil else { return }
        let id = project.id
        working[id] = "Getting the code"
        Task {
            guard let actions = await BackendCodeBackupHolder.shared.actions else { self.working[id] = nil; return }
            _ = await actions.getCode(projectID: id) { text in Task { @MainActor in if self.working[id] != nil { self.working[id] = text } } }
            self.working[id] = nil
            self.load(refresh: false)
        }
    }

    func setMode(_ project: BackendCodeBackupProject, _ mode: BackendCodeBackupMode) {
        guard !fixture else { return }
        let id = project.id
        Task {
            await BackendCodeBackupHolder.shared.actions?.setMode(projectID: id, mode)
            self.load(refresh: false)
        }
    }

    /// A project secret file that travels: his press moves it to the Bin ("Everywhere": off every Mac; "Cloud": his
    /// devices keep their copies). Names only; the value never leaves the store.
    func deleteSecretFile(owner: String, name: String, folderHint: String?, scope: CloudDeleteScope) {
        guard !fixture, secretGateOpen,
              let file = secretStatus?.projects.first(where: { $0.id == owner })?.files
                .first(where: { $0.path == name && (folderHint == nil || $0.folder == folderHint) }) else { return }
        NativeCloudSheetGuard.shared.pagePress {
            let actor = NativeCloudDeleteNames.personActor()
            secretLine[owner] = BackendCloudFilesWords.removing
            Task {
                do {
                    guard let store = BackendProjectSecretFilesHolder.shared.store,
                          let item = try await store.deleteItem(projectId: owner, folder: file.folder, path: file.path) else { throw CloudFailure.invalidRequest }
                    _ = try await store.deleteItems([item], scope: scope, by: actor)
                    self.secretLine[owner] = "Moved to the Bin for 30 days."
                } catch { self.secretLine[owner] = "That file could not be removed. Nothing was changed." }
                self.load(refresh: false)
            }
        }
    }

    func toggle(_ id: String) {
        if opened.contains(id) { opened.remove(id) } else { opened.insert(id) }
    }
}

/// The Code page: every project, what needs attention first, its last backup to GitHub as a date and time, private or
/// public as a plain word, and on opening a row the lists of what is not backed up. Slice 2: each row has at most one
/// action (Back up now, or Get the code) and its backup choice (Automatic / Manual / Off).
struct NativeCodeBackupPage: View {
    @State private var model: NativeCodeBackupPageModel
    typealias W = BackendCodeBackupWords

    init(model: NativeCodeBackupPageModel = .shared) {
        _model = State(initialValue: model)
    }

    var body: some View {
        MACHINESPage(title: W.title, subtitle: "", switcher: { EmptyView() }, actions: {
            NativeCodeBackupRefresh(model: model)
        }) {
            NativeCodeBackupContent(model: model)
        }
        .task { model.load(refresh: false) }
    }
}

/// The Code page's Refresh button; the Cloud page's "Code" shows the same one above its rows.
struct NativeCodeBackupRefresh: View {
    let model: NativeCodeBackupPageModel
    var body: some View {
        Button { model.load(refresh: true) } label: { Label(BackendCodeBackupWords.refresh, systemImage: "arrow.clockwise") }
            .disabled(model.loading || model.fixture).help("Read every project's folder again")
            .accessibilityIdentifier("code.refresh")
    }
}

/// Mac tidy (Owner, 15 Nov: "a proper backup of code in GitHub, manage from there"): what the Code page shows, ONE
/// view drawn in two places: the Code page and the Cloud page when "Code" is chosen in its list.
struct NativeCodeBackupContent: View {
    let model: NativeCodeBackupPageModel
    @State private var github = GitHubScreenModel()
    typealias W = BackendCodeBackupWords

    var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                if let report = model.report {
                    if report.signedInToGitHub == false { signInLine }
                    else if report.automaticWaits && !report.projects.isEmpty {
                        Text(W.automaticWaits).font(.callout).foregroundStyle(.secondary)
                    }
                    if report.projects.isEmpty {
                        Text(W.noProjects).font(.callout).foregroundStyle(.secondary)
                    } else {
                        MACHINESCard { rows(report.projects) }
                    }
                    footnote(report)
                } else if model.unavailable {
                    Text("Starting…").font(.callout).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        .onChange(of: github.auth?.connected) { _, connected in if connected == true { model.load(refresh: true) } }
    }

    // MARK: Signed out of GitHub: one quiet line, never a sheet

    private var signInLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.open").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(W.signInLine).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(github.authBusy ? "Connecting…" : W.signInButton) {
                    github.show(NSHomeDirectory())
                    github.connect()
                }
                .buttonStyle(.borderless).disabled(model.fixture || github.authBusy)
                .accessibilityIdentifier("code.signIn")
            }
            if let prompt = github.auth?.pending {
                Text("Code: \(prompt.userCode)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let failure = github.auth?.failure, !github.authBusy {
                Text(failure.message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Rows

    private func rows(_ projects: [BackendCodeBackupProject]) -> some View {
        VStack(spacing: 0) {
            ForEach(projects) { project in
                row(project)
                if project.id != projects.last?.id { Divider() }
            }
        }
    }

    private func row(_ project: BackendCodeBackupProject) -> some View {
        let open = model.opened.contains(project.id)
        let summary = W.summary(project, now: model.now)
        let last = W.lastBackedUp(project, now: model.now)
        return VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .center, spacing: 10) {
            Button { withAnimation(.snappy(duration: 0.2)) { model.toggle(project.id) } } label: {
                HStack(alignment: .center, spacing: 12) {
                    Circle().fill(Self.tint(project)).frame(width: 8, height: 8).accessibilityHidden(true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            titleBlock(project, summary: summary)
                            Spacer(minLength: 12)
                            if !last.isEmpty { Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            titleBlock(project, summary: summary)
                            if !last.isEmpty { Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 4).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(project.name), \(summary)\(last.isEmpty ? "" : ", " + last)")
            .accessibilityHint(open ? "Hides what is not backed up" : "Shows what is not backed up")
            .accessibilityIdentifier("code.row.\(project.name)")
            controls(project)
          }
            if open { details(project).padding(.leading, 20).padding(.bottom, 12).transition(.opacity) }
        }
    }

    private func titleBlock(_ project: BackendCodeBackupProject, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                // Mac tidy (15 Nov): its GitHub repository by name, a link to its page.
                if let home = project.home { homeLink(home, link: project.homeLink) }
                if project.home != nil, project.visibility != .notChecked { visibility(project.visibility) }
            }
            Text(summary).font(.caption).foregroundStyle(project.needsAttention ? .primary : .secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let line = W.homeLine(project) ?? notFoundLine(project) {
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let line = model.working[project.id] ?? project.note {
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// Mac tidy: the repository's name, opening its GitHub page; plain text without a link. A part of a project with
    /// several folders shows its own in the opened row.
    @ViewBuilder private func homeLink(_ home: String, link: String?) -> some View {
        if let link, let url = URL(string: link) {
            Link(home, destination: url).font(.caption).lineLimit(1).truncationMode(.middle)
                .help("Open on GitHub").accessibilityIdentifier("code.home.\(home)")
        } else {
            Text(home).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    /// Mac tidy: code not here and nothing of it on his GitHub: say so (only once GitHub has answered).
    private func notFoundLine(_ project: BackendCodeBackupProject) -> String? {
        guard model.report?.signedInToGitHub == true, project.state == .codeNotHere, project.getFrom == nil, !project.getting else { return nil }
        return W.notFoundOnGitHub
    }

    // MARK: Slice 2: one action and the backup choice, beside the row

    /// Nothing works without GitHub: signed out, the page's one Connect GitHub line is the only control.
    @ViewBuilder private func controls(_ project: BackendCodeBackupProject) -> some View {
        if model.report?.signedInToGitHub != false {
            HStack(spacing: 8) {
                if let line = model.waiting[project.id] {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Undo") { model.cancel(project.id) }.buttonStyle(.borderless)
                        .accessibilityIdentifier("code.undo.\(project.name)")
                } else if model.working[project.id] != nil {
                    ProgressView().controlSize(.small)
                } else if project.state == .codeNotHere {
                    if project.getFrom != nil {
                        Button(project.getting ? "Continue" : "Get the code") { model.getCode(project) }
                            .disabled(model.fixture).accessibilityIdentifier("code.get.\(project.name)")
                    }
                } else if project.hasFolder && project.problem == nil {
                    if project.offersBackUp {
                        Button("Back up now") { model.backUp(project) }
                            .disabled(model.fixture).accessibilityIdentifier("code.backup.\(project.name)")
                    }
                    Menu {
                        // An organisation's home: Manual or Off only.
                        ForEach(project.modeChoices, id: \.self) { mode in
                            Button { model.setMode(project, mode) } label: {
                                if mode == project.mode { Label(mode.word, systemImage: "checkmark") } else { Text(mode.word) }
                            }
                        }
                    } label: { Text(project.mode.word).font(.caption) }
                    .menuStyle(.button).buttonStyle(.borderless).fixedSize().disabled(model.fixture)
                    .help(BackendCodeBackupActions.automaticRule)
                    .accessibilityLabel("Backup: \(project.mode.word)").accessibilityIdentifier("code.mode.\(project.name)")
                }
            }
            .controlSize(.small)
        }
    }



    private func visibility(_ value: BackendCodeBackupProject.Visibility) -> some View {
        HStack(spacing: 3) {
            switch value {
            case .isPrivate: Image(systemName: "lock.fill").imageScale(.small)
            case .isPublic: Image(systemName: "globe").imageScale(.small)
            case .notChecked: EmptyView()
            }
            Text(value.word)
        }
        .font(.caption).foregroundStyle(value == .notChecked ? .tertiary : .secondary)
        .accessibilityElement(children: .combine)
    }

    static func tint(_ project: BackendCodeBackupProject) -> Color {
        switch project.state {
        case .commitsNotOnGitHub, .filesChanged: .orange
        case .setAside: .orange
        case .noHome, .couldNotCheck, .secretsInCommits: .yellow
        case .backedUp: project.held.isEmpty ? .green : .yellow
        case .noFolder, .codeNotHere, .backupOff: Color.secondary.opacity(0.5)
        }
    }

    // MARK: An opened row

    private func details(_ project: BackendCodeBackupProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if project.parts.count > 1 {
                ForEach(Array(project.parts.enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(Self.tint(part)).frame(width: 6, height: 6).accessibilityHidden(true)
                            Text(part.folderName ?? part.id).font(.system(size: 12, weight: .semibold))
                            Text(W.summary(part, now: model.now)).font(.caption).foregroundStyle(.secondary)
                        }
                        folder(part, owner: project.id, folderHint: part.folderName ?? part.id)
                    }
                }
            } else {
                folder(project, owner: project.id, folderHint: nil)
            }
        }
    }

    /// One code folder: where it goes, its branch, then the lists of what is not backed up.
    private func folder(_ project: BackendCodeBackupProject, owner: String, folderHint: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            facts(project)
            if project.isRepository, project.problem == nil {
                if project.changedCount > 0 { list(W.changedTitle, count: project.changedCount, names: project.changedFiles) }
                if project.commitCount > 0 {
                    list(project.home != nil ? W.commitsTitle : "Commits not pushed", count: project.commitCount,
                         names: project.commits.map { $0.subject.isEmpty ? "(no message)" : $0.subject + " · " + W.short($0.at, now: model.now) })
                }
                if project.setAsideCount > 0 { list(W.setAsideTitle, count: project.setAsideCount, names: []) }
                if !project.secretsInCommits.isEmpty {
                    list(W.secretsInCommitsTitle, count: project.secretsInCommits.count, names: project.secretsInCommits)
                }
                if !project.held.isEmpty {
                    list(W.heldTitle, count: project.held.count, names: project.held.map { $0.name + " · " + (project.secretsTravel[$0.name].map { W.reason(.looksSecret) + " · " + $0 } ?? W.reason($0.reason)) })
                    secretFiles(project.held.map(\.name).filter { project.secretsTravel[$0] != nil }, owner: owner, folderHint: folderHint)
                }
            }
        }
    }

    /// Delete rule (L3): the secret files that travel with his saved passwords, each with the two delete buttons;
    /// none while an older Mac exists.
    @ViewBuilder private func secretFiles(_ names: [String], owner: String, folderHint: String?) -> some View {
        if NativeCloudOffers.shows(.projectCloudActions), model.secretGateOpen, !names.isEmpty, !model.fixture {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 8) {
                        Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button { model.deleteSecretFile(owner: owner, name: name, folderHint: folderHint, scope: .cloud) } label: {
                            Label(CloudDeleteWords.cloud, systemImage: "trash") }.help("Your devices keep their copies")
                        Button { model.deleteSecretFile(owner: owner, name: name, folderHint: folderHint, scope: .everywhere) } label: {
                            Label(CloudDeleteWords.everywhere, systemImage: "trash") }.help("Removed from all devices, in the Bin for 30 days")
                    }
                }
                if let line = model.secretLine[owner] { Text(line).font(.caption).foregroundStyle(.secondary) }
            }
            .controlSize(.small).buttonStyle(.borderless)
        }
    }

    private func facts(_ project: BackendCodeBackupProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let home = project.home {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("On GitHub").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                    homeLink(home, link: project.homeLink)
                    if project.visibility != .notChecked { Text(project.visibility.word).foregroundStyle(.secondary) }
                }.font(.caption)
            } else if let other = project.otherHost { fact("Kept at", other) }
            if project.isRepository { fact("Branch", project.branch ?? W.notOnBranch) }
            if let folder = project.folderName { fact("Folder", folder) }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(value).lineLimit(1).truncationMode(.middle)
        }.font(.caption)
    }

    private func list(_ title: String, count: Int, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(count))").font(.system(size: 12, weight: .semibold))
            if !names.isEmpty { VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(names.prefix(12).enumerated()), id: \.offset) { _, name in
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if count > min(names.count, 12) {
                    Text("and \(count - min(names.count, 12)) more").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 8)) }
        }
    }

    private func footnote(_ report: BackendCodeBackupReport) -> some View {
        Text("Checked \(W.short(report.checkedAt, now: model.now))")
            .font(.caption).foregroundStyle(.tertiary)
    }
}
