@preconcurrency import AVFoundation
import SwiftUI
import TerminalDeckNativeCore

/// Explicit Mac playback. Input stays with the composer's existing dictation owner.
@MainActor @Observable final class NativeChatVoice: NSObject, AVSpeechSynthesizerDelegate {
    let dictation: HootComposerVoice
    private(set) var speaking = false
    private(set) var speakingRecord: String?
    private(set) var preparing = false
    @ObservationIgnored private var player: AVSpeechSynthesizer?
    @ObservationIgnored private var utteranceID: ObjectIdentifier?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let playOverride: ((String) -> Void)?
    @ObservationIgnored private let stopOverride: (() -> Void)?
    init(dictation: HootComposerVoice, play: ((String) -> Void)? = nil, stop: (() -> Void)? = nil) {
        self.dictation = dictation; playOverride = play; stopOverride = stop
        super.init()
    }
    static func checkedText(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768 else { throw NativeRPCError.invalidArguments("Choose a recorded assistant reply up to 32 KiB to read aloud.") }
        return text
    }
    var state: NativeRPCValue {
        let phase = speaking ? "speaking" : dictation.recording ? "listening" : dictation.starting ? "starting" : dictation.finishing ? "finishing" : preparing ? "preparing" : "idle"
        return .object([.init("state", .string(phase)), .init("speakingRecordId", speakingRecord.map(NativeRPCValue.string) ?? .null),
            .init("microphoneAvailable", .bool(dictation.available)), .init("dictationProblem", dictation.problem.map(NativeRPCValue.string) ?? .null),
            .init("playback", .string("Explicit Mac system voice")), .init("input", .string("Existing on-device dictation into the draft; no automatic send")), .init("providerConversationalVoice", .null)])
    }
    func play(text: String, record: String) async throws {
        let text = try Self.checkedText(text)
        guard !preparing else { throw NativeRPCError.invalidArguments("Wait for voice playback to finish preparing.") }
        preparing = true; defer { preparing = false }
        generation += 1; let mine = generation
        stopSpeaking(); await dictation.stop()
        guard mine == generation else { return }
        if let playOverride { speaking = true; speakingRecord = record; playOverride(text); return }
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else { throw NativeRPCError.invalidArguments("No Mac speech voice is available. Add a system voice in Accessibility → Spoken Content.") }
        let engine = player ?? AVSpeechSynthesizer(); player = engine; engine.delegate = self
        let utterance = AVSpeechUtterance(string: text)
        utteranceID = ObjectIdentifier(utterance); speaking = true; speakingRecord = record
        engine.speak(utterance)
    }
    func beginDictation() { generation += 1; stopSpeaking() }
    func listen(write: @escaping (String) -> Void) async { beginDictation(); await dictation.start(write: write) }
    func stopSpeaking() {
        let wasSpeaking = speaking
        utteranceID = nil; speaking = false; speakingRecord = nil
        if wasSpeaking { if let stopOverride { stopOverride() } else { player?.stopSpeaking(at: .immediate) } }
    }
    func stop() async { generation += 1; stopSpeaking(); await dictation.stop() }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish(ObjectIdentifier(utterance)) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish(ObjectIdentifier(utterance)) }
    nonisolated private func finish(_ id: ObjectIdentifier) {
        Task { @MainActor [weak self] in guard let self, self.utteranceID == id else { return }; self.utteranceID = nil; self.speaking = false; self.speakingRecord = nil }
    }
}
extension NativeHootChatModel {
    var spokenReplies: [HootChatRow] { rows.filter { $0.kind == .message && !($0.value["text"].string ?? "").isEmpty } }
    func voiceTool(_ action: String, request: String?) async throws -> NativeRPCValue {
        if action == "open" { chatVoiceVisible = true }
        if action == "close" { chatVoiceVisible = false }
        if action == "stop" { await chatVoice.stop() }
        if action == "speak" {
            guard !busy, !loading, !changingConversation else { throw NativeRPCError.invalidArguments("Wait for the assistant reply to finish before reading it aloud.") }
            guard let row = request.flatMap({ id in spokenReplies.first { $0.id == id } }) ?? (request == nil ? spokenReplies.last : nil) else { throw NativeRPCError.invalidArguments("Choose an assistant reply ID from this conversation.") }
            try await chatVoice.play(text: row.value["text"].string ?? "", record: row.id)
        }
        if action == "listen" {
            guard !readOnly, !loading, !changingConversation else { throw NativeRPCError.invalidArguments("Wait for this chat to be editable before dictating.") }
            let prefix = composerDraft.text, conversation = conversationID
            await chatVoice.listen { [weak self] heard in
                guard let self, self.conversationID == conversation, !self.readOnly else { return }
                self.composerDraft.text = prefix + (prefix.isEmpty || prefix.hasSuffix(" ") ? "" : " ") + heard
            }
        }
        return chatVoice.state.setting("replies", .array(spokenReplies.map { .object([.init("id", .string($0.id)), .init("text", .string(String(($0.value["text"].string ?? "").prefix(200))))]) }))
    }
}
struct NativeChatVoicePopover: View {
    @Bindable var model: NativeHootChatModel
    @State private var problem: String?
    private var voice: NativeChatVoice { model.chatVoice }
    var body: some View {
        Color.clear
            .popover(isPresented: $model.chatVoiceVisible) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Mac voice and dictation").font(.headline)
                    Text("Reply playback uses the Mac system voice. Listening uses the same on-device dictation as the composer and adds text to your draft. Nothing sends automatically. Conversation with voice, below, connects supported provider voice separately.").font(.caption).foregroundStyle(.secondary)
                    Text("Voice: \(voice.state["state"].string ?? "idle")").font(.callout).accessibilityAddTraits(.updatesFrequently)
                    HStack {
                        Button("Listen into draft") { run("listen") }.disabled(!voice.dictation.available || voice.dictation.starting || voice.dictation.recording || voice.dictation.finishing || model.readOnly || model.loading || model.changingConversation)
                        Button("Stop voice") { run("stop") }.disabled(!voice.speaking && !voice.preparing && !voice.dictation.recording && !voice.dictation.starting && !voice.dictation.finishing)
                    }
                    if !voice.dictation.available { Text("No microphone connected.").font(.caption).foregroundStyle(.secondary) }
                    ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
                        if model.spokenReplies.isEmpty { Text("No assistant replies to read yet.").foregroundStyle(.secondary) }
                        ForEach(model.spokenReplies.suffix(8).reversed()) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.value["text"].string ?? "").lineLimit(3).font(.callout)
                                Button("Read reply aloud") { run("speak", row.id) }.disabled(model.busy || model.loading || model.changingConversation || voice.preparing)
                            }
                        }
                    } }.frame(maxHeight: 280)
                    if let line = problem ?? voice.dictation.problem { Text(line).font(.caption).foregroundStyle(.red) }
                    // Provider voice was the Provider sheet's own voice section: one entry per job (17 Oct 2026).
                    GroupBox { NativeChatProviderVoiceView(sessionID: model.source.sessionID ?? "hoot").padding(4) }
                }.padding(16).frame(width: 520)
            }
            .onChange(of: model.conversationID) { _, _ in Task { await voice.stop() } }
            .onAppear { voice.dictation.viewAppeared() }
            .onDisappear { if voice.dictation.viewDisappeared() { Task { await voice.stop() } } }
    }
    private func run(_ action: String, _ request: String? = nil) { Task { do { _ = try await model.voiceTool(action, request: request); problem = nil } catch { problem = error.localizedDescription } } }
}
