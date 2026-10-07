import Foundation

/// Leaf equivalent of agent-unavailable.ts; callers retain the provider id.
public struct BackendAppSessionAgentUnavailableError: Error, LocalizedError, Sendable {
    public let provider: String
    public let message: String
    public let name = "AgentUnavailableError"
    public init(provider: String, label: String, insideWSL: Bool = false) {
        self.provider = provider
        message = "\(label) could not be found \(insideWSL ? "inside the WSL distribution" : "on this machine"), so this session was not started."
    }
    public var errorDescription: String? { message }
}
public struct BackendAppSessionBoundary: Sendable, Equatable {
    public let folder: String
    public let readable: [String]
    public let readableFiles: [String]
    public let readableProjects: [String]
    public let platform = "darwin"
    public init(folder: String, readable: [String], readableFiles: [String], readableProjects: [String] = []) {
        self.folder = folder; self.readable = readable; self.readableFiles = readableFiles; self.readableProjects = readableProjects
    }
    public init(plan: BackendMacConfinement.Plan) {
        self.init(folder: plan.folder, readable: plan.writable + plan.readable,
                  readableFiles: plan.readableFiles, readableProjects: plan.readOnlyProjects)
    }
    public func allows(_ path: String) -> Bool {
        if readableFiles.contains(path) { return true }
        let asked = URL(fileURLWithPath: path).standardizedFileURL.path
        return readable.contains { root in
            let root = URL(fileURLWithPath: root).standardizedFileURL.path
            return asked == root || asked.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }
}
/// Informational attachment reachability. The kernel's actual fence stays in
/// BackendMacConfinement; absence means an ordinary unconstrained local tab.
public actor BackendAppSessionBoundaryRegistry {
    private var boundaries: [String: BackendAppSessionBoundary] = [:]
    public init() {}
    public func note(_ sessionID: String, plan: BackendMacConfinement.Plan) { boundaries[sessionID] = BackendAppSessionBoundary(plan: plan) }
    public func note(_ sessionID: String, boundary: BackendAppSessionBoundary) { boundaries[sessionID] = boundary }
    public func forget(_ sessionID: String) { boundaries[sessionID] = nil }
    public func boundary(for sessionID: String) -> BackendAppSessionBoundary? { boundaries[sessionID] }
}
public enum BackendAppSessionNoVerbsReason: String, CaseIterable, Sendable {
    case provider, wsl, device, endpoint, early
    public var because: String {
        switch self {
        case .provider: "this app can only add its browser verbs to a Claude session"
        case .wsl: "this app’s endpoint is on the Windows side and this session could not reach it from inside WSL"
        case .device: "the device that started this session cannot show a browser window"
        case .endpoint: "this app’s control endpoint is not running here"
        case .early: "this session started before this app’s control endpoint did, and the flag that carries them is read once at launch"
        }
    }
    public var then: String {
        switch self {
        case .wsl: "Tell the person to start this session again; if it still cannot, this distribution has Windows interop switched off, and `enabled = true` under `[interop]` in its `/etc/wsl.conf` is what lets this app reach in. Until then say what you would have done on the page and let them do it; there is no other way in."
        case .early: "Tell the person this session has to be started again before it can read a page in one of its own windows, and do not look for another way in."
        default: "Say what you would have done on the page and let the person do it; there is no other way in."
        }
    }
}
public actor BackendAppSessionVerbsRegistry {
    private var withheld: [String: BackendAppSessionNoVerbsReason] = [:]
    public init() {}
    public func note(_ sessionID: String, reason: BackendAppSessionNoVerbsReason) { if !sessionID.isEmpty { withheld[sessionID] = reason } }
    public func forget(_ sessionID: String) { withheld[sessionID] = nil }
    public func line(for sessionID: String) -> String? {
        withheld[sessionID].map { "You cannot read or act on what is in them from here — \($0.because). \($0.then)" }
    }
    public nonisolated static var reasons: [String] { BackendAppSessionNoVerbsReason.allCases.map(\.because) }
}
