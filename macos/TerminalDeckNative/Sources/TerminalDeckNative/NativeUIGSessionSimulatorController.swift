import AppKit
import Observation
import TerminalDeckNativeCore

/// Who a phone panel belongs to: a terminal session, or Hoot (same panel, same engine).
@MainActor protocol NativeUIGSimulatorOwner: AnyObject {
    var sessionId: String { get }
    var ended: Bool { get }
    var removed: Bool { get }
    var isRemote: Bool { get }
}
extension NativeUIGSimulatorOwner { var isRemote: Bool { false } }
extension NativeTerminalSession: NativeUIGSimulatorOwner {}

/// One dock per actual session. Device decoding/input/Inspect stay in the existing model.
@MainActor @Observable final class NativeUIGSessionSimulatorController {
    let session: any NativeUIGSimulatorOwner
    /// 0 the session's first device panel, 1 the second (a session shows up to two).
    let slot: Int
    let model = NativeSimulatorModel(deviceRail: true)
    var layout: UIGSessionSimulatorState
    var inOwnWindow = false
    /// The "Choose a device" dropdown is open (its button, or the empty panel's own Choose a device).
    var pickerShown = false
    var busy = false
    var problem = ""
    var ticket: UIGSessionSimulatorTicket?
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var visible = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var visibilityEpoch = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tools: NativeSimPanelTools?
    @ObservationIgnored private var recorder: NativeSimRecorder?
    let lifecycleEnabled: Bool
    init(session: any NativeUIGSimulatorOwner, slot: Int = 0, defaults: UserDefaults = .standard, lifecycleEnabled: Bool = true) {
        self.session = session; self.slot = slot; self.defaults = defaults; self.lifecycleEnabled = lifecycleEnabled
        layout = .restored(from: defaults.data(forKey: UIGSessionSimulatorState.storageKey(sessionID: session.sessionId, slot: slot)))
        model.attachedSessionID = session.sessionId
        model.onStaleAttachment = { [weak self] in self?.resync() }
        model.feedbackScope = "phone:" + session.sessionId + ":" + String(slot)
        model.scopedDeviceInvoke = { [weak self] channel, args in
            guard let self else { throw Self.unavailable("This simulator panel closed.") }
            return try await self.invokeDevice(channel, args)
        }
        model.scopedSend = { [weak self] text, target, round, revision in
            guard let self else { return "This simulator panel closed." }
            return await self.send(text, target: target, round: round, revision: revision)
        }
        model.scopedFeedbackValidate = { [weak self] revision in
            guard let self, let ticket = self.ticket, ticket.token == revision, ticket.deviceID != nil,
                  !self.session.ended, !self.session.removed else { throw Self.unavailable("The session attachment changed. Nothing was sent.") }
            _ = try await EngineBridge.shared.invoke("session-simulator:validate", [ticket.arguments])
            guard self.ticket == ticket else { throw Self.unavailable("The session attachment changed. Nothing was sent.") }
        }
        model.scopedHootSend = { [weak self] text, blocks, source, captureRevision in
            guard let self, let ticket = self.ticket, ticket.token == captureRevision,
                  ticket.deviceID != nil, !self.session.ended, !self.session.removed else {
                throw Self.unavailable("The session attachment changed. Nothing was sent.")
            }
            let receipt = try await EngineBridge.shared.invoke("session-simulator:send-hoot", [ticket.arguments,
                text, blocks.map { $0.foundation ?? NSNull() }, source.foundation ?? NSNull()])
            NativeHOOTSIMFeedback.rememberPreview(receipt: receipt, message: text, attachments: blocks, source: source)
        }
        // Snip, the light Annotate popup, and the full panel's width taken from the session.
        // The panel keeps both; they go with it (U143 #195).
        tools = NativeSimPanelTools.attach(to: model) { [weak self] extra in self?.widen(by: extra) }
        // Record: the session simulator's own recorder, for this session's attached device.
        recorder = NativeSimRecorder.attach(to: model) { [weak self] action in
            guard let self, let ticket = self.ticket, ticket.deviceID != nil else { throw Self.unavailable("Attach a running simulator or emulator to record it.") }
            return try await EngineBridge.shared.invoke("session-simulator:record", [ticket.arguments, action])
        }
    }
    var id: String { session.sessionId }
    /// On screen now: shown in the session, or in its own window.
    var showing: Bool { visible > 0 || inOwnWindow }
    /// This panel's own key (windows, drag): the session, and the slot when it is the second.
    var key: String { slot == 0 ? id : id + "#\(slot)" }
    var title: String { model.device?.platform == "android" ? "Android" : "iOS Simulator" }
    var entries: [DeviceEntry] { UIGSimulatorPresentation.entries(model.list, open: model.device) }
    var selected: DeviceEntry? { entries.first { $0.id == ticket?.deviceID } }
    var canSend: Bool {
        ticket?.deviceID != nil && !session.ended && !session.removed &&
            (model.canSendRound || (model.shot != nil && model.target != nil))
    }
    func saveLayout() {
        guard lifecycleEnabled else { return }
        var saved = layout
        if let base = widthBeforeWidening { saved.resize(to: base) } // the full panel's extra is never kept
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: UIGSessionSimulatorState.storageKey(sessionID: id, slot: slot))
        }
    }
    func setOpen(_ open: Bool) { layout.isOpen = open; saveLayout() }
    /// The panel's own width before the full Annotate panel widened it (not saved: it is given back).
    @ObservationIgnored private var widthBeforeWidening: Double?
    func widen(by extra: Double) {
        if extra > 0 {
            if widthBeforeWidening == nil { widthBeforeWidening = layout.width }
            layout.resize(to: (widthBeforeWidening ?? layout.width) + extra)
        } else if let base = widthBeforeWidening {
            widthBeforeWidening = nil
            layout.resize(to: base)
        }
    }
    func resize(_ width: Double) { layout.resize(to: width); saveLayout() }
    func appear() {
        guard lifecycleEnabled else { return }
        visible += 1; visibilityEpoch += 1
        guard visible == 1 else { return }
        subscribe()
        Task {
            do {
                let current = try await snapshot()
                guard visible > 0 else { return }
                adopt(current)
                model.appear()
                await model.refresh()
                guard visible > 0 else { return }
                if let entry = selected, entry.available { await model.open(entry.id) }
                else if selected == nil, let saved = defaults.string(forKey: UIGSessionSimulatorState.deviceKey(sessionID: id, slot: slot)),
                        let entry = entries.first(where: { $0.id == saved && $0.available }) {
                    await select(entry) // the device this place showed last time, when it is still running (never booted for it)
                }
            } catch { fail(error) }
        }
    }
    func disappear() {
        guard lifecycleEnabled else { return }
        visible = max(0, visible - 1); visibilityEpoch += 1
        let epoch = visibilityEpoch
        Task {
            await Task.yield()
            guard visible == 0, epoch == visibilityEpoch else { return }
            model.disappear()
            if let ticket { _ = try? await EngineBridge.shared.invoke("session-simulator:release", [ticket.arguments]) }
            for subscription in subscriptions { subscription.cancel() }; subscriptions = []
        }
    }
    private func subscribe() {
        guard subscriptions.isEmpty else { return }
        subscriptions = [
            EngineBridge.shared.on("session-simulator:frame") { [weak self] args in
                guard let self, args.count == 3, let current = self.ticket,
                      let incoming = UIGSessionSimulatorTicket(value: args[0], for: self.id),
                      let device = args[1] as? String, current.acceptsFrame(ticket: incoming, deviceID: device),
                      let data = args[2] as? Data else { return }
                self.model.receiveDockFrame(id: device, data: data)
            },
            EngineBridge.shared.on("session-simulator:closed") { [weak self] args in
                guard let self, args.count >= 2, let current = self.ticket,
                      let incoming = UIGSessionSimulatorTicket(value: args[0], for: self.id),
                      let device = args[1] as? String, current.acceptsFrame(ticket: incoming, deviceID: device) else { return }
                self.model.receiveDockClosed(id: device, reason: args.count > 2 ? args[2] as? String ?? "" : "")
            },
            EngineBridge.shared.on("session-simulator:attachment") { [weak self] args in
                guard let self, let value = args.first,
                      let incoming = UIGSessionSimulatorTicket(value: value, for: self.id), incoming.slot == self.slot else { return }
                if (value as? [String: Any])?["invalidated"] as? Bool == true {
                    self.adopt(nil); self.problem = "This session ended or was replaced."
                } else if incoming != self.ticket {
                    self.adopt(incoming)
                    if self.visible > 0, !self.busy, let entry = self.selected, entry.available {
                        Task { await self.model.open(entry.id) }
                    }
                }
            }
        ]
    }
    private func snapshot() async throws -> UIGSessionSimulatorTicket {
        guard !session.ended, !session.removed else { throw Self.unavailable("This session has ended.") }
        let result = try await EngineBridge.shared.invoke("session-simulator:get", [["sessionId": id, "slot": slot]])
        guard let value = UIGSessionSimulatorTicket(value: result, for: id) else { throw Self.unavailable("The session attachment could not be read.") }
        return value
    }
    private func adopt(_ next: UIGSessionSimulatorTicket?) {
        if next == ticket { return }
        generation += 1; model.back(); model.shot = nil
        ticket = next; model.attachmentRevision = next?.token
        problem = "" // a new attachment (or none): an error about the old one no longer applies

    }
    func select(_ entry: DeviceEntry) async {
        guard lifecycleEnabled else { return }
        guard !busy else { return }
        busy = true; problem = ""; defer { busy = false }
        do {
            let answer: Any
            do {
                answer = try await EngineBridge.shared.invoke("session-simulator:attach", [["sessionId": id, "slot": slot, "deviceId": entry.id]])
            } catch where Self.isAlreadyOpen(error) {
                // Asad, 31 Oct: "That device is already open in this session" while nothing showed it. The session's
                // other place holds it with its panel hidden: it moves here. Shown in the other panel: say where.
                guard try await takeFromHiddenPlace(entry.id) else { throw Self.unavailable("That device is already shown in this session's other device panel.") }
                answer = try await EngineBridge.shared.invoke("session-simulator:attach", [["sessionId": id, "slot": slot, "deviceId": entry.id]])
            }
            guard let next = UIGSessionSimulatorTicket(value: answer, for: id) else { throw Self.unavailable("The device could not be attached.") }
            adopt(next)
            defaults.set(entry.id, forKey: UIGSessionSimulatorState.deviceKey(sessionID: id, slot: slot))
            if entry.available { await model.open(entry.id) }
            else if entry.canBoot { await model.start(entry) }
        } catch { fail(error) }
    }
    func detach() async {
        guard let ticket else { return }
        do {
            let answer = try await EngineBridge.shared.invoke("session-simulator:detach", [ticket.arguments])
            adopt(UIGSessionSimulatorTicket(value: answer, for: id))
            defaults.removeObject(forKey: UIGSessionSimulatorState.deviceKey(sessionID: id, slot: slot))
        } catch { fail(error) }
    }
    private func invokeDevice(_ channel: String, _ args: [Any?]) async throws -> Any {
        if channel == "devices:watch", args.count > 1, args[1] as? Bool == false,
           args[0] as? String != ticket?.deviceID { return NSNull() }
        let current: UIGSessionSimulatorTicket
        if let ticket { current = ticket } else { current = try await snapshot() }
        if ticket == nil { ticket = current; model.attachmentRevision = current.token }
        let epoch = generation
        do {
            // A missing value (an Android short tap has no hold time) goes as null: a nested Optional cannot cross the bridge.
            let wire: [Any] = args.map { $0 ?? NSNull() }
            var answer: Any
            do { answer = try await EngineBridge.shared.invoke("session-simulator:device", [current.arguments, channel, wire]) }
            catch where Self.isStale(error) {
                // The attachment moved on (popping out, Hoot or another panel re-read it): take the current one and
                // try once more, instead of showing "Refresh the attachment" in a window that cannot.
                let fresh = try await snapshot()
                guard fresh.deviceID == current.deviceID else { throw error }
                ticket = fresh; model.attachmentRevision = fresh.token
                answer = try await EngineBridge.shared.invoke("session-simulator:device", [fresh.arguments, channel, wire])
            }
            guard epoch == generation, !Task.isCancelled else { throw Self.unavailable("The attached device changed.") }
            // A one-off device hiccup ("Android agent did not acknowledge command 34") must not stay on the panel
            // once the device answers again (seen live on an Android emulator, 10 Oct).
            if !problem.isEmpty, ticket != nil { problem = "" }
            if channel == "devices:boot", let value = answer as? [String: Any], value["ok"] as? Bool == true,
               let newID = value["id"] as? String, newID != current.deviceID {
                let updated = try await snapshot()
                guard updated.deviceID == newID else { throw Self.unavailable("The started device changed.") }
                ticket = updated; model.attachmentRevision = updated.token
            }
            return answer
        } catch { fail(error); throw error }
    }
    private func send(_ text: String, target: AgentSessionRow, round: String?, revision: String?) async -> String? {
        guard let ticket, ticket.token == revision, target.id == id else { return "The session attachment changed. Nothing was sent." }
        do {
            var args = ticket.arguments; if let round { args["roundId"] = round }
            let answer = try await EngineBridge.shared.invoke("session-simulator:send", [args, ["text": text, "submit": true]])
            if let value = answer as? [String: Any], value["ok"] as? Bool == false {
                return value["message"] as? String ?? "The session did not accept the message."
            }
            return nil
        } catch { return error.localizedDescription }
    }
    private static func isAlreadyOpen(_ error: any Error) -> Bool {
        ((error as? EngineWireError)?.description ?? error.localizedDescription).contains("already open in this session")
    }
    /// The session's other place holds `deviceID` while no panel shows it (closed, or never opened: an agent attached
    /// it there): it is let go there so this panel can show it. False when the other panel is on screen.
    private func takeFromHiddenPlace(_ deviceID: String) async throws -> Bool {
        let other = slot == 0 ? 1 : 0
        guard !NativeUIGSessionSimulatorStore.shared.isShowing(session, slot: other) else { return false }
        let result = try await EngineBridge.shared.invoke("session-simulator:get", [["sessionId": id, "slot": other]])
        guard let held = UIGSessionSimulatorTicket(value: result, for: id), held.deviceID != nil else { return true }
        _ = try await EngineBridge.shared.invoke("session-simulator:detach", [held.arguments])
        defaults.removeObject(forKey: UIGSessionSimulatorState.deviceKey(sessionID: id, slot: other))
        NSLog("[session simulator] %@ moved from this session's hidden place %d to place %d", deviceID, other, slot)
        return true
    }
    private static func isStale(_ error: any Error) -> Bool {
        let text = (error as? EngineWireError)?.description ?? error.localizedDescription
        return text.contains("Refresh the attachment")
    }
    private func fail(_ error: any Error) {
        let text = (error as? EngineWireError)?.description ?? error.localizedDescription
        if NativeSimulatorModel.isStaleAttachment(text) {
            NSLog("[session simulator] stale attachment hidden: %@", text)
            resync(); return
        }
        problem = text
    }
    /// Takes the current attachment quietly (the device id kept, so the phone on show stays).
    private func resync() {
        Task { [weak self] in
            guard let self, let fresh = try? await self.snapshot() else { return }
            if fresh.deviceID == self.ticket?.deviceID { self.ticket = fresh; self.model.attachmentRevision = fresh.token }
            else { self.adopt(fresh) }
            if NativeSimulatorModel.isStaleAttachment(self.problem) { self.problem = "" }
        }
    }
    private static func unavailable(_ message: String) -> NSError {
        NSError(domain: "TerminalDeck.SessionSimulator", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
