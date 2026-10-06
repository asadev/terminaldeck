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

/// The words, for a Mac (`platform.ts`: "Mac", "macOS"; `brand.ts`: "Terminal Deck").
public enum PowerWords {
    public static let title = "Power"
    public static let blurb = "Keep this machine running when you close it."

    public static func rowLabel(hasLid: Bool) -> String {
        hasLid ? "Keep running with the lid closed" : "Keep this Mac from going to sleep"
    }

    /// `lidAwakeHelp`.
    public static func help(hasLid: Bool) -> String {
        let what = hasLid
            ? "Close the lid and the screen goes off while this Mac keeps running — every session, every process. "
            : "This Mac has no lid to close, so this simply stops it going to sleep on its own — every session, every process keeps running. "
        return what + "This changes a setting on the machine itself, not just in this app, so it stays that way until it is turned off here. "
            + "macOS asks for your password the first time, and again if you turn it off."
    }

    /// `lidAwakeCaution`.
    public static func caution(hasLid: Bool) -> String? {
        guard hasLid else { return nil }
        return "A closed lid means no airflow, so this Mac will run hotter than usual. "
            + "On battery it will keep draining until it is flat — nothing here will stop it, and the app will say so rather than turning itself off behind your back."
    }

    /// `idleBlockedNote`: nil while the switch is on (it would contradict it).
    public static func idleBlocked(hasLid: Bool, lidAwake: Bool?) -> String? {
        if lidAwake == true { return nil }
        let held = "While Terminal Deck is open, this Mac will not fall asleep on its own."
        guard lidAwake != nil else { return held }
        return "\(held) \(hasLid ? "Closing the lid or choosing Sleep still does." : "Choosing Sleep still does.")"
    }

    /// `unknownStateNote`.
    public static let unknownState = "This Mac did not report this setting, so the app cannot say whether it is on."

    public static func changing(needsAuthorization: Bool) -> String {
        needsAuthorization
            ? "Waiting for macOS — its password box is on screen, and this will not finish until it is answered or dismissed."
            : "Asking macOS to change it…"
    }

    public static let unwired = "This build has no way to read or change that setting yet."
    public static let cannotHold = "The app cannot hold this Mac awake through a lid close."
    public static let preexisting = "This was already on before the app started. It is a setting on the Mac and survives a quit, so it is usually this app's own last run — though a terminal or another app can set it too."
    public static let readFailed = "The app could not read this machine’s sleep setting."
    public static let changeFailed = "That change could not be made."
    public static let cautionTitle = "Heat and battery"
}
