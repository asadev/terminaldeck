import Foundation
import SwiftUI
import TerminalDeckNativeCore

/// The app's own page inside the existing server page. Reads and changes stay
/// with NativeAppsModel, including its approval path and visible-only log stream.
struct NativeAppsDetailView: View {
    @Bindable var model: NativeAppsModel
    let app: NativeAppsSummary
    let onBack: () -> Void
    @State private var confirmation: NativeAppsDetailConfirmation?
    @State private var hostname = ""

    private var detail: NativeAppsDetail? {
        guard model.detail?.app.id == app.id else { return nil }
        return model.detail
    }

    private var currentApp: NativeAppsSummary { detail?.app ?? app }
    private var busy: Bool { model.busy != nil }
    private var writeControlsDisabled: Bool { busy || !model.canChange }
    private var pendingText: String? {
        guard let progress = model.busy else { return nil }
        // A read or a change may still finish after another app is opened. Keep
        // its actual destination in the pending line, rather than inferring it
        // from this page's heading.
        if let name = model.operationAppName, !name.isEmpty, !progress.contains(name) {
            return progress + " — " + name + "…"
        }
        return progress + "…"
    }
    private var isDatabase: Bool {
        ["database", "postgres", "postgresql", "mysql", "redis", "mongodb"].contains(currentApp.kind.lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
            tabs
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            Divider()
            Form {
                if !model.canChange {
                    Section {
                        if model.checkingCapabilities {
                            NativePageNote("Checking whether changes are available…", busy: true).frame(minHeight: 28)
                        } else {
                            NativeSettingsProse(text: model.writesUnavailableReason
                                ?? "This version cannot safely undo an interrupted server change.")
                            Button("Check again", action: model.refreshCapabilities).disabled(busy)
                        }
                    }
                }
                if let progress = pendingText {
                    Section { NativePageNote(progress, busy: true).frame(minHeight: 28) }
                }
                if model.detailLoading && detail != nil {
                    Section { NativePageNote("Refreshing app…", busy: true).frame(height: 28) }
                }
                if let problem = model.displayProblem, detail != nil, problem != model.writesUnavailableReason {
                    Section {
                        NativeCodingAINotice(tone: .error, text: problem)
                        if problem != model.sectionProblem {
                            Button("Read again", action: model.refreshDetail).disabled(busy || model.detailLoading)
                        }
                    }
                }
                if let notice = model.notice, notice != model.displayProblem, notice != model.sectionProblem {
                    Section { NativeSettingsProse(text: notice) }
                }
                if let problem = model.sectionProblem {
                    Section {
                        if problem != model.displayProblem {
                            NativeCodingAINotice(tone: .error, text: problem)
                        }
                        Button("Read again") { model.showTab(model.activeTab) }
                            .disabled(busy || model.sectionLoading || model.detailLoading)
                    }
                }
                if model.detailLoading && detail == nil {
                    NativeAppsDetailSkeleton(tab: model.activeTab)
                } else if let detail {
                    if model.sectionLoading {
                        NativeAppsDetailSkeleton(tab: model.activeTab)
                    } else if model.sectionProblem != nil && !(model.activeTab == .logs && !model.logs.isEmpty) {
                        Section {
                            NativePageEmpty(symbol: "exclamationmark.triangle", title: "Could not read \(model.activeTab.title.lowercased())") {
                                Text("Try again to read this section from the server.")
                            }
                        }
                    } else {
                        sections(detail)
                    }
                } else {
                    Section {
                        NativePageEmpty(symbol: "square.stack", title: "This app could not be read", action:
                            PageEmptyAction(label: "Read again", busy: model.detailLoading, perform: model.refreshDetail)) {
                            Text(model.displayProblem ?? "The server has not returned this app’s details.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
        }
        // The existing server page contains a vertical scroll. Give its nested
        // native form the same minimum measure as Advanced so it cannot collapse.
        .frame(maxWidth: .infinity, minHeight: 480, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .onChange(of: detail?.addresses.map(\.hostname)) { _, addresses in
            let candidate = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !candidate.isEmpty, addresses?.contains(candidate) == true { hostname = "" }
        }
        .sheet(item: $confirmation) { request in
            NativeAppsDetailConfirmationSheet(request: request, appName: currentApp.name, busy: writeControlsDisabled) { typedName in
                guard model.canChange else { confirmation = nil; return }
                switch request {
                case .removeApp:
                    model.removeApp(confirmationName: typedName)
                case .restore(let backupID, _):
                    model.restoreBackup(backupID, confirmationName: typedName)
                case .removeAddress(let address):
                    model.removeAddress(address)
                }
                confirmation = nil
            } onCancel: {
                confirmation = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("Back to apps", action: onBack)
                Spacer(minLength: 12)
                Button {
                    model.refreshDetail()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.detailLoading || model.sectionLoading || busy)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                NativeSettingsHead(title: currentApp.name, blurb: nil)
                Spacer(minLength: 12)
                Text(NativeAppsRules.friendlyStatus(currentApp.status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(NativeAppsTab.allCases, id: \.self) { tab in
                    NativeAppsDetailTabButton(title: tab.title, selected: model.activeTab == tab) {
                        model.showTab(tab)
                    }
                    .disabled(model.detailLoading || (tab == .backups && !isDatabase))
                    .help(tab == .backups && !isDatabase ? "Backups are available for databases." : "")
                }
            }
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("App sections")
    }

    @ViewBuilder private func sections(_ detail: NativeAppsDetail) -> some View {
        switch model.activeTab {
        case .overview: overview(detail)
        case .deploys: deploys(detail)
        case .logs: logs
        case .settings: settings(detail)
        case .address: addresses(detail)
        case .backups: backups(detail)
        }
    }

    @ViewBuilder private func overview(_ detail: NativeAppsDetail) -> some View {
        Section("App") {
            NativeSettingRow(label: "Status") {
                Text(NativeAppsRules.friendlyStatus(detail.app.status))
            }
            NativeSettingRow(label: "Source") {
                Text(detail.source.isEmpty ? "Not supplied" : detail.source)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let branch = detail.branch, !branch.isEmpty {
                NativeSettingRow(label: "Branch") {
                    Text(branch).textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(branch)
                }
            }
            if let port = detail.port {
                NativeSettingRow(label: "App port", help: "The number your app uses to receive requests.") {
                    Text(String(port)).monospacedDigit()
                }
            }
            if let updated = detail.updatedAt {
                NativeSettingRow(label: "Last updated") { Text(updated) }
            }
            if let address = detail.app.address, !address.isEmpty {
                NativeSettingRow(label: "Address") {
                    if let url = NativeAppsDetailWords.secureURL(address) {
                        Link(address, destination: url)
                            .lineLimit(2).truncationMode(.middle).help(address)
                    } else {
                        Text(address).textSelection(.enabled)
                    }
                }
            }
        }
        if isDatabase {
            Section("Connection") {
                NativeAppsDataDatabaseConnectionPanel(connection: model.dataDatabaseConnection,
                                                      loading: model.dataDatabaseLoading,
                                                      problem: model.dataDatabaseProblem,
                                                      onRefresh: model.refreshDatabaseConnection,
                                                      onOpenSettings: { model.showTab(.settings) })
            }
        }
        Section {
            HStack(spacing: 8) {
                Button("Restart app") { model.restartApp() }
                    .disabled(writeControlsDisabled)
                if !isDatabase {
                    Button("Deploy now") { model.deployApp() }
                        .disabled(writeControlsDisabled)
                }
                Button("View logs") { model.showTab(.logs) }
                    .disabled(model.detailLoading)
            }
        }
    }

    @ViewBuilder private func deploys(_ detail: NativeAppsDetail) -> some View {
        if !isDatabase {
            Section {
                HStack {
                    NativeSettingsProse(text: "Deploy the latest version from your saved source.")
                    Spacer(minLength: 12)
                    Button("Deploy now") { model.deployApp() }.disabled(writeControlsDisabled)
                }
            }
        }
        Section("Deploy history") {
            if detail.deployments.isEmpty {
                NativePageEmpty(symbol: "clock.arrow.circlepath", title: "No deploys yet") {
                    Text("Finished and failed deploys will appear here.")
                }
            } else {
                ForEach(detail.deployments, id: \.id) { deployment in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(deployment.title).font(.callout.weight(.medium)).lineLimit(2).truncationMode(.middle)
                                    .help(deployment.title)
                                if let date = deployment.createdAt {
                                    Text(date).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 12)
                            Text(NativeAppsRules.friendlyStatus(deployment.status))
                                .font(.callout).foregroundStyle(.secondary)
                            if deployment.canRollback {
                                Button("Roll back") { model.rollback(deployment.id) }
                                    .disabled(writeControlsDisabled)
                                    .help("Use this saved deploy after the change is approved.")
                                    .accessibilityLabel("Roll back to \(deployment.title)")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var logs: some View {
        Section {
            HStack(spacing: 8) {
                Label(model.logsLive ? "Live logs" : "Recent logs", systemImage: "text.alignleft")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Read again") { model.showTab(.logs) }
                    .disabled(model.sectionLoading || model.detailLoading)
            }
            if model.logs.isEmpty {
                NativePageEmpty(symbol: "text.alignleft", title: "No log lines yet") {
                    Text(model.logsLive ? "New lines will appear while this section is open." : "The app has not returned any log lines.")
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(model.logs.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                }
                .frame(minHeight: 240, maxHeight: 400)
                .accessibilityLabel("App log lines")
            }
            NativeSettingsProse(text: "Live logs stop when you leave this section. Saved secrets are hidden.")
                .font(.callout)
        }
    }

    @ViewBuilder private func settings(_ detail: NativeAppsDetail) -> some View {
        Section("Settings and secrets") {
            if isDatabase {
                NativeSettingsProse(text: "These values created the database’s login. This editor cannot change its saved login.")
                Button("View connection") { model.showTab(.overview) }
            } else {
                NativeSettingsProse(text: "Values stay hidden. To change one, enter a replacement value.")
                NativeSettingsProse(text: "New deploys use your saved settings.").font(.callout)
            }
            if detail.environment.isEmpty {
                NativePageNote(isDatabase ? "No setup settings were returned." : "No settings have been added.").frame(height: 28)
            }
            ForEach(detail.environment, id: \.key) { key in
                NativeAppsEnvironmentRow(key: key, appName: currentApp.name, busy: writeControlsDisabled,
                                         editable: !NativeAppsRules.isDatabaseLoginKey(kind: currentApp.kind, key: key.key)) { replacement in
                    model.saveEnvironment(key: key.key, value: replacement, remove: false)
                } onRemove: {
                    model.saveEnvironment(key: key.key, value: "", remove: true)
                }
            }
            if !isDatabase {
                NativeAppsNewEnvironmentRow(busy: writeControlsDisabled, existingKeys: Set(detail.environment.map(\.key)), kind: currentApp.kind) { key, value in
                    model.saveEnvironment(key: key, value: value, remove: false)
                }
            }
        }
        Section("Remove app") {
            NativeSettingsProse(text: isDatabase
                ? "Before removing \(currentApp.name), make sure you have any database backups you need."
                : "Remove \(currentApp.name) from this server. Its address will stop serving this app.")
            Button("Remove app…", role: .destructive) { confirmation = .removeApp }
                .disabled(writeControlsDisabled)
        }
    }

    @ViewBuilder private func addresses(_ detail: NativeAppsDetail) -> some View {
        Section("Web addresses") {
            if detail.addresses.isEmpty {
                NativePageEmpty(symbol: "globe", title: "No web address yet") {
                    Text(isDatabase ? "Databases do not need a public web address." : "A secure address appears after a successful deploy.")
                }
            }
            ForEach(detail.addresses, id: \.hostname) { address in
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            addressName(address)
                            Spacer(minLength: 12)
                            addressActions(address)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            addressName(address)
                            addressActions(address)
                        }
                    }
                    NativeSettingRow(label: "DNS", help: "The address setting that points visitors to this server.") {
                        Text(address.dnsReady == true ? "Pointing to this server" : address.dnsReady == false ? "Not pointing here yet" : "Not checked yet")
                            .foregroundStyle(.secondary)
                    }
                    NativeSettingRow(label: "Secure connection") {
                        Text(address.httpsReady == true ? "Ready" : address.httpsReady == false ? "Not ready yet" : "Not checked yet")
                            .foregroundStyle(.secondary)
                    }
                    if !address.isDefault, address.dnsReady != true {
                        if let instructions = address.instructions, !instructions.isEmpty {
                            NativeSettingsProse(text: instructions).font(.callout)
                        } else if let expected = address.expectedAddress, !expected.isEmpty {
                            NativeSettingsProse(text: "In your domain provider’s DNS settings, point \(address.hostname) to \(expected). Then choose Check.")
                                .font(.callout)
                        } else {
                            NativeSettingsProse(text: "In your domain provider’s DNS settings, point this name to this server. Choose Check to read the exact address it needs.")
                                .font(.callout)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        if !isDatabase {
            Section("Add your own address") {
                NativeSettingsProse(text: "Use a name you own, such as app.example.com. A secure connection is set up after it points to this server.")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        addressDraftField.frame(minWidth: 180)
                        addressDraftActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        addressDraftField
                        addressDraftActions
                    }
                }
                if let check = model.draftAddressCheck, check.hostname == hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                    NativeSettingsProse(text: check.dnsReady == true ? "DNS is pointing here. You can add this address." : "DNS is not pointing here yet.")
                    if let instructions = check.instructions, !instructions.isEmpty {
                        NativeSettingsProse(text: instructions).font(.callout)
                    } else if let expected = check.expectedAddress {
                        NativeSettingsProse(text: "In your domain provider’s DNS settings, point \(check.hostname) to \(expected). Then choose Check DNS.").font(.callout)
                    }
                }
            }
        }
    }

    private func addressName(_ address: NativeAppsAddress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(address.hostname).font(.callout.weight(.medium)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if address.isDefault {
                Text("Default").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func addressActions(_ address: NativeAppsAddress) -> some View {
        HStack(spacing: 8) {
            if let url = NativeAppsDetailWords.secureURL(address.hostname) {
                Link("Open", destination: url).buttonStyle(.bordered)
            }
            Button("Check") { model.checkAddress(address.hostname) }.disabled(busy)
            if !address.isDefault {
                Button("Remove…", role: .destructive) { confirmation = .removeAddress(address.hostname) }
                    .disabled(writeControlsDisabled)
            }
        }
        .fixedSize()
    }

    private var addressDraftField: some View {
        TextField("app.example.com", text: $hostname)
            .accessibilityLabel("New web address")
    }

    private var addressDraftActions: some View {
        HStack(spacing: 8) {
            Button("Check DNS") {
                model.checkAddress(hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            Button("Add address") {
                model.addAddress(hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            .disabled(!model.canChange)
        }
        .fixedSize()
        .disabled(busy || !NativeAppsRules.validHostname(hostname.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @ViewBuilder private func backups(_ detail: NativeAppsDetail) -> some View {
        if !isDatabase {
            Section {
                NativePageEmpty(symbol: "externaldrive", title: "Backups are for databases") {
                    Text("Choose a database app to view and manage its backups.")
                }
            }
        } else {
            Section("Scheduled backups") {
                NativeAppsBackupScheduleEditor(schedule: detail.backupSchedule, busy: writeControlsDisabled) {
                    model.saveBackupSchedule($0)
                }
            }
            Section("Backup storage") {
                NativeAppsDataBackupUploadEditor(settings: model.dataBackupSettings,
                                                busy: writeControlsDisabled, problem: nil) {
                    model.saveBackupUpload($0)
                }
            }
            Section("Saved backups") {
                HStack {
                    NativeSettingsProse(text: "Backups are stored on the server.")
                    Spacer(minLength: 12)
                    Button("Back up now") { model.backupNow() }.disabled(writeControlsDisabled)
                }
                if detail.backups.isEmpty {
                    NativePageEmpty(symbol: "externaldrive", title: "No backups yet") {
                        Text("Make the first backup now, or add a daily schedule.")
                    }
                } else {
                    ForEach(detail.backups, id: \.id) { backup in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(backup.createdAt ?? "Saved backup").font(.callout.weight(.medium))
                                if let size = backup.size {
                                    Text(size).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 12)
                            Button("Restore…") {
                                confirmation = .restore(backup.id, backup.createdAt ?? "this saved backup")
                            }
                            .disabled(writeControlsDisabled)
                            .accessibilityLabel("Restore backup from \(backup.createdAt ?? backup.id)")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}
