import SwiftUI
import TerminalDeckNativeCore

// Settings → Hoot: While it works, At the top of the screen, The action log, What it
// can reach (web: CopilotSection.tsx `ShowingGroup`, `MenuBarGroup`, `ActionsGroup`,
// `ActionRow`, `ReachGroup`).

struct CopilotShowingGroup: View {
    @Bindable var model: CopilotSettingsPageModel

    var body: some View {
        CopilotBlock(title: "While it works",
                     says: "Whether it takes you along when it looks through your sessions, or works quietly and answers.",
                     more: "With this on, it moves the window to whatever it is reading, boxes the exact words and dulls the rest — at machine speed, to watch rather than to read. The answer arrives in its chat either way; with it off, nothing on your screen moves.") {
            NativeSettingRow(label: "Show me what it is looking at",
                             help: model.interactive == nil
                                 ? "The settings file could not be read, so this cannot be changed here."
                                 : "It jumps to each session and highlights what it read. The answer is the same either way.") {
                Toggle("Show me what it is looking at", isOn: Binding(
                    get: { model.interactive ?? true },
                    set: { next in
                        model.interactive = next
                        model.problem = nil
                        Task {
                            do {
                                _ = try await model.call("settings:set", [[CopilotShowing.setting: next]])
                            } catch {
                                model.interactive = !next
                                model.problem = CodingAIErrorText.from(error, fallback: "That setting could not be saved.")
                            }
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.interactive == nil)
            }
        }
    }
}

/// Hoot in the middle of the menu bar.
struct CopilotMenuBarGroup: View {
    let model: CopilotSettingsPageModel
    @State private var enabled: Bool?
    @State private var wired = true

    var body: some View {
        if wired {
            CopilotBlock(title: "At the top of the screen",
                         says: "\(CopilotWords.assistant) in the middle of the menu bar, over every app. Hover it to talk.",
                         more: "Hover it, or click it, and it grows into a panel with the latest messages, a box to ask, and the sessions waiting on you. On a MacBook it sits around the notch, never behind it. When a session needs you it says so for a moment. It takes the keyboard only when you click it.") {
                NativeSettingRow(label: "Show \(CopilotWords.assistant) at the top of the screen", help: "Off takes it away until you turn it back on.") {
                    Toggle("Show \(CopilotWords.assistant) at the top of the screen", isOn: Binding(
                        get: { enabled ?? true },
                        set: { next in
                            let before = enabled
                            enabled = next
                            model.problem = nil
                            Task {
                                do {
                                    let raw = try await model.call("hoot-menubar:configure", [["enabled": next]])
                                    enabled = Self.read(raw) ?? before
                                } catch {
                                    enabled = before
                                    model.problem = CodingAIErrorText.from(error, fallback: "That setting could not be saved.")
                                }
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(enabled == nil)
                }
            }
            .task {
                do { enabled = Self.read(try await model.call("hoot-menubar:config")) } catch { wired = false }
            }
        }
    }

    /// `readMenuBar`: on unless it says false; nil when nothing readable came back.
    static func read(_ raw: CodingAIJSON) -> Bool? { raw.isObject ? raw["enabled"].bool != false : nil }
}

struct CopilotActionsGroup: View {
    let model: CopilotSettingsPageModel
    @State private var open = false
    @State private var all = false

    var body: some View {
        let rows = model.actions?.rows ?? []
        let shown = CopilotLogWords.shown(model.actions, all: all)
        CopilotBlock(title: "The action log", says: "Every tool call it made, what came back, and whether a human said yes.",
                     more: "Append-only, and kept outside \(CopilotWords.assistant)’s own folder on purpose — a record the audited party can compose is not a record. The app writes every line; \(CopilotWords.assistant)’s only way to add one is a log.note call, which is itself recorded.") {
            CopilotPathRow {
                CopilotLabel(text: "What it has done", badges: [(CopilotLogWords.badge(model.actions, loading: model.loading), true)])
                if let actions = model.actions { CopilotHelp(CopilotWords.logTrustLine(actions)) }
                if rows.isEmpty, !model.loading {
                    CopilotHelp(model.actions?.exists == true
                        ? "The file is there and has nothing in it yet."
                        : "Nothing has been recorded — \(CopilotWords.assistant) has done nothing yet.")
                }
            } actions: {
                Button(open ? "Hide" : "View") { open.toggle() }.disabled(rows.isEmpty)
                Button("Open the folder") { model.reveal("log") }
            }
            if open, !rows.isEmpty {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, row in CopilotActionRow(row: row) }
                if rows.count > shown.count {
                    Button("Show the other \(rows.count - shown.count)") { all = true }
                }
            }
        }
    }
}

/// `ActionRow`: when, which tool, its tier and outcome, the detail, and who said yes.
struct CopilotActionRow: View {
    let row: CopilotLoggedAction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(CopilotWords.whenIso(row.at))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.tool ?? row.action).font(.callout.monospaced())
                    if let tier = row.tier { CopilotBadge(text: tier, quiet: true) }
                    if row.outcome == .refused { CopilotBadge(text: "refused", quiet: true) }
                    if row.outcome == .error { CopilotBadge(text: "failed", quiet: true) }
                    if row.caller == "remote" { CopilotBadge(text: "from a paired device", quiet: true) }
                }
                CopilotHelp(row.detail.isEmpty ? "—" : row.detail)
                if let error = row.error { CopilotHelp(error) }
                CopilotHelp(CopilotLogWords.confirmLine(row))
            }
        }
    }
}

struct CopilotReachGroup: View {
    let model: CopilotSettingsPageModel

    var body: some View {
        let records = model.state?.records
        let fenceable = (records?.kind ?? "none") != "none"
        CopilotBlock(title: "What it can reach",
                     says: "Everything you can. It is an ordinary Terminal Deck session running as your account, not a sandboxed one.",
                     more: "It was confined once, and the jail made it worse at its job than the sessions it supervises: it started signed out and could not read a line of your code. What bounds it instead is the tool tiers, the confirmation you are shown, and the refusals below.") {
            VStack(alignment: .leading, spacing: 4) {
                CopilotLabel(text: "Reads and writes", badges: [("not sandboxed", true)])
                lineWithMore("Your home directory, your projects, your shell and your tools, your git and GitHub logins, your keychain, the network — the same as any session you open yourself.",
                             label: "what it can reach",
                             more: "Reading your code is what lets it look at the failing test instead of asking you to paste it; writing is what lets it fix a line rather than describe the fix. Anything that touches this app’s own state — your settings, your sessions, your routines — goes through a confirmation you see, whatever else is set.")
            }
            VStack(alignment: .leading, spacing: 4) {
                CopilotLabel(text: "Two kinds of prompt, and only one is ours")
                lineWithMore("The CLI it runs on asks you things too, and those prompts follow your settings for that CLI — not this app’s.",
                             label: "the CLI’s own prompts",
                             more: "They come before it runs a command or edits a file, exactly as in every other session you open, and they are governed by your own settings file for that CLI — on this machine, ~/.claude/settings.json. If you have set that to bypass them, \(CopilotWords.assistant) will not stop to ask either. This app does not change that setting in either direction.")
                lineWithMore("The confirmation this app shows you is a separate thing. Nothing in that settings file turns it off.",
                             label: "this app’s confirmation",
                             more: "It is asked by the desktop rather than by the CLI, before this app writes a setting, starts a session or changes a routine, over a request the agent cannot answer for itself — so nothing \(CopilotWords.assistant) says can wave itself through. With no window open to ask, it is refused rather than allowed.")
            }
            VStack(alignment: .leading, spacing: 4) {
                CopilotLabel(text: "Refused: this app’s own records", badges: [(CopilotLogWords.recordsBadge(records), records?.enforced != true)])
                lineWithMore("Five paths, and only five: its routines, the record of what it did, and the two files that decide which of your paired devices may reach it.",
                             label: "the five refused paths", more: CopilotLogWords.refusedMore(records))
                if let state = model.state { CopilotHelp(CopilotLogWords.recordsLine(state)) }
                if !fenceable {
                    CopilotHelp("Here it is a rule in its instructions rather than a refusal by the operating system. Its actions are still recorded; the record is not held against it.")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                CopilotLabel(text: "What it keeps from your other sessions")
                lineWithMore("It can read them, and is told never to keep anything out of them. Nothing on this machine enforces that.",
                             label: "its memory rule",
                             more: "Memory is the folder it loads at the start of every conversation, so a fact copied out of somebody else’s agent would be in its head in every future one. It is a rule written into its instructions in those words — not a wall — and the folder is one you can read and prune yourself.")
            }
        }
    }

    private func lineWithMore(_ text: String, label: String, more: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            CopilotHelp(text)
            NativeCodingAIInfo(label: label, text: more)
        }
    }
}
