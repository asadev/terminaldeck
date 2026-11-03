import AVFoundation
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Notifications (`NotificationsSection.tsx`): the table's rows, a
/// test banner (and the way to the system's notification settings) under
/// "Tell me when a session finishes", a Test under "Sound", and what the check
/// found. Turning a banner on proves it with one, as the page does.
struct NativeNotificationsSettings: View {
    @State private var check = NativeNotificationCheck()
    @State private var soundNote: String?
    private let store = NativeSettingsValues.shared

    var body: some View {
        NativeSettingsPage(sectionId: "notifications") {
            Section("Tell me when") {
                // TRUTH-B: shown on the Mac too (it was compiled out, so session banners could not be turned off here).
                if let definition = finishDefinition {
                    NativeSettingControl(setting: definition, onSave: saveAndProve)
                }
                NativeSettingRow(label: "Approvals", help: "Always on the phone too.",
                    more: "Approval requests always reach the owner. This cannot be turned off here.") {
                    Text("Always on").foregroundStyle(.secondary)
                }
                testButtons
            }
            Section("How") {
                // TRUTH-B: the switch the Sound picker depends on was not on the Mac page; the app plays it now.
                NativeSettingRow(label: "Play a sound when a session finishes") {
                    Toggle("Play a sound when a session finishes", isOn: Binding(get: { store.bool("notifications.onFinishSound") },
                        set: { store.save(["notifications.onFinishSound": .bool($0)]) }))
                        .labelsHidden().toggleStyle(.switch).disabled(store.loading)
                }
                NativeSettingRow(label: "Sound") {
                    HStack {
                        Picker("Sound", selection: Binding(get: { store.string("notifications.soundName") },
                            set: { store.save(["notifications.soundName": .string($0)]) })) {
                            Text("Chime").tag("chime"); Text("Blip").tag("blip"); Text("Knock").tag("knock")
                        }.labelsHidden().disabled(store.loading)
                        Button("Test", action: testSound)
                    }
                }
            }
            if soundNote != nil || check.state != nil {
                Section {
                    if let soundNote { NativeCodingAINotice(tone: .warn, text: soundNote) }
                    if let state = check.state {
                        VStack(alignment: .leading, spacing: 6) {
                            NativeCodingAINotice(tone: Self.tone(state.tone), text: state.text)
                            if state.offerSettings && check.canOpenSettings {
                                Button("Open notification settings") { check.openSettings() }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { check.readSupport() }
    }

    private var finishDefinition: SettingDefinition? {
        guard var definition = SettingsSchema.setting("notifications.onComplete") else { return nil }
        definition.label = "A session finishes"; definition.help = ""
        return definition
    }

    /// The check's tone as a notice's (kept out of the view body so it type-checks fast).
    private static func tone(_ tone: SettingsNotifications.Tone) -> NativeCodingAINotice.Tone {
        switch tone {
        case .info: return .info
        case .warn: return .warn
        case .error: return .error
        }
    }

    private var testButtons: AnyView {
        AnyView(HStack {
            Button(check.busy ? SettingsNotifications.askingLabel : SettingsNotifications.testLabel) { check.fire(test: true) }
                .disabled(check.busy)
            if check.canOpenSettings {
                Button("Open notification settings") { check.openSettings() }
            }
        })
    }

    private func saveAndProve(_ patch: [String: CodingAIJSON]) {
        store.save(patch)
        if SettingsNotifications.turnedOnABanner(patch) { check.fire(test: false) }
    }

    private func testSound() {
        let name = store.string("notifications.soundName")
        let id = SettingsSound.isSoundId(name) ? name : "chime"
        soundNote = NativeSettingsSoundPlayer.shared.play(id) ? nil : SettingsNotifications.noAudio
    }
}

/// `useNotificationCheck`: show a banner through the engine, then ask the OS
/// whether it recorded one.
@MainActor
@Observable
final class NativeNotificationCheck {
    private(set) var canOpenSettings = false
    private(set) var state: SettingsNotifications.CheckState?
    private(set) var busy = false

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func readSupport() {
        Task {
            guard let raw = try? await call("notifications:support") else { return }
            canOpenSettings = SettingsNotifications.support(raw).settingsPane
        }
    }

    func fire(test: Bool) {
        let since = Date().timeIntervalSince1970 * 1000
        let banner = SettingsNotifications.banner(test: test)
        let id = "settings-\(UUID().uuidString)"
        Task {
            do {
                _ = try await call("native-shell:notify", [["id": id, "title": banner.title, "body": banner.body]])
            } catch {
                state = .init(text: CodingAIErrorText.from(error, fallback: SettingsNotifications.refused), tone: .error, offerSettings: true)
                return
            }
            busy = true
            state = SettingsNotifications.checking
            let raw = (try? await call("notifications:delivery", [since])) ?? .null
            _ = try? await call("native-shell:notify-close", [id])
            busy = false
            let report = SettingsNotifications.report(raw)
            state = SettingsNotifications.deliveryCopy(verdict: report.verdict, at: report.at, test: test)
        }
    }

    func openSettings() {
        Task {
            do {
                _ = try await call("notifications:open-settings")
            } catch {
                state = .init(text: SettingsNotifications.wouldNotOpen, tone: .error, offerSettings: false)
            }
        }
    }
}

/// Plays the synthesised finish sounds (`notification-sound.ts`).
@MainActor
final class NativeSettingsSoundPlayer {
    static let shared = NativeSettingsSoundPlayer()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    /// False when there is no audio output to play it on.
    func play(_ id: String) -> Bool {
        let rate = 44_100.0
        let samples = SettingsSound.samples(id, sampleRate: rate)
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        let engine = self.engine ?? AVAudioEngine()
        let player = self.player ?? AVAudioPlayerNode()
        if self.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            self.engine = engine
            self.player = player
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return false
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        return true
    }
}
