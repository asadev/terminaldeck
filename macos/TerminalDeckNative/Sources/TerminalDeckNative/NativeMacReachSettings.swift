import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Every required system switch is shown until macOS confirms it. Buttons navigate; only the person flips settings.
struct NativeMacReachSettings: View {
    @State private var model: NativeMacReach
    let fixture: Bool
    init(fixture: Bool, model: NativeMacReach? = nil) {
        self.fixture = fixture
        _model = State(initialValue: model ?? (fixture ? NativeMacReach.fixture(registration: .notRegistered) : NativeMacReach.shared))
    }
    var body: some View {
        Section("Access after lock or restart") {
            if model.registration != .enabled {
                Text("Reach your Mac before sign-in").font(.headline)
                Text("Enable the access helper here, then allow it in System Settings → General → Login Items & Extensions. You only need to approve it once.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.registration == .needsApproval {
                    Button("Open Login Items") { NativeMacReach.openLoginItems() }
                } else if model.registration == .notBundled {
                    Text("The signed release app is needed to enable the helper.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(model.busy ? "Enabling…" : "Enable access helper") {
                        Task { do { try await model.enable() } catch { issue = "The access helper could not be enabled. Try again." } }
                    }.disabled(fixture || model.busy)
                }
            } else {
                LabeledContent("Access helper", value: model.agentConnected ? "Connected" : "Waiting for the screen agent")
                HStack {
                    Button("Check again") { Task { await model.refresh() } }.disabled(fixture)
                    Button("Disable access helper") {
                        Task { do { try await model.disable() } catch { issue = "The access helper could not be disabled. Try again." } }
                    }.disabled(fixture || model.busy)
                }
            }
            if fixture || !NativeMacScreen.canRecord {
                Text("Allow Screen Recording so your phone can see the Mac. Existing permissions stay with the same app across updates.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Screen Recording") { NSWorkspace.shared.open(NativeMacScreen.recordingSettings) }.disabled(fixture)
            }
            if fixture || !NativeMacScreen.canControl {
                Text("Allow Accessibility so your phone can click and type, including at sign-in.").font(.callout).foregroundStyle(.secondary)
                Button("Open Accessibility") { NSWorkspace.shared.open(NativeMacScreen.accessibilitySettings) }.disabled(fixture)
            }
            DisclosureGroup("FileVault after a restart") {
                Text(MacReach.diskDetail).font(.callout).foregroundStyle(.secondary)
                Text("For the optional Unlock disk button on your phone, turn on Remote Login yourself before restarting. Choose a Mac account allowed to unlock the disk. The phone checks the SSH identity before sending your password.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Remote Login") { NativeMacReach.openRemoteLogin() }.disabled(fixture)
            }
            if let message = issue ?? model.problem { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .task { if !fixture { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !fixture { Task { await model.refresh() } }
        }
    }
    @State private var issue: String?
}
