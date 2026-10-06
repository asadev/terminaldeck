import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Linux (`LinuxSection.tsx`): which Linux a session in a Linux
/// folder runs inside. The page lists this section on Windows only; drawn here
/// whenever the page lists it.
struct NativeLinuxSettings: View {
    @State private var model = NativeLinuxModel()
    /// `machineNoun` for the platform this section is shown on.
    private let here = "PC"

    var body: some View {
        let snapshot = model.snapshot
        let ready = snapshot?.state == .ready
        NativeSettingsPage(sectionId: "linux") {
            Section {
                NativeSettingsProse(text: SettingsWslSnapshot.intro(here))
                if model.unwired {
                    NativeCodingAINotice(tone: .warn, text: SettingsWslSnapshot.unwired)
                }
                if !model.unwired && snapshot?.read != true {
                    NativeCodingAINotice(tone: .info, text: SettingsWslSnapshot.checking(here))
                }
                if !model.unwired, let snapshot, snapshot.read, snapshot.state == .absent {
                    HStack(spacing: 4) {
                        NativeCodingAINotice(tone: .info, text: SettingsWslSnapshot.absent(here))
                        installLink
                    }
                }
                if !model.unwired, let snapshot, snapshot.read, snapshot.state == .noDistros {
                    HStack(spacing: 4) {
                        NativeCodingAINotice(tone: .warn, text: SettingsWslSnapshot.noDistros)
                        installLink
                    }
                }
                if !model.unwired, let detail = snapshot?.detail {
                    Text(detail).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            if ready, let snapshot {
                Section {
                    ForEach(snapshot.distros) { distro in
                        let inUse = distro.name == snapshot.active
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle()
                                .fill(distro.running ? Color.green : Color.secondary)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(distro.name)
                                    if inUse { NativeCodingAIBadge(text: "In use") }
                                    if distro.isDefault && !inUse { NativeCodingAIBadge(text: "Windows’ default", quiet: true) }
                                }
                                Text(distro.note).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !inUse {
                                Button("Use this one") { model.choose(distro.name) }
                                    .disabled(model.loading)
                            }
                        }
                    }
                    if snapshot.distros.count > 1, let active = snapshot.active {
                        NativeSettingsProse(text: SettingsWslSnapshot.remembered(active, here))
                    }
                    if let home = snapshot.home {
                        HStack(spacing: 4) {
                            Text("A session with no folder of its own starts in").foregroundStyle(.secondary)
                            NativeCodingAICommand(text: home)
                        }
                    }
                }
            }
            Section {
                Button(model.loading ? "Checking…" : "Check again") { model.load(force: true) }
                    .disabled(model.unwired || model.loading)
                if let error = model.error {
                    NativeCodingAINotice(tone: .error, text: error)
                }
            }
        }
        .onAppear { model.load(force: false) }
    }

    @ViewBuilder private var installLink: some View {
        if let url = URL(string: SettingsWslSnapshot.installDocs) {
            Link("How to install it", destination: url)
        }
    }
}

@MainActor
@Observable
final class NativeLinuxModel {
    private(set) var snapshot: SettingsWslSnapshot?
    private(set) var loading = false
    private(set) var error: String?
    /// The engine always has both channels; kept for the page's "cannot read" state.
    let unwired = false

    func load(force: Bool) {
        loading = true
        error = nil
        Task {
            do {
                snapshot = SettingsWslSnapshot.parse(CodingAIJSON(try await EngineBridge.shared.invoke("wsl:status", [force])))
            } catch {
                self.error = CodingAIErrorText.from(error, fallback: "Could not ask Windows what it has.")
            }
            loading = false
        }
    }

    func choose(_ distro: String) {
        loading = true
        error = nil
        Task {
            do {
                snapshot = SettingsWslSnapshot.parse(CodingAIJSON(try await EngineBridge.shared.invoke("wsl:choose", [distro])))
            } catch {
                self.error = CodingAIErrorText.from(error, fallback: "Could not save that choice.")
            }
            loading = false
        }
    }
}
