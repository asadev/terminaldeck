import Foundation
import TerminalDeckNativeCore

/// A host-issued tier narrows the existing device/folder/account grants.
/// Pairing, message capabilities and peer fields never create this grant.
public enum BackendINT2PhoneAccessLevel: String, CaseIterable, Sendable {
    case look, work, full
    public var tiers: Set<BackendMCPTier> {
        switch self { case .look: [.read]; case .work, .full: [.read, .act, .alter] }
    }
    public func permits(_ type: String, panel: String? = nil) -> Bool {
        let type = RNMHootWireCompatibility.incomingClientType(type)
        if Self.reads.contains(type) { return true }
        if type == "panel.act" {
            return self == .full || self == .work && ["tasks", "goals"].contains(panel ?? "")
        }
        return self == .full || self == .work && Self.workMessages.contains(type)
    }
    public static let managementPanels: Set<String> = ["settings", "plugins", "ai-apps", "hooks", "servers"]
    public static let reads: Set<String> = ["hello", "list", "attach", "detach", "resize", "ping", "ports",
        "folders.browse", "files.list", "files.read", "git.status", "git.diff", "panel.read", "usage.read", "account.read",
        "controls.read", "settings.read", "devices.list", "host.status", "github.read", "dev.status", "browser.profiles",
        "browser.windows", "browser.window.steps", "browser.surfaces", "browser.watch", "browser.unwatch", "browser.frame.ack",
        "copilot.hello", "copilot.attach", "copilot.detach", "copilot.state", "copilot.sessions", "copilot.log", "copilot.pending",
        "copilot.files", "copilot.file.read", "routines", "routine.text"]
    public static let workMessages: Set<String> = ["input", "create", "close", "rename", "upload.begin", "upload.data", "upload.end",
        "upload.cancel", "copilot.start", "copilot.say", "copilot.cancel", "copilot.stop", "dev.start", "tunnel.open",
        "tunnel.close", "net.open", "net.data", "net.ack", "net.close"]
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
        phoneAccessLevels = next; onChanged?()
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
