import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Walk 1 (7 Oct 2026): a copy of the app pulled itself in front of the app the
// person was typing in, and their keys changed its Settings. The app may take
// the front only for the person's own press; nothing else raises a window.

@Test func theFrontIsTakenOnlyForThePersonsOwnPress() {
    // Already in front: nothing is taken.
    #expect(NativeFrontPolicy.mayTakeFront(appIsActive: true, currentInput: .none, secondsSinceLastPress: nil))
    // Their click or key, now or a moment ago (a page click that arrives as a message).
    #expect(NativeFrontPolicy.mayTakeFront(appIsActive: false, currentInput: .press, secondsSinceLastPress: nil))
    #expect(NativeFrontPolicy.mayTakeFront(appIsActive: false, currentInput: .none, secondsSinceLastPress: 0.4))
    // Another app in front and no press here: a hover, a scroll, an Accessibility action,
    // a timer, a page or channel request — never.
    #expect(!NativeFrontPolicy.mayTakeFront(appIsActive: false, currentInput: .other, secondsSinceLastPress: nil))
    #expect(!NativeFrontPolicy.mayTakeFront(appIsActive: false, currentInput: .none, secondsSinceLastPress: nil))
    #expect(!NativeFrontPolicy.mayTakeFront(appIsActive: false, currentInput: .other, secondsSinceLastPress: 1.6))
    #expect(!NativeFrontPolicy.mayTakeFront(appIsActive: false, currentInput: .none, secondsSinceLastPress: 60))
    #expect(!NativeFrontPolicy.mayTakeFront(appIsActive: false, currentInput: .none, secondsSinceLastPress: -1))
}

/// Every call in the app that raises a window or activates the app is gated by
/// NativeFront, or names why it is the person's own request (`front-ok:`).
/// Comment lines are skipped, so a comment that names a call is not a use.
@Test func everyWindowRaisingCallIsGatedOrNamesThePerson() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckNative", isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "NativeCompositionFront.swift" }
    #expect(files.count > 50)
    var ungated: [String] = []
    for file in files {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("///") { continue }
            let code = raw.components(separatedBy: "//").first ?? raw
            let raises = NativeFrontPolicy.raisingCalls.contains { code.contains($0) }
            // `let open = openWindow` hands the opener on: the next lines must gate its use.
            let alias = code.contains("= openWindow")
            guard raises || alias else { continue }
            let window = lines[index...min(lines.count - 1, index + (alias ? 2 : 0))].joined(separator: "\n")
            if raw.contains(NativeFrontPolicy.allowMarker) || window.contains("NativeFront.") { continue }
            ungated.append(file.lastPathComponent + ":\(index + 1): " + trimmed)
        }
    }
    #expect(ungated.isEmpty, Comment(rawValue: "Ungated window-raising calls:\n" + ungated.joined(separator: "\n")))
}

// Who brought the app forward (walk 1: he was typing in another app when it took the keyboard).
@Test func anActivationIsThePersonsOnlyForTheirOwnGesture() {
    typealias F = NativeFrontPolicy.ActivationFacts
    let long = 600.0
    // Plain typing in another app is never the person, however recent.
    #expect(NativeFrontPolicy.activationReason(F(secondsSinceLaunch: long)) == nil)
    #expect(NativeFrontPolicy.activationReason(F(secondsSinceLaunch: long, secondsSinceClick: 0.1, clickOwner: .other)) == nil)
    // ⌘-Tab: Command held as it came forward.
    #expect(NativeFrontPolicy.activationReason(F(secondsSinceLaunch: long, commandHeld: true)) == "⌘-Tab")
    // A click on the Dock (or Stage Manager / Mission Control) just now.
    #expect(NativeFrontPolicy.activationReason(F(secondsSinceLaunch: long, secondsSinceClick: 0.2, clickOwner: .dock)) == "a click on the Dock")
    #expect(NativeFrontPolicy.activationReason(F(secondsSinceLaunch: long, secondsSinceClick: 4, clickOwner: .dock)) == nil)
    // A click on one of the app's own windows (its press monitor saw it).
    #expect(NativeFrontPolicy.activationReason(F(secondsSinceLaunch: long, secondsSincePressInApp: 0.1)) == "a press in the app")
    #expect(NativeFrontPolicy.activationReason(F(secondsSinceLaunch: long, secondsSincePressInApp: 30)) == nil)
    // The reopen Apple event (Dock icon, Spotlight, a launcher), Siri, a notification click.
    #expect(NativeFrontPolicy.activationReason(F(secondsSinceLaunch: long, expected: "reopen")) == "reopen")
    // Launch: a foreground launch's own activation; a background launch only in its first second.
    #expect(NativeFrontPolicy.activationReason(F(launchedInFront: true, secondsSinceLaunch: 3)) == "launch")
    #expect(NativeFrontPolicy.activationReason(F(launchedInFront: false, secondsSinceLaunch: 3)) == nil)
    #expect(NativeFrontPolicy.activationReason(F(launchedInFront: false, secondsSinceLaunch: 0.4)) == "launch")
}

// Verify run, 7 Oct: a background launch must still show the main window, just not in front.
@Test func aBackgroundLaunchStillShowsTheMainWindowWithoutActivating() {
    typealias R = NativeLaunchWindowRule
    // Background launch, SwiftUI made no window yet: open it.
    #expect(R.action(mainExists: false, mainVisible: false, mainMiniaturized: false, appActive: false, appHidden: false, terminating: false) == .open)
    // Made but never ordered in, app not active: ordered in behind the person's work, not activated.
    #expect(R.action(mainExists: true, mainVisible: false, mainMiniaturized: false, appActive: false, appHidden: false, terminating: false) == .orderBack)
    // The app is in front already: in front.
    #expect(R.action(mainExists: true, mainVisible: false, mainMiniaturized: false, appActive: true, appHidden: false, terminating: false) == .orderFront)
    // Already showing, minimised by the person, the app hidden by the person, or quitting: leave it.
    #expect(R.action(mainExists: true, mainVisible: true, mainMiniaturized: false, appActive: false, appHidden: false, terminating: false) == .none)
    #expect(R.action(mainExists: true, mainVisible: false, mainMiniaturized: true, appActive: false, appHidden: false, terminating: false) == .none)
    #expect(R.action(mainExists: true, mainVisible: false, mainMiniaturized: false, appActive: false, appHidden: true, terminating: false) == .none)
    #expect(R.action(mainExists: false, mainVisible: false, mainMiniaturized: false, appActive: false, appHidden: false, terminating: true) == .none)
}
