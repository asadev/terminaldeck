import Foundation
import TerminalDeckNativeCore

// Asad, 31 Oct 2026 ("yes let it have that too"): from this Mac, see and use another Mac's screen. The other Mac is a
// machine this Mac is already linked to (Devices › Machines: the same pairing code and the same "Let it in" with an
// access level on the other Mac that phones get, no new trust path). Its screen is the same `sims` service a phone uses
// ("This Mac" on the other side), so the other Mac decides everything: Work or Full control to watch, Full control to
// click and type, its own "Controlled from …" card and Stop, its own permissions. This side only asks and shows.

/// One picture of another Mac's screen, joined from its parts.
public struct BackendRemoteMacPicture: Sendable {
    public let machine: String
    public let display: String
    public let seq: Int
    public let width: Int
    public let height: Int
    public let jpeg: Data
}

/// What a remote Mac viewer is told besides pictures.
public enum BackendRemoteMacEvent: Sendable {
    /// "opening", "live" or "ended", with the other Mac's own words.
    case state(String, note: String)
    /// A click, key or watch the other Mac refused, in its own words.
    case refused(String)
}

/// This Mac's views of other Macs' screens.
public actor BackendRemoteMacScreens {
    public static let shared = BackendRemoteMacScreens()

    /// Sends one frame to a linked machine and asks it for a list: wired to the machine coordinator.
    public struct Link: Sendable {
        public var send: @Sendable (String, String, [NativeRPCValue.Field]) async throws -> Void
        public var request: @Sendable (String, String, [NativeRPCValue.Field], Set<String>) async throws -> NativeRPCValue
        public var name: @Sendable (String) async -> String
        public init(send: @escaping @Sendable (String, String, [NativeRPCValue.Field]) async throws -> Void,
                    request: @escaping @Sendable (String, String, [NativeRPCValue.Field], Set<String>) async throws -> NativeRPCValue,
                    name: @escaping @Sendable (String) async -> String = { $0 }) {
            self.send = send; self.request = request; self.name = name
        }
    }

    struct Key: Hashable, Sendable { let machine: String; let display: String }
    struct Viewer {
        var maxWidth: Int
        var fps: Int
        var onPicture: @Sendable (BackendRemoteMacPicture) -> Void
        var onEvent: @Sendable (BackendRemoteMacEvent) -> Void
        var pieces: (seq: Int, parts: [Int: String]) = (-1, [:])
        var started: Double
        var pictures = 0
    }

    private var link: Link?
    private var viewers: [Key: Viewer] = [:]
    private var counter = 0
    /// Rids of input and watches in flight, so the other Mac's refusal reaches the right viewer.
    private var asks: [String: Key] = [:]

    public init() {}

    public func bind(_ link: Link) { self.link = link }

    // MARK: Asking

    /// The other Mac's own displays (its "This Mac" rows), or a refusal in its words.
    public func displays(_ machine: String) async throws -> [NativeRPCValue] {
        guard let link else { throw NativeRPCError(code: "unavailable", message: "Other Macs are not wired in this copy.") }
        let answer = try await link.request(machine, "sims.list", [], ["sims.rows"])
        return (answer["devices"].elements ?? []).filter { $0["platform"].string == "mac" }
    }

    /// Starts showing one display of another Mac. Pictures and events arrive through the callbacks until `close`.
    public func open(_ machine: String, display: String, maxWidth: Int = 2560, fps: Int = 30,
                     onPicture: @escaping @Sendable (BackendRemoteMacPicture) -> Void,
                     onEvent: @escaping @Sendable (BackendRemoteMacEvent) -> Void) async throws {
        guard display.hasPrefix("mac:") else { throw NativeRPCError.invalidArguments("Choose one of that Mac's displays.") }
        let key = Key(machine: machine, display: display)
        viewers[key] = Viewer(maxWidth: maxWidth, fps: fps, onPicture: onPicture, onEvent: onEvent, started: Date().timeIntervalSince1970 * 1_000)
        onEvent(.state("opening", note: ""))
        try await watch(key)
    }

    private func watch(_ key: Key) async throws {
        guard let link, let viewer = viewers[key] else { return }
        let rid = nextRid("watch")
        asks[rid] = key
        do {
            try await link.send(key.machine, "sims.watch", [.init("rid", .string(rid)), .init("id", .string(key.display)),
                .init("maxWidth", .number(Double(viewer.maxWidth))), .init("quality", .number(70)), .init("fps", .number(Double(viewer.fps)))])
        } catch {
            asks[rid] = nil
            viewer.onEvent(.state("ended", note: Self.words(error)))
            throw error
        }
    }

    /// Stops showing a display (the viewer window closed, or Stop).
    public func close(_ machine: String, display: String) async {
        guard viewers.removeValue(forKey: Key(machine: machine, display: display)) != nil else { return }
        try? await link?.send(machine, "sims.unwatch", [.init("id", .string(display))])
    }

    /// Stops every view of another Mac from here (the MCP stop).
    public func closeAll() async -> Int {
        let keys = Array(viewers.keys)
        for key in keys {
            viewers[key]?.onEvent(.state("ended", note: "Stopped on this Mac."))
            await close(key.machine, display: key.display)
        }
        return keys.count
    }

    /// One input to the other Mac: `fields` are a `sims.input`'s own (`do` and its values).
    public func input(_ machine: String, display: String, _ fields: [NativeRPCValue.Field]) async {
        let key = Key(machine: machine, display: display)
        guard let link, viewers[key] != nil else { return }
        let rid = nextRid("in")
        asks[rid] = key
        if asks.count > 256 { asks.removeAll() }
        do { try await link.send(machine, "sims.input", [.init("rid", .string(rid)), .init("id", .string(display))] + fields) }
        catch { asks[rid] = nil; viewers[key]?.onEvent(.refused(Self.words(error))) }
    }

    /// The viewer drew a picture: the other Mac may send the next.
    public func ack(_ machine: String, display: String, seq: Int) async {
        try? await link?.send(machine, "sims.ack", [.init("id", .string(display)), .init("seq", .number(Double(seq)))])
    }

    // MARK: Answers (every frame from a linked machine passes here)

    public func received(_ machine: String, _ frame: NativeRPCValue) {
        switch frame["t"].string {
        case "sims.frame":
            guard let display = frame["id"].string else { return }
            let key = Key(machine: machine, display: display)
            guard var viewer = viewers[key], let seq = frame["seq"].number.map(Int.init), let data = frame["data"].string else { return }
            var text = data
            let parts = Int(frame["parts"].number ?? 1)
            if parts > 1 {
                if viewer.pieces.seq != seq { viewer.pieces = (seq, [:]) }
                viewer.pieces.parts[Int(frame["part"].number ?? 0)] = data
                guard viewer.pieces.parts.count == parts else { viewers[key] = viewer; return }
                text = (0..<parts).compactMap { viewer.pieces.parts[$0] }.joined()
                viewer.pieces = (-1, [:])
            }
            viewer.pictures += 1
            viewers[key] = viewer
            guard let jpeg = Data(base64Encoded: text) else { Task { await self.ack(machine, display: display, seq: seq) }; return }
            viewer.onPicture(.init(machine: machine, display: display, seq: seq, width: Int(frame["w"].number ?? 0), height: Int(frame["h"].number ?? 0), jpeg: jpeg))
        case "sims.state":
            guard let display = frame["id"].string, let viewer = viewers[Key(machine: machine, display: display)] else { return }
            viewer.onEvent(.state(frame["state"].string ?? "", note: frame["note"].string ?? ""))
        case "error":
            guard let rid = frame["rid"].string, let key = asks.removeValue(forKey: rid), let viewer = viewers[key] else { return }
            let words = frame["message"].string ?? "That Mac refused."
            if rid.hasPrefix("m2m-watch") { viewer.onEvent(.state("ended", note: words)) } else { viewer.onEvent(.refused(words)) }
        default:
            break
        }
    }

    /// The link to a machine is back (a new welcome): every view of it asks for its pictures again.
    public func linkOnline(_ machine: String) async {
        for key in viewers.keys where key.machine == machine { try? await watch(key) }
    }

    /// The link to a machine dropped: its viewers say so and wait (the link reconnects by itself).
    public func linkLost(_ machine: String, why: String) {
        for (key, viewer) in viewers where key.machine == machine { viewer.onEvent(.state("opening", note: why)) }
    }

    /// For mac_screen.status: the other Macs this Mac is watching now.
    public func watching() async -> [NativeRPCValue] {
        var rows: [NativeRPCValue] = []
        let now = Date().timeIntervalSince1970 * 1_000
        for (key, viewer) in viewers.sorted(by: { $0.value.started < $1.value.started }) {
            let name = await link?.name(key.machine) ?? key.machine
            rows.append(.object([.init("machine", .string(name)), .init("machineId", .string(key.machine)), .init("display", .string(key.display)),
                .init("seconds", .number(((now - viewer.started) / 100).rounded() / 10)), .init("pictures", .number(Double(viewer.pictures)))]))
        }
        return rows
    }

    private func nextRid(_ kind: String) -> String {
        counter += 1
        return "m2m-\(kind)-\(counter)"
    }

    static func words(_ error: Error) -> String { (error as? NativeRPCError)?.message ?? error.localizedDescription }
}
