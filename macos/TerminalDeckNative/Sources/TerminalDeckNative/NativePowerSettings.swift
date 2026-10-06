import SwiftUI
import TerminalDeckNativeCore

/// Settings → Power (`PowerSection.tsx`): one switch — keep this Mac running with
/// the lid closed — and every sentence the page says about it, in the same order:
/// the idle note, the heat-and-battery caution, the change in flight, why the
/// switch is missing or unsure, why it was already on, the machine's own warning,
/// and the answer to the last change.
struct NativePowerSettings: View {
    @State private var state: LidAwakeState?
    @State private var loading = true
    @State private var changing = false
    @State private var result: LidAwakeResult?
    @State private var subscription: EngineSubscription?

    var body: some View {
        let supported = state?.supported == true
        let known = state?.known == true
        let on = known && state?.on == true
        let hasLid = state?.hasLid ?? true
        let answered = !loading && state != nil
        let unavailable = answered && !supported
        let unwired = !EngineBridge.shared.isReady
        NativeSettingsPage(sectionId: "power") {
            Section {
                if !unavailable {
                    NativeSettingRow(label: PowerWords.rowLabel(hasLid: hasLid), help: PowerWords.help(hasLid: hasLid)) {
                        Toggle("", isOn: Binding(get: { on }, set: change))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(unwired || loading || changing || !supported || !known)
                            .accessibilityLabel(PowerWords.rowLabel(hasLid: hasLid))
                    }
                }
                if state?.idleBlocked == true, let note = PowerWords.idleBlocked(hasLid: hasLid, lidAwake: known ? on : nil) {
                    NativeCodingAINotice(tone: .info, text: note)
                }
                if !unavailable, let caution = PowerWords.caution(hasLid: hasLid) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PowerWords.cautionTitle).font(.subheadline.weight(.semibold))
                        Text(caution)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if changing {
                    NativeCodingAINotice(tone: .info, text: PowerWords.changing(needsAuthorization: state?.needsAuthorization == true))
                }
                if unwired {
                    NativeCodingAINotice(tone: .warn, text: PowerWords.unwired)
                }
                if !unwired, unavailable {
                    NativeCodingAINotice(tone: .warn, text: state?.detail ?? PowerWords.cannotHold)
                }
                if !unwired, !loading, supported, !known {
                    NativeCodingAINotice(tone: .warn, text: "\(PowerWords.unknownState) \(state?.detail ?? "")")
                }
                if on, state?.preexisting == true {
                    NativeCodingAINotice(tone: .info, text: PowerWords.preexisting)
                }
                if let warning = state?.warning {
                    NativeCodingAINotice(tone: .warn, text: warning)
                }
                if let result {
                    NativeCodingAINotice(tone: result.isWarning ? .warn : .info, text: result.message)
                }
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
        do {
            let raw = try await EngineBridge.shared.invoke("power:lid-awake:get")
            state = LidAwakeState.decode(raw)
        } catch {
            result = LidAwakeResult(outcome: .failed, state: nil, message: Self.errorText(error, fallback: PowerWords.readFailed))
        }
        loading = false
    }

    private func change(_ next: Bool) {
        result = nil
        changing = true
        Task {
            do {
                let answer = LidAwakeResult.decode(try await EngineBridge.shared.invoke("power:lid-awake:set", [next]))
                changing = false
                result = answer
                if let fresh = answer.state { state = fresh }
            } catch {
                changing = false
                result = LidAwakeResult(outcome: .failed, state: nil, message: Self.errorText(error, fallback: PowerWords.changeFailed))
            }
        }
    }

    /// `errorText`: the engine's own sentence, or the fallback.
    static func errorText(_ error: Error, fallback: String) -> String {
        if let wire = error as? EngineWireError, case .refused(let why) = wire, !why.isEmpty { return why }
        return fallback
    }
}
