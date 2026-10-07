import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// Lane BR (browser parity): Size ▸ Custom's width × height (DeviceBar.tsx), the
// ⋮ menu's History (HistoryPanel.tsx) and its way into Settings sections.

// MARK: - Size ▸ Custom

struct NativeBrowserCustomSizeBar: View {
    @Bindable var tab: NativeBrowserTab

    var body: some View {
        HStack(spacing: 6) {
            Text("W").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("", text: $tab.customWidth)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .accessibilityLabel("Custom width in pixels")
            Text("x").foregroundStyle(.secondary)
            Text("H").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("", text: $tab.customHeight)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .accessibilityLabel("Custom height in pixels")
            Text("\(BRDeviceSize.minimum)–\(BRDeviceSize.maximum)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - Into a Settings section (App.tsx openSettings(section))

@MainActor
enum NativeBRSettingsLink {
    /// Bring the Settings window up, then show the section once its page is ready.
    static func open(_ section: String) {
        let app = AppModel.shared
        app.requestSettings()
        Task { @MainActor in
            for _ in 0..<50 {
                if app.settingsReady {
                    app.selectSettingsSection(section)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

// MARK: - History

struct NativeBrowserHistorySheet: View {
    let tab: NativeBrowserTab
    let profileName: String
    @Environment(\.dismiss) private var dismiss
    @State private var visits: [BRHistoryVisit] = []
    @State private var query = ""
    @State private var loaded = false
    @State private var arming = false

    private var profileID: String { BackendBrowserProfiles.normalizedID(tab.profile) }
    private static let time: DateFormatter = {
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("jmm")
        return format
    }()

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let days = BRHistory.byDay(visits, now: Date())
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(BRHistory.title(profileName: profileName)).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search history", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search history")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loaded && days.isEmpty {
                        Text(BRHistory.empty(searching: searching)).foregroundStyle(.secondary)
                    }
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.heading).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(day.visits) { entry in row(entry) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if arming {
                    Button("Delete all of it", role: .destructive) { Task { await clear() } }
                    Button("Cancel") { arming = false }
                } else {
                    Button("Clear history") { arming = true }
                        .disabled(visits.isEmpty && !searching)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .task(id: query) { await load() }
    }

    private func row(_ entry: BRHistoryVisit) -> some View {
        HStack(spacing: 10) {
            Button {
                if let url = URL(string: entry.url) { tab.load(url) }
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Text(entry.label).lineLimit(1)
                    Text(entry.host).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(entry.url)
            Text(Self.time.string(from: Date(timeIntervalSince1970: entry.visitedAt / 1000)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Forget") { Task { await forget(entry) } }
                .buttonStyle(.link)
                .accessibilityLabel("Forget \(entry.label)")
        }
        .font(.callout)
        .padding(.vertical, 2)
    }

    private func load() async {
        arming = false
        guard EngineBridge.shared.isReady else { loaded = true; return }
        visits = BRHistoryVisit.list(try? await EngineBridge.shared.invoke("browser-history:list", [profileID, query]))
        loaded = true
    }

    private func forget(_ entry: BRHistoryVisit) async {
        visits = BRHistoryVisit.list(try? await EngineBridge.shared.invoke("browser-history:forget", [profileID, entry.url]))
    }

    private func clear() async {
        arming = false
        visits = BRHistoryVisit.list(try? await EngineBridge.shared.invoke("browser-history:clear", [profileID]))
    }
}
