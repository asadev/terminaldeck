import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The Debug panel (`DebugPanel.tsx`): the main process's IPC calls as they happen
/// (filter, Pause, Clear; the six slowest channels above), the session processes
/// (re-read every two seconds while shown), the support bundle (Collect, Copy) and
/// the log (Refresh, Open log folder, Clear). Settings → Advanced → Diagnostics
/// shows it with `enabled: true`.
struct NativeDebugPanel: View {
    /// Shown regardless of the stored debug mode (and without "Turn off debug mode").
    var enabled: Bool = true

    @AppStorage("app:debug-mode") private var storedMode = "off"
    @State private var calls: [IpcCallRecord] = []
    @State private var paused = false
    @State private var filter = ""
    @State private var sessions: [TerminalSessionInfo] = []
    @State private var created: [String: Double] = [:]
    @State private var bundle: String?
    @State private var collecting = false
    @State private var copied = false
    @State private var log: LogTail?
    @State private var now = Date().timeIntervalSince1970 * 1000
    @State private var subscription: EngineSubscription?

    private var on: Bool { enabled || storedMode == "on" }
    private var wired: Bool { EngineBridge.shared.isReady }

    var body: some View {
        if on {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Debug").font(.title3.weight(.semibold))
                        Text(wired ? DebugPanelRules.subtitle : DebugPanelRules.unwired)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !enabled {
                        Button("Turn off debug mode") { storedMode = "off" }
                    }
                }
                ipcSection
                sessionsSection
                bundleSection
                logSection
            }
            .task { await start() }
            .onDisappear { stop() }
        }
    }

    // MARK: Sections

    private var ipcSection: some View {
        let rows = DebugPanelRules.order(calls, filter: filter)
        let summary = Array(DebugPanelRules.summarize(calls).prefix(6))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("IPC calls").font(.headline)
                Spacer()
                TextField("Filter channels", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .accessibilityLabel("Filter IPC channels")
                Button(paused ? "Resume" : "Pause") { paused.toggle() }
                Button("Clear") {
                    calls = []
                    Task { _ = try? await EngineBridge.shared.invoke("debug:ipc-clear") }
                }
            }
            if rows.isEmpty {
                Text(calls.isEmpty ? "No calls recorded yet." : "No channel matches that filter.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if !summary.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                        GridRow { head("Channel"); head("Calls"); head("Average"); head("Slowest"); head("Errors") }
                        ForEach(summary) { row in
                            GridRow {
                                mono(row.channel)
                                mono("\(row.calls)")
                                mono(DebugPanelRules.ms(row.avgMs))
                                mono(DebugPanelRules.ms(row.maxMs))
                                mono("\(row.errors)").foregroundStyle(row.errors > 0 ? Color.red : Color.primary)
                            }
                        }
                    }
                }
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                        GridRow { head("Time"); head("Channel"); head("Kind"); head("Took"); head("Result") }
                        ForEach(rows) { call in
                            GridRow {
                                mono(DebugPanelRules.clock(call.at))
                                mono(call.channel)
                                mono(call.kind)
                                mono(DebugPanelRules.ms(call.ms)).foregroundStyle(call.ms >= 250 ? Color.orange : Color.primary)
                                mono(call.ok ? "ok" : (call.error ?? "failed"))
                            }
                            .foregroundStyle(call.ok ? Color.primary : Color.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Session processes").font(.headline)
                Spacer()
                Button("Refresh") { Task { await readSessions() } }
            }
            if sessions.isEmpty {
                Text("No sessions are running.").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow { head("Session"); head("Agent"); head("Folder"); head("Uptime"); head("State") }
                    ForEach(sessions, id: \.id) { session in
                        GridRow {
                            mono(String(session.id.prefix(8)))
                            mono(session.provider)
                            mono(session.title).help(session.cwd)
                            mono(DebugPanelRules.duration(now - (created[session.id] ?? now)))
                            mono(session.exitCode.map { "exited \($0)" } ?? "running")
                        }
                        .foregroundStyle((session.exitCode ?? 0) != 0 ? Color.red : Color.primary)
                    }
                }
            }
        }
    }

    private var bundleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Support bundle").font(.headline)
                Spacer()
                Button(collecting ? "Collecting…" : bundle == nil ? "Collect" : "Recollect") { collect() }
                    .disabled(collecting || !wired)
                Button(copied ? "Copied" : "Copy") { copyBundle() }.disabled(bundle == nil)
            }
            Text(DebugPanelRules.bundleHint)
                .font(.callout).foregroundStyle(.secondary)
                .help(DebugPanelRules.bundleHelp)
            if let bundle { pre(bundle) }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Refresh") { Task { await readLog() } }.disabled(!wired)
                Button("Open log folder") { Task { _ = try? await EngineBridge.shared.invoke("log:open-folder") } }.disabled(!wired)
                Button("Clear") {
                    Task {
                        if (try? await EngineBridge.shared.invoke("log:clear")) != nil { await readLog() }
                    }
                }
                .disabled(!wired)
            }
            if let log {
                Text(log.file).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if log.lines.isEmpty {
                    Text("The log is empty.").font(.callout).foregroundStyle(.secondary)
                } else {
                    pre(log.lines.joined(separator: "\n"))
                }
            } else {
                Text("The log has not been read yet.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Pieces

    private func head(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }

    private func pre(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 260)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
    }

    // MARK: Engine

    private func start() async {
        guard wired else { return }
        calls = IpcCallRecord.list(try? await EngineBridge.shared.invoke("debug:ipc-log"))
        _ = try? await EngineBridge.shared.invoke("debug:subscribe")
        subscription = EngineBridge.shared.on("debug:ipc-call") { args in
            guard !paused, let record = IpcCallRecord.decode(args.first) else { return }
            calls = DebugPanelRules.appending(record, to: calls)
        }
        await readLog()
        // The session table re-reads every two seconds while the panel is shown (`useEvery`).
        while !Task.isCancelled {
            await readSessions()
            now = Date().timeIntervalSince1970 * 1000
            try? await Task.sleep(for: .seconds(DebugPanelRules.sessionTick))
        }
    }

    private func stop() {
        subscription = nil
        Task { _ = try? await EngineBridge.shared.invoke("debug:unsubscribe") }
    }

    private func readSessions() async {
        guard let list = try? await EngineBridge.shared.invoke("session:list") as? [Any] else {
            sessions = []
            return
        }
        sessions = list.compactMap(TerminalSessionInfo.decode)
        for case let record as [String: Any] in list {
            if let id = record["id"] as? String, let at = TerminalJSON.number(record["createdAt"]) { created[id] = at }
        }
    }

    private func readLog() async {
        log = LogTail.decode(try? await EngineBridge.shared.invoke("log:recent", [200]))
    }

    private func collect() {
        collecting = true
        copied = false
        Task {
            do {
                let text = try await EngineBridge.shared.invoke("debug:diagnostics-text")
                bundle = text as? String ?? ""
            } catch {
                bundle = "Could not collect diagnostics: \(error)"
            }
            collecting = false
        }
    }

    private func copyBundle() {
        guard let bundle else { return }
        let board = NSPasteboard.general
        board.clearContents()
        copied = board.setString(bundle, forType: .string)
    }
}
