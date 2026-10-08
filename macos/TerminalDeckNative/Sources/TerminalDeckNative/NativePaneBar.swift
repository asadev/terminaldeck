import SwiftUI
import TerminalDeckNativeCore

/// What a pane shows (shell/PaneBar.tsx `PaneSubject`).
enum NativePaneSubject: Equatable {
    case session(id: String, title: String, status: TerminalStatus, isCopilot: Bool, folder: String?)
    case elsewhere(title: String, where: String, status: TerminalStatus)
    case page(title: String)
    case empty
}

/// shell/PaneBar.tsx, drawn natively: the bar over each pane of a split. A
/// session pane: status dot, title, folder chip then `chips` (the account chip,
/// lane T), the Attach browser button, `controls` (SessionControls, lane T), and
/// Close. A session elsewhere: dot, title and where. A page: globe and title. An
/// empty pane: "Empty pane". Lane T's split view puts one over each pane.
struct NativePaneBar<Chips: View, Controls: View>: View {
    let paneId: String
    let subject: NativePaneSubject
    let focused: Bool
    let onClose: (String) -> Void
    var rename: ((String) -> Void)? = nil
    @ViewBuilder var chips: () -> Chips
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(spacing: 8) {
            lead
            Spacer(minLength: 4)
            switch subject {
            case .session, .elsewhere: controls()
            default: EmptyView()
            }
            Button { onClose(paneId) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Close this pane")
            .accessibilityLabel("Close this pane")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .opacity(focused ? 1 : 0.78) // dim the content, never the terminal paper
        .foregroundStyle(NativeSessionChrome.ink)
        .background(NativeSessionChrome.ground)
    }

    @ViewBuilder private var lead: some View {
        switch subject {
        case .session(let id, let title, let status, let isCopilot, let folder):
            NativeSessionStatusDot(status: status)
            NativeSessionTitle(title: title, rename: isCopilot ? nil : rename)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if let folder {
                HStack(spacing: 6) {
                    NativeFolderChip(path: folder)
                    chips()
                }
            }
            NativeAttachBrowser(sessionId: id)
        case .elsewhere(let title, let place, let status):
            NativeSessionStatusDot(status: status)
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .page(let title):
            Image(systemName: "globe").foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
        case .empty:
            Text("Empty pane").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// PaneBar's AttachBrowser: says which windows are attached right now ("B1 B2"),
/// and its tooltip says what pressing it does. The menu is the engine's
/// (`browser:bind-menu`).
struct NativeAttachBrowser: View {
    let sessionId: String
    var machineId = ""
    @State private var slots: [String] = []
    @State private var subscription: EngineSubscription?

    var body: some View {
        let tip = slots.isEmpty
            ? "No browser window attached. Attach one, or open a new one attached to this session."
            : "\(slots.joined(separator: ", ")) attached to this session. Attach or detach a browser window."
        Button {
            NativeBindMenu.popUp(sessionId: sessionId, machineId: machineId) // lane E2: the engine's menu as data
        } label: {
            HStack(spacing: 3) {
                Text(slots.isEmpty ? "Attach browser" : slots.joined(separator: " "))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(tip)
        .accessibilityLabel(tip)
        .task {
            subscription = EngineBridge.shared.on("browser:bindings") { args in
                if let view = args.first { apply(view) }
            }
            if let view = try? await EngineBridge.shared.invoke("browser:bindings") { apply(view) }
        }
        .onDisappear { subscription?.cancel() }
    }

    private func apply(_ view: Any) {
        let session = BrowserDriverSession(sessionId: sessionId, machineId: machineId)
        slots = BrowserBindings.read(view).of(session).map { "B\($0.n)" }
    }
}
