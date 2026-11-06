import Foundation
import TerminalDeckNativeCore

/// A host-issued tier narrows the existing device/folder/account grants.
/// Pairing, message capabilities and peer fields never create this grant.
public enum BackendINT2PhoneAccessLevel: String, CaseIterable, Sendable {
    /// `hoot`: the phone can talk to Hoot and nothing else — no sessions, files, panels or devices.
    case look, hoot, work, full
    /// The one list the Devices screen's pickers and the device-access tool both offer (#153).
    public static let offered: [Self] = [.full, .work, .hoot, .look]
    public var title: String {
        switch self { case .look: "Look only"; case .hoot: "Hoot only"; case .work: "Work"; case .full: "Full control" }
    }
    public var tiers: Set<BackendMCPTier> {
        switch self { case .look: [.read]; case .hoot: [.read, .act]; case .work, .full: [.read, .act, .alter] }
    }
    /// What the phone is told. Phones up to 0.20.0 know only look/work/full and hide Hoot for any
    /// other word, so Hoot only is announced as "work"; this host still enforces Hoot only.
    public var wireLevel: String { self == .hoot ? Self.work.rawValue : rawValue }
    /// Whether a chat or session this phone starts runs inside its device folder sandbox (27 Oct, Decker D2). At Full
    /// control (the person's own device) it runs like one started on this Mac, with no sandbox; below Full the
    /// folder boundary holds its writes. No level (an older phone or a guest without one) keeps the sandbox.
    public static func sandboxesStarts(_ level: Self?) -> Bool { level != .full }
    /// #27: no sandbox only for the person's own device at Full. A guest raised to Full on the Devices page still works
    /// inside its folders and its own account folders (sec-26), never on the owner's.
    public static func sandboxesStarts(_ level: Self?, kind: BackendRemoteDeviceKind) -> Bool { kind != .mine || sandboxesStarts(level) }
    public func permits(_ type: String, panel: String? = nil) -> Bool {
        if self == .hoot { return Self.hootMessages.contains(type) }
        // #27 (Decker, review S-D2): Files at Look only is view only. Listing and reading a file are reads; any other
        // `files.*` (a write, a delete, a rename, should one ever be added) is never a read, whatever list it lands in:
        // Full control, or Work only if it is named a Work message.
        if type.hasPrefix("files."), !Self.fileReads.contains(type) { return self == .full || self == .work && Self.workMessages.contains(type) }
        if type == "panel.read", Self.workReadPanels.contains(panel ?? "") { return self == .full || self == .work }
        if Self.reads.contains(type) { return true }
        if type == "panel.act" {
            return self == .full || self == .work && ["tasks", "goals"].contains(panel ?? "")
        }
        return self == .full || self == .work && Self.workMessages.contains(type)
    }
    public static let managementPanels: Set<String> = ["settings", "plugins", "ai-apps", "hooks", "servers"]
    /// The phone's Files reads (BackendPhoneFiles): the only `files.*` messages a Look-only device may send.
    public static let fileReads: Set<String> = ["files.list", "files.read"]
    /// Panels whose reads need Work, not Look: the Receiver shows what outsiders sent in (31 Oct 2026, web v1).
    /// Projects stays an ordinary read (Look).
    public static let workReadPanels: Set<String> = ["receiver"]
    public static let reads: Set<String> = ["hello", "list", "attach", "detach", "resize", "take", "ping", "ports",
        "folders.browse", "files.list", "files.read", "git.status", "git.diff", "panel.read", "usage.read", "account.read",
        "controls.read", "settings.read", "devices.list", "host.status", "github.read", "dev.status", "browser.profiles",
        "browser.windows", "browser.window.steps", "browser.surfaces", "browser.watch", "browser.unwatch", "browser.frame.ack",
        "hoot.hello", "hoot.attach", "hoot.detach", "hoot.state", "hoot.sessions", "hoot.log", "hoot.pending", "hoot.older",
        "hoot.files", "hoot.file.read", "routines", "routine.text", "chats.watch", "chats.unwatch", "chats.older", "hoot.account.read",
        "chats.choices", "chats.options", "hoot.options.read", "chats.app.read", "chats.app.bridge",
        // 28 Oct: the Mac's pictures (project logos, agent pictures, who works in each session).
        "pictures", "picture",
        // 31 Oct: alerts while the phone's app is closed — the phone's own registration, at every level.
        "push.register", "push.presence", "push.forget",
        // 31 Oct: the Mac's load on the phone's Activity page — watching, at every level.
        "activity.watch", "activity.unwatch", "widgets.read",
        // 31 Oct: the Mac's simulators and emulators: the list, watching one, and a still to annotate.
        "sims.list", "sims.watch", "sims.unwatch", "sims.ack", "sims.key", "sims.shot"]
    public static let workMessages: Set<String> = ["input", "create", "close", "rename", "upload.begin", "upload.data", "upload.end",
        "upload.cancel", "hoot.start", "hoot.say", "hoot.cancel", "hoot.stop", "dev.start", "tunnel.open",
        "tunnel.close", "net.open", "net.data", "net.ack", "net.close", "chats.say", "chats.steer", "chats.new", "chats.interrupt",
        // A chat's model and effort; its permission mode is Full control (BackendPhoneChats checks it).
        "chats.set",
        // 31 Oct: driving a simulator or emulator, starting or stopping it, and sending an annotated still.
        "sims.input", "sims.power", "sims.annotate", "sims.record"]
    /// Hoot only: the Hoot conversation's reads and its say/start/stop, never files, memory or answers.
    public static let hootMessages: Set<String> = ["chats.app.read", "chats.app.bridge", "hello", "ping", "hoot.hello", "hoot.attach", "hoot.detach", "hoot.older",
        "hoot.bye", "hoot.state", "hoot.sessions", "hoot.log", "hoot.pending",
        "hoot.start", "hoot.say", "hoot.cancel", "hoot.stop", "hoot.account.read", "hoot.options.read",
        "push.register", "push.presence", "push.forget",
        "activity.watch", "activity.unwatch"]
}

public extension BackendRemoteTrustStore {
    func phoneAccess(_ id: String) -> BackendINT2PhoneAccessLevel? {
        guard isApproved(id) else { return nil }
        return phoneAccessLevels[id]
    }
    func setPhoneAccess(_ id: String, level: BackendINT2PhoneAccessLevel?) throws {
        try requireOpen()
        guard isApproved(id) else { throw NativeRPCError(code: "access-denied", message: "Approve this device before choosing its access.") }
        var next = phoneAccessLevels; next[id] = level
        try BackendRemoteTrustStorage.write(.object([.init("version", .number(1)), .init("devices", .object(next.sorted { $0.key < $1.key }.map {
            .init($0.key, .string($0.value.rawValue))
        }))]), file: directory.appendingPathComponent("remote-access.json"))
        phoneAccessLevels = next; changed()
    }
    /// The pairing sheet's "Let it in": the chosen access is written first, then the device is
    /// approved as the owner's own, in one actor turn — no connection can attach in between, and
    /// it is never briefly approved with broader access than chosen. A failed approval puts the
    /// access file back.
    func approveWithPhoneAccess(_ id: String, level: BackendINT2PhoneAccessLevel) throws {
        try requireOpen()
        guard devices.contains(where: { $0.id == id && !$0.revoked }) else {
            throw NativeRPCError(code: "missing-device", message: "That device is no longer waiting. Pair it again.")
        }
        if let decided = kinds[id], decided.kind != .mine {
            throw NativeRPCError(code: "access-denied", message: "This device was let in as a guest. Revoke it and pair it again.")
        }
        let before = phoneAccessLevels
        var next = before; next[id] = level
        try writePhoneAccessLevels(next)
        do {
            _ = try remoteServeForgetFolderGrants(id)
            _ = try remoteServeForgetAccountGrants(id)
            _ = try approve(id, kind: .mine)
        } catch {
            try? writePhoneAccessLevels(before)
            throw error
        }
        guard isApproved(id), phoneAccess(id) == level else {
            throw NativeRPCError(code: "access-unconfirmed", message: "The device was not approved. Try again.")
        }
        changed()
    }
    func writePhoneAccessLevels(_ next: [String: BackendINT2PhoneAccessLevel]) throws {
        try BackendRemoteTrustStorage.write(.object([.init("version", .number(1)), .init("devices", .object(next.sorted { $0.key < $1.key }.map {
            .init($0.key, .string($0.value.rawValue))
        }))]), file: directory.appendingPathComponent("remote-access.json"))
        phoneAccessLevels = next
    }
    func phoneAccessRows() -> NativeRPCValue {
        .array(listDevices().map { device in device.value.setting("access", phoneAccess(device.id).map { .string($0.rawValue) } ?? .null) })
    }
    func requirePhoneAccess(_ id: String, message: String, panel: String? = nil) throws {
        guard let level = phoneAccess(id), level.permits(message, panel: panel) else {
            throw NativeRPCError(code: "access-denied", message: "This device's current access does not permit that action.")
        }
    }
}
