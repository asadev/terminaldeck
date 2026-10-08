import Foundation

enum PhoneAccessLevel: String, Equatable {
    case look, work, full

    var title: String {
        switch self {
        case .look: return "Look only"
        case .work: return "Work"
        case .full: return "Full control"
        }
    }
}

struct PhoneAccessGrant: Equatable {
    let level: PhoneAccessLevel

    // Unknown or malformed levels never become a grant.
    static func decode(_ object: [String: Any]) -> PhoneAccessGrant? {
        guard let raw = object["level"] as? String,
              let level = PhoneAccessLevel(rawValue: raw) else { return nil }
        return .init(level: level)
    }

    func allows(_ message: ClientMessage) -> Bool {
        guard let data = WireCodec.encode(message).data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = frame["t"] as? String else { return false }
        if Self.reads.contains(type) { return true }
        if type == "panel.act", let name = frame["panel"] as? String,
           let panel = PanelKind(rawValue: name) {
            return level == .full || level == .work && !panel.requiresFullControl
        }
        if level == .full { return true }
        return level == .work && Self.work.contains(type)
    }

    private static let reads: Set<String> = [
        "hello", "list", "attach", "detach", "resize", "ping", "ports",
        "folders.browse", "files.list", "files.read", "git.status", "git.diff",
        "panel.read", "usage.read", "account.read", "controls.read", "settings.read",
        "devices.list", "host.status", "github.read", "dev.status",
        "browser.profiles", "browser.windows", "browser.window.steps", "browser.surfaces",
        "browser.watch", "browser.unwatch", "browser.frame.ack",
        "copilot.hello", "copilot.attach", "copilot.detach", "copilot.state",
        "copilot.sessions", "copilot.log", "copilot.pending", "copilot.files",
        "copilot.file.read", "routines", "routine.text"
    ]
    private static let work: Set<String> = [
        "input", "create", "close", "rename", "upload.begin", "upload.data", "upload.end",
        "upload.cancel", "copilot.start", "copilot.say", "copilot.cancel", "copilot.stop",
        "dev.start", "tunnel.open", "tunnel.close", "net.open", "net.data", "net.ack", "net.close"
    ]
}
