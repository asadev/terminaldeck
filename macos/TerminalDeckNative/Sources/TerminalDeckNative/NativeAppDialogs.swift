import SwiftUI
import TerminalDeckNativeCore

// The page's dialogs that the native window draws (lane S), presented on the main
// window as sheets. Each is one entry here plus its own file. The page decides and
// acts; these only ask (see NativeDialogs.swift in Core and native-dialogs.ts).

/// Names the page and the native window agree on. Each is also in NativeScreens.registered,
/// which is how the page knows to hand it over instead of drawing it.
enum NativeDialogName {
    static let closeConfirm = "close-confirm"
    static let switchAccount = "switch-account"
    static let alerts = "alerts-sheet"
    static let palette = "palette"
    static let shortcuts = "shortcuts"
    static let help = "help"
    static let onboarding = "onboarding"
    static let sessionInspector = "session-inspector"
    static let featureOffer = "feature-offer"
    static let joinRemote = "join-remote" // lane E1
    static let copilotSetup = "copilot-setup" // lane B
    static let copilotConsent = "copilot-consent" // lane B
}

struct NativeAppDialogs: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(item: binding(NativeDialogName.closeConfirm)) { open in
                if let request = open.request.decode(CloseConfirmRequest.self) {
                    NativeCloseSessionConfirm(request: request, opening: open.request.opening, model: model)
                }
            }
            .sheet(item: binding(NativeDialogName.switchAccount)) { open in
                if let request = open.request.decode(SwitchAccountRequest.self) {
                    NativeSwitchAccountConfirm(request: request, model: model)
                }
            }
            .sheet(item: binding(NativeDialogName.alerts, dismiss: "close")) { open in
                if let request = open.request.decode(AlertsRequest.self) {
                    NativeAlertsSheet(request: request, model: model)
                }
            }
            .sheet(item: binding(NativeDialogName.shortcuts, dismiss: "close")) { open in
                let hidden = (try? JSONSerialization.jsonObject(with: open.request.data) as? [String: Any])?["hidden"] as? [String] ?? []
                NativeShortcutsSheet(hidden: Set(hidden)) { model.answerDialog(NativeDialogName.shortcuts, "close") }
            }
            .sheet(item: binding(NativeDialogName.help, dismiss: "close")) { _ in
                NativeHelpSheet { model.answerDialog(NativeDialogName.help, "close") }
            }
            // Lane T's Session inspector, opened by the page (native-dialogs.ts).
            // Lane E1's Join a remote session, opened by the page (command palette's app.join).
            .sheet(item: binding(NativeDialogName.joinRemote, dismiss: "close")) { _ in
                NativeJoinRemoteDialog { model.answerDialog(NativeDialogName.joinRemote, "close") }
            }
            // Lane B's Hoot setup flow and Hoot's permission question, opened by the page.
            .sheet(item: binding(NativeDialogName.copilotSetup, dismiss: "close")) { _ in
                NativeCopilotSetup(model: model)
            }
            // Hoot's permission question shows at once, over any open sheet (NativeConsentSheet.swift).
            .onChange(of: model.dialogs[NativeDialogName.copilotConsent].map { "\($0.opening)#\($0.seq)" }, initial: true) {
                NativeConsentSheet.sync(model)
            }
            .sheet(item: binding(NativeDialogName.sessionInspector, dismiss: "close")) { open in
                if let request = open.request.decode(SessionInspectorRequest.self) {
                    NativeSessionInspector(request: request) { model.answerDialog(NativeDialogName.sessionInspector, "close") }
                }
            }
            // The palette floats over the window, as on the page — not a sheet.
            .overlay {
                if let open = model.dialogs[NativeDialogName.palette], let request = open.decode(PaletteRequest.self) {
                    NativeCommandPalette(request: request, opening: open.opening, model: model)
                }
            }
            // First run covers the whole window, as the page's screen did.
            .overlay {
                if let open = model.dialogs[NativeDialogName.onboarding] {
                    let data = (try? JSONSerialization.jsonObject(with: open.data)) as? [String: Any]
                    NativeOnboarding(appName: data?["appName"] as? String ?? "Terminal Deck", model: model)
                }
            }
    }

    /// A sheet open while the page has that dialog open; dismissing it (Esc) answers
    /// `dismiss` — "cancel" for a question, "close" for a window.
    private func binding(_ name: String, dismiss: String = "cancel") -> Binding<OpenDialog?> {
        Binding(
            get: { model.dialogs[name].map(OpenDialog.init) },
            set: { value in if value == nil, model.dialogs[name] != nil { model.answerDialog(name, dismiss) } }
        )
    }
}

struct OpenDialog: Identifiable {
    let request: DialogRequest
    /// Stable while the dialog is up and only updated; new when it opens again.
    var id: String { "\(request.name)#\(request.opening)" }
}

/// HoverNote: a small ⓘ whose words show on hover, and on a click for keyboards and
/// trackpads that cannot hover.
struct InfoNote: View {
    let label: String
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("More about \(label)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}

extension View {
    func nativeAppDialogs(_ model: AppModel) -> some View { modifier(NativeAppDialogs(model: model)) }
}
