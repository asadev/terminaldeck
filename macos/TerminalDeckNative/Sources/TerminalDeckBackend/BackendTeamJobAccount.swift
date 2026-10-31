import Foundation
import TerminalDeckNativeCore

/// 30 Oct (Decker, Asad: "fix all the problems you see for collaborations"): a seat's job started on this Mac's own
/// ("Default") Claude login while it was signed out, and answered only "Not logged in · Please run /login".
/// A job now starts on, in order:
///   1. the account the starter named for this job (refused plainly if it is signed out: an explicit choice is never
///      swapped behind the starter's back);
///   2. otherwise the account the seat's levels give (the agent's own → its seat → its project → the whole app →
///      this Mac's login), when that login is not definitely signed out;
///   3. otherwise the first signed-in account of the same AI in the person's account order (Settings › Accounts, the
///      order `profiles:list` gives).
/// No signed-in account at all: nothing starts, and the refusal says so. The pick always says which account and why.
public enum BackendTeamJobAccount {
    public struct Candidate: Equatable, Sendable {
        public let id: String, name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public struct Pick: Equatable, Sendable {
        public let id: String, name: String, why: String
        public var wire: NativeRPCValue {
            .object([.init("id", .string(id)), .init("name", .string(name)), .init("why", .string(why))])
        }
    }
    /// `state`: the sign-in reader ("signed-in", "signed-out", or anything else when it cannot be told). Only a definite
    /// "signed-out" passes an account over, the same rule the launch itself applies (BackendAccountLaunchAdapter).
    public static func choose(requested: Candidate?, assigned: Candidate, assignedSource: String,
                              candidates: [Candidate], state: @Sendable (String) async -> String?) async throws -> Pick {
        if let requested {
            guard await state(requested.id) != "signed-out" else {
                throw NativeRPCError.invalidArguments("The account \u{201C}\(requested.name)\u{201D} is signed out, so the job was not started. Sign in to it (Settings \u{203A} Coding AIs \u{203A} Sign in) or choose another account.")
            }
            return .init(id: requested.id, name: requested.name, why: "chosen for this job")
        }
        if await state(assigned.id) != "signed-out" {
            return .init(id: assigned.id, name: assigned.name, why: Self.sourceSentence(assignedSource))
        }
        for candidate in candidates where candidate.id != assigned.id {
            if await state(candidate.id) == "signed-in" {
                return .init(id: candidate.id, name: candidate.name,
                             why: "\u{201C}\(assigned.name)\u{201D} (\(Self.sourceSentence(assignedSource))) is signed out; first signed-in account in your account order")
            }
        }
        throw NativeRPCError.invalidArguments("No signed-in account was found for this AI (\u{201C}\(assigned.name)\u{201D}, \(Self.sourceSentence(assignedSource)), is signed out), so the job was not started. Sign in to an account in Settings \u{203A} Coding AIs.")
    }
    static func sourceSentence(_ source: String) -> String {
        switch source {
        case "session": "the agent's own account"
        case "seat": "the seat's account"
        case "project": "the project's account"
        case "app": "the whole app's account"
        default: "this Mac's own login"
        }
    }
}
