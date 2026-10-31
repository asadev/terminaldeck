import Foundation
import TerminalDeckNativeCore

/// AI sessions' device tools send iOS Simulator input the phone panel's way (Asad, 22 Oct 2026: "fix ai taps";
/// DeviceToolDirect): the app installs the route at launch (DeviceDirectInputs); without one, everything goes
/// the engine's way as before.
public final class BackendAppDeviceDirectInput: @unchecked Sendable {
    public typealias Route = @Sendable (_ id: String, _ input: DeviceInput, _ modifiers: [String]) async -> DeviceToolDirect.Answer
    public static let shared = BackendAppDeviceDirectInput()
    private let lock = NSLock()
    private var route: Route?
    public init() {}
    public func install(_ route: Route?) { lock.withLock { self.route = route } }
    public var installed: Bool { lock.withLock { route != nil } }

    /// true: delivered the direct way; false: send it the engine's way. Throws a refusal the AI can read when
    /// neither way can deliver it (the engine's way would drop it without a word).
    public func send(_ id: String, _ input: DeviceInput, modifiers: [String] = []) async throws -> Bool {
        guard let route = lock.withLock({ self.route }) else { return false }
        // Devices freeze (26 Oct): the input helper answers within its own waits (ready, each typed piece's echo);
        // past them this call ends in words, never by holding the tool. Not sent again the engine's way: it may
        // have played already.
        let answer: DeviceToolDirect.Answer
        do {
            answer = try await BackendAppDeviceDeadline.run(within: Self.deadline(for: input), "The simulator's input helper") {
                await route(id, input, modifiers)
            }
        } catch is BackendAppDeviceDeadline.Expired {
            throw BackendDeckToolsMachinesShared.refused("The simulator's input helper did not answer in time, so this input may or may not have reached the device. Look at the screen (devices_screenshot) before trying it again.")
        }
        switch answer {
        case .sent: return true
        case .engine: return false
        case .refused(let why): throw BackendDeckToolsMachinesShared.refused(why)
        }
    }

    /// Two helper ready waits, each typed piece's echo wait and the input's own play time, with room to spare.
    static func deadline(for input: DeviceInput) -> Double {
        var seconds = 30 + DeviceToolDirect.duration(input) / 1_000
        if case .type(let text) = input { seconds += Double(DeviceToolDirect.pieces(text).count) * DeviceToolDirect.pieceWithin }
        return seconds
    }
}
