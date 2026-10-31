import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

// Asad, 22 Oct 2026: "fix ai taps". Once Device Hub (or Xcode) has touched an iOS Simulator, the simulator takes
// input only from Apple's CoreDevice touchscreen until it shuts down. AI sessions' device tools (devices_tap,
// devices_swipe, devices_type, devices_button) take the phone panel's route (DeviceToolDirect): the direct helper when
// the touchscreen in use takes it there, the device engine otherwise (since 28 Oct Terminal Deck's own, which types
// long or non-US text through the pasteboard and ⌘V on this same route), a refusal in words when neither can deliver
// it. One helper per simulator: a panel showing it lends its own; otherwise an input-only helper (no screen, no frame
// notices) is started for the AI and closed after a short quiet spell, so nothing runs while no input comes. The
// helper is the only way input reaches an iOS Simulator now, so it is used even when the panel's direct screen is off.

/// Routes AI device-tool input for iOS Simulators through the direct helpers.
@MainActor final class DeviceDirectInputs {
    static let shared = DeviceDirectInputs()
    /// An input-only helper closes this long after the last input it carried.
    static let idleAfter: Duration = .seconds(20)
    /// How long input waits for a helper's ready line before the device engine answers instead.
    static let readyWithin: Double = 6
    /// An input-only helper that failed is tried again after this long.
    static let retryAfter: TimeInterval = 10

    /// Panels' helpers (screen and input), by simulator.
    private var panels: [String: [ObjectIdentifier: Weak]] = [:]
    /// Input-only helpers started for AI input, by simulator.
    private var own: [String: SimDirectSource] = [:]
    private var idle: [String: Task<Void, Never>] = [:]
    /// Input carried by an input-only helper now: it does not close under it.
    private var busy: [String: Int] = [:]
    /// An input-only helper that failed is not tried again for this simulator for a short while (the AI is told
    /// in words meanwhile).
    private var failures: [String: Date] = [:]
    /// The touchscreen each simulator used when a helper last said (true: CoreDevice's). Input that finds no helper
    /// ready for a simulator last seen on CoreDevice's is refused in words: the engine's way would answer "sent" and
    /// drop it (review 22 Oct 2026). Forgotten when a helper sees the simulator shut down.
    private var lastCoreDevice: [String: Bool] = [:]

    private final class Weak {
        weak var source: SimDirectSource?
        init(_ source: SimDirectSource) { self.source = source }
    }

    /// The tools' way in (BackendAppDeviceToolService). Called once at launch.
    static func install() {
        BackendAppDeviceDirectInput.shared.install { id, input, modifiers in
            await DeviceDirectInputs.shared.send(id, input, modifiers: modifiers)
        }
    }

    // MARK: Panels

    /// A panel started its helper for this simulator: an input-only one for it closes first.
    func panelStarted(_ source: SimDirectSource) {
        panels[source.udid, default: [:]][ObjectIdentifier(source)] = Weak(source)
        closeOwn(source.udid, why: "a panel shows it now")
    }

    func panelStopped(_ source: SimDirectSource) {
        panels[source.udid]?[ObjectIdentifier(source)] = nil
        if panels[source.udid]?.isEmpty == true { panels[source.udid] = nil }
    }

    private func panelSource(_ udid: String) -> SimDirectSource? {
        panels[udid]?.values.compactMap(\.source).first { !$0.isStopped }
    }

    /// A helper (a panel's or an input-only one) said which touchscreen the simulator uses; nil: it shut down.
    func heard(_ udid: String, coreDevice: Bool?) { lastCoreDevice[udid] = coreDevice }

    // MARK: Input

    func send(_ id: String, _ input: DeviceInput, modifiers: [String]) async -> DeviceToolDirect.Answer {
        guard id.hasPrefix("ios:") else { return .engine }
        let udid = String(id.dropFirst(4))
        guard UUID(uuidString: udid) != nil else { return .engine }
        // Twice at most: an input-only helper can close under the wait when a panel takes the simulator over.
        for _ in 0..<2 {
            let lent = panelSource(udid)
            guard let source = lent ?? ownSource(udid) else { return noHelper(udid, input) }
            if lent == nil { hold(udid) }
            let ready = await source.whenReady(within: Self.readyWithin)
            if let ready, !source.isStopped {
                let answer = await deliver(input, modifiers: modifiers, through: source, ready: ready)
                if lent == nil { release(udid) }
                return answer
            }
            if lent == nil { release(udid) }
            // A panel took the simulator over meanwhile: through its helper then.
            if lent == nil, let panel = panelSource(udid), panel !== source { continue }
            // Never got ready: closed and not tried again for a while. Ended by itself: onEnded decided.
            if lent == nil, !source.isStopped {
                if own[udid] === source { closeOwn(udid, why: "it did not get ready") }
                failures[udid] = Date()
            }
            return noHelper(udid, input)
        }
        return noHelper(udid, input)
    }

    /// No helper can take it now: the device engine answers (typing through the pasteboard, anything else in words),
    /// unless the simulator was last seen on CoreDevice's touchscreen, which says so in its own words.
    private func noHelper(_ udid: String, _ input: DeviceInput) -> DeviceToolDirect.Answer {
        lastCoreDevice[udid] == true ? DeviceToolDirect.untaken(input, coreDevice: true) : .engine
    }

    private func hold(_ udid: String) {
        idle.removeValue(forKey: udid)?.cancel()
        busy[udid, default: 0] += 1
    }

    private func release(_ udid: String) {
        let left = (busy[udid] ?? 1) - 1
        busy[udid] = left > 0 ? left : nil
        quietly(udid)
    }

    /// The input through this helper when the touchscreen in use takes it there, else the device engine or a
    /// refusal (DeviceToolDirect.untaken). Answers once the input has played on the device.
    private func deliver(_ input: DeviceInput, modifiers: [String], through source: SimDirectSource,
                         ready: SimDirectLine.Ready) async -> DeviceToolDirect.Answer {
        let coreDevice = source.current?.coreDevice ?? ready.coreDevice
        let taken: Bool
        switch input {
        case .type(let text) where coreDevice && source.canType:
            // CoreDevice's touchscreen: typing goes as keys, in pieces each within one helper write. The next piece
            // is written only once the helper has taken this one (its echo): a fixed pause let a slow helper's pipe
            // fill, and the short write ended the helper, a panel's screen with it (review 22 Oct 2026).
            guard DeviceDirectKeys.strokes(text) != nil else { return DeviceToolDirect.untaken(input, coreDevice: true) }
            let parts = DeviceToolDirect.pieces(text)
            var written = 0, confirmed = true
            for part in parts {
                guard !source.isStopped, source.send(.type(part)) else { break }
                written += 1
                guard await source.settled(within: DeviceToolDirect.pieceWithin) else { confirmed = false; break }
            }
            if written == 0 {
                taken = false
            } else if written == parts.count, confirmed || !source.isStopped {
                // All written; a last echo that is merely late still counts: the helper has every key.
                taken = true
            } else {
                return .refused("The simulator's input helper stopped or fell behind while typing, so only part of the text may have been typed. Check the field before typing the rest.")
            }
        case .key(let name):
            taken = source.sendKey(name, modifiers: modifiers)
        default:
            taken = source.sendFromTool(input)
        }
        guard taken else { return DeviceToolDirect.untaken(input, coreDevice: source.current?.coreDevice ?? coreDevice) }
        try? await Task.sleep(for: .milliseconds(Int(DeviceToolDirect.duration(input))))
        return .sent
    }

    // MARK: Input-only helpers

    private func ownSource(_ udid: String) -> SimDirectSource? {
        if let running = own[udid], !running.isStopped { return running }
        own[udid] = nil
        if let failed = failures[udid], Date().timeIntervalSince(failed) < Self.retryAfter { return nil }
        let source = SimDirectSource(udid: udid, screen: false)
        source.onEnded = { [weak self, weak source] reason in
            guard let self, let source, self.own[udid] === source else { return }
            self.own[udid] = nil
            self.idle.removeValue(forKey: udid)?.cancel()
            if reason != "The simulator shut down." { self.failures[udid] = Date() }
        }
        own[udid] = source
        source.start()
        return source.isStopped ? nil : source
    }

    /// After the last input, the input-only helper closes once nothing has come for a short while.
    private func quietly(_ udid: String) {
        idle.removeValue(forKey: udid)?.cancel()
        guard own[udid] != nil, busy[udid] == nil else { return }
        idle[udid] = Task { [weak self] in
            try? await Task.sleep(for: Self.idleAfter)
            guard !Task.isCancelled, let self, self.busy[udid] == nil else { return }
            self.idle[udid] = nil
            self.closeOwn(udid, why: "no input for a while")
        }
    }

    private func closeOwn(_ udid: String, why: String) {
        idle.removeValue(forKey: udid)?.cancel()
        guard let source = own.removeValue(forKey: udid) else { return }
        NativeCompositionRoot.note("device direct: \(udid) input helper closed: \(why)")
        source.stop()
    }
}
