import Foundation
import TerminalDeckNativeCore

public struct BackendMacAppSetupContextInput: Sendable {
    public let version: String, machineName: String
    public let opensInApp: Bool
    public init(version: String, machineName: String, opensInApp: Bool) { self.version = version; self.machineName = machineName; self.opensInApp = opensInApp }
}
public struct BackendMacAppSetupContextWritten: Sendable {
    public let dir: String, index: String, files: [String], map: String
}
public protocol BackendMacAppSetupContextIO: Sendable {
    func ensureDirectory(_ directory: String) async throws
    func writeAtomically(_ file: String, text: String) async throws
}
public struct BackendMacAppSetupLocalContextIO: BackendMacAppSetupContextIO, Sendable {
    public init() {}
    public func ensureDirectory(_ directory: String) async throws { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
    public func writeAtomically(_ file: String, text: String) async throws { try BackendAccountFiles.writeAtomic(Data(text.utf8), to: URL(fileURLWithPath: file)) }
}
public enum BackendMacAppSetupContextPages {
    public static let directoryName = "context", indexFile = "INDEX.md"
    public static let fileNames = ["INDEX.md", "sessions-and-machines.md", "browser-windows.md"]
    public static func contextDir(_ root: String) -> String { NativePlatformPaths.join(platform: .darwin, [root, directoryName]) }
    public static func mapText(version: String, machine: String, directory: String) -> String {
        let separator = directory.contains("\\") ? "\\" : "/"
        return "It is version \(version), running on \(machine). What else is true of this app is written in files on this machine. \(directory)\(separator)\(indexFile) is a short index naming which of them answers what — read it when a question about this app comes up, and not before."
    }
    public static func preamble(_ version: String) -> String { "<!-- Written by Terminal Deck \(version) at every start. Do not edit: this file is\nrewritten on the next launch, so a change here would look permanent and be lost. -->" }
    /// The reasons come from the session-verbs owner; no copied reason table.
    /// Remote composition is pure Mac-side SSH payload preparation, not a Linux
    /// server implementation. It never writes to the other computer.
    public static func compose(_ input: BackendMacAppSetupContextInput, directory: String?, remoteAppMachine: String? = nil,
                               noVerbsReasons: [String]) -> [(name: String, text: String)] {
        typealias T = BackendMacAppSetupContextTemplates
        let ssh = remoteAppMachine != nil, appMachine = remoteAppMachine ?? "", intro = preamble(input.version)
        let opener = input.opensInApp ? "`open <url>` inside a session opens a window in this app. See `browser-windows.md`." : ssh ? "`open` inside this session is this server's own opener; this app could not put its own on this shell's PATH." : "`open` inside a session is the machine's own opener; this build does not shim it here."
        let machine = ssh ? "\(input.machineName) — a server this app is signed in to over SSH from \(appMachine)" : "\(input.machineName) (macOS)"
        let index = T.render("index", [intro, "Terminal Deck", input.version, machine, directory.map { "\n- This directory: \($0)" } ?? "", opener])
        let sessionIntro = ssh ? T.render("sshSession", ["Terminal Deck"]) : T.render("localSession", ["Terminal Deck", "TERMINALDECK_SESSION_ID"])
        let hookTransport = T.render(ssh ? "sshHooks" : "localHooks", ["terminaldeck"])
        let hostLocation = ssh ? "This session is running on \(input.machineName), and the app — with its screen, its browser windows and the person reading this — is on \(appMachine)." : "This session is running on \(input.machineName)."
        let sessions = T.render("sessions", [intro, sessionIntro, hookTransport, "Terminal Deck", hostLocation])
        let opening = input.opensInApp ? T.render("openingShim", [ssh ? "this server's" : "the machine's", ssh ? ", on \(appMachine)," : "", ssh ? "this server" : "the machine"]) : ssh ? T.render("openingSSH", []) : T.render("openingBare", ["macOS"])
        let clauses = noVerbsReasons.map { clause in "- " + String(clause.prefix(1)).uppercased() + String(clause.dropFirst()) + "." }.joined(separator: "\n")
        let driving = T.render("driving", [T.render(ssh ? "whichSSH" : "whichLocal", []), ssh ? "" : T.render("without", [clauses]), input.opensInApp && !ssh ? T.render("drivingOpener", []) : "", T.render(ssh ? "closingSSH" : "closingLocal", [])])
        let browser = T.render("browser", [intro, "Terminal Deck", ssh ? ", on \(appMachine)" : "", opening, driving])
        return [(indexFile, index), ("sessions-and-machines.md", sessions), ("browser-windows.md", browser)]
    }
}
/// Only the generated-document metadata and the source BeforeAgent latch.
/// The retained native composition root owns this one instance and the existing
/// session/hook/lifecycle owners call it; it starts no session or hook listener.
public actor BackendMacAppSetupContext {
    public static let mapEvents: Set<String> = ["SessionStart", "BeforeAgent"]
    private var current: BackendMacAppSetupContextWritten?
    private var told: Set<String> = []
    private let io: any BackendMacAppSetupContextIO
    private let reasons: @Sendable () async throws -> [String]
    public init(io: any BackendMacAppSetupContextIO, noVerbsReasons: @escaping @Sendable () async throws -> [String]) { self.io = io; reasons = noVerbsReasons }
    public func currentAppContext() -> BackendMacAppSetupContextWritten? { current }
    public func write(paths: NativePlatformPaths, input: BackendMacAppSetupContextInput) async throws -> BackendMacAppSetupContextWritten {
        let directory = BackendMacAppSetupContextPages.contextDir(paths.userData), pages = BackendMacAppSetupContextPages.compose(input, directory: directory, noVerbsReasons: try await reasons())
        try await io.ensureDirectory(directory)
        var files: [String] = []
        for page in pages { let path = directory + "/" + page.name; try await io.writeAtomically(path, text: page.text); files.append(path) }
        let result = BackendMacAppSetupContextWritten(dir: directory, index: directory + "/INDEX.md", files: files, map: BackendMacAppSetupContextPages.mapText(version: input.version, machine: input.machineName, directory: directory))
        current = result; return result
    }
    public func bootMapFor(event: String, sessionID: String?, machineID: String = "", override: String? = nil) -> String? {
        guard let sessionID, let map = override ?? current?.map, Self.mapEvents.contains(event) else { return nil }
        if event != "BeforeAgent" { return map }
        let key = machineID + "\0" + sessionID
        guard told.insert(key).inserted else { return nil }; return map
    }
    public func resetForTests() { current = nil; told.removeAll() }
}

/// Existing hook-server and browser-binding owners supply their event policy
/// and standing context. This adapter adds only app-context's source map/latch.
public protocol BackendMacAppSetupHookContextDependencies: Sendable {
    func mayAnswer(provider: String, event: String) async throws -> Bool
    func isMidTurn(_ event: String) async throws -> Bool
    func announcement(sessionID: String, machineID: String) async throws -> String?
    func standingContext(sessionID: String?, machineID: String, map: String?) async throws -> String?
}
public struct BackendMacAppSetupHookContextAdapter: Sendable {
    private let context: BackendMacAppSetupContext
    private let existing: any BackendMacAppSetupHookContextDependencies
    public init(context: BackendMacAppSetupContext, existing: any BackendMacAppSetupHookContextDependencies) { self.context = context; self.existing = existing }
    public func answer(provider: String, event: String, sessionID: String?, machineID: String = "", override: String? = nil) async throws -> String? {
        guard try await existing.mayAnswer(provider: provider, event: event) else { return nil }
        if try await existing.isMidTurn(event) { guard let sessionID else { return nil }; return try await existing.announcement(sessionID: sessionID, machineID: machineID) }
        let map = await context.bootMapFor(event: event, sessionID: sessionID, machineID: machineID, override: override)
        return try await existing.standingContext(sessionID: sessionID, machineID: machineID, map: map)
    }
}
