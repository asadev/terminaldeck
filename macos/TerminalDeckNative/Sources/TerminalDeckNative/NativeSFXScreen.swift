import SwiftUI
import TerminalDeckNativeCore

/// The only app-specific adapter. INT2 replaces the existing screen route with
/// this type; no second engine, project store, account store, or session system.
struct NativeSFXScreen: View {
    @State private var model = NativeSFXModel(
        invoke: { channel, args in
            let timeout: TimeInterval?
            switch channel {
            case StaysFixedWire.check: timeout = 900
            case SFXSetupWire.prepare, SFXSetupWire.apply: timeout = 300
            default: timeout = nil
            }
            return try await EngineBridge.shared.invoke(channel, args, timeout: timeout)
        },
        subscribe: { receive in
            let subscription = EngineBridge.shared.on(StaysFixedWire.changed) { args in
                if let path = args.first as? String { receive(path) }
            }
            return { subscription.cancel() }
        },
        askAI: NativeSFXSession.open,
        describeError: deckMessage)

    var body: some View {
        let project = DeckProject.current
        Group {
            if AppModel.shared.sidebar == nil {
                NativePageNote("Loading Terminal Deck…", busy: true)
            } else if project != nil {
                NativeSFXPage(model: model, sourceControl: { DeckProject.show("git") }, copy: DeckProject.copy)
            } else {
                NativePageEmpty(symbol: "checkmark.shield", title: "Stays Fixed needs an open project",
                                action: PageEmptyAction(label: "Open a project", perform: { AppModel.shared.openProject() })) {
                    Text("Open the project you want to keep working, then follow the setup steps.")
                }
            }
        }
        .onChange(of: project, initial: true) { _, path in model.show(path) }
        .onAppear { model.show(project) }
        .onDisappear { model.leave() }
    }
}

@MainActor
private enum NativeSFXSession {
    /// Uses the same provider and login resolution as New session. The supported
    /// native create request has no firstPrompt field, so the UI honestly copies
    /// a ready request for the person to paste and send after login.
    static func open(project: String, prompt: String) async throws -> String {
        let bridge = EngineBridge.shared
        let detected = CodingAIJSON(try await bridge.invoke("providers:detect"))
        let added = NewSessionCustomAgent.parse(CodingAIJSON(try await bridge.invoke("agents:list")))
        let preferences = CodingAIJSON(try await bridge.invoke("prefs:get"))
        let profiles = CodingAIAccountsParse.snapshot(CodingAIJSON(try await bridge.invoke("profiles:list")))
        let resolvedProfile = CodingAIAccountsParse.account(CodingAIJSON(try await bridge.invoke("profiles:resolve", [["projectPath": project]])))
        let rows = NewSessionProviders.rows(detected: detected, added: added)
        let resolution = NewSessionStart.resolve(
            providers: NewSessionStartProvider.from(rows),
            profiles: profiles.accounts.map { NewSessionStartProfile(id: $0.id, name: $0.name, system: $0.system) },
            memory: NewSessionMemory(), defaultProvider: preferences["defaultProvider"].string,
            defaultProfileId: resolvedProfile?.id, projectPath: project, provider: nil, profileId: nil)
        guard let request = resolution.request else {
            throw NativeSFXSessionError(resolution.problem ?? "Choose an installed coding agent in Coding AI settings.")
        }
        let input: [String: Any] = ["cwd": request.cwd, "provider": request.provider,
                                   "profileId": request.profileId as Any? ?? NSNull(),
                                   "cols": request.cols, "rows": request.rows]
        let raw = try await bridge.invoke("session:create", [input])
        guard let meta = raw as? [String: Any], let id = meta["id"] as? String, !id.isEmpty else {
            throw NativeSFXSessionError("The coding agent did not return a session. Open New session and try again.")
        }
        DeckProject.copy(prompt)
        AppModel.shared.openScreenWindow(ScreenRef(kind: .session, id: id), title: "Stays Fixed fix")
        return "an AI session"
    }
}

private struct NativeSFXSessionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
