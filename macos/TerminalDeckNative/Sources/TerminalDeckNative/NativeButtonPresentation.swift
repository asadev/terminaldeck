import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Reuses the existing native session form without asking the hidden page to open it.
@MainActor enum NativeButtonPresentation {
    static func mainWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier?.rawValue == "main" }
    }
    private static var parent: NSWindow? {
        NSApp?.keyWindow ?? NSApp?.mainWindow ?? mainWindow(in: NSApp?.windows ?? [])
    }
    /// The New session form always sits on the main window, never on Settings or a pop-out
    /// that can close under it (#620).
    static var sessionParent: NSWindow? {
        mainWindow(in: NSApp?.windows ?? []) ?? NSApp?.mainWindow ?? NSApp?.keyWindow
    }
    static func session(folder: String?) throws {
        try NativeNewSession.open(folder: folder)
    }
    static func confirm(_ request: CloseConfirmRequest) async -> Bool {
        if let settings = try? await EngineBridge.shared.invoke("settings:get") as? [String: Any], (settings["values"] as? [String: Any])?["general.confirmCloseWorking"] as? Bool == false { return true }
        guard let parent else { return false }
        return await withCheckedContinuation { done in
            let answer = CloseAnswer(done)
            let window = NSWindow()
            let view = NativeCloseSessionConfirm(request: request, opening: 0, nativeAnswer: { accepted, suppress in
                Task { @MainActor in
                    if accepted, suppress {
                        do { _ = try await EngineBridge.shared.invoke("settings:set", [["general.confirmCloseWorking": false]]) }
                        catch { AppModel.shared.buttonActions.problem = "The session will close, but the close-question setting could not be saved." }
                    }
                    parent.endSheet(window); window.orderOut(nil)
                    answer.finish(accepted)
                }
            })
            window.contentViewController = NSHostingController(rootView: view)
            window.styleMask = [.titled]; window.title = request.subject == .project ? "Remove from sidebar?" : request.heading
            // The window under the question can go away unanswered (a pop-out closing with its
            // session): that is a "no", or every later sidebar and tab button waits forever (#105).
            answer.parentClosing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { _ in
                MainActor.assumeIsolated { window.orderOut(nil); answer.finish(false) }
            }
            parent.beginSheet(window)
        }
    }

}

/// Answers one close question exactly once: from its own buttons, or "no" when its window goes away.
@MainActor final class CloseAnswer {
    private var done: CheckedContinuation<Bool, Never>?
    var parentClosing: NSObjectProtocol?
    init(_ done: CheckedContinuation<Bool, Never>) { self.done = done }
    var answered: Bool { done == nil }
    func finish(_ accepted: Bool) {
        if let parentClosing { NotificationCenter.default.removeObserver(parentClosing); self.parentClosing = nil }
        done?.resume(returning: accepted); done = nil
    }
}

struct NativeButtonProblems: ViewModifier {
    let actions: NativeButtonActions
    func body(content: Content) -> some View {
        content.alert("That change could not be made", isPresented: Binding(get: { actions.problem != nil }, set: { if !$0 { actions.problem = nil } })) {
            Button("OK") { actions.problem = nil }
        } message: { Text(actions.problem ?? "Please try again.") }
    }
}

/// Hold the first SSH output while Open terminal is waiting for its shell id.
/// The native terminal starts listening before this capture is retired, so no frame is lost.
@MainActor final class NativeButtonShellCapture {
    private var output: [String: String] = [:]
    private(set) var ended: Set<String> = []
    private var subscriptions: [EngineSubscription] = []
    init() {
        subscriptions.append(EngineBridge.shared.on("servers:shell:output") { [weak self] args in
            guard let row = args.first as? [String: Any], let id = row["shellId"] as? String, let text = row["data"] as? String else { return }
            self?.output[id] = String(((self?.output[id] ?? "") + text).suffix(256 * 1024))
        })
        subscriptions.append(EngineBridge.shared.on("servers:shell:closed") { [weak self] args in
            if let row = args.first as? [String: Any], let id = row["shellId"] as? String { self?.ended.insert(id) }
        })
    }
    func take(_ id: String) -> String { output.removeValue(forKey: id) ?? "" }
    func stop() { subscriptions.forEach { $0.cancel() }; subscriptions.removeAll(); output.removeAll() }
}
