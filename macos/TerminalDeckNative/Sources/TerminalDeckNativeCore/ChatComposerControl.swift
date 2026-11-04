import Foundation

/// The same control owns sending and interrupting. Background work has its own, narrower owner.
public enum ChatComposerControl: String, Sendable {
    case send, queue, stop, stopping

    public static func action(turnRunning: Bool, hasDraft: Bool, allowsQueue: Bool, stopping: Bool = false, canStop: Bool = true) -> Self {
        if stopping { return .stopping }
        if turnRunning && canStop && (!hasDraft || !allowsQueue) { return .stop }
        return allowsQueue && turnRunning && hasDraft ? .queue : .send
    }

    public var label: String {
        switch self {
        case .send: return "Send message"
        case .queue: return "Queue message"
        case .stop: return "Stop current answer"
        case .stopping: return "Stopping current answer…"
        }
    }
}
