import AppKit
import SwiftUI
import Observation
import TerminalDeckNativeCore
import TerminalDeckBackend

@MainActor @Observable
final class NativeCloudRecoverySheetState {
    var words: [String]
    let positions: [Int]
    var answers: [Int: String] = [:]
    var kept = false
    var verifying = false
    var failed = false
    let confirm: @MainActor (CloudRecoveryConfirmation) -> Void
    let cancel: @MainActor () -> Void
    init(words: [String], positions: [Int], confirm: @escaping @MainActor (CloudRecoveryConfirmation) -> Void, cancel: @escaping @MainActor () -> Void) {
        self.words = words; self.positions = positions; self.confirm = confirm; self.cancel = cancel
    }
    var confirmed: Bool { words.count == 24 && kept && positions.allSatisfy { answers[$0]?.decomposedStringWithCompatibilityMapping == words[$0] } }
}
struct NativeCloudRecoverySetupSheet: View {
    @Bindable var state: NativeCloudRecoverySheetState
    var body: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s16) {
            Text("Keep your recovery words").font(DeckTokens.Typography.title)
            Text("Keep these words somewhere safe. They unlock your saved passwords if you lose your devices.")
                .font(DeckTokens.Typography.body)
            NativeCloudRecoveryProtectedWords(words: state.words)
                .frame(height: DeckTokens.Metrics.rowMin * 6)
                .modifier(NativeCloudRecoveryWordsAccess(words: state.words, readable: NativeCloudScratch.readableWordsHere))
            Toggle("I have kept these words somewhere safe", isOn: $state.kept).disabled(state.verifying || state.failed)
            HStack(spacing: DeckTokens.Spacing.s12) {
                ForEach(state.positions, id: \.self) { position in
                    SecureField("Word \(position + 1)", text: Binding(get: { state.answers[position] ?? "" }, set: { state.answers[position] = $0 }))
                        .accessibilityLabel("Word \(position + 1)")
                        .disabled(state.verifying || state.failed)
                }
            }
            if state.verifying { ProgressView("Checking your recovery copy in Cloud…") }
            if state.failed {
                Text("Setup did not finish. Your local saved passwords were kept. Keep these words in case the recovery copy reached Cloud, then try unlocking with them.")
                    .font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.warn)
            }
            HStack {
                Spacer()
                Button(state.failed ? "Close" : "Cancel", action: state.cancel).disabled(state.verifying).keyboardShortcut(.cancelAction)
                if !state.failed {
                    Button("Protect saved passwords") {
                        guard state.confirmed else { return }
                        state.verifying = true
                        state.confirm(.init(keptWords: true, answers: state.answers))
                        state.answers.removeAll()
                    }.disabled(!state.confirmed || state.verifying).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(DeckTokens.Spacing.s24)
        .frame(width: DeckTokens.Metrics.objectSize.width + DeckTokens.Spacing.s24 * 2)
        .background(.regularMaterial)
    }
}

@MainActor
final class NativeCloudRecoveryInteraction: CloudSecretsInteractionPort {
    private let parent: @MainActor @Sendable () -> NSWindow?
    private var panel: NSPanel?
    private var activeAlert: NSAlert?
    private var setupState: NativeCloudRecoverySheetState?
    private var setupAnswer: CheckedContinuation<CloudRecoveryConfirmation, Error>?
    init(parent: @escaping @MainActor @Sendable () -> NSWindow?) { self.parent = parent }
    func confirmWords(_ words: [String], positions: [Int]) async throws -> CloudRecoveryConfirmation {
        guard panel == nil, activeAlert == nil, words.count == 24, positions.count == 3, let parent = parent() else { throw CloudFailure.unavailable }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
            setupAnswer = continuation
            let state = NativeCloudRecoverySheetState(words: words, positions: positions, confirm: { [weak self] result in
                let answer = self?.setupAnswer; self?.setupAnswer = nil; answer?.resume(returning: result)
            }, cancel: { [weak self] in self?.closeSetup() })
            let size = CGSize(width: DeckTokens.Metrics.objectSize.width + DeckTokens.Spacing.s24 * 2,
                              height: DeckTokens.Metrics.settingsSize.height + DeckTokens.Spacing.s40)
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Cloud secrets"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: NativeCloudRecoverySetupSheet(state: state))
            self.panel = panel; setupState = state
            parent.beginSheet(panel)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.closeSetup() } }
    }
    /// Closes only on success. Whether a cancellation closes the sheet is the
    /// coordinator's decision (it calls dismiss() while no vault exists yet);
    /// once the server accepted the vault the words are the only copy and stay
    /// visible as "did not finish, keep these words", even if the task was
    /// cancelled (round-5 review S-b).
    func finishWords(succeeded: Bool) async {
        if succeeded { closeSetup() }
        else { setupState?.verifying = false; setupState?.failed = true }
    }
    /// Tests only: adopt a sheet state without a window.
    func adoptForTest(_ state: NativeCloudRecoverySheetState) { setupState = state }
    var shownWords: [String] { setupState?.words ?? [] }
    private func closeSetup() {
        setupAnswer?.resume(throwing: CancellationError()); setupAnswer = nil
        setupState?.words.removeAll(); setupState?.answers.removeAll(); setupState = nil
        if let panel { panel.sheetParent?.endSheet(panel); panel.contentView = nil; panel.close() }
        panel = nil
    }
    private func alert(title: String, message: String, action: String, accessory: NSView? = nil, cancel: Bool = true, cancelTitle: String = "Cancel") async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action)
        if cancel { alert.addButton(withTitle: cancelTitle) }
        alert.accessoryView = accessory
        return try await present(alert, accept: .alertFirstButtonReturn)
    }
    /// The security comparison must take a deliberate click: Return answers
    /// "They don’t match", and "Codes match" has no key equivalent at all.
    static func transferConfirmationAlert(_ display: CloudSecretsApprovalDisplay) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Check the second code"
        alert.informativeText = "Second code: \(display.matchingCode)\n\nCompare this with the second code now showing on \(display.deviceName). Choose Codes match only when they are the same. Your saved passwords stay locked until you confirm."
        let refuse = alert.addButton(withTitle: "They don’t match")
        refuse.keyEquivalent = "\r"
        let accept = alert.addButton(withTitle: "Codes match")
        accept.keyEquivalent = ""
        // Review S-A6: with keyboard navigation on, Tab+Space must never press the accepting button.
        NativeCloudSheetGuard.harden(alert, accept: transferConfirmationAccept)
        return alert
    }
    static let transferConfirmationAccept = NSApplication.ModalResponse.alertSecondButtonReturn
    private func present(_ alert: NSAlert, accept: NSApplication.ModalResponse) async throws -> Bool {
        guard let parent = parent(), panel == nil, activeAlert == nil else { throw CloudFailure.unavailable }
        activeAlert = alert
        // R3 (lean scope item 4), for every approval answered here ("Allow this device", "Codes match", "Add this MCP
        // server", "Unlock", "Start new saved passwords"): a press that follows the app's own remote input (Mac reach
        // from the phone) by less than two seconds is a refusal, and the sheet closes, as a refusal, when remote
        // control of this Mac starts or ends.
        let remote = NativeCloudSheetGuard.shared.remote
        let watch = NativeCloudSheetGuard.shared.opened { [weak alert] in
            if let alert { alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort) }
        }
        defer { activeAlert = nil; NativeCloudSheetGuard.shared.closed(watch) }
        return await withTaskCancellationHandler {
            if Task.isCancelled { return false }
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: parent) { continuation.resume(returning: NativeCloudSheetGuard.accepted($0, accept: accept, remote: remote)) }
            }
        } onCancel: { Task { @MainActor [weak self] in
            if let alert = self?.activeAlert { alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort) }
        }}
    }
    func recoveryWords() async throws -> [String] {
        let field = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: DeckTokens.Metrics.objectSize.width, height: DeckTokens.Metrics.rowMin))
        field.placeholderString = "Your 24 recovery words"
        defer { field.stringValue = "" }
        guard try await alert(title: "Unlock saved passwords", message: "Type the 24 words you kept when you protected your saved passwords.", action: "Unlock", accessory: field) else { throw CancellationError() }
        let words = field.stringValue.decomposedStringWithCompatibilityMapping.split(whereSeparator: \.isWhitespace).map(String.init)
        field.stringValue = ""
        return words
    }
    /// The first code guards the real key itself: a habit press of Return must
    /// refuse. "Don’t allow" is the Return button; "Allow this device" has no
    /// key equivalent and needs a deliberate click.
    static func allowDeviceAlert(_ display: CloudSecretsApprovalDisplay) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = allowDeviceTitle(display)
        // PASSWORDS-2: a request the device signed (checked with the key this Mac pinned) carries no code: the
        // question is only whether he is setting that device up now.
        let rest = display.matchingCode.isEmpty
            ? Self.allowSignedText(display.deviceName)
            : "\(display.deviceName) · \(display.platform.rawValue)\n\nMatching code: \(display.matchingCode)\n\nAllow only if the code is the same on your other device."
        alert.informativeText = signedOutLine(display).map { $0 + "\n\n" + rest } ?? rest
        let refuse = alert.addButton(withTitle: "Don’t allow")
        refuse.keyEquivalent = "\r"
        let accept = alert.addButton(withTitle: allowDeviceButton(display))
        accept.keyEquivalent = ""
        NativeCloudSheetGuard.harden(alert, accept: allowDeviceAccept)
        return alert
    }
    static let allowDeviceAccept = NSApplication.ModalResponse.alertSecondButtonReturn
    /// 15 Nov small fixes item 4: a Mac another device signed out and that signed in again is asked about by name.
    static func allowDeviceTitle(_ display: CloudSecretsApprovalDisplay) -> String {
        display.signedOutBefore ? "Is this your \(display.deviceName)?" : "Allow this device?"
    }
    static func allowDeviceButton(_ display: CloudSecretsApprovalDisplay) -> String {
        display.signedOutBefore ? "Yes, it\u{2019}s mine" : "Allow this device"
    }
    /// The one plain line under the title for such a Mac: "It was signed out from <device> on <date>."
    static func signedOutLine(_ display: CloudSecretsApprovalDisplay) -> String? {
        guard display.signedOutBefore else { return nil }
        let by = display.signedOutBy?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80).description
        let from = (by?.isEmpty == false ? by : nil) ?? "another of your devices"
        guard let at = display.signedOutAt, at > 0 else { return "It was signed out from \(from)." }
        return "It was signed out from \(from) on \(NativeCloudTrustWords.day(at))."
    }
    static func allowSignedText(_ name: String) -> String {
        "\(name) wants to open your saved passwords. Allow it only if you are setting it up now."
    }
    func allowDevice(_ display: CloudSecretsApprovalDisplay) async throws -> Bool {
        try await present(Self.allowDeviceAlert(display), accept: Self.allowDeviceAccept)
    }
    func showMatchingCode(_ display: CloudSecretsApprovalDisplay) async throws {
        guard let parent = parent(), panel == nil, activeAlert == nil else { throw CloudFailure.unavailable }
        let alert = NSAlert()
        alert.messageText = "Check your other device"
        alert.informativeText = "\(display.deviceName) · \(display.platform.rawValue)\n\nMatching code: \(display.matchingCode)\n\nOn an unlocked device, open Cloud and choose Allow this device when the codes match."
        alert.addButton(withTitle: "Done")
        activeAlert = alert
        // Return while this sheet is visible so the approval event can be received.
        alert.beginSheetModal(for: parent) { [weak self] _ in
            if self?.activeAlert === alert { self?.activeAlert = nil }
        }
    }
    func showTransferCode(_ display: CloudSecretsApprovalDisplay) async throws {
        guard let parent = parent(), panel == nil, activeAlert == nil else { throw CloudFailure.unavailable }
        let alert = NSAlert()
        alert.messageText = "Finish on your other device"
        alert.informativeText = "Second code: \(display.matchingCode)\n\nOn \(display.deviceName), check that this second code matches, then choose Codes match. Keep this code visible until you finish there."
        alert.addButton(withTitle: "Done")
        activeAlert = alert
        alert.beginSheetModal(for: parent) { [weak self] _ in
            if self?.activeAlert === alert { self?.activeAlert = nil }
        }
    }
    func confirmTransferCode(_ display: CloudSecretsApprovalDisplay) async throws -> Bool {
        await finishApproval()
        return try await present(Self.transferConfirmationAlert(display), accept: Self.transferConfirmationAccept)
    }
    func dismiss() async {
        closeSetup()
        if let alert = activeAlert { alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort); activeAlert = nil }
    }
    func finishApproval() async {
        if let alert = activeAlert { alert.window.sheetParent?.endSheet(alert.window); activeAlert = nil }
    }
    /// The only way a restored MCP server is added: the person reads the whole
    /// command in this sheet and clicks "Add this MCP server". Return answers
    /// "Don't add"; the add button has no key equivalent. Tools never reach it.
    /// The plain warning lines above the details (round-8 S-3/S-4).
    static func mcpWarnings(_ item: BackendCloudSecretsMCPPendingItem) -> [String] {
        let place = item.scope == "project" ? "the project \(item.project ?? "")" : "every project on this Mac"
        var lines = ["From your Cloud account, for \(place)."]
        if item.runsScript { lines += ["", "This runs a script: read it before adding."] }
        if !item.environment.isEmpty {
            lines += ["", "Settings are passed to this command. Settings can change what it does: add it only if you recognise them."]
        }
        if !item.runChangingSettings.isEmpty {
            lines += ["", "Warning: " + item.runChangingSettings.joined(separator: ", ")
                + " can change which program actually runs. Add this only if you recognise these values."]
        }
        if !item.networkSettings.isEmpty {
            lines += ["", "Warning: " + item.networkSettings.joined(separator: ", ")
                + " can send its network traffic somewhere else or change which certificates it trusts."]
        }
        if item.kind == .changed { lines += ["", "It was changed on another device. A server with this name already exists here and is not replaced."] }
        return lines
    }
    /// Everything that will run, in full, for the scrolling box.
    static func mcpDetails(_ item: BackendCloudSecretsMCPPendingItem) -> String {
        var lines = ["This command will run on this Mac:", item.commandLine]
        if let helper = item.helperCommand, !helper.isEmpty { lines += ["", "This command also runs to sign in:", helper] }
        if let oauth = item.oauth, !oauth.isEmpty { lines += ["", "It signs in with OAuth: " + oauth] }
        if let folder = item.workingFolder, !folder.isEmpty { lines += ["", "It runs in this folder: " + folder] }
        if !item.environment.isEmpty { lines += ["", "Settings passed to it (secret values hidden):"] + item.environment }
        if !item.headerNames.isEmpty { lines += ["", "Headers sent (values hidden): " + item.headerNames.joined(separator: ", ")] }
        return lines.joined(separator: "\n")
    }
    /// A selectable, scrolling box: a long command or many settings never push
    /// the buttons or the warnings off the sheet.
    static func mcpDetailsBox(_ text: String) -> NSScrollView {
        let width: CGFloat = 440
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 180))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 180))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.string = text
        view.setAccessibilityLabel("What this MCP server runs")
        scroll.documentView = view
        return scroll
    }
    static func mcpAddAlert(_ item: BackendCloudSecretsMCPPendingItem) -> NSAlert {
        let alert = NSAlert()
        if item.kind == .removed {
            alert.messageText = "\(item.name) was removed on another device"
            alert.informativeText = "It was not removed here. Remove it in MCP settings if you no longer want it."
            alert.addButton(withTitle: "OK").keyEquivalent = "\r"
            return alert
        }
        alert.messageText = "Add this MCP server: \(item.name)?"
        alert.informativeText = mcpWarnings(item).joined(separator: "\n")
        alert.accessoryView = mcpDetailsBox(mcpDetails(item))
        let refuse = alert.addButton(withTitle: "Don’t add")
        refuse.keyEquivalent = "\r"
        let accept = alert.addButton(withTitle: "Add this MCP server")
        accept.keyEquivalent = ""
        NativeCloudSheetGuard.harden(alert, accept: .alertSecondButtonReturn)
        return alert
    }
    func confirmMCPAdd(_ item: BackendCloudSecretsMCPPendingItem) async -> Bool {
        let accept: NSApplication.ModalResponse = item.kind == .removed ? .alertFirstButtonReturn : .alertSecondButtonReturn
        return (try? await present(Self.mcpAddAlert(item), accept: accept)) ?? false
    }
    /// Security review V1: starting new saved passwords must take a deliberate click. "Don’t start new" is the
    /// Return button; "Start new saved passwords" has no key equivalent (the same pattern as the first-code sheet).
    /// No tool can open this sheet: the one registered tool (`BackendCloudSecretsLeanTool`) refuses `reset`.
    static func resetAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Start new saved passwords?"
        alert.informativeText = "Your teams, notes, conversations and work stay available. Old saved passwords stay encrypted in their archive. You will need to sign in to those services again."
        let refuse = alert.addButton(withTitle: "Don’t start new")
        refuse.keyEquivalent = "\r"
        let accept = alert.addButton(withTitle: "Start new saved passwords")
        accept.keyEquivalent = ""
        NativeCloudSheetGuard.harden(alert, accept: resetAccept)
        return alert
    }
    static let resetAccept = NSApplication.ModalResponse.alertSecondButtonReturn
    func confirmReset() async throws -> Bool {
        try await present(Self.resetAlert(), accept: Self.resetAccept)
    }
}

/// The words stay hidden from the Accessibility tree, as on every real copy. Only a throwaway test copy whose scratch
/// plan says `"wordsReadable": true` (plain debug build, never the shipped flavour) exposes them, so an automated test
/// can read them without a screenshot (two-Mac proof, 13 Nov).
struct NativeCloudRecoveryWordsAccess: ViewModifier {
    let words: [String]
    let readable: Bool
    /// What the Accessibility tree may read: nil (hidden) unless `readable`, and always nil in a release build.
    static func exposed(_ words: [String], readable: Bool) -> String? {
        #if DEBUG
        guard readable else { return nil }
        return words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")
        #else
        return nil
        #endif
    }
    func body(content: Content) -> some View {
        if let text = Self.exposed(words, readable: readable) {
            content.accessibilityElement(children: .ignore).accessibilityLabel("Recovery words").accessibilityValue(text)
        } else {
            content.accessibilityHidden(true)
        }
    }
}
