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
        let soundHelp = SettingsNotifications.soundHelp(playsOnFinish: store.bool("notifications.onFinishSound"))
        NativeSettingsPage(sectionId: "notifications") {
            Section {
                NativeSettingsList(
                    section: "notifications",
                    helpFor: soundHelp.map { ["notifications.soundName": $0] } ?? [:],
                    onSave: saveAndProve,
                    extras: [
                        "notifications.onComplete": testButtons,
                        "notifications.soundName": AnyView(Button("Test", action: testSound)),
                    ])
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
