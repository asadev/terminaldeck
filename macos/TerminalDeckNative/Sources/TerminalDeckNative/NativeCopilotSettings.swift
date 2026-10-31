import AppKit
import SwiftUI
import TerminalDeckNativeCore

// SETTINGS-TRUTH row 105 (12 Oct): the old Settings › Hoot page could no longer be reached and was removed. Its
// "Reset Hoot…" lives on Hoot's profile (HootProfileView). The section's state model below is Hoot's profile's.

// MARK: - The section's state

@MainActor @Observable
final class CopilotSettingsPageModel {
    typealias Invoke = @MainActor (String, [Any?]) async throws -> CodingAIJSON
    var state: CopilotState?
    var signIn: CopilotSignIn?
    var memory: CopilotMemoryReport?
    var actions: CopilotActionLog?
    var routines: [CopilotRoutine]?
    var interactive: Bool?
    var identity = CopilotIdentity()
    /// `useCopilotSetup`'s status: whether the questions have been answered once.
    var setUp: Bool?
    var loading = true
    var busy: String?
    var status: String?
    var problem: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let invoke: Invoke
    @ObservationIgnored private let live: Bool

    init(live: Bool = true, invoke: @escaping Invoke = { channel, args in
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }) {
        self.live = live; self.invoke = invoke
    }

    func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        try await invoke(channel, args)
    }

    /// Read everything again; an answer from an older read is dropped.
    func load() {
        guard live else { return }
        generation += 1
        let mine = generation
        loading = true
        problem = nil
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard generation == mine, loading else { return }
            generation += 1; loading = false
            problem = "Hoot's settings took too long to read. Try Again."
        }
        Task {
            async let state = try? call("hoot:state")
            async let memory = try? call("hoot:memory")
            async let actions = try? call("hoot:actions", [200])
            async let routines = try? call("routines:list")
            async let settings = try? call("settings:get")
            async let instructions = try? call("hoot:read-instructions")
            let read = await (state, memory, actions, routines, settings, instructions)
            guard mine == generation else { return }
            if let raw = read.0 { self.state = CopilotState.from(raw) } else {
                problem = "Could not read \(CopilotWords.assistant)’s state."
            }
            self.memory = read.1.flatMap(CopilotMemoryReport.from)
            self.actions = read.2.flatMap(CopilotActionLog.from)
            self.routines = read.3.map(CopilotRoutine.list)
            self.interactive = read.4.map(CopilotShowing.interactive)
            if let raw = read.5 {
                if case .text(let text, _) = CopilotInstructionsRead.from(raw) {
                    let reading = CopilotIdentity.read(text)
                    identity = reading.identity
                    setUp = reading.ran
                } else {
                    identity = CopilotIdentity()
                    setUp = false
                }
            } else {
                setUp = true
            }
            loading = false
        }
    }

    /// `act`: one thing at a time; its sentence is shown, then everything is read again.
    func act(_ key: String, _ work: @escaping @MainActor () async throws -> String?) {
        guard busy == nil else { return }
        busy = key
        status = nil
        Task {
            do { status = try await work() } catch { status = CodingAIErrorText.from(error, fallback: "That did not work.") }
            busy = nil
            load()
        }
    }

    func reveal(_ place: String) {
        act("reveal:\(place)") { [self] in CopilotReveal.message(try await call("hoot:reveal", [place])) }
    }

    /// "Set it up…": the main window opens the questions (the page's `set-up-copilot`).
    /// The person asked, so an earlier "not now" no longer holds them back.
    func setUpCopilot() {
        HootSetupMemory.askAgain()
        _ = NativeCodingAIPages.evaluate(CodingAIPageScripts.relay(.object(["type": .string("set-up-copilot")])), in: .settings)
    }
}

// MARK: - Shared parts

/// `Block`: a group's title with its ⓘ, and the one line under it.
struct CopilotBlock<Content: View>: View {
    let title: String
    let says: String
    var more: String?
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            content
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(title)
                    if let more { NativeCodingAIInfo(label: title, text: more) }
                }
                Text(says)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// `settings-badge`: a word beside a row's label; quiet ones are grey.
struct CopilotBadge: View {
    let text: String
    var quiet = false
    var body: some View { NativeCodingAIBadge(text: text, quiet: quiet) }
}

/// `settings-path-row`: label and badges, lines under it, buttons on the right.
struct CopilotPathRow<Main: View, Actions: View>: View {
    @ViewBuilder let main: Main
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) { main }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) { actions }
                .fixedSize()
        }
    }
}

struct CopilotLabel: View {
    let text: String
    var badges: [(text: String, quiet: Bool)] = []
    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in CopilotBadge(text: badge.text, quiet: badge.quiet) }
        }
    }
}

struct CopilotHelp: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}

struct CopilotPath: View {
    let path: String
    var body: some View {
        Text(path)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
    }
}

// MARK: - 1. Its session

/// `FolderRow`: where it works — this app's folder or one of yours.
struct CopilotFolderRow: View {
    let model: CopilotSettingsPageModel

    var body: some View {
        let folder = model.state?.folder
        let chosen = folder != nil && folder?.isDefault == false
        let shown = folder?.home ?? model.state?.paths.root ?? "—"
        CopilotPathRow {
            CopilotLabel(text: "Its folder", badges: folder == nil ? [] : [(chosen ? "yours" : "this app’s", !chosen)])
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CopilotHelp(chosen
                    ? "You pointed it at a folder of your own. It reads that folder’s own instructions and its memory the same way any session you start there would — and this app writes nothing into it."
                    : "A folder this app made for it. Point it at one of your own and it picks up whatever assistant already lives there.")
                NativeCodingAIInfo(label: "choosing a folder", text: CopilotFolderWords.choosing)
            }
            CopilotPath(path: shown)
            if let folder, let problem = folder.problem {
                ROUTINESNotice(tone: .warn, text: "\(folder.chosen.map { "\($0) — " } ?? "")\(problem) It is running in \(folder.home) instead.")
            }
            if let folder, folder.restartNeeded {
                ROUTINESNotice(tone: .info, text: "\(CopilotWords.assistant) is still working in \(folder.runningIn ?? "") for now. \(CopilotFolderWords.needsRestart)")
            }
        } actions: {
            Button("Open") { model.reveal("root") }
            Button(model.busy == "folder-pick" ? "Choosing…" : "Choose a folder…") {
                model.act("folder-pick") { [model] in
                    let result = CopilotFolderChange.from(try await model.call("hoot:folder:pick"))
                    if result.cancelled { return nil }
                    if let problem = result.problem { return problem }
                    guard let folder = result.folder else { return "The folder could not be changed." }
                    return "\(CopilotWords.assistant) will start in \(folder.home). \(CopilotFolderWords.needsRestart)"
                }
            }
            .disabled(model.busy != nil || model.loading)
            if chosen {
                Button("Use this app’s folder") {
                    model.act("folder-clear") { [model] in
                        let result = CopilotFolderChange.from(try await model.call("hoot:folder:clear"))
                        guard let folder = result.folder else { return "That did not work." }
                        return "Back to \(folder.home). Nothing was moved out of the folder you had chosen. \(CopilotFolderWords.needsRestart)"
                    }
                }
                .disabled(model.busy != nil)
            }
        }
    }
}
