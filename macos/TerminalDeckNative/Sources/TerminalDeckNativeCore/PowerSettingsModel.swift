import Foundation

// Settings → Power (`settings/sections/PowerSection.tsx`): keep this machine
// running with the lid closed — a setting on the machine itself, read and changed
// over `power:lid-awake:get` / `:set`, pushed on `power:lid-awake:state`.

public struct LidAwakeBattery: Equatable, Sendable {
    public let present: Bool
    public let discharging: Bool
    public let percent: Double?
}

/// `LidAwakeState`, narrowed pessimistically: anything not literally `true` is "cannot say".
public struct LidAwakeState: Equatable, Sendable {
    public let supported: Bool
    public let on: Bool
    public let known: Bool
    public let needsAuthorization: Bool
    public let preexisting: Bool
    public let battery: LidAwakeBattery?
    public let detail: String?
    public let warning: String?
    public let idleBlocked: Bool

    public static func decode(_ raw: Any?) -> LidAwakeState? {
        guard let record = raw as? [String: Any] else { return nil }
        func flag(_ key: String) -> Bool { TerminalJSON.bool(record[key]) == true }
        let battery = (record["battery"] as? [String: Any]).map {
            LidAwakeBattery(present: TerminalJSON.bool($0["present"]) == true, discharging: TerminalJSON.bool($0["discharging"]) == true,
                            percent: TerminalJSON.number($0["percent"]))
        }
        return LidAwakeState(supported: flag("supported"), on: flag("on"), known: flag("known"),
                             needsAuthorization: flag("needsAuthorization"), preexisting: flag("preexisting"),
                             battery: battery, detail: TerminalJSON.text(record["detail"]), warning: TerminalJSON.text(record["warning"]),
                             idleBlocked: flag("idleBlocked"))
    }

    /// No battery reading at all, or a battery that is present: a machine with a lid.
    public var hasLid: Bool { battery == nil || battery?.present != false }
}

/// `LidAwakeResult`.
public struct LidAwakeResult: Equatable, Sendable {
    public enum Outcome: String, Sendable { case changed, unchanged, cancelled, failed, unsupported }
    public let outcome: Outcome
    public let state: LidAwakeState?
    public let message: String

    public init(outcome: Outcome, state: LidAwakeState?, message: String) {
        self.outcome = outcome
        self.state = state
        self.message = message
    }

    public static func decode(_ raw: Any?) -> LidAwakeResult {
        let record = raw as? [String: Any]
        return LidAwakeResult(outcome: (record?["outcome"] as? String).flatMap(Outcome.init(rawValue:)) ?? .failed,
                              state: LidAwakeState.decode(record?["state"]),
                              message: TerminalJSON.text(record?["message"]) ?? "The change finished without saying what happened.")
    }

    /// The notice's tone: news for a change or a no-op, a warning otherwise.
    public var isWarning: Bool { outcome != .changed && outcome != .unchanged }
}

/// The words the Power row in General uses, for a Mac.
public enum PowerWords {
    public static let title = "Keep this Mac awake"
    public static let detail = "While on, this Mac never sleeps. Screens may turn off; your phone wakes them when you open the screen view. An approved access helper keeps the Mac awake after a restart, before sign-in or opening the app."
    /// `lidAwakeCaution`.
    public static func caution(hasLid: Bool) -> String? {
        guard hasLid else { return nil }
        return "A closed lid means no airflow, so this Mac will run hotter than usual. "
            + "On battery it will keep draining until it is flat — nothing here will stop it, and the app will say so rather than turning itself off behind your back."
    }
    public static let readFailed = "The app could not read this machine’s sleep setting."
    public static let changeFailed = "That change could not be made."
}
