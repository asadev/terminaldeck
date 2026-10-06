import SwiftUI
import TerminalDeckNativeCore

// Hoot's setup flow, drawn in Swift (lane B) — renderer/copilot/CopilotSetup.tsx.
// The page still decides when it opens (`openCopilot`, Settings → Hoot's "Set up")
// and what happens after (`showCopilot`); this sheet asks the four questions and
// writes the answers into Hoot's own instructions through the same engine channels
// the page's dialog used. Close answers "close"; finishing answers "done".

@MainActor
@Observable
final class NativeCopilotSetupModel {
    var step: CopilotSetupStep = .name
    var name = ""
    var callThem = ""
    var addressNote = ""
    var accountId: String?
    private(set) var folder: CopilotFolder?
    private(set) var busy = false
    private(set) var picking = false
    private(set) var problem: String?
    private(set) var snapshot: CodingAIAccountsSnapshot = .empty
    private(set) var signIns: [String: CodingAISignIn] = [:]
    private(set) var loadingAccounts = true

    var identity: CopilotIdentity { CopilotSetupRules.identity(name: name, callThem: callThem, addressNote: addressNote) }
    var accounts: [CodingAIAccount] { CopilotSetupRules.accounts(snapshot) }
    var chosen: CodingAIAccount? { accounts.first { $0.id == accountId } }
    var currentAccountId: String? { CopilotSetupRules.currentAccountId(snapshot, home: folder?.home) }
    var running: Bool { folder?.runningIn != nil }
    var answered: Bool { CopilotSetupRules.answered(step, identity: identity, folder: folder, accountChosen: chosen != nil) }
    var advanceLabel: String {
        busy ? CopilotSetupWords.saving
            : CopilotSetupWords.advanceLabel(step, answered: answered, identity: identity, running: running)
    }

    private func call(_ channel: String, _ args: [Any?] = [], timeout: TimeInterval? = nil) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args, timeout: timeout))
    }

    /// What it opens on: where it will work, what it is called now, and the accounts.
    func load() async {
        async let folderRaw = try? call("copilot:folder")
        async let instructionsRaw = try? call("copilot:read-instructions")
        async let profilesRaw = try? call("profiles:list")
        if let raw = await folderRaw { folder = CopilotFolder.from(raw) }
        if let raw = await instructionsRaw, case .text(let text, _) = CopilotInstructionsRead.from(raw) {
            let current = CopilotIdentity.read(text).identity
            name = current.name ?? ""
            callThem = current.callThem ?? ""
            addressNote = current.addressNote ?? ""
        }
        if let raw = await profilesRaw { snapshot = CodingAIAccountsParse.snapshot(raw) }
        loadingAccounts = false
        // The address on each row: the engine's last answer (it keeps them a while).
        for account in accounts {
            let id = account.id
            Task {
                if let raw = try? await call("profiles:signin", [id, ["refresh": false]]) {
                    signIns[id] = CodingAIAccountsParse.signIn(raw)
                }
            }
        }
    }

    func label(_ account: CodingAIAccount) -> String {
        CodingAIAccountLabels.profileLoginLabel(account, signIns[account.id], namesTheAgent: false)
    }

    func note(_ account: CodingAIAccount) -> String {
        CopilotSetupRules.note(account, signIn: signIns[account.id], currentId: currentAccountId)
    }

    /// The engine's folder panel; the choice is stored the moment it is made.
    func pickFolder() {
        picking = true
        problem = nil
        Task {
            defer { picking = false }
            do {
                let change = CopilotFolderChange.from(try await call("copilot:folder:pick", timeout: 3600))
                if let next = change.problem { problem = next }
                if let next = change.folder { folder = next }
            } catch {
                problem = CopilotSetupWords.pickFailed
            }
        }
    }

    func useAppFolder() {
        problem = nil
        Task {
            do {
                if let next = CopilotFolderChange.from(try await call("copilot:folder:clear")).folder { folder = next }
            } catch {
                problem = CopilotSetupWords.clearFailed
            }
        }
    }

    /// The last button: write the block, pin the account, then hand back to the page.
    func finish(done: @escaping () -> Void) {
        busy = true
        problem = nil
        let identity = identity
        let chosen = chosen
        let folder = folder
        Task {
            defer { busy = false }
            do {
                guard let text = try await readInstructions() else {
                    problem = CopilotSetupWords.unreadable
                    return
                }
                let write = CopilotWriteResult.write(try await call("copilot:write-instructions", [CopilotIdentity.writing(identity, into: text)]))
                if !write.done || write.error != nil {
                    problem = write.error ?? CopilotSetupWords.unsaved
                    return
                }
                if let chosen, let folder {
                    do { _ = try await call("profiles:set-project-default", [folder.home, chosen.id]) } catch { problem = CopilotSetupWords.unpinned }
                }
                done()
            } catch {
                problem = CopilotSetupWords.failed
            }
        }
    }

    /// Its instructions, writing the file first when it has never been written.
    private func readInstructions() async throws -> String? {
        if case .text(let text, _) = CopilotInstructionsRead.from(try await call("copilot:read-instructions")) { return text }
        _ = try await call("copilot:scaffold")
        if case .text(let text, _) = CopilotInstructionsRead.from(try await call("copilot:read-instructions")) { return text }
        return nil
    }
}

struct NativeCopilotSetup: View {
    let model: AppModel
    @State private var setup = NativeCopilotSetupModel()
    @FocusState private var focused: CopilotSetupStep?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(CopilotSetupWords.title())
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The page's Modal close: writes nothing and starts nothing.
                Button { model.answerDialog(NativeDialogName.copilotSetup, "close") } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.quaternary.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
            }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 12) {
                Text(setup.step.title).font(.headline)
                switch setup.step {
                case .name: nameStep
                case .you: youStep
                case .folder: folderStep
                case .account: accountStep
                }
                if let problem = setup.problem {
                    Text(problem)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 16)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .task { await setup.load() }
        .onChange(of: setup.step, initial: true) { _, step in focused = step == .folder || step == .account ? nil : step }
    }

    // MARK: Steps

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            says(CopilotSetupWords.nameSays)
            field(CopilotSetupWords.nameLabel, optional: false) {
                SetupField(text: $setup.name, prompt: CopilotWords.assistant, limit: CopilotSetupRules.maxName)
                    .focused($focused, equals: .name)
            }
        }
    }

    private var youStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            says(CopilotSetupWords.youSays)
            field(CopilotSetupWords.callLabel, optional: false) {
                SetupField(text: $setup.callThem, prompt: CopilotSetupWords.callPlaceholder, limit: CopilotSetupRules.maxCallThem)
                    .focused($focused, equals: .you)
            }
            field(CopilotSetupWords.addressLabel, optional: true) {
                SetupField(text: $setup.addressNote, prompt: CopilotSetupWords.addressPlaceholder, limit: CopilotSetupRules.maxAddressNote)
            }
        }
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                says(CopilotSetupWords.folderSays)
                InfoNote(label: "the folder", text: CopilotFolderWords.choosing)
            }
            HStack(spacing: 8) {
                Text(setup.folder?.home ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
                Text(CopilotSetupWords.whose(setup.folder))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(CopilotSetupWords.chooseFolder) { setup.pickFolder() }
                    .disabled(setup.busy || setup.picking)
                if let folder = setup.folder, !folder.isDefault {
                    Button(CopilotSetupWords.useAppFolder) { setup.useAppFolder() }
                        .disabled(setup.busy)
                }
            }
            if setup.folder?.restartNeeded == true { quiet(CopilotFolderWords.needsRestart) }
        }
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                says(CopilotSetupWords.accountSays)
                InfoNote(label: "the account", text: CopilotSetupWords.accountNote)
            }
            if setup.loadingAccounts {
                quiet(CopilotSetupWords.readingAccounts)
            } else if setup.accounts.isEmpty {
                quiet(CopilotSetupWords.noAccounts)
            }
            if !setup.accounts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(setup.accounts) { account in accountRow(account) }
                    }
                }
                .frame(maxHeight: 168)
                .fixedSize(horizontal: false, vertical: true)
            }
            if setup.accountId != nil {
                Button(CopilotSetupWords.leaveToDefaults) { setup.accountId = nil }
                    .buttonStyle(.link)
                    .font(.footnote)
            }
            if setup.running { quiet(CopilotSetupWords.renameTakesARestart) }
        }
    }

    private func accountRow(_ account: CodingAIAccount) -> some View {
        let selected = account.id == setup.accountId
        let note = setup.note(account)
        return Button { setup.accountId = account.id } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: selected ? 4.5 : 1.5)
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(setup.label(account)).font(.callout).foregroundStyle(.primary)
                    if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Pieces

    private func says(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ label: String, optional: Bool, @ViewBuilder input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                if optional {
                    Text(CopilotSetupWords.optional).font(.caption).foregroundStyle(.tertiary)
                }
            }
            input()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(CopilotSetupStep.allCases, id: \.self) { each in
                    Capsule()
                        .fill(each == setup.step ? Color.accentColor
                              : each.index < setup.step.index ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.3))
                        .frame(width: each == setup.step ? 16 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(setup.step.index + 1) of \(CopilotSetupStep.allCases.count)")
            Spacer()
            Button(CopilotSetupWords.back) { setup.step = setup.step.previous }
                .disabled(setup.step.index == 0 || setup.busy)
            Button(setup.advanceLabel) {
                if setup.step.isLast {
                    setup.finish { model.answerDialog(NativeDialogName.copilotSetup, "done") }
                } else {
                    setup.step = setup.step.next
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(setup.busy)
        }
    }
}

/// One of the flow's text boxes: filled, no border, cut at the page's maxLength.
private struct SetupField: View {
    @Binding var text: String
    let prompt: String
    let limit: Int

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.body)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            .onChange(of: text) { _, value in
                if value.count > limit { text = String(value.prefix(limit)) }
            }
    }
}
