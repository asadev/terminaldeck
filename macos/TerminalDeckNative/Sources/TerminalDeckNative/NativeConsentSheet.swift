import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Hoot's permission question (lane B's NativeCopilotConsent) at once, over whatever
/// is open — as the page's modal is. SwiftUI shows one sheet per window at a time, so
/// a `.sheet` would wait behind New session or the inspector; this is an AppKit sheet
/// begun on the top-most open sheet (a sheet on a sheet), or on the window itself.
/// If the sheet it sits on goes away first, it moves to whatever is top-most then.
/// The keys are the page's: Esc refuses, and so does Return — "a hurried Return must
/// not approve" (CopilotConsent.tsx). Every dismissal is a refusal.
@MainActor
enum NativeConsentSheet {
    private static var panel: ConsentPanel?
    private static var host: NSHostingController<AnyView>?
    private static var opening: Int?
    private static var observers: [NSObjectProtocol] = []

    /// Called whenever the page's consent dialog changes (NativeAppDialogs).
    static func sync(_ model: AppModel) {
        guard let open = model.dialogs[NativeDialogName.copilotConsent],
              let request = open.decode(CopilotConsentRequest.self) else {
            close()
            return
        }
        let view = AnyView(NativeCopilotConsent(request: request, model: model))
        if let panel, let host, opening == open.opening {
            host.rootView = view // the same question, updated
            panel.refuse = { refuse(model, id: request.id) }
            return
        }
        close()
        let made = NSHostingController(rootView: view)
        made.sizingOptions = [.preferredContentSize]
        let window = ConsentPanel(contentViewController: made)
        window.styleMask = [.titled]
        window.title = "Hoot asks"
        window.refuse = { refuse(model, id: request.id) }
        host = made
        panel = window
        opening = open.opening
        present(on: model)
        watch(model)
    }

    private static func refuse(_ model: AppModel, id: String) {
        model.answerDialog(NativeDialogName.copilotConsent, "refuse", argument: ["id": id], closes: false)
    }

    /// The window, then down its chain of sheets to the one in front.
    private static func topMost(_ model: AppModel) -> NSWindow? {
        guard var top = model.web.webView.window else { return nil }
        while let sheet = top.attachedSheet, sheet !== panel { top = sheet }
        return top
    }

    private static func present(on model: AppModel) {
        guard let panel, let parent = topMost(model) else { return }
        parent.beginSheet(panel)
    }

    /// A sheet ending or a window closing may take this one's parent with it.
    private static func watch(_ model: AppModel) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didEndSheetNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { rehome(model) }
            })
        }
    }

    private static func rehome(_ model: AppModel) {
        guard let panel else { return }
        if let parent = panel.sheetParent, parent.isVisible, parent.sheetParent != nil || parent === model.web.webView.window { return }
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        present(on: model)
    }

    private static func close() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let panel {
            panel.refuse = nil
            panel.sheetParent?.endSheet(panel)
            panel.orderOut(nil)
        }
        panel = nil
        host = nil
        opening = nil
    }
}

/// The question's sheet window: Esc and a plain Return both refuse.
final class ConsentPanel: NSWindow {
    var refuse: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        refuse?()
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, event.keyCode == 36 || event.keyCode == 76 {
            refuse?()
            return
        }
        super.keyDown(with: event)
    }
}
