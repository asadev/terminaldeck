import SwiftUI
import TerminalDeckNativeCore

/// Legacy section route stays available; General owns the visible row.
struct NativePowerSettings: View {
    var body: some View { NativeGeneralSettings() }
    static func errorText(_ error: Error, fallback: String) -> String { NativeMacAwakeSetting.errorText(error, fallback: fallback) }
}

struct NativeMacAwakeSetting: View {
    @State private var state: LidAwakeState?
    @State private var loading = true
    @State private var changing = false
    @State private var result: LidAwakeResult?
    @State private var subscription: EngineSubscription?

    var body: some View {
        Group {
            if loading || state?.supported == true {
                NativeSettingsToggle(label: "Keep this Mac awake",
                                 help: "Sessions keep running with the lid closed. While Terminal Deck is open this Mac never idles to sleep, whatever this switch says.",
                                 more: PowerWords.caution(hasLid: state?.hasLid ?? true),
                                 value: Binding(
                        get: { state?.known == true && state?.on == true },
                        set: change))
                        .disabled(loading || changing || state?.supported != true || state?.known != true)
            }
            if changing { Text("Changing…").font(.callout).foregroundStyle(.secondary) }
            if let result { NativeCodingAINotice(tone: result.isWarning ? .warn : .info, text: result.message) }
            if let warning = state?.warning {
                NativeCodingAIInfo(label: "Keep this Mac awake", text: warning)
            }
        }
        .task { await load() }
        .onDisappear { subscription = nil }
    }

    private func load() async {
        if subscription == nil {
            subscription = EngineBridge.shared.on("power:lid-awake:state") { args in
                if let next = LidAwakeState.decode(args.first) { state = next }
            }
        }
        do { state = LidAwakeState.decode(try await EngineBridge.shared.invoke("power:lid-awake:get")) }
        catch { result = LidAwakeResult(outcome: .failed, state: nil, message: Self.errorText(error, fallback: PowerWords.readFailed)) }
        loading = false
    }

    private func change(_ next: Bool) {
        result = nil; changing = true
        Task {
            defer { changing = false }
            do {
                let answer = LidAwakeResult.decode(try await EngineBridge.shared.invoke("power:lid-awake:set", [next]))
                result = answer
                if let fresh = answer.state { state = fresh }
            } catch { result = LidAwakeResult(outcome: .failed, state: nil, message: Self.errorText(error, fallback: PowerWords.changeFailed)) }
        }
    }

    static func errorText(_ error: Error, fallback: String) -> String {
        if let wire = error as? EngineWireError, case .refused(let why) = wire, !why.isEmpty { return why }
        return fallback
    }
}
