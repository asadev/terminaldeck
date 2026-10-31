@preconcurrency import AVFoundation
import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Provider voice is separate from local dictation and Mac text-to-speech.
struct NativeChatProviderVoiceView: View {
    let sessionID: String
    @State private var voice = NativeChatProviderVoice()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Conversation with voice", systemImage: "waveform")
                Spacer()
                Text(voice.state).foregroundStyle(.secondary)
                Button(voice.active ? "Stop voice" : "Start voice") {
                    Task { if voice.active { await voice.stop() } else { await voice.start(sessionID: sessionID) } }
                }
                .disabled(voice.stopping)
            }
            Text("Uses this conversation's provider. Availability depends on your account and model.")
                .font(.caption).foregroundStyle(.secondary)
            if let problem = voice.problem { Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if voice.problem != nil && voice.supportsTransport && !voice.active {
                Button("Stop existing provider voice") { Task { await voice.stopExisting(sessionID: sessionID) } }.disabled(voice.stopping)
            }
            if !voice.transcript.isEmpty { Text(voice.transcript).font(.callout).textSelection(.enabled).lineLimit(6) }
        }
        .onDisappear { voice.close() }
        .onChange(of: sessionID) { _, _ in voice.close() }
    }
}

/// Exact little-endian signed PCM16 envelope used by the provider pipe; no file is created.
enum NativeChatProviderVoicePCM {
    struct Chunk: Sendable {
        let bytes: Data
        let rate: Double
        let channels: Int
        var frames: Int { bytes.count / (2 * channels) }
    }
    static func decode(_ value: NativeRPCValue) -> Chunk? {
        guard let encoded = value["data"].string, encoded.utf8.count <= 524_288,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
              let rate = value["sampleRate"].number, rate.rounded() == rate, (8_000...192_000).contains(rate),
              let channels = value["numChannels"].number, channels.rounded() == channels, (1...2).contains(channels),
              bytes.count % (2 * Int(channels)) == 0 else { return nil }
        return .init(bytes: bytes, rate: rate, channels: Int(channels))
    }
    static func sample(_ bytes: Data, at index: Int) -> Float {
        let word = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
        return Float(Int16(bitPattern: word)) / 32_768
    }
}

/// U47: one late sound chunk never ends a voice call, in either direction. The app may be busy for a moment
/// while sending the microphone, and the provider sends its spoken answer faster than it is played; only a
/// backlog that lasts seconds ends the call.
enum NativeChatProviderVoiceLimits {
    /// Microphone audio waiting for the provider: three seconds of 24 kHz mono PCM16, well inside one send.
    static let microphoneBytes = 24_000 * 2 * 3
    /// The provider's spoken answer waiting to be played.
    static let playbackSeconds: Double = 120
}

/// Microphone audio not sent yet, joined into one piece: a slow send makes the next piece longer instead of
/// dropping words. Past `limit` the provider has fallen behind for seconds, not for one chunk.
struct NativeProviderVoiceBacklog {
    let limit: Int
    private(set) var pending = Data()
    init(limit: Int = NativeChatProviderVoiceLimits.microphoneBytes) { self.limit = limit }
    /// False once more than `limit` bytes wait.
    mutating func append(_ bytes: Data) -> Bool { pending.append(bytes); return pending.count <= limit }
    mutating func take() -> Data? {
        guard !pending.isEmpty else { return nil }
        defer { pending = Data() }
        return pending
    }
}

@MainActor @Observable final class NativeChatProviderVoice {
    private(set) var state = "Stopped"
    private(set) var active = false
    private(set) var stopping = false
    private(set) var problem: String?
    private(set) var supportsTransport = false
    private(set) var transcript = ""
    @ObservationIgnored private var sessionID = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var providerStarted = false
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var capture: NativeProviderVoiceCapture?
    @ObservationIgnored private var sender: Task<Void, Never>?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var observations: [NSObjectProtocol] = []
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var requestedCursor = 0
    @ObservationIgnored private var queuedSeconds: Double = 0
    @ObservationIgnored private var playbackFormat: AVAudioFormat?

    isolated deinit {
        capture?.finish(); sender?.cancel(); reader?.cancel()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        player?.stop(); engine?.stop()
        for observer in observations { NotificationCenter.default.removeObserver(observer) }
    }
    private func call(_ operation: String, _ arguments: NativeRPCValue = .object([]), id: String? = nil) async throws -> NativeRPCValue {
        let target = id ?? sessionID
        let fields: [Any?] = target == "hoot" ? [operation, arguments.foundation ?? [:]] : [target, operation, arguments.foundation ?? [:]]
        let raw = try await EngineBridge.shared.invoke(target == "hoot" ? "hoot:chat:provider" : "session:chat:provider", fields)
        return try NativeRPCValue.fromFoundation(raw)
    }
    func start(sessionID: String) async {
        guard !active, !stopping else { return }
        generation += 1
        let token = generation
        self.sessionID = sessionID; active = true; state = "Checking provider…"; problem = nil; transcript = ""
        do {
            let capabilities = try await call("capabilities")
            guard generation == token else { return }
            guard capabilities["transportSupported"].bool == true else {
                throw NarrationListenerError.sentence(capabilities["reason"].string ?? "Conversational voice is unavailable for this provider.")
            }
            supportsTransport = true
            // Start with the current cursor so old audio is never replayed on a new voice call.
            let initial = try await call("voice/events", .object([.init("cursor", .number(0))]))
            guard generation == token else { return }
            cursor = Int(initial["cursor"].number ?? 0); requestedCursor = cursor
            var allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                state = "Waiting for microphone permission…"
                allowed = await AVCaptureDevice.requestAccess(for: .audio)
            }
            guard generation == token else { return }
            guard allowed else { throw NarrationListenerError.sentence("Allow microphone access in System Settings to use provider voice.") }
            let engine = AVAudioEngine()
            _ = try NativeNarrationMic.usableInput(engine)
            self.engine = engine
            // Voice processing supplies echo cancellation for the full duplex conversation.
            try engine.inputNode.setVoiceProcessingEnabled(true)
            let input = try NativeNarrationMic.usableInput(engine)
            let capture = try NativeProviderVoiceCapture(format: input)
            self.capture = capture
            let player = AVAudioPlayerNode(); self.player = player; engine.attach(player)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1) else {
                throw NarrationListenerError.sentence("Audio playback could not be prepared.")
            }
            engine.connect(player, to: engine.mainMixerNode, format: format); playbackFormat = format
            engine.prepare(); try engine.start(); player.play()
            listen(token: token)
            state = "Connecting…"
            _ = try await call("voice/start")
            // A stop while start was in flight must also stop the late provider session.
            guard generation == token else { _ = try? await call("voice/stop", id: sessionID); return }
            providerStarted = true
            capture.install(on: engine.inputNode, format: input)
            tapInstalled = true
            state = "Listening"
            sender = Task { [weak self] in
                // Each wake-up sends everything captured since the last send, as one piece.
                sending: for await _ in capture.stream {
                    while let audio = capture.take() {
                        guard !Task.isCancelled, let self, self.generation == token else { break sending }
                        do {
                            _ = try await self.call("voice/audio", .object([.init("audio", audio)]))
                        } catch {
                            guard self.generation == token else { break sending }
                            await self.fail(error.localizedDescription); break sending
                        }
                    }
                }
                if let self, self.generation == token, capture.congested {
                    await self.fail("Microphone audio could not reach the provider fast enough. Start voice again.")
                }
            }
        } catch {
            guard generation == token else { return }
            await fail(error.localizedDescription)
        }
    }
    private func listen(token: Int) {
        subscriptions.append(EngineBridge.shared.on(sessionID == "hoot" ? "hoot:chat:changed" : "session:chat:changed") { [weak self] args in
            guard let self, self.generation == token else { return }
            let raw: Any
            if self.sessionID == "hoot" { guard let first = args.first else { return }; raw = first }
            else { guard args.count > 1, args[0] as? String == self.sessionID else { return }; raw = args[1] }
            guard let snapshot = try? NativeRPCValue.fromFoundation(raw) else { return }
            if self.providerStarted && (snapshot["alive"].bool == false || snapshot["provider"].string != "codex") {
                Task { await self.fail("The provider session changed or stopped. Voice stopped.") }
                return
            }
            if let cursor = snapshot["providerFeatureCursor"].number { self.requestEvents(Int(cursor), token: token) }
        })
        for channel in ["session:exit", "session:removed"] {
            subscriptions.append(EngineBridge.shared.on(channel) { [weak self] args in
                guard let self, self.generation == token else { return }
                let first = args.first.flatMap { try? NativeRPCValue.fromFoundation($0) }
                if first?.string == self.sessionID || first?["id"].string == self.sessionID {
                    Task { await self.fail("This session closed. Voice stopped.") }
                }
            })
        }
        observations.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.generation == token else { return }; await self.fail("The audio device changed. Start voice again to reconnect.") }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        })
    }
    private func requestEvents(_ next: Int, token: Int) {
        requestedCursor = max(requestedCursor, next)
        guard reader == nil else { return }
        reader = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.reader = nil } }
            while self.generation == token, !Task.isCancelled, self.requestedCursor > self.cursor {
                do {
                    let result = try await self.call("voice/events", .object([.init("cursor", .number(Double(self.cursor)))]))
                    guard self.generation == token else { return }
                    if (result["droppedBefore"].number ?? 0) > Double(self.cursor) {
                        await self.fail("Voice audio fell behind and was dropped. Start voice again."); return
                    }
                    let old = self.cursor
                    for event in result["events"].elements ?? [] {
                        guard self.generation == token else { return }
                        if let sequence = event["sequence"].number, sequence > Double(self.cursor) {
                            self.cursor = Int(sequence)
                            try await self.accept(event["value"], token: token)
                        }
                    }
                    self.cursor = max(self.cursor, Int(result["cursor"].number ?? Double(self.cursor)))
                    if self.cursor <= old { break }
                } catch {
                    guard self.generation == token else { return }
                    await self.fail(error.localizedDescription); return
                }
            }
        }
    }
    private func accept(_ event: NativeRPCValue, token: Int) async throws {
        let method = event["method"].string ?? "", params = event["params"]
        switch method {
        case "thread/realtime/error": await fail(params["message"].string ?? "Provider voice failed.")
        case "thread/realtime/closed":
            let reason = params["reason"].string
            await stop(); if let reason, !reason.isEmpty { problem = reason }
        case "thread/realtime/outputAudio/delta": try play(params["audio"], token: token)
        case "thread/realtime/transcript/delta": transcript = String((transcript + (params["delta"].string ?? "")).suffix(16_384))
        case "thread/realtime/transcript/done": transcript = String((params["text"].string ?? transcript).suffix(16_384))
        default: break
        }
    }
    private func play(_ audio: NativeRPCValue, token: Int) throws {
        guard let chunk = NativeChatProviderVoicePCM.decode(audio), let engine, let player,
              let format = AVAudioFormat(standardFormatWithSampleRate: chunk.rate, channels: AVAudioChannelCount(chunk.channels)) else {
            throw NarrationListenerError.sentence("The provider sent unsupported voice audio.")
        }
        let seconds = Double(chunk.frames) / chunk.rate
        // An answer arriving faster than it is spoken simply waits its turn (U47).
        guard queuedSeconds + seconds <= NativeChatProviderVoiceLimits.playbackSeconds else {
            throw NarrationListenerError.sentence("Voice playback fell behind. Start voice again.")
        }
        if playbackFormat != format {
            guard queuedSeconds == 0 else { throw NarrationListenerError.sentence("The provider changed audio format during playback.") }
            player.stop(); engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format); playbackFormat = format; player.play()
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.frames)),
              let data = buffer.floatChannelData else { throw NarrationListenerError.sentence("Voice playback could not allocate a buffer.") }
        buffer.frameLength = AVAudioFrameCount(chunk.frames)
        for frame in 0..<chunk.frames {
            for channel in 0..<chunk.channels { data[channel][frame] = NativeChatProviderVoicePCM.sample(chunk.bytes, at: frame * chunk.channels + channel) }
        }
        queuedSeconds += seconds; state = "Speaking"
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.queuedSeconds = max(0, self.queuedSeconds - seconds)
                if self.queuedSeconds < 0.001 { self.state = "Listening" }
            }
        }
    }
    private func fail(_ message: String) async { await stop(); problem = message }
    func stopExisting(sessionID: String) async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        do {
            let result = try await call("voice/stop", id: sessionID)
            guard result["stopped"].bool == true else { throw NarrationListenerError.sentence("The provider did not confirm that its voice connection stopped.") }
            problem = nil; state = "Idle"
        } catch { problem = error.localizedDescription }
    }
    func stop() async {
        guard !stopping else { return }
        stopping = true
        let id = sessionID, shouldStopProvider = providerStarted
        release()
        defer { stopping = false }
        if shouldStopProvider {
            do { _ = try await call("voice/stop", id: id) }
            catch { problem = "Voice stopped on this Mac. Provider stop failed: \(error.localizedDescription)" }
        }
    }
    /// Synchronous local cleanup happens before any async provider work when a view closes.
    func close() {
        let id = sessionID, shouldStopProvider = providerStarted
        release()
        if shouldStopProvider { Task { _ = try? await call("voice/stop", id: id) } }
    }
    private func release() {
        generation += 1
        capture?.finish(); capture = nil
        sender?.cancel(); sender = nil; reader?.cancel(); reader = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player?.stop(); engine?.stop(); player = nil; engine = nil
        for subscription in subscriptions { subscription.cancel() }; subscriptions.removeAll()
        for observer in observations { NotificationCenter.default.removeObserver(observer) }; observations.removeAll()
        playbackFormat = nil; queuedSeconds = 0; providerStarted = false; active = false; state = "Stopped"
    }
}

/// The real-time callback owns a converter and the unsent audio, capped at a few seconds: a slow provider
/// cannot grow memory, and a briefly slow send costs nothing.
private final class NativeProviderVoiceCapture: @unchecked Sendable {
    /// A wake-up for the sender; the audio itself waits in `backlog`, so a missed wake-up loses nothing.
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var stopped = false
    private var overflowed = false
    private var backlog = NativeProviderVoiceBacklog()
    init(format input: AVAudioFormat) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: format) else {
            throw NarrationListenerError.sentence("The microphone could not prepare provider audio.")
        }
        self.format = format; self.converter = converter; converter.downmix = true
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    /// The tap block is made here, in a nonisolated class, because AVAudioEngine calls it on its real-time
    /// audio thread. Written inside the @MainActor voice model it would be main-actor isolated and trap
    /// the moment the first microphone buffer arrived (review chat-ui #1).
    func install(on node: AVAudioInputNode, format input: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 2400, format: input) { [self] buffer, _ in append(buffer) }
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !stopped else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false
            let status = converter.convert(to: out, error: nil) { _, state in
                guard !supplied else { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            guard status != .error, out.frameLength > 0, let data = out.int16ChannelData?[0] else { return }
            // Dropping captured words is never silent: past the backlog limit, end this call so the UI reports congestion.
            guard backlog.append(Data(bytes: data, count: Int(out.frameLength) * 2)) else {
                stopped = true; overflowed = true; continuation.finish(); return
            }
            continuation.yield(())
        }
    }
    /// Everything captured since the last send, as one provider audio piece.
    func take() -> NativeRPCValue? {
        guard let bytes = lock.withLock({ backlog.take() }) else { return nil }
        return .object([.init("data", .string(bytes.base64EncodedString())), .init("sampleRate", .number(24_000)),
                        .init("numChannels", .number(1)), .init("samplesPerChannel", .number(Double(bytes.count / 2)))])
    }
    func finish() { lock.withLock { stopped = true; continuation.finish() } }
    var congested: Bool { lock.withLock { overflowed } }
}
