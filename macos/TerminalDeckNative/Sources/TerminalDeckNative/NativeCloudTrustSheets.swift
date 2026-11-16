import AppKit
import SwiftUI
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Plain words for a device row (Settings → Cloud → Devices and the new-Mac sheet).
enum NativeCloudTrustWords {
    static func day(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(date: .abbreviated, time: .omitted)
    }
    /// "This Mac", "Known to this Mac since 12 Nov 2026" or "New device".
    static func standing(_ row: CloudDeviceTrustRow) -> String {
        switch row.standing {
        case .thisMac: return "This Mac"
        case .trusted: return row.knownSince.map { "Known to this Mac since " + day($0) } ?? "Known to this Mac"
        case .new: return row.removed ? "Removed (reported)" : "New device"
        }
    }
    /// What the service says about it and what is waiting; nil when there is nothing to say.
    static func detail(_ row: CloudDeviceTrustRow) -> String? {
        var parts: [String] = []
        if row.standing == .new, let added = row.addedAt { parts.append("Added " + day(added) + " (reported)") }
        if row.waiting > 0 { parts.append(waiting(row.waiting)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    static func waiting(_ count: Int) -> String { count == 1 ? "1 change waiting" : "\(count) changes waiting" }
    /// The Status line. "Saved" for a source only means what THIS Mac holds of it is in Cloud, and changes waiting
    /// from a device not yet trusted count nowhere else, so while anything waits the status says so in plain words
    /// instead of "Connected" (sync result 8fcfe0d4, note 3).
    static func status(_ snapshot: CloudAccountSnapshot) -> String {
        if snapshot.phase == .paused { return "Paused" }
        let waiting = snapshot.trust.filter { $0.waiting > 0 && $0.standing == .new && !$0.stale }
        if waiting.count == 1, let one = waiting.first { return "Changes from “\(one.name)” are waiting for you to trust it" }
        if waiting.count > 1 { return "Changes from \(waiting.count) devices are waiting for you to trust them" }
        if snapshot.heldChanges > 0 { return "Changes from a device you have not trusted are waiting" }
        return "Connected"
    }
    /// This Mac's first save, honestly: how far it is and, when it is paused, when it goes on by itself.
    static func baseline(_ progress: CloudBaselineProgress, now: Date = Date(), calendar: Calendar = .current) -> String {
        BackendCloudOverviewWords.baseline(progress, now: now, calendar: calendar)
    }
    /// The one line for packs this Mac could not check (design 3.3).
    static func refused(_ count: Int) -> String { BackendCloudOverviewWords.refused(count) }
    /// The name is the device's own claim (security review M1): always quoted, after a fixed label, apart from the code.
    static func claim(_ row: CloudDeviceTrustRow) -> String {
        row.standing == .thisMac ? "This Mac calls itself: “\(row.name)”" : "Calls itself: “\(row.name)”"
    }
    static let sameCode = "Two devices show the same code. Do not trust either."
    static let sameKey = "Two devices use the same key. Do not trust either."
    static let removed = "Cloud reports this device as removed from your account. It cannot be trusted."
    /// Security review S5: two different codes that begin or end with the same four characters.
    static let lookAlike = "This code looks like another one here. Compare every character."
    /// The alarm line under a device, or nil.
    static func alarm(_ row: CloudDeviceTrustRow) -> String? {
        if row.sameKey { return sameKey }
        if row.sameCode { return sameCode }
        return row.removed && row.standing == .new ? removed : nil
    }
    /// Said instead of opening the new-Mac sheet while this Mac is being controlled from another device (S3).
    static let setupWhileRemote = "This Mac is being controlled from another device, so the list of devices to trust was not opened. Open it yourself at this Mac: Settings → Cloud → Choose devices."
    static let unreadable = "Can't read this device yet. Try again."
}

/// A device's code, always in the same place and the same style (first line, fixed-width, semibold), which no
/// device name can imitate: names are shown smaller, quoted, after a fixed label, on a line of their own.
struct NativeCloudDeviceCode: View {
    let code: String?
    var body: some View {
        if let code {
            Text(code).font(DeckTokens.Typography.mono.weight(.semibold)).foregroundStyle(DeckTokens.textPrimary).textSelection(.enabled)
                .accessibilityLabel("Code " + code)
        } else {
            Text(NativeCloudTrustWords.unreadable).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
        }
    }
}

/// The new-Mac sheet's choices (design 5.3): every device is listed and nothing is ticked for the person.
@MainActor @Observable
final class NativeCloudSetupSheetState {
    let rows: [CloudDeviceTrustRow]
    /// The devices whose code begins or ends like another device's on this account (security review S5), taken
    /// from every device the sheet was opened with, not only the new ones.
    let lookAlike: Set<String>
    private(set) var ticked: Set<String> = []
    let use: @MainActor ([BackendCloudTrustCapture]) -> Void
    let cancel: @MainActor () -> Void
    /// Security review S3: a tick that follows the app's own remote input is not the person's.
    private let pressRefused: @MainActor () -> Bool
    /// `pressRefused` defaults to the real record of the app's own remote input, never to "always allowed".
    /// "Do not trust either" is the GROUP's alarm (run 14): `rows` are judged together, and with `all` (every device
    /// the sheet was opened with), so each device that shows another's code or uses another's key is drawn warned
    /// and cannot be ticked, whichever of them arrived marked.
    init(rows: [CloudDeviceTrustRow], among all: [CloudDeviceTrustRow] = [], lookAlike: Set<String> = [],
         pressRefused: @escaping @MainActor () -> Bool = { NativeCloudSheetGuard.shared.remote.refusesPress(at: NativeCloudSheetGuard.pressTime()) },
         use: @escaping @MainActor ([BackendCloudTrustCapture]) -> Void, cancel: @escaping @MainActor () -> Void) {
        let ids = Set(rows.map { $0.deviceId })
        let others = all.filter { !ids.contains($0.deviceId) }
        // Same order and count as handed in: the sheet's own rows come first.
        self.rows = Array(BackendCloudTrustRows.alarmed(rows + others).prefix(rows.count))
        self.lookAlike = lookAlike; self.pressRefused = pressRefused; self.use = use; self.cancel = cancel
    }
    /// A device whose key cannot be read, whose code another device also shows or which Cloud reports as removed
    /// cannot be ticked; and nothing is ticked by a click that follows the app's own remote input (the phone could
    /// otherwise tick a device and leave the person to press "Use the ticked devices"). Unticking is always taken.
    func tick(_ deviceId: String, _ on: Bool) {
        guard on else { ticked.remove(deviceId); return }
        guard !pressRefused() else { return }
        if rows.contains(where: { $0.deviceId == deviceId && $0.canBeTrusted }) { ticked.insert(deviceId) }
    }
    /// The ticked devices exactly as they were drawn (R1).
    var captures: [BackendCloudTrustCapture] {
        rows.filter { ticked.contains($0.deviceId) }.compactMap { BackendCloudTrustCapture(row: $0) }
    }
}

struct NativeCloudSetupSheet: View {
    @Bindable var state: NativeCloudSetupSheetState
    var body: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s16) {
            Text("Set up this Mac from your Cloud").font(DeckTokens.Typography.title)
            Text("These devices have saved to your Cloud. On a Mac you already use, open Settings → Cloud, choose Show this Mac's code and compare. Tick only devices you know are yours. Changes from a device you do not tick wait, and you can trust it later in Settings → Cloud.")
                .font(DeckTokens.Typography.body).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: DeckTokens.Spacing.s12) {
                    ForEach(state.rows) { row in
                        Toggle(isOn: Binding(get: { state.ticked.contains(row.deviceId) }, set: { state.tick(row.deviceId, $0) })) {
                            VStack(alignment: .leading, spacing: DeckTokens.Spacing.s4) {
                                NativeCloudDeviceCode(code: row.code)
                                Text(NativeCloudTrustWords.claim(row)).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary).lineLimit(1)
                                if let detail = NativeCloudTrustWords.detail(row) {
                                    Text(detail).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
                                }
                                if let alarm = NativeCloudTrustWords.alarm(row) {
                                    Text(alarm).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.warn)
                                }
                                if state.lookAlike.contains(row.deviceId) {
                                    Text(NativeCloudTrustWords.lookAlike).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.warn)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!row.canBeTrusted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: DeckTokens.Metrics.rowMin * 10)
            HStack {
                Spacer()
                // No key answers for this one and it cannot hold the keyboard focus (security review S6): it takes a click.
                Button("Use the ticked devices") { state.use(state.captures) }.disabled(state.ticked.isEmpty).focusable(false)
                Button("Not now", action: state.cancel).keyboardShortcut(.defaultAction)
            }
        }
        .padding(DeckTokens.Spacing.s24)
        .frame(width: DeckTokens.Metrics.objectSize.width + DeckTokens.Spacing.s24 * 2)
        .background(.regularMaterial)
    }
}

/// The two places a device can become trusted on this Mac, both answered by a press in this Mac's own window:
/// the trust sheet for one new device (design 5.4) and the new-Mac sheet (5.3). No tool opens or answers them.
@MainActor
final class NativeCloudTrustSheets {
    static let shared = NativeCloudTrustSheets()
    private var alert: NSAlert?
    private var panel: NSPanel?
    private var panelWatch: UUID?
    /// The device list as it was when the open sheet was drawn. R1: if it changes, the sheet closes.
    private var drawn: Set<String>?
    /// Fixtures replace this so no sheet needs a window.
    var parent: @MainActor () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain }
    }
    var isOpen: Bool { alert != nil || panel != nil }

    /// Which devices, with which keys, the list shows. A device added or gone, or a key that changed, changes it.
    nonisolated static func fingerprint(_ rows: [CloudDeviceTrustRow]) -> Set<String> {
        Set(rows.map { $0.deviceId + ":" + ($0.keyId ?? "") })
    }
    nonisolated static func mustClose(drawn: Set<String>?, now rows: [CloudDeviceTrustRow]) -> Bool {
        guard let drawn else { return false }
        return fingerprint(rows) != drawn
    }
    /// `row` as it stands among `all`, the devices shown with it: alarmed when another device there shows its code
    /// or uses its key. The list's own line for the device is used when it shows the same key (it carries every
    /// alarm the list knows of); a row the list does not hold is judged as it was handed over.
    nonisolated static func judged(_ row: CloudDeviceTrustRow, among all: [CloudDeviceTrustRow]) -> CloudDeviceTrustRow {
        let marked = BackendCloudTrustRows.alarmed(all + [row])
        return marked.first { $0.deviceId == row.deviceId && $0.keyId == row.keyId } ?? row
    }
    /// "Not now" is the default button and answers Return; "Trust this device" has no key equivalent and takes a click.
    static func trustAlert(_ capture: BackendCloudTrustCapture, waiting: Int, lookAlike: Bool = false) -> NSAlert {
        let alert = NSAlert()
        // Security review M1: nothing the device chose is in the title, and the code is not in the running text at
        // all. It sits alone below, large and fixed-width, where a name cannot put a second "code".
        alert.messageText = "Trust this device?"
        var text = "It calls itself: “\(BackendCloudTrustRows.plainName(capture.name))”\n\nIts code is shown below in large type. On that device, open Settings → Cloud and choose Show this Mac's code. It must be the same. If it is not, choose Not now.\n\nTrusting it lets its changes apply on this Mac."
        if waiting > 0 { text += "\n\n" + NativeCloudTrustWords.waiting(waiting) + "." }
        // Security review S5: another device on this account has a code that begins or ends the same way.
        if lookAlike { text += "\n\n" + NativeCloudTrustWords.lookAlike }
        alert.informativeText = text
        alert.accessoryView = codeView(capture.code)
        let refuse = alert.addButton(withTitle: "Not now")
        refuse.keyEquivalent = "\r"
        alert.addButton(withTitle: "Trust this device")
        NativeCloudSheetGuard.harden(alert, accept: trustAccept)
        return alert
    }
    static let trustAccept = NSApplication.ModalResponse.alertSecondButtonReturn
    /// The code on the trust sheet: one fixed-width, large, selectable line of its own.
    static func codeView(_ code: String) -> NSTextField {
        let label = NSTextField(labelWithString: code)
        label.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        label.alignment = .center
        label.isSelectable = true
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setAccessibilityLabel("This device's code")
        label.frame = NSRect(x: 0, y: 0, width: 360, height: 30)
        return label
    }

    /// "Ask me for each new device" only: this Mac's own code, alone in a sheet, for the person to compare with the
    /// sheet on the other device. Nothing to accept. The one other place a code appears.
    static func showOwnCode(_ code: String) {
        let alert = NSAlert()
        alert.messageText = "This Mac's code"
        alert.informativeText = "Compare it with the code the other device shows. They must be the same."
        alert.accessoryView = codeView(code)
        alert.addButton(withTitle: "OK")
        NativeCloudSheetGuard.shared.notice(alert)
    }
    /// Settings → Devices' Trust button (owner via review, 14 Nov: one click on the row, no sheet). The capture is the
    /// row as drawn (R1); the group alarm still refuses a look-alike; the press is a guarded page press (R3).
    static func trustNow(_ row: CloudDeviceTrustRow, model: NativeCloudAccount) {
        guard model.trustMode == .ask else { return }
        let checked = Self.judged(row, among: model.snapshot.trust)
        guard let capture = BackendCloudTrustCapture(row: checked) else {
            if let alarm = NativeCloudTrustWords.alarm(checked) { model.say(alarm) }
            return
        }
        NativeCloudSheetGuard.shared.pagePress(model: model) { Task { await model.trust([capture], restore: false) } }
    }
    /// The trust sheet for one new device. What is stored on Trust is `capture`, taken from the row as it is drawn
    /// here (R1); nothing read later can replace it.
    func ask(_ row: CloudDeviceTrustRow, model: NativeCloudAccount) async {
        // Owner, 13 Nov: "Automatically, with my account" shows no trust sheet, whatever asks for one.
        guard !isOpen, model.trustMode == .ask else { return }
        // "Do not trust either" is the GROUP's alarm (run 14): the press on ANY device of a same-code or same-key
        // group opens no sheet and says why, also when only its twin's line carries the mark.
        let judged = Self.judged(row, among: model.snapshot.trust)
        guard let capture = BackendCloudTrustCapture(row: judged) else {
            if let alarm = NativeCloudTrustWords.alarm(judged) { model.say(alarm) }
            return
        }
        guard let window = parent() else { return }
        let made = Self.trustAlert(capture, waiting: row.waiting,
                                   lookAlike: BackendCloudTrustRows.lookAlike(model.snapshot.trust).contains(row.deviceId))
        alert = made
        drawn = Self.fingerprint(model.snapshot.trust)
        // R3: the sheet closes if remote control of this Mac starts or ends, and a press that follows the app's own
        // remote input is refused. Both are decided at the moment of the press, before anything else is awaited.
        let answer = await NativeCloudSheetGuard.shared.present(made, on: window, accept: Self.trustAccept)
        alert = nil
        drawn = nil
        guard answer.chose else { return }
        guard answer.taken else { model.say(BackendCloudTrustRefusal.remoteInput.words); return }
        await model.trust([capture], restore: false)
    }
    /// The new-Mac sheet, once, right after the person's own sign-in when the account already has other devices.
    /// `all` is the whole device list of the SAME read `rows` came from (security review S14): the sheet's "list as
    /// drawn" and its rows can then never be a step apart, which would close the sheet as it opens.
    func setUp(_ rows: [CloudDeviceTrustRow], all: [CloudDeviceTrustRow], model: NativeCloudAccount) {
        guard !isOpen, !rows.isEmpty, model.trustMode == .ask, let window = parent() else { return }
        // Security review S3: not opened while this Mac is being controlled from another device. The Cloud page
        // keeps "Choose devices…" for the person at this Mac.
        guard !NativeCloudSheetGuard.shared.remote.remoteControlActive() else { model.say(NativeCloudTrustWords.setupWhileRemote); return }
        let state = NativeCloudSetupSheetState(rows: rows, among: all, lookAlike: BackendCloudTrustRows.lookAlike(all), use: { [weak self] captures in
            // R3, at the moment of the press, judged by the press's own time.
            let refused = NativeCloudSheetGuard.shared.remote.refusesPress(at: NativeCloudSheetGuard.pressTime())
            self?.closePanel()
            // A refused press is no answer: the sheet can be opened again from the Cloud page.
            guard !refused else { model.say(BackendCloudTrustRefusal.remoteInput.words); return }
            Task { await model.useTicked(captures) }
        }, cancel: { [weak self] in
            // "Not now" IS an answer (hand-back 4): this Mac's own memory may now be set up.
            self?.closePanel()
            model.answerNewMac()
        })
        let size = CGSize(width: DeckTokens.Metrics.objectSize.width + DeckTokens.Spacing.s24 * 2, height: DeckTokens.Metrics.objectSize.height)
        let made = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        made.title = "Cloud"
        made.isReleasedWhenClosed = false
        made.contentView = NSHostingView(rootView: NativeCloudSetupSheet(state: state))
        panel = made
        drawn = Self.fingerprint(all)
        panelWatch = NativeCloudSheetGuard.shared.presentPanel(made, on: window) { [weak self] in self?.closeAll() }
    }
    /// R1: the device list changed while a sheet was open. It closes and nothing is trusted.
    func deviceListChanged(_ rows: [CloudDeviceTrustRow]) {
        guard Self.mustClose(drawn: drawn, now: rows) else { return }
        closeAll()
    }
    /// Every open trust sheet closes without trusting anything.
    func closeAll() {
        if let alert { alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort) }
        closePanel()
    }
    private func closePanel() {
        if let panel { panel.sheetParent?.endSheet(panel); panel.contentView = nil; panel.close() }
        panel = nil
        if let panelWatch { NativeCloudSheetGuard.shared.closed(panelWatch) }
        panelWatch = nil
        if alert == nil { drawn = nil }
    }
}
