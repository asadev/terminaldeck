import Foundation
import TerminalDeckNativeCore

public enum BackendServersHostStep: String, Codable, Sendable { case idle, checking, uploading, installing, service, pairing, done, removing, failed }
public struct BackendServersHostState: Codable, Equatable, Sendable {
    public var serverId: String; public var step: BackendServersHostStep; public var line: String; public var detail: String
    public var done: [String]; public var code: String?; public var weInstalled: Bool
    public init(serverId: String, step: BackendServersHostStep = .idle, line: String = "", detail: String = "", done: [String] = [], code: String? = nil, weInstalled: Bool = false) {
        self.serverId = serverId; self.step = step; self.line = line; self.detail = detail; self.done = done; self.code = code; self.weInstalled = weInstalled
    }
    public var wireValue: NativeRPCValue { .object([.init("serverId", .string(serverId)), .init("step", .string(step.rawValue)), .init("line", .string(line)), .init("detail", .string(detail)), .init("done", .array(done.map(NativeRPCValue.string))), .init("code", BackendServersSetupWire.text(code)), .init("weInstalled", .bool(weInstalled))]) }
}
public struct BackendServersHostOnServer: Codable, Equatable, Sendable {
    public var command: String; public var version: String; public var running: BackendServersSigninState; public var status: String; public var address: String
    public var unit: String; public var linger: Bool; public var data: Bool; public var dataDir: String
    public init(command: String = "", version: String = "", running: BackendServersSigninState = .unknown, status: String = "", address: String = "", unit: String = "", linger: Bool = false, data: Bool = false, dataDir: String = "") {
        self.command = command; self.version = version; self.running = running; self.status = status; self.address = address; self.unit = unit; self.linger = linger; self.data = data; self.dataDir = dataDir
    }
    public var wireValue: NativeRPCValue { .object([.init("command", .string(command)), .init("version", .string(version)), .init("running", .string(running.rawValue)), .init("status", .string(status)), .init("address", .string(address)), .init("unit", .string(unit)), .init("linger", .bool(linger)), .init("data", .bool(data)), .init("dataDir", .string(dataDir))]) }
}
public struct BackendServersHostRoom: Codable, Equatable, Sendable {
    public var os: String; public var arch: String; public var libc: String; public var node: String; public var npm: String; public var missingTools: [String]
    public var downloader: String; public var canHash: Bool; public var canUnpack: Bool; public var homeFreeKb: Double?; public var systemdUser: Bool
    public init(os: String, arch: String = "", libc: String = "gnu", node: String = "", npm: String = "", missingTools: [String] = [], downloader: String = "", canHash: Bool = false, canUnpack: Bool = false, homeFreeKb: Double? = nil, systemdUser: Bool = false) {
        self.os = os; self.arch = arch; self.libc = libc; self.node = node; self.npm = npm; self.missingTools = missingTools
        self.downloader = downloader; self.canHash = canHash; self.canUnpack = canUnpack; self.homeFreeKb = homeFreeKb; self.systemdUser = systemdUser
    }
    public var wireValue: NativeRPCValue { .object([.init("os", .string(os)), .init("arch", .string(arch)), .init("libc", .string(libc)), .init("node", .string(node)), .init("npm", .string(npm)), .init("missingTools", .array(missingTools.map(NativeRPCValue.string))), .init("downloader", .string(downloader)), .init("canHash", .bool(canHash)), .init("canUnpack", .bool(canUnpack)), .init("homeFreeKb", homeFreeKb.map(NativeRPCValue.number) ?? .null), .init("systemdUser", .bool(systemdUser))]) }
}
public struct BackendServersHostLook: Sendable, Equatable {
    public var host: BackendServersHostOnServer; public var room: BackendServersHostRoom
    public init(host: BackendServersHostOnServer, room: BackendServersHostRoom) { self.host = host; self.room = room }
    public var wireValue: NativeRPCValue { .object([.init("host", host.wireValue), .init("room", room.wireValue)]) }
}
public enum BackendServersHostRelay: String, Sendable { case connected, off, unknown; case notConnected = "not-connected" }

public enum BackendServersHostRules {
    public static let removeHostLabel = "Remove it from this server"
    public static let done = "__terminaldeck_host"
    public static let codePattern = #"Pairing code[^\S\n]+(\S+)"#
    public static let fingerprintPattern = #"Fingerprint[^\S\n]+(\S+)"#
    public static let verdictPattern = #"(Approved as your own device|was NOT approved)"#
    public static func relayState(_ status: String) -> BackendServersHostRelay {
        let lines = status.components(separatedBy: "\n")
        guard let at = lines.firstIndex(where: { BackendServersSetupWire.trim($0) == "Relay" }), at + 1 < lines.count else { return .unknown }
        let said = BackendServersSetupWire.trim(lines[at + 1])
        if said.hasPrefix("connected") { return .connected }; if said.hasPrefix("not connected") { return .notConnected }; if said.hasPrefix("off") { return .off }; return .unknown
    }
    public static func hostIdOf(_ status: String) -> String { BackendServersSetupWire.capture(#"(?m)^[^\S\n]*host id[^\S\n]+(\S+)"#, status) ?? "" }
    public static func channelsOf(_ status: String) -> Int? { BackendServersSetupWire.capture(#"(?m)^[^\S\n]*channels[^\S\n]+(\d+)"#, status).flatMap(Int.init) }
    public static func serverAddressOf(_ status: String) -> String {
        let lines = status.components(separatedBy: "\n")
        guard let at = lines.firstIndex(where: { BackendServersSetupWire.trim($0) == "Server address" }), at + 1 < lines.count else { return "" }
        let said = BackendServersSetupWire.trim(lines[at + 1]); return BackendSharedServerAddresses.parse(said) == nil ? "" : said
    }
    public static func readHostProbe(_ out: String) -> BackendServersHostLook {
        let marker = out.range(of: "--- status ---\n")
        let head = marker.map { String(out[..<$0.lowerBound]) } ?? out
        let status = marker.map { BackendServersSetupWire.trim(String(out[$0.upperBound...])) } ?? ""
        var said: [String: String] = [:]
        for line in head.components(separatedBy: "\n") { if let tab = line.firstIndex(of: "\t"), tab > line.startIndex { said[String(line[..<tab])] = BackendServersSetupWire.trim(String(line[line.index(after: tab)...])) } }
        func v(_ key: String) -> String { said[key] ?? "" }
        let number = Double(v("home_free_kb")).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let command = v("command")
        let running: BackendServersSigninState = command.isEmpty || status.isEmpty ? .unknown : status.range(of: #"host:\s*not running"#, options: [.regularExpression, .caseInsensitive]) != nil ? .no : .yes
        return .init(host: .init(command: command, version: v("version"), running: running, status: status, address: serverAddressOf(status), unit: v("unit"), linger: v("linger") == "yes", data: v("state") == "yes", dataDir: v("state_dir")),
                     room: .init(os: v("os").lowercased(), arch: v("arch"), libc: v("libc") == "musl" ? "musl" : "gnu", node: v("node"), npm: v("npm"), missingTools: v("tools").split(separator: " ").map(String.init), downloader: v("fetch"), canHash: !v("hash").isEmpty, canUnpack: v("tar") == "yes", homeFreeKb: number, systemdUser: v("systemd_user") == "yes"))
    }
    public static func usableNode(_ room: BackendServersHostRoom) -> Bool {
        !room.npm.isEmpty && (BackendServersSetupWire.capture(#"^v?(\d+)"#, room.node).flatMap(Int.init) ?? 0) >= 22
    }
    public static func whyNotHost(_ room: BackendServersHostRoom) -> String? {
        if room.os != "linux" && room.os != "darwin" { return "The headless host runs on Linux and macOS, and this server answered “\(room.os.isEmpty ? "nothing" : room.os)”. On Windows people install the desktop app instead." }
        if room.libc == "musl" { return "This server uses musl (Alpine or similar), and the Node project publishes no musl build — so there is no runtime to fetch for it. Install Node 22 or newer from the distribution (apk add --no-cache nodejs npm) and this becomes available." }
        if room.os == "linux", !room.missingTools.isEmpty { return "This server is missing the build tools a session’s pseudo terminal needs: \(room.missingTools.joined(separator: ", ")). node-pty ships no Linux binary, so it compiles during the install, and without a compiler that fails a minute in. Someone will need to add them first: sudo apt-get install -y \(room.missingTools.joined(separator: " "))" }
        if !usableNode(room) {
            if room.downloader.isEmpty { return "This server has no Node 22 or newer, and no curl or wget to fetch one with. Someone will need to add one of those first." }
            if !room.canHash { return "This server has no sha256 tool (sha256sum, shasum or openssl), and a Node runtime will not be unpacked here unverified. Install coreutils, or install Node 22 or newer yourself." }
            if !room.canUnpack { return "This server has no tar, so a Node runtime could not be unpacked here." }
        }
        if let free = room.homeFreeKb, free < 400 * 1024 { return "There is \(Int(floor(free / 1024 + 0.5))) MB free in your home folder on this server and this needs about 400 MB." }
        return nil
    }
    public static func hostConsequence(_ serverName: String, room: BackendServersHostRoom) -> String {
        let runtime = usableNode(room) ? "It uses the Node \(room.node) that is already there." : "This server has no Node 22 or newer, so an official Node build is fetched, checked against the checksum Node published for it, and unpacked into ~/.\(BackendSharedBrand.id)/runtime, where nothing else on this server uses it."
        return "Today a session on \(serverName) is an SSH shell this app holds open. It lives inside that connection: it ends when this app quits or the link drops, and only this computer can reach it.\n\nInstalling the host makes \(serverName) a machine in its own right. Its sessions keep running when this computer is closed, you can open them from your phone, and it joins the machines list instead of sitting apart as a server. \(runtime) It needs no administrator access, writes only inside your home folder, and can be removed again from here.\n\nThis computer is linked to it as part of the install, so there is nothing to type in afterwards. A code is only for a phone, and only when you ask for one.\n\n\(BackendSharedBrand.assistant) is not on it. That part of the app needs a window, and this host has none."
    }
    public static func hostLine(_ host: BackendServersHostOnServer) -> String {
        if host.command.isEmpty { return "Sessions here run over SSH. This server is not a machine of its own yet." }
        if host.version.isEmpty { return "The host is on this server and will not start." }
        if host.running == .no { return "The host \(host.version) is here and is not running." }
        if host.running == .unknown { return "The host \(host.version) is here. It would not say whether it is running." }
        return "The host \(host.version) is here and running."
    }
    public static func reachLine(_ host: BackendServersHostOnServer) -> String? {
        if host.command.isEmpty { return nil }
        if host.unit.isEmpty { return "It was not set up to start on its own, so it will not come back after this server reboots. Removing it and installing it again from here sets that up." }
        if !host.linger { return "It starts with this server, and stops when your last login on this server ends — running `sudo loginctl enable-linger $(id -un)` once on that server is what stops that." }
        return "It starts with this server and keeps running when you log out."
    }
    public static func removeConsequence(_ host: BackendServersHostOnServer, alsoData: Bool) -> String {
        let service = host.unit.isEmpty ? "" : " Its service is stopped and its unit file removed."
        let data = alsoData ? " Everything it stored on that server goes too — \(host.dataDir), which is the devices paired to it and the folders each of them may use. Any phone paired to this host will need pairing again." : " What it stored stays: \(host.dataDir) holds the devices paired to it and the folders each of them may use, so a later install finds them again. Tick the box to remove that as well."
        return "This removes the host program and, if this app fetched one, the private Node runtime beside it.\(service)\(data) This app’s own record of the machine is separate — forget it under Machines if you want that gone too."
    }
    public static func hostUpdateAvailable(_ host: BackendServersHostOnServer, mine: String) -> String? {
        func version(_ raw: String) -> [Int]? {
            var text = BackendServersSetupWire.trim(raw); if text.hasPrefix("v") { text.removeFirst() }
            let parts = text.components(separatedBy: ".")
            guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0.range(of: #"^\d+$"#, options: .regularExpression) != nil }) else { return nil }
            let numbers = parts.compactMap(Int.init); guard numbers.count == parts.count else { return nil }; return numbers + Array(repeating: 0, count: 3 - numbers.count)
        }
        guard !host.command.isEmpty, let there = version(host.version), let here = version(mine) else { return nil }
        for i in 0..<3 where there[i] != here[i] { return there[i] < here[i] ? mine : nil }; return nil
    }
    public static func shellQuote(_ value: String) -> String { BackendServersSetupWire.quote(value) }
}
