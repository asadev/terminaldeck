import Foundation

// The native browser's smaller rules, each a port of the web browser's own so
// the two behave alike: zoom steps, the localhost-ports list, the screenshot's
// file name and the one line a session receives, and which sessions can be
// sent to.

/// Zoom steps, as the web browser's menu offers them (`renderer/browser/devices.ts`).
public enum BrowserZoom {
    public static let steps: [Double] = [0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 2]

    /// One step in (`+1`) or out (`-1`) from the nearest step to `current`.
    public static func step(_ current: Double, by delta: Int) -> Double {
        var nearest = 0
        for i in steps.indices where abs(steps[i] - current) < abs(steps[nearest] - current) { nearest = i }
        return steps[max(0, min(steps.count - 1, nearest + delta))]
    }

    public static func percent(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }
}

/// One port something is listening on — the engine's `dev:ports` row (`DevPort`).
public struct BrowserDevPort: Equatable, Sendable, Identifiable {
    public let port: Int
    /// The process holding it, e.g. "node".
    public let process: String
    /// Only the port answered; the process could not be named.
    public let guessed: Bool
    /// Terminal Deck itself is holding it.
    public let ours: Bool
    public var id: Int { port }

    public init(port: Int, process: String, guessed: Bool = false, ours: Bool = false) {
        self.port = port
        self.process = process
        self.guessed = guessed
        self.ours = ours
    }

    /// `5173 node` — the row's words.
    public var summary: String { process.isEmpty ? String(port) : "\(port) \(process)" }

    /// The answer to `dev:ports`, forgivingly read (`readPorts` in StartPage.tsx):
    /// named ports first, then by number.
    public static func read(_ value: Any) -> [BrowserDevPort] {
        guard let rows = value as? [Any] else { return [] }
        var out: [BrowserDevPort] = []
        for row in rows {
            guard let fields = row as? [String: Any] else { continue }
            let port: Int
            if let number = fields["port"] as? NSNumber {
                port = number.intValue
            } else if let text = fields["port"] as? String, let number = Int(text) {
                port = number
            } else { continue }
            guard port > 0 else { continue }
            out.append(BrowserDevPort(port: port,
                                      process: (fields["process"] as? String) ?? "",
                                      guessed: (fields["guessed"] as? Bool) ?? false,
                                      ours: (fields["ours"] as? Bool) ?? false))
        }
        return out.sorted { ($0.guessed ? 1 : 0, $0.port) < ($1.guessed ? 1 : 0, $1.port) }
    }
}

/// Text that goes into a terminal: one line, with nothing in it that could submit
/// early or repaint the screen (`oneLine` in `capture-text.ts`).
public enum BrowserText {
    public static func oneLine(_ value: String) -> String {
        let spaced = String(String.UnicodeScalarView(value.unicodeScalars.map { scalar -> Unicode.Scalar in
            let code = scalar.value
            let control = code < 0x20 || (code >= 0x7f && code <= 0x9f) || code == 0x2028 || code == 0x2029
            return control ? " " : scalar
        }))
        return spaced
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A screenshot of the page: where it is saved and what a session is told about it.
public enum BrowserShot {
    /// `localhost-3000-20261005-142233.png` — the web browser's `screenshotName`,
    /// saved under ~/Pictures/Terminal Deck like the web browser's; a drawn-on
    /// one ends `-marked.png`.
    public static func fileName(url: URL?, now: Date, timeZone: TimeZone = .current, suffix: String = "") -> String {
        var host = url?.host(percentEncoded: true) ?? ""
        if !host.isEmpty, let port = url?.port { host += ":\(port)" }
        var safe = host.replacingOccurrences(of: #"[^a-zA-Z0-9.\-]"#, with: "-", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"^[.\-]+"#, with: "", options: .regularExpression)
        safe = String(safe.prefix(48))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        func pad(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let stamp = "\(c.year ?? 0)\(pad(c.month))\(pad(c.day))-\(pad(c.hour))\(pad(c.minute))\(pad(c.second))"
        return "\(safe.isEmpty ? "page" : safe)-\(stamp)\(suffix).png"
    }

    /// The one line a session receives: what was typed, then the picture's
    /// path, the page's address and its size — exactly the web browser's
    /// `composeShot` (ScreenshotPopup.tsx). The title is not in the line there,
    /// so it is not here (lane BR: it was added in the port; TS is the spec).
    public static func compose(instruction: String, path: String, url: URL?, title: String, width: Int, height: Int,
                               marks: Int = 0) -> String {
        var context = "[browser screenshot"
        if marks > 0 { context += " with \(marks) mark\(marks == 1 ? "" : "s") on it" }
        let address = url.map { BrowserText.oneLine($0.absoluteString) } ?? ""
        if !address.isEmpty { context += " of \(address)" }
        context += ": \(path) (\(width) x \(height))]"
        let lead = BrowserText.oneLine(instruction)
        return lead.isEmpty ? context : "\(lead) \(context)"
    }
}

/// How a line is typed into a session so it is actually submitted
/// (`terminalWrites` in `chat/attach/mentions.ts`): the text, a short pause,
/// then Return on its own — a long text with Return in the same write is
/// read as a paste and never submitted.
public enum BrowserTerminalSend {
    /// The pause between the two writes, in milliseconds. The web app's is 50;
    /// these writes cross one more hop (HTTP to the engine), so a little more.
    public static let submitGapMilliseconds: UInt64 = 80

    public static func writes(_ message: String) -> [String] {
        [message.contains("@") ? message + " " : message, "\r"]
    }
}

/// A session the screenshot can be sent to — read from the engine's `session:list`.
public struct BrowserSessionChoice: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let cwd: String
    public let ended: Bool

    public init(id: String, label: String, cwd: String = "", ended: Bool = false) {
        self.id = id
        self.label = label
        self.cwd = cwd
        self.ended = ended
    }

    /// The sessions on this machine, named the way the web browser's picker names
    /// them (`agent-target.ts`): its own name if it has one, else
    /// "<folder> · Session N". Exited sessions are left out — nothing can be sent to them.
    public static func read(_ value: Any) -> [BrowserSessionChoice] {
        guard let rows = value as? [Any] else { return [] }
        var counts: [String: Int] = [:]
        var out: [BrowserSessionChoice] = []
        for row in rows {
            guard let fields = row as? [String: Any],
                  let id = fields["id"] as? String, !id.isEmpty else { continue }
            let cwd = (fields["cwd"] as? String) ?? ""
            let title = (fields["title"] as? String) ?? ""
            let ended = fields["exitCode"] is NSNumber
            let index = (counts[cwd] ?? 0) + 1
            counts[cwd] = index
            if ended { continue }
            let folder = folderName(cwd)
            let label: String
            if !title.isEmpty && title != folder {
                label = title
            } else {
                label = folder.isEmpty ? "Session \(index)" : "\(folder) · Session \(index)"
            }
            out.append(BrowserSessionChoice(id: id, label: label, cwd: cwd, ended: ended))
        }
        return out
    }

    static func folderName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }
}

/// The "Size" control's device frames — the web browser's `DEVICE_PRESETS`.
public struct BrowserDevicePreset: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let width: Int
    public let height: Int
    public let group: String

    public static let all: [BrowserDevicePreset] = [
        .init(id: "phone-sm", label: "Phone, small", width: 375, height: 667, group: "phone"),
        .init(id: "phone", label: "Phone", width: 390, height: 844, group: "phone"),
        .init(id: "tablet", label: "Tablet", width: 768, height: 1024, group: "tablet"),
        .init(id: "tablet-lg", label: "Tablet, large", width: 1024, height: 1366, group: "tablet"),
        .init(id: "laptop", label: "Laptop", width: 1280, height: 800, group: "desktop"),
        .init(id: "desktop", label: "Desktop", width: 1440, height: 900, group: "desktop"),
    ]

    public static func byID(_ id: String) -> BrowserDevicePreset? { all.first { $0.id == id } }

    /// The phone's user agent the web browser offers (`MOBILE_USER_AGENT`).
    public static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// The page's size inside `container` (`fitInto`): never larger than the room,
    /// and `clamped` when it had to shrink.
    public static func fit(width: Int, height: Int, landscape: Bool,
                           into container: (width: Double, height: Double)) -> (width: Double, height: Double, clamped: Bool) {
        let w = Double(landscape ? height : width)
        let h = Double(landscape ? width : height)
        let fw = min(w, container.width)
        let fh = min(h, container.height)
        return (fw, fh, fw < w || fh < h)
    }
}

/// A browser profile, as the engine lists them (`browser-profile:list`).
/// Each profile's cookies live in a website-data store of its own, named by
/// `storeIdentifier` — the same profile always opens the same store.
public struct BrowserProfile: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The badge's character — the profile's own, else its name's first letter.
    public let badge: String
    public let isDefault: Bool

    public init(id: String, name: String, avatar: String = "", isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        let own = avatar.trimmingCharacters(in: .whitespaces)
        self.badge = own.isEmpty ? (name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "") : String(own.prefix(2))
    }

    /// `{profiles: [...], activeId}` → the profiles and the active one's id.
    public static func read(_ value: Any) -> (profiles: [BrowserProfile], activeID: String) {
        guard let state = value as? [String: Any], let rows = state["profiles"] as? [Any] else { return ([], "") }
        var out: [BrowserProfile] = []
        for row in rows {
            guard let fields = row as? [String: Any],
                  let id = fields["id"] as? String, !id.isEmpty else { continue }
            out.append(BrowserProfile(id: id,
                                      name: (fields["name"] as? String) ?? "",
                                      avatar: (fields["avatar"] as? String) ?? "",
                                      isDefault: (fields["isDefault"] as? Bool) ?? false))
        }
        return (out, (state["activeId"] as? String) ?? "")
    }

    /// The website-data store's identifier for a profile id: a fixed UUID made
    /// from the id, so a profile reopens its own cookies on every launch.
    /// The empty id (no profile chosen) is the default store.
    public static func storeIdentifier(for profileID: String) -> UUID {
        // FNV-1a, 128 bits as two 64-bit lanes with different seeds: stable across
        // launches and machines (Swift's own hashing is seeded per process).
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash: UInt64 = seed
            for byte in Array(("td-browser-profile:" + profileID).utf8) {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            return hash
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: a >> (UInt64(i) * 8))
            bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (UInt64(i) * 8))
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50 // version 5-style (name-based)
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
