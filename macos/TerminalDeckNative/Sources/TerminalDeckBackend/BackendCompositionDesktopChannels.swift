import Foundation
import TerminalDeckNativeCore

/// Links and outside attachments, natively (D14), over the existing owners:
/// `BackendMacAppHandoffLinks` (link-open.ts openSystemUrl / showLinkMenu) and
/// `BackendMacAppHandoffAttachments` (attach-outside.ts browse / inspect /
/// paste). Their app-target presenters (Launch Services, NSMenu, NSOpenPanel,
/// NSPasteboard) are `NativeCompositionDesktopHandoff` in the app target.
/// attach:boundary / attach:bring-in stay with the files graph.
public enum BackendCompositionDesktopChannels {
    public static func register(registry: NativeChannelRegistry, ownerID: String, authority: BackendCompositionAuthority,
                                links: BackendMacAppHandoffLinks, attachments: BackendMacAppHandoffAttachments,
                                linkRequests: BackendCompositionLinkRequests) async throws -> (invokes: [String], sends: [String], events: [String]) {
        var table = BackendCompositionChannelTable()
        // link-open.ts L300-302. link:system is links.open's channel; the menu is
        // a pointer gesture over the asking window and stays the window's.
        table.invoke("link:system", .change) { context, args in .bool(try await links.openSystem(context.argument(0, in: args))) }
        table.invoke("link:menu", .window) { context, args in .bool(try await links.menu(ownerID: context.ownerID, url: context.argument(0, in: args))) }
        // browser-binding-ipc.ts L1082-1094: the window's answer to a link-tab request.
        table.send("link:opened", .window) { context, args in await linkRequests.settle(context.argument(0, in: args)) }
        // attach-outside.ts L409-498 (tools projects.browse / sessions.attach; the
        // clipboard read is never a tool's).
        table.invoke("attach:browse", .read) { context, args in try await attachments.browse(context.argument(0, in: args), context: context) }
        table.invoke("attach:inspect", .read) { context, args in await attachments.inspect(context.argument(0, in: args)) }
        table.invoke("attach:paste", .window) { _, _ in try await attachments.paste() }
        // link-open.ts LINK_TAB_CHANNEL: the request a session's link makes of the window's browser.
        return try await table.install(registry: registry, ownerID: ownerID, authority: authority,
            events: [BackendMacAppHandoffLinkRules.tabChannel])
    }
}

/// browser-binding-ipc.ts askRenderer / `link:opened` (L360-397, L1082-1094):
/// one request out on `link:open-tab` carrying a request id, and its one
/// answer — the tab the window opened, or why not. A window that does not
/// answer within two seconds is answered for, with the source sentence.
public actor BackendCompositionLinkRequests {
    public static let timeoutMilliseconds = 2_000
    private var pending: [String: CheckedContinuation<NativeRPCValue, Never>] = [:]
    private var sequence = 0
    public init() {}
    /// `push` delivers `{url, requestId, sessionId?, machineId?}` on `link:open-tab`.
    /// Answers `{tabId}` or `{refused}`.
    public func ask(url: String, sessionID: String? = nil, machineID: String = "",
                    push: @escaping @Sendable (NativeRPCValue) async throws -> Void) async -> NativeRPCValue {
        sequence += 1
        let requestID = "open:\(Int64(Date().timeIntervalSince1970 * 1000)):\(sequence)"
        var request = NativeRPCValue.object([.init("url", .string(url)), .init("requestId", .string(requestID))])
        if let sessionID { request = request.setting("sessionId", .string(sessionID)) }
        if !machineID.isEmpty { request = request.setting("machineId", .string(machineID)) }
        let late = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.timeoutMilliseconds))
            await self?.finish(requestID, .object([.init("refused", .string("No \(BackendSharedBrand.name) window answered — opening it in your default browser."))]))
        }
        defer { late.cancel() }
        let outgoing = request
        return await withCheckedContinuation { continuation in
            pending[requestID] = continuation
            Task {
                do { try await push(outgoing) }
                catch { await self.finish(requestID, .object([.init("refused", .string("No \(BackendSharedBrand.name) window answered — opening it in your default browser."))])) }
            }
        }
    }
    /// The `link:opened` send: settles the named request once; unknown ids are ignored.
    public func settle(_ raw: NativeRPCValue) {
        guard let id = raw["requestId"].string, !id.isEmpty, pending[id] != nil else { return }
        if let tab = raw["tabId"].string, !tab.isEmpty { finish(id, .object([.init("tabId", .string(tab))])); return }
        let refused = raw["refused"].string ?? ""
        finish(id, .object([.init("refused", .string(refused.isEmpty
            ? "\(BackendSharedBrand.name) could not open a window for that link — opening it in your default browser." : refused))]))
    }
    private func finish(_ id: String, _ reply: NativeRPCValue) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: reply)
    }
}
