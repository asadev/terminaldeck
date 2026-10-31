import AppKit
import Foundation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

extension FIXESTaskWritingProof {
    init?(json: [String: Any]) {
        guard TasksJSON.isTrue(json["busy"]),
              let task = (json["taskID"] ?? json["taskId"]) as? String, !task.isEmpty,
              let agent = (json["agentID"] ?? json["agentId"]) as? String, !agent.isEmpty,
              let turn = (json["turnID"] ?? json["turnId"]) as? String, !turn.isEmpty,
              let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.init(taskID: task, agentID: agent, turnID: turn, name: name,
                  icon: AGTIcon.parse(json["icon"] as? String) ?? .symbol("person.crop.square"),
                  isHoot: agent == "hoot")
    }
}

/// A real transport in the app, an injected backend/receipt in tests. Construction
/// performs no app lookup, engine start, session launch or network request.
@MainActor struct NativeFIXESTaskThreadTransport {
    let invoke: @MainActor (String, [NativeRPCValue]) async throws -> NativeRPCValue
    let observe: @MainActor (@escaping @MainActor () -> Void) -> NativeFIXESTaskThreadCancel
    static let live = Self(invoke: { function, values in
        let raw = try await EngineBridge.shared.invoke("tasks:local-detail", [function, NativeRPCValue.array(values).foundation])
        return try NativeRPCValue.fromFoundation(raw)
    }, observe: { changed in
        let subscription = EngineBridge.shared.on("tasks:changed") { _ in Task { @MainActor in changed() } }
        return .init { subscription.cancel() }
    })
}
@MainActor struct NativeFIXESTaskThreadCancel {
    let cancel: @MainActor () -> Void
}

/// No profile colour becomes an avatar background. Chosen emoji can be supplied
/// by the common kit; the fallback remains neutral initials/monoline glyph.
struct NativeFIXESCommentAvatar: View {
    let name: String
    let hoot: Bool
    var glyph = "person"
    var glyphColor: Color = .secondary
    var body: some View {
        AgentAvatar(icon: .symbol(glyph), size: 26, tint: glyphColor, hoot: hoot)
        .accessibilityHidden(true)
    }
}
import Foundation

/// A recipient that has a comment and has not answered yet (#109 "is writing").
struct FIXESWritingCandidate: Equatable, Sendable {
    let agentID: String
    let name: String
    let sessionID: String?
    init?(json: [String: Any]) {
        guard let agent = json["agentID"] as? String, !agent.isEmpty else { return nil }
        agentID = agent
        name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (agent == "hoot" ? "Hoot" : agent)
        sessionID = (json["sessionID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct FIXESCommentDelivery: Equatable, Sendable {
    public enum State: String, Sendable { case sent, delivered, seen, answered, failed }
    public let state: State
    public let agentID: String
    public let agentName: String
    public let deliveredAt: Double?
    public let seenAt: Double?
    public let reason: String?
    /// Saved and handed to the task, waiting for the worker to start.
    public let waiting: Bool
    public init?(json: [String: Any]) {
        guard let name = json["agentName"] as? String, let id = json["agentID"] as? String,
              let raw = json["state"] as? String, let state = State(rawValue: raw) else { return nil }
        self.state = state; agentID = id; agentName = name
        deliveredAt = (json["deliveredAt"] as? NSNumber)?.doubleValue
        seenAt = (json["seenAt"] as? NSNumber)?.doubleValue
        reason = json["error"] as? String
        waiting = (json["waiting"] as? Bool) == true
    }
    public var message: String {
        switch state {
        case .sent: return waiting ? "\(agentName) isn't running yet — it gets this when it starts…" : "Sending…"
        case .delivered: return "Delivered to \(agentName)"
        case .seen, .answered:
            guard let seenAt else { return "Delivered to \(agentName) · seen" }
            return "Delivered to \(agentName) · seen " + Date(timeIntervalSince1970: seenAt / 1000).formatted(date: .omitted, time: .shortened)
        case .failed: return "Couldn't reach \(agentName)."
        }
    }
}
