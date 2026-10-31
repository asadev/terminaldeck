import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Alerts for a phone whose app is closed (31 Oct): the remote `push` capability (`BackendPhonePush`), fed by the same
/// chat engine events the Mac's own Chat banners read (`NativeChatAttention`), with a tracker of its own so the Mac's
/// banner settings and whether a chat is on this Mac's screen never decide what a phone in a pocket hears.
/// Not fatal: without it a phone alerts only while its app is open, as before.
extension NativeCompositionProduction {
    func installPhonePush() async {
        guard let endpoint = remoteEndpoint, let trust = remoteTrust, let sessions else {
            report("Phone alerts are unavailable: the remote endpoint is not wired.")
            return
        }
        let push = BackendPhonePush(directory: root.dataRoot.appendingPathComponent("remote"), trust: trust,
                                    relayURL: BackendRelayAddress.resolve(), macName: Host.current().localizedName ?? "Mac")
        let owner = "native.phone-push"
        do {
            let lease = try await endpoint.installFeatures(ownerID: owner, features: [await push.feature()],
                connectionClosed: { await push.disconnected($0) })
            let watcher = await MainActor.run { NativePhonePushWatcher(push: push, meta: { id in
                sessions.manager.list().first { $0.id == id }
            }) }
            await MainActor.run { watcher.start() }
            do {
                try await root.retain(.init(name: "phone-push", domains: ["phone-push"], ownerID: owner, invokes: [], stop: {
                    await MainActor.run { watcher.stop() }; await lease.cancelAndWait()
                }))
                phonePush = push; phonePushWatcher = watcher
            } catch { await MainActor.run { watcher.stop() }; await lease.cancelAndWait(); throw error }
        } catch {
            report("Phone alerts are unavailable: " + error.localizedDescription)
        }
    }

    /// `phone.alerts` / `phone.alerts_test`: what each phone hears while closed, and a test alert (deck-tools).
    func installPhonePushTools(access: BackendDeckToolsAppAccess) async throws {
        let owner = "native.phone-push-tools", root = self.root, joins = self.joins
        let definitions = try BackendPhonePushMCP.definitions(push: { [weak self] in await MainActor.run { self?.phonePush } }, access: access)
        let policies = definitions.map { joins.nativePolicy($0) }
        let bundle = try BackendDeckCoreCatalogueBundle(metadata: definitions.map(\.catalogueMetadata), policies: policies)
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "phone-push-tools", domains: ["phone-push-tools"], ownerID: owner, invokes: [], stop: {
                await root.mcp.removeTools(ownerID: owner); try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            }))
        } catch {
            await root.mcp.removeTools(ownerID: owner); try? joins.replaceContributions(owner: owner, [], policiesWrapped: true); throw error
        }
    }
}

/// The chat engine's change events, turned into phone alerts.
@MainActor
final class NativePhonePushWatcher {
    private let push: BackendPhonePush
    private let meta: @Sendable (String) -> BackendSessionMeta?
    private var tracker = NativeChatNoticeTracker()
    private var subscriptions: [EngineSubscription] = []

    init(push: BackendPhonePush, meta: @escaping @Sendable (String) -> BackendSessionMeta?) { self.push = push; self.meta = meta }

    func start() {
        guard subscriptions.isEmpty else { return }
        subscriptions = [EngineBridge.shared.on("hoot:chat:changed") { [weak self] args in
            guard let raw = args.first, let value = try? NativeRPCValue.fromFoundation(raw) else { return }
            MainActor.assumeIsolated { self?.handle(value, source: "hoot") }
        }, EngineBridge.shared.on("session:chat:changed") { [weak self] args in
            guard args.count > 1, let id = args[0] as? String, let value = try? NativeRPCValue.fromFoundation(args[1]) else { return }
            MainActor.assumeIsolated { self?.handle(value, source: id) }
        }]
    }

    func stop() { subscriptions.forEach { $0.cancel() }; subscriptions = [] }

    private func handle(_ snapshot: NativeRPCValue, source: String) {
        for notice in tracker.consume(snapshot, source: source, complete: true, input: true, visible: false) {
            guard let alert = Self.notice(notice, snapshot: snapshot, meta: source == "hoot" ? nil : meta(source),
                                          agent: source == "hoot" ? nil : NativePhonePictureFaces.sessions([source])[source]?.name) else { continue }
            let push = self.push
            Task { await push.notify(alert) }
        }
    }

    /// One tracker notice as a phone alert: who, which chat, and the preview a phone may choose to show.
    nonisolated static func notice(_ notice: NativeChatNoticeTracker.Notice, snapshot: NativeRPCValue,
                                   meta: BackendSessionMeta?, agent: String?) -> BackendPhonePush.Notice? {
        let asking = notice.kind == "input-needed"
        let pending = snapshot["pending"].elements?.last
        let question = ["title", "summary", "description", "question", "toolName", "tool"].lazy.compactMap { pending?[$0].string }.first
        let reply = (snapshot["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) }
            .last { $0.record.kind == .message }?.record.value["text"].string
        let preview = asking ? question : reply
        if notice.source == "hoot" {
            return .init(kind: asking ? .needsYou : .hoot, session: "hoot", agent: "Hoot", title: "Hoot", folder: "", preview: preview)
        }
        guard let meta else { return nil }
        let provider = meta.provider.isEmpty ? "Agent" : meta.provider.prefix(1).uppercased() + meta.provider.dropFirst()
        let title = meta.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(kind: asking ? .needsYou : .finished, session: meta.id, agent: agent ?? provider,
                     title: title.isEmpty ? URL(fileURLWithPath: meta.cwd).lastPathComponent : title, folder: meta.cwd, preview: preview)
    }
}
