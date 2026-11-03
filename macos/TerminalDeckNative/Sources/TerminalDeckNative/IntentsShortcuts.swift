import AppIntents
import Observation
import TerminalDeckNativeCore

// Siri / Shortcuts (lane R): the phrases Siri listens for, with no setup.
//
// The phrases must be literals here (the build reads them out of this file into
// `Metadata.appintents`); `IntentPhrases` in Core holds the same strings, and
// `build-app.sh` fails the build when the two disagree. `.applicationName` is
// the app's name or one of its alternatives (`INAlternativeAppNames` in
// Info.plist: "Terminal Deck"), so "Ask Terminal Deck" works.

struct TerminalDeckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHootIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask Hoot in \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Ask \(.applicationName) something",
            ],
            shortTitle: "Ask Hoot",
            systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(
            intent: WhatNeedsMeIntent(),
            phrases: [
                "What needs me in \(.applicationName)",
                "What needs my attention in \(.applicationName)",
                "What's waiting for me in \(.applicationName)",
                "Check \(.applicationName)",
            ],
            shortTitle: "What Needs Me",
            systemImageName: "bell.badge")
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Add a task to \(.applicationName)",
                "New \(.applicationName) task",
            ],
            shortTitle: "Add Task",
            systemImageName: "checklist")
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: [
                "Start a session in \(\.$project) with \(.applicationName)",
                "Start a \(.applicationName) session in \(\.$project)",
                "Start a \(.applicationName) session",
            ],
            shortTitle: "Start Session",
            systemImageName: "terminal")
        AppShortcut(
            intent: OpenTerminalDeckIntent(),
            phrases: [
                "Show \(.applicationName)",
                "Bring up \(.applicationName)",
            ],
            shortTitle: "Open Terminal Deck",
            systemImageName: "macwindow")
        AppShortcut(
            intent: GoalStatusIntent(),
            phrases: [
                "How is \(\.$goal) going in \(.applicationName)",
                "Goal status in \(.applicationName)",
                "Check my goal in \(.applicationName)",
            ],
            shortTitle: "Goal Status",
            systemImageName: "flag")
        // Last on purpose: the metadata reader gives every shortcut after an
        // `if #available` block that block's availability too.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            AppShortcut(
                intent: OpenProjectIntent(),
                phrases: [
                    "Open \(\.$target) in \(.applicationName)",
                    "Show \(\.$target) in \(.applicationName)",
                ],
                shortTitle: "Open Project",
                systemImageName: "folder")
        }
        #else
        AppShortcut( // an older SDK: the plain intent (IntentsActions.swift), on every macOS
            intent: OpenProjectIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Show \(\.$target) in \(.applicationName)",
            ],
            shortTitle: "Open Project",
            systemImageName: "folder")
        #endif
    }

    static let shortcutTileColor: ShortcutTileColor = .grayBlue
}

/// Keeps Siri's list of project names current, so "Start a session in shop"
/// knows "shop". Called once from `applicationDidFinishLaunching`; after that it
/// follows the sidebar's projects (an event, no timer).
@MainActor
enum IntentsLaunch {
    private static var started = false
    private static var lastProjects: [String]?

    static func start() {
        guard !started else { return }
        started = true
        follow()
    }

    private static func follow() {
        let projects = withObservationTracking {
            (AppModel.shared.sidebar?.projects ?? []).map(\.id).filter { $0.hasPrefix("/") }
        } onChange: {
            Task { @MainActor in IntentsLaunch.follow() }
        }
        guard projects != lastProjects else { return }
        lastProjects = projects
        TerminalDeckShortcuts.updateAppShortcutParameters()
    }
}
