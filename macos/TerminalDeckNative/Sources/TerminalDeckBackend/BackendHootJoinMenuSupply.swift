import Foundation
import TerminalDeckNativeCore

/// Request 8: the backend half of `BackendHootMenuBarDependencies`, built from
/// the one retained runtime/PTY/lifecycle/settings graph (index.ts
/// `wireMenuBar` parity). The app supplies only AppKit pieces (`UI`). This
/// owns no session, no second Hoot, no PTY and no transcript reader of its own:
/// chat reuses `BackendCopilotRemoteChatWatcher`, typing reuses the shared
/// two-write submit. Nothing starts until `start()`.
@MainActor public final class BackendHootJoinMenuSupply {
    /// App-owned AppKit suppliers (panels, placement, window navigation).
    @MainActor public struct UI {
        public let makeIsland: () throws -> any BackendHootIslandSurface
        public let makeCatcher: () throws -> any BackendHootCatcherSurface
        public let place: () -> BackendHootIslandPlace
        public let showSession: (String) -> Void
        public let openApp: (String?) -> Void
        public let quit: (@MainActor @Sendable () -> Void)?
        public let shownChanged: () -> Void
        public let appearance: () -> String
        public let supported: Bool
        public let log: (String, NativeRPCValue) -> Void
        public init(makeIsland: @escaping () throws -> any BackendHootIslandSurface,
                    makeCatcher: @escaping () throws -> any BackendHootCatcherSurface,
                    place: @escaping () -> BackendHootIslandPlace, showSession: @escaping (String) -> Void,
                    openApp: @escaping (String?) -> Void, quit: (@MainActor @Sendable () -> Void)?, shownChanged: @escaping () -> Void = {},
                    appearance: @escaping () -> String, supported: Bool = true,
                    log: @escaping (String, NativeRPCValue) -> Void = { _, _ in }) {
            self.makeIsland = makeIsland; self.makeCatcher = makeCatcher; self.place = place; self.showSession = showSession
            self.openApp = openApp; self.quit = quit; self.shownChanged = shownChanged; self.appearance = appearance
            self.supported = supported; self.log = log
        }
    }

    private let runtime: BackendCopilotSessionRuntime
    private let manager: BackendPTYManager
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let snapshot: BackendHootJoinMenuSnapshot
    private let settings: BackendAppSettingsStore
    private let transcriptScope: @Sendable () async throws -> NativeTranscriptScope
    private var stored: NativeRPCValue = .object([])
    private var storedSequence: UInt64 = 0
    private var settingsWatch: NativeRPCSubscription?
    private let sequence = BackendHootJoinSequence()

    /// `transcriptScope` is the app's installed scope for the desk Hoot's
    /// account (it must already carry `BackendCopilotSessionRuntime.homeScope`).
    public init(runtime: BackendCopilotSessionRuntime, manager: BackendPTYManager,
                lifecycle: BackendSessionLifecycleCoordinator, snapshot: BackendHootJoinMenuSnapshot,
                settings: BackendAppSettingsStore,
                transcriptScope: @escaping @Sendable () async throws -> NativeTranscriptScope) {
        self.runtime = runtime; self.manager = manager; self.lifecycle = lifecycle; self.snapshot = snapshot
        self.settings = settings; self.transcriptScope = transcriptScope
    }

    /// Seed and follow the settings snapshot (the store calls the listener
    /// once immediately). Call from the Hoot area's explicit start only.
    public func start() async {
        guard settingsWatch == nil else { return }
        let counter = sequence
        settingsWatch = await settings.observeSnapshot { [weak self] value in
            let number = counter.next()
            Task { @MainActor [weak self] in self?.accept(value, number: number) }
        }
    }
    public func stop() async {
        let watch = settingsWatch; settingsWatch = nil
        await watch?.cancelAndWait()
    }
    private func accept(_ envelope: NativeRPCValue, number: UInt64) {
        guard number > storedSequence else { return }
        storedSequence = number
        let values = envelope["values"]
        stored = values.fields == nil ? .object([]) : values
    }

    public func dependencies(_ ui: UI) -> BackendHootMenuBarDependencies {
        BackendHootMenuBarDependencies(
            makeIsland: ui.makeIsland, makeCatcher: ui.makeCatcher, place: ui.place,
            read: { [weak self] key in self?.stored[key] ?? .missing },
            write: { [weak self] patch in try self?.write(patch) },
            hoot: { [weak self] in self?.snapshot.hoot ?? .init(status: "stopped", cwd: "") },
            startHoot: { [weak self] in
                guard let self else { throw NativeRPCError(code: "unavailable", message: "Hoot's island supply has stopped.") }
                return try await self.startHoot()
            },
            say: { [weak self] id, text in
                guard let self else { throw NativeRPCError(code: "unavailable", message: "Hoot's island supply has stopped.") }
                try await self.say(id, text)
            },
            watchChat: { [weak self] cwd, agentSessionID, update in
                guard let self else { throw NativeRPCError(code: "unavailable", message: "Hoot's island supply has stopped.") }
                return self.watchChat(cwd: cwd, agentSessionID: agentSessionID, update: update)
            },
            sessions: { [weak self] in self?.snapshot.sessions ?? [] },
            isHoot: { [runtime] id in runtime.isCopilotSession(id) },
            showSession: ui.showSession, openApp: ui.openApp, quit: ui.quit, shownChanged: ui.shownChanged,
            appearance: ui.appearance, supported: ui.supported, log: ui.log)
    }

    /// `patchStoredSettings`: the menu's write is synchronous, so the local
    /// read model updates now and the one settings store persists the patch.
    private func write(_ patch: NativeRPCValue) throws {
        guard let fields = patch.fields else { throw NativeRPCError.invalidArguments("A settings patch must be an object.") }
        for field in fields { stored = stored.setting(field.key, field.value) }
        let store = settings
        Task {
            do { _ = try await store.patch(patch) }
            catch { NSLog("[native Hoot] could not save the island setting: %@", error.localizedDescription) }
        }
    }

    private func startHoot() async throws -> String? {
        let state = try await runtime.ensure()
        let metadata = await lifecycle.metadata()
        snapshot.update(state, metadata: metadata)
        return state.status == .running || state.status == .starting ? nil : state.problem
    }

    /// `typeAndSubmit` into Hoot's own live PTY only: text, then a bare CR
    /// 50 ms later. The PTY write itself rechecks that the process is alive.
    private func say(_ id: String, _ text: String) async throws {
        if runtime.structuredChat != nil {
            guard runtime.isCopilotSession(id) else { throw BackendSessionFailure.missingSession }
            _ = try await runtime.invoke("hoot:chat:say", arguments: [.string(text)])
            return
        }
        guard runtime.isCopilotSession(id), manager.list().contains(where: { $0.id == id && $0.exitCode == nil }) else {
            throw BackendSessionFailure.missingSession
        }
        let ptys = manager
        try BackendCopilotRemoteSurface.typeAndSubmit(text, write: { data in try ptys.write(id, data: data) })
    }

    private func watchChat(cwd: String, agentSessionID: String?,
                           update: @escaping @MainActor ([NativeRPCValue], Bool) -> Void) -> any BackendHootCancellation {
        let handle = BackendHootJoinChatWatch()
        if let chat = runtime.structuredChat {
            handle.task = Task {
                let stream = await chat.subscribe()
                for await value in stream {
                    guard !Task.isCancelled else { return }
                    let events = try? (value["events"].elements ?? []).map(HootChatEvent.init(wire:))
                    let messages = HootChatProjection.rows(events ?? []).compactMap { row -> NativeRPCValue? in
                        guard [.user, .message, .textDelta, .error].contains(row.kind) else { return nil }
                        return .object([.init("id", .string(row.id)), .init("role", .string(row.kind == .user ? "user" : "assistant")),
                            .init("text", row.value["text"])])
                    }
                    update(messages, true)
                }
            }
            return handle
        }
        let scope = transcriptScope
        handle.task = Task { [weak handle] in
            do {
                let resolved = try await scope()
                let watcher = BackendCopilotRemoteChatWatcher(cwd: cwd, agentSessionID: agentSessionID, scope: resolved) { change in
                    await MainActor.run { update(change.messages, change.reset) }
                }
                // This Task inherits the main actor; it resumes here after awaits.
                guard handle?.attach(watcher) == true else { await watcher.stop(); return }
                try await watcher.start()
            } catch {
                NSLog("[native Hoot] could not follow Hoot's transcript: %@", error.localizedDescription)
            }
        }
        return handle
    }
}

/// One island chat follow; cancelling stops its watcher exactly once.
@MainActor final class BackendHootJoinChatWatch: BackendHootCancellation {
    var task: Task<Void, Never>?
    private var watcher: BackendCopilotRemoteChatWatcher?
    private var cancelled = false
    func attach(_ watcher: BackendCopilotRemoteChatWatcher) -> Bool {
        guard !cancelled else { return false }
        self.watcher = watcher; return true
    }
    func cancel() {
        guard !cancelled else { return }
        cancelled = true; task?.cancel(); task = nil
        if let watcher { Task { await watcher.stop() } }
        watcher = nil
    }
}

/// Monotonic order for settings snapshots hopping to the main actor.
final class BackendHootJoinSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.withLock { value &+= 1; return value } }
}
