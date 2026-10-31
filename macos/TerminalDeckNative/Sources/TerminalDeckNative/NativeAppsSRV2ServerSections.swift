import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// SRV2: the server's own Apps page — Server setup, Alerts, Recent alerts,
/// Cleanup and disk — in the same header + grouped Form as the app page.
struct NativeAppsSRV2ServerPage: View {
    let serverID: String
    let serverName: String
    var writesDisabled = false
    let onBack: () -> Void
    @State private var holder = NativeAppsSRV2ServerHolder()

    var body: some View {
        let model = holder.model(serverID: serverID, serverName: serverName)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button("Back to apps", action: onBack)
                    Spacer(minLength: 12)
                    Button { model.load() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(model.loading || model.busy != nil)
                }
                NativeSettingsHead(title: "Server", blurb: "How \(serverName) runs your apps when this Mac is off.")
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()
            Form {
                NativeAppsSRV2ServerSectionList(model: model, writesDisabled: writesDisabled)
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
        }
        .frame(maxWidth: .infinity, minHeight: 480, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}

@MainActor
final class NativeAppsSRV2ServerHolder {
    private var current: NativeAppsSRV2ServerModel?

    func model(serverID: String, serverName: String) -> NativeAppsSRV2ServerModel {
        if let current, current.serverID == serverID { return current }
        let next = NativeAppsSRV2ServerModel(serverID: serverID, serverName: serverName)
        current = next
        return next
    }
}

enum NativeAppsSRV2ServerConfirm: Identifiable {
    case remove
    case addLine(file: String, line: String)
    var id: String {
        switch self {
        case .remove: "remove"
        case .addLine(let file, let line): "line:" + file + "\n" + line
        }
    }
}

enum NativeMACHINESServerSettingsSection: Hashable { case setup, alerts, history, cleanup }

struct NativeAppsSRV2ServerSectionList: View {
    @Bindable var model: NativeAppsSRV2ServerModel
    var writesDisabled = false
    var sections: Set<NativeMACHINESServerSettingsSection> = [.setup, .alerts, .history, .cleanup]
    @State private var confirm: NativeAppsSRV2ServerConfirm?
    @State private var expanded: Set<UUID> = []

    private typealias Model = NativeAppsSRV2ServerModel
    private var controlsDisabled: Bool { writesDisabled || model.busy != nil }
    private func shows(_ parts: Model.Part...) -> Bool { model.resultPart.map { parts.contains($0) } ?? false }

    var body: some View {
        if let status = model.status {
            Group {
                if sections.contains(.setup) { setup(status) }
                if sections.contains(.alerts) { alerts(status) }
                if sections.contains(.history), status.installed, model.alerts != nil { history }
                if sections.contains(.cleanup) { cleanup(status) }
            }
            .task(id: model.serverID) { model.loadIfNeeded() }
            .sheet(item: $confirm) { request in confirmationSheet(request, status: status) }
        } else {
            Section("Server setup") {
                if model.loading {
                    NativePageNote("Checking this server…", busy: true).frame(height: 28)
                } else {
                    NativeCodingAINotice(tone: .error, text: model.loadProblem ?? "This server could not be checked.")
                    Button("Check again", action: model.load)
                }
            }
            .task(id: model.serverID) { model.loadIfNeeded() }
        }
    }

    // MARK: Server setup

    private func setup(_ status: Model.Status) -> some View {
        Section("Server setup") {
            NativeSettingRow(label: "Set up for Apps") {
                Text(setupWords(status)).foregroundStyle(.secondary)
            }
            NativeSettingRow(label: "Docker") {
                Text(status.docker.map { "Version \($0)" } ?? "Not installed yet").foregroundStyle(.secondary)
            }
            if let summary = status.routerSummary, !summary.isEmpty {
                NativeSettingRow(label: "Web addresses", help: summary) { EmptyView() }
            }
            if status.installed {
                NativeSettingRow(label: "Server duties", help: dutiesWords(status.duties)) { EmptyView() }
                if let host = status.duties?.hooksHost, !host.isEmpty {
                    NativeSettingRow(label: "Deploy endpoint", help: "Where GitHub and build services ask this server to deploy.") {
                        Text(host).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(host)
                    }
                }
            }
            if let plan = model.plan, !status.installed || status.needsUpdate {
                if let blocked = plan.blockedReason, !blocked.isEmpty {
                    NativeSettingsProse(text: blocked)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(plan.upgrade == true ? "What updating will do" : "What setup will do").font(.callout.weight(.medium))
                        ForEach(plan.steps ?? []) { step in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(.callout)
                                Text(step.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    HStack(spacing: 8) {
                        Button(plan.upgrade == true ? "Update the helper set" : "Set up this server") { model.install(writesDisabled: writesDisabled) }
                            .disabled(controlsDisabled)
                        Text("You’ll review the server change before it runs.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else if model.plan == nil, !status.installed, status.administrator == false {
                NativeSettingsProse(text: "Setup needs administrator access (root, or sudo without a password). Terminals and the Docker view keep working without it.")
            }
            persistence
            NativeAppsSRV2ResultLine(busy: model.busy, problem: model.problem, note: model.note,
                                     shown: shows(.setup, .remove, .persist))
            if status.installed {
                VStack(alignment: .leading, spacing: 8) {
                    NativeSettingsProse(text: "Removes Terminal Deck’s helpers, duties and settings from this server. Your apps, their data and backups stay.")
                        .font(.callout)
                    Button("Remove Terminal Deck from this server…", role: .destructive) { confirm = .remove }
                        .disabled(controlsDisabled)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private var persistence: some View {
        if let persistence = model.persistence {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keep addresses after a restart").font(.callout.weight(.medium))
                NativeSettingsProse(text: persistence.note).font(.callout)
                if !persistence.ready, let line = persistence.line, let file = persistence.file {
                    Text(line)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                    Text("In \(file)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Add this line…") { confirm = .addLine(file: file, line: line) }
                        .disabled(controlsDisabled)
                }
            }
            .padding(.vertical, 4)
        } else if let problem = model.persistenceProblem {
            NativeSettingsProse(text: problem).font(.callout)
        }
    }

    @ViewBuilder private func confirmationSheet(_ request: NativeAppsSRV2ServerConfirm, status: Model.Status) -> some View {
        switch request {
        case .remove:
            if let owned = model.persistence?.owned {
                // Exactly the line Terminal Deck added (its receipt), shown before anything runs.
                NativeAppsSRV2ConfirmationSheet(
                    title: "Remove Terminal Deck from \(model.serverName)?",
                    message: "Its helpers, duties and settings are removed from this server: alerts, checks, cleanup, scheduled jobs and automatic deploys stop. Your apps, their data and backups stay.\n\nTerminal Deck also added this line to \(owned.file). If you take it out, the files Terminal Deck wrote in \(owned.folder) go too, and your apps lose their addresses the next time Caddy restarts.",
                    code: owned.line,
                    typedName: model.confirmationName,
                    optionLabel: "Also take this line out of \(owned.file)",
                    confirmTitle: "Remove", destructive: true, busy: controlsDisabled) { typed, option in
                        model.remove(typedName: typed, addressManager: false, importUndo: option ? owned : nil, writesDisabled: writesDisabled)
                        confirm = nil
                    } onCancel: { confirm = nil }
            } else {
                NativeAppsSRV2ConfirmationSheet(
                    title: "Remove Terminal Deck from \(model.serverName)?",
                    message: "Its helpers, duties and settings are removed from this server: alerts, checks, cleanup, scheduled jobs and automatic deploys stop. Your apps, their data and backups stay.",
                    typedName: model.confirmationName,
                    optionLabel: status.router == "ours" ? "Also remove Terminal Deck’s address manager (kept if apps still use it)" : nil,
                    confirmTitle: "Remove", destructive: true, busy: controlsDisabled) { typed, option in
                        model.remove(typedName: typed, addressManager: option, writesDisabled: writesDisabled)
                        confirm = nil
                    } onCancel: { confirm = nil }
            }
        case .addLine(let file, let line):
            NativeAppsSRV2ConfirmationSheet(message: "Add this one line to \(file):", code: line,
                                            confirmTitle: "Add line", busy: controlsDisabled) { _, _ in
                model.applyPersistence(file: file, line: line, writesDisabled: writesDisabled)
                confirm = nil
            } onCancel: { confirm = nil }
        }
    }

    private func setupWords(_ status: Model.Status) -> String {
        guard let installed = status.installedVersion, !installed.isEmpty else { return "Not yet" }
        if status.needsUpdate, let helper = status.helperVersion { return "Yes — update available (\(installed) → \(helper))" }
        return "Yes, helper set \(installed)"
    }

    private func dutiesWords(_ duties: Model.Status.Duties?) -> String {
        func on(_ state: String?) -> Bool { ["active", "listening", "activating", "reloading"].contains(state ?? "") }
        guard let duties else { return "Not reported yet." }
        return [on(duties.watch) ? "Alert watcher on" : "Alert watcher off",
                on(duties.checks) ? "Checks every 5 minutes" : "Checks off",
                on(duties.cleanup) ? "Cleanup scheduled" : "Cleanup off",
                on(duties.endpoint) ? "Deploy endpoint ready" : "Deploy endpoint off"].joined(separator: " · ")
    }

    // MARK: Alerts

    private func alerts(_ status: Model.Status) -> some View {
        Section("Alerts") {
            if !status.installed {
                NativeSettingsProse(text: "Set up this server first. The server then sends alerts itself, even when this Mac is off.")
            } else if let problem = model.alertsProblem {
                NativeCodingAINotice(tone: .error, text: problem)
                Button("Read again", action: model.load).disabled(model.loading || model.busy != nil)
            } else if model.alerts != nil {
                NativeSettingsProse(text: "The server warns you when an app stops or keeps restarting, the disk or memory runs low, a backup or deploy fails, or a certificate is not renewing.")
                NativeSettingRow(label: "Send alerts") {
                    Toggle("Send alerts", isOn: $model.alertsDraft.enabled).labelsHidden().toggleStyle(.switch)
                }
                if model.alertsDraft.channels.isEmpty {
                    NativePageNote("No channels yet. Add one to receive alerts.").frame(height: 28)
                }
                ForEach($model.alertsDraft.channels) { $channel in
                    NativeAppsSRV2AlertChannelRow(channel: $channel, expanded: Binding(get: { expanded.contains(channel.id) || !channel.saved },
                                                                                        set: { if $0 { expanded.insert(channel.id) } else { expanded.remove(channel.id) } }),
                                                  testResult: model.testResults[channel.name]) {
                        model.removeChannel(channel.id)
                    }
                }
                Menu("Add a channel") {
                    ForEach(Model.ChannelKind.allCases) { kind in
                        Button { model.addChannel(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(model.alertsDraft.channels.count >= 10)
                NativeSettingRow(label: "Disk fuller than") {
                    NativeAppsSRV2NumberField(label: "Disk fuller than", value: $model.alertsDraft.diskPercent, range: 50...99, unit: "%")
                }
                NativeSettingRow(label: "Memory pressure above", help: "How much of the last 10 seconds the server spent waiting for memory.") {
                    NativeAppsSRV2NumberField(label: "Memory pressure above", value: $model.alertsDraft.memoryPressure, range: 1...100, unit: "%")
                }
                NativeSettingRow(label: "Certificate expires within") {
                    NativeAppsSRV2NumberField(label: "Certificate expires within", value: $model.alertsDraft.certDays, range: 1...60, unit: "days")
                }
                NativeSettingRow(label: "Remind again after", help: "While a problem lasts.") {
                    NativeAppsSRV2NumberField(label: "Remind again after", value: $model.alertsDraft.remindMinutes, range: 10...10_080, unit: "minutes")
                }
                NativeSettingRow(label: "Also watch", help: "Other running services on this server, by name, separated by commas. Terminal Deck’s own apps are always watched.") {
                    TextField("Also watch", text: $model.alertsDraft.watch, prompt: Text("my-proxy, my-database")).labelsHidden()
                        .frame(minWidth: 160, maxWidth: 260)
                }
                HStack(spacing: 8) {
                    Button("Save") { model.saveAlerts(writesDisabled: writesDisabled) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.alertsChanged || controlsDisabled)
                    if model.alertsChanged {
                        Button("Undo changes", action: model.revertAlerts).disabled(controlsDisabled)
                    }
                    Spacer(minLength: 12)
                    Button("Send a test alert") { model.testAlerts(writesDisabled: writesDisabled) }
                        .disabled(!model.canTestAlerts || controlsDisabled)
                        .help(model.alertsChanged ? "Save your changes first." : "Sends a short test message to every channel that is on.")
                }
                NativeAppsSRV2ResultLine(busy: model.busy, problem: model.problem, note: model.note,
                                         shown: shows(.alerts, .test))
            }
        }
        .disabled(writesDisabled)
    }

    private var history: some View {
        Section("Recent alerts") {
            if model.history.isEmpty {
                NativePageNote("No alerts sent yet.").frame(height: 28)
            } else {
                ForEach(model.history.prefix(10)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: entry.severity == "critical" ? "xmark.octagon" : entry.severity == "warning" ? "exclamationmark.triangle" : "info.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(entry.severity == "critical" ? "Critical" : entry.severity == "warning" ? "Warning" : "Information")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(.callout.weight(.medium)).lineLimit(2)
                            if !entry.message.isEmpty {
                                Text(entry.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(deliveredWords(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        if let at = entry.at { Text(at).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func deliveredWords(_ entry: Model.AlertEntry) -> String {
        let app = entry.app.map { "\($0) · " } ?? ""
        guard !entry.delivered.isEmpty else { return app + "No channel was on" }
        let reached = entry.delivered.filter(\.ok).map(\.id)
        let missed = entry.delivered.filter { !$0.ok }.map(\.id)
        var words = reached.isEmpty ? "Not delivered" : "Sent to " + reached.joined(separator: ", ")
        if !missed.isEmpty, !reached.isEmpty { words += " · failed: " + missed.joined(separator: ", ") }
        else if !missed.isEmpty { words += " (" + missed.joined(separator: ", ") + ")" }
        return app + words
    }

    // MARK: Cleanup and disk

    private func cleanup(_ status: Model.Status) -> some View {
        Section("Cleanup and disk") {
            if let disk = status.diskPercent {
                NativeSettingRow(label: "Disk in use",
                                 help: model.alerts.map { "You get an alert when it is fuller than \($0.diskPercent)%. Change that in Alerts." }) {
                    Text("\(Int(disk))%").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if !status.installed {
                NativeSettingsProse(text: "Set up this server first. Cleanup then runs on the server by itself.")
            } else if let problem = model.cleanupProblem {
                NativeCodingAINotice(tone: .error, text: problem)
                Button("Read again", action: model.load).disabled(model.loading || model.busy != nil)
            } else if model.cleanup != nil {
                NativeSettingsProse(text: "Cleanup removes only what Terminal Deck made: unused leftovers from its own builds. Other tools’ files and programs are never touched, except the shared build cache below if you turn it on.")
                NativeSettingRow(label: "Automatic cleanup") {
                    Toggle("Automatic cleanup", isOn: $model.cleanupDraft.enabled).labelsHidden().toggleStyle(.switch)
                }
                if model.cleanupDraft.enabled {
                    NativeAppsSRV2ScheduleEditor(schedule: $model.cleanupSchedule, presets: [.daily, .weekly, .custom])
                    if let next = NativeAppsSRV2Engine.systemdDate(model.cleanupNextRun) {
                        NativeSettingRow(label: "Next cleanup") { Text(next).foregroundStyle(.secondary) }
                    }
                }
                Text("It may also remove").font(.callout.weight(.medium)).padding(.top, 4)
                NativeSettingRow(label: "Older app versions", help: "The newest ones are kept so you can still roll back.") {
                    Toggle("Older app versions", isOn: $model.cleanupDraft.removeOldVersions).labelsHidden().toggleStyle(.switch)
                }
                if model.cleanupDraft.removeOldVersions {
                    NativeSettingRow(label: "Versions to keep per app") {
                        NativeAppsSRV2NumberField(label: "Versions to keep per app", value: $model.cleanupDraft.keepVersions, range: 1...50, unit: nil)
                    }
                }
                NativeSettingRow(label: "Storage left by removed apps", help: "Only unnamed storage that Terminal Deck made.") {
                    Toggle("Storage left by removed apps", isOn: $model.cleanupDraft.unnamedStorage).labelsHidden().toggleStyle(.switch)
                }
                NativeSettingRow(label: "Every tool’s build cache older than a week",
                                 help: "Docker keeps one build cache for the whole server, so this also clears week-old cache that other tools made. Their next build starts from scratch.") {
                    Toggle("Every tool’s build cache older than a week", isOn: $model.cleanupDraft.buildCache).labelsHidden().toggleStyle(.switch)
                }
                HStack(spacing: 8) {
                    Button("Save") { model.saveCleanup(writesDisabled: writesDisabled) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.cleanupChanged || controlsDisabled)
                    if model.cleanupChanged {
                        Button("Undo changes", action: model.revertCleanup).disabled(controlsDisabled)
                    }
                }
                NativeAppsSRV2ResultLine(busy: model.busy, problem: model.problem, note: model.note, shown: model.resultPart == .cleanup)
                if let last = model.cleanupLast, let when = NativeAppsSRV2Engine.date(last.finishedAt) {
                    NativeSettingRow(label: "Last cleanup") {
                        Text("\(when) · \(NativeAppsSRV2Engine.bytes(last.freedBytes)) freed").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Show what would be removed", action: model.previewCleanup)
                        .disabled(model.busy != nil)
                    Button("Run cleanup now") { model.runCleanup(writesDisabled: writesDisabled) }
                        .disabled(model.cleanupPreview == nil || controlsDisabled)
                        .help(model.cleanupPreview == nil ? "Check what would be removed first." : "Removes the items listed below.")
                }
                if let preview = model.cleanupPreview {
                    let items = preview.items ?? []
                    if items.isEmpty {
                        NativePageNote("Nothing to remove right now.").frame(height: 28)
                    } else {
                        ForEach(items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: item.kind == "build-cache" ? "hammer" : item.kind == "unnamed-storage" ? "externaldrive" : "shippingbox")
                                    .foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(itemTitle(item)).font(.callout)
                                    Text(itemDetail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 12)
                                if let bytes = item.bytes, bytes > 0 {
                                    Text(NativeAppsSRV2Engine.bytes(bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                NativeAppsSRV2ResultLine(busy: model.busy, problem: model.problem, note: model.note, shown: model.resultPart == .preview)
            }
        }
    }

    private func itemTitle(_ item: Model.CleanupResult.Item) -> String {
        switch item.kind {
        case "build-cache": "Every tool’s build cache older than a week"
        case "unnamed-storage": "Storage left by a removed app"
        default: item.reason == "older app version" ? "Older app version" : "Unused build leftover"
        }
    }

    private func itemDetail(_ item: Model.CleanupResult.Item) -> String {
        let state: String
        switch item.result {
        case "would-remove", "would-trim": state = "Would be removed"
        case "removed", "trimmed": state = "Removed"
        case "kept-in-use": state = "Kept: still in use"
        case "failed": state = "Could not be removed"
        default: state = item.result ?? ""
        }
        let app = item.app.flatMap { $0.isEmpty ? nil : $0 }
        return [app, state].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Alert channel row

struct NativeAppsSRV2AlertChannelRow: View {
    @Binding var channel: NativeAppsSRV2ServerModel.AlertChannel
    @Binding var expanded: Bool
    let testResult: Bool?
    let onRemove: () -> Void
    @State private var removing = false

    private var summary: String {
        switch channel.kind {
        case .telegram: return channel.chatId.isEmpty ? "Telegram bot" : "Telegram · \(channel.chatId)"
        case .email: return channel.to.isEmpty ? "Email" : "Email · \(channel.to)"
        case .webhook, .receiver:
            let host = URL(string: channel.url)?.host() ?? ""
            return channel.kind.title + (host.isEmpty ? "" : " · \(host)")
        }
    }

    /// A brand-new, still empty channel shows no complaint yet.
    private var touched: Bool {
        channel.saved || ![channel.secret, channel.chatId, channel.smtpUrl, channel.username, channel.from, channel.to, channel.url].allSatisfy(\.isEmpty)
    }

    private var secretLabel: String {
        switch channel.kind {
        case .telegram: "Bot token"
        case .email: "Password"
        case .webhook: "Signing secret"
        case .receiver: "Secret"
        }
    }

    private var secretPrompt: String {
        if channel.hasSecret { return "Saved — type to replace" }
        switch channel.kind {
        case .telegram: return "123456789:AA…"
        case .email: return "Mail account password"
        case .webhook: return "Optional"
        case .receiver: return "From the Receiver source"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: channel.kind.symbol).foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name).font(.callout.weight(.medium))
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if let testResult {
                    Text(testResult ? "Test arrived" : "Test failed").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("On", isOn: $channel.enabled).toggleStyle(.checkbox).font(.callout)
                if channel.saved {
                    Button(expanded ? "Done" : "Edit") { expanded.toggle() }
                }
                Button("Remove…", role: .destructive) { removing = true }
            }
            if expanded {
                if !channel.saved {
                    NativeSettingRow(label: "Name", help: "Letters, numbers, dashes and underscores. It can’t change after saving.") {
                        TextField("Name", text: $channel.name, prompt: Text("my-phone")).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                    }
                }
                switch channel.kind {
                case .telegram:
                    NativeSettingRow(label: "Chat", help: "The numeric chat ID, or @channel for a public channel.") {
                        field("Chat", $channel.chatId, "-1001234567890")
                    }
                case .email:
                    NativeSettingRow(label: "Mail server", help: "Such as smtps://smtp.example.com:465.") { field("Mail server", $channel.smtpUrl, "smtps://smtp.example.com:465") }
                    NativeSettingRow(label: "User name", help: "Leave blank if the server needs no sign-in.") { field("User name", $channel.username, "alerts@example.com") }
                    NativeSettingRow(label: "From") { field("From", $channel.from, "alerts@example.com") }
                    NativeSettingRow(label: "To", help: "Up to 10 addresses, separated by commas.") { field("To", $channel.to, "you@example.com") }
                case .webhook:
                    NativeSettingRow(label: "Address", help: "An https:// address that accepts a JSON message.") { field("Address", $channel.url, "https://example.com/alerts") }
                case .receiver:
                    NativeSettingRow(label: "Address", help: "The address of a Receiver source.") { field("Address", $channel.url, "https://…/in/…") }
                }
                NativeSettingRow(label: secretLabel, help: channel.hasSecret ? "Saved on the server and never shown again." : nil) {
                    SecureField(secretLabel, text: $channel.secret, prompt: Text(secretPrompt)).labelsHidden().frame(minWidth: 160, maxWidth: 260)
                }
                if touched, let problem = NativeAppsSRV2ServerModel.channelProblem(channel) {
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .alert("Remove \(channel.name)?", isPresented: $removing) {
            Button("Cancel", role: .cancel) {}
            Button("Remove channel", role: .destructive, action: onRemove)
        } message: {
            Text("Alerts stop going to this channel after you save.")
        }
    }

    private func field(_ label: String, _ text: Binding<String>, _ prompt: String) -> some View {
        TextField(label, text: text, prompt: Text(prompt)).labelsHidden().frame(minWidth: 160, maxWidth: 260)
    }
}

// MARK: - Shared pieces (server page and app page)

/// The section's last result: a busy line, a problem, or the saved note.
struct NativeAppsSRV2ResultLine: View {
    let busy: String?
    let problem: String?
    let note: String?
    let shown: Bool

    var body: some View {
        if shown {
            if let busy {
                NativePageNote(busy + "…", busy: true).frame(height: 28)
            } else if let problem {
                NativeCodingAINotice(tone: .error, text: problem)
            } else if let note {
                NativeSettingsProse(text: note).font(.callout)
            }
        }
    }
}

/// Repeat: every hour / day / week, or a custom calendar time.
struct NativeAppsSRV2ScheduleEditor: View {
    @Binding var schedule: NativeAppsSRV2Schedule
    var presets: [NativeAppsSRV2Schedule.Preset] = NativeAppsSRV2Schedule.Preset.allCases

    private func title(_ preset: NativeAppsSRV2Schedule.Preset) -> String {
        switch preset {
        case .hourly: "Every hour"
        case .daily: "Every day"
        case .weekly: "Every week"
        case .custom: "Custom"
        }
    }

    var body: some View {
        NativeSettingRow(label: "Repeat", help: "Times use the server’s clock.") {
            Picker("Repeat", selection: $schedule.preset) {
                ForEach(presets) { preset in Text(title(preset)).tag(preset) }
            }
            .labelsHidden()
            .fixedSize()
        }
        if schedule.preset == .weekly {
            NativeSettingRow(label: "On") {
                Picker("Day", selection: $schedule.day) {
                    ForEach(Array(NativeAppsSRV2Schedule.days.enumerated()), id: \.element) { index, day in
                        Text(NativeAppsSRV2Schedule.dayNames[index]).tag(day)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        if schedule.preset == .daily || schedule.preset == .weekly {
            NativeSettingRow(label: "At", help: "24-hour time: 03:00 means 3 am.") {
                TextField("At", text: $schedule.time, prompt: Text("03:00")).labelsHidden().frame(width: 90)
                    .accessibilityLabel("Time of day on the server")
            }
        }
        if schedule.preset == .custom {
            NativeSettingRow(label: "Schedule", help: "A systemd calendar time, such as Mon *-*-* 03:00:00.") {
                TextField("Schedule", text: $schedule.custom, prompt: Text("*-*-* 02:30:00")).labelsHidden()
                    .font(.callout.monospaced()).frame(minWidth: 160, maxWidth: 260)
            }
        }
        if let problem = schedule.problem {
            NativeCodingAINotice(tone: .warn, text: problem)
        }
    }
}

/// A secret shown as dots until Show; Copy marks the clipboard as concealed so
/// clipboard managers skip it. The value is never logged.
struct NativeAppsSRV2SecretValue: View {
    let value: String?
    let busy: Bool
    let onShow: () -> Void
    let onHide: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(value ?? NativeAppsVariable.mask)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel(value == nil ? "Secret hidden" : "Secret shown")
            Button(value == nil ? "Show" : "Hide") { value == nil ? onShow() : onHide() }
            Button("Copy", action: onCopy)
        }
        .disabled(busy)
    }
}

enum NativeAppsSRV2Clipboard {
    @MainActor @discardableResult
    static func copy(_ text: String, secret: Bool = false) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        let copied = board.setString(text, forType: .string)
        if secret { _ = board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
        return copied
    }
}

/// A confirmation in the look of NativeAppsDetailConfirmationSheet, with an
/// optional typed name, an exact text block and one extra choice.
struct NativeAppsSRV2ConfirmationSheet: View {
    var title: String? = nil
    let message: String
    var code: String? = nil
    var typedName: String? = nil
    var optionLabel: String? = nil
    let confirmTitle: String
    var destructive = false
    let busy: Bool
    let onConfirm: (String, Bool) -> Void
    let onCancel: () -> Void
    @State private var typed = ""
    @State private var option = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title { NativeSettingsHead(title: title, blurb: nil) }
            NativeSettingsProse(text: message)
            if let code {
                Text(code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
            }
            if let optionLabel {
                Toggle(optionLabel, isOn: $option).toggleStyle(.checkbox)
            }
            if let typedName {
                Text("Type \(typedName) to confirm.").font(.callout)
                TextField("Server name", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Type \(typedName) to confirm")
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: destructive ? .destructive : nil) { onConfirm(typed.trimmingCharacters(in: .whitespaces), option) }
                    .disabled(busy || (typedName.map { typed.trimmingCharacters(in: .whitespaces) != $0 } ?? false))
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
