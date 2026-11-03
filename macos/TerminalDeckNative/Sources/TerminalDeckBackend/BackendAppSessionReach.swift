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
