@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech
import TerminalDeckNativeCore

/// Live narration — the ears (lane NARR). The microphone, and the engines that turn
/// it into words while he speaks. Every time here is seconds of AUDIO (from the
/// first sample the microphone gave); the narration turns them into video time.
///
/// Engines, in order of preference:
///   - On this Mac (default, private, free): SpeechAnalyzer + SpeechTranscriber
///     (macOS 26+), else SFSpeechRecognizer on-device.
///   - The transcription key he saved for voice input (OpenAI, Groq or ElevenLabs),
///     phrase by phrase through the app's `voice:transcribe`; the key never leaves
///     the engine.

/// What an engine heard.
enum NarrationHeard: Sendable {
    /// Words it will not change, for the audio time `from..<to` (nil: all so far).
    case final([NarrationWord], from: Double?, to: Double?)
    /// Words still being worked out; each replaces the last.
    case volatile([NarrationWord])
    /// A phrase was sent and its words are on their way (or arrived: false).
    case waiting(Bool)
    /// A plain line for the caption strip: getting ready, or why no words are written.
    case status(String)
}

protocol NarrationListener: AnyObject, Sendable {
    /// Ready to hear `format` (the microphone's mono format). Throws with a sentence.
    func start(format: AVAudioFormat) async throws
    /// One slice of microphone audio. Called on the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer, at seconds: Double)
    /// The recording stopped: what is still being worked out is finished.
    func finish() async
}

enum NarrationListenerError: LocalizedError {
    case sentence(String)
    var errorDescription: String? { if case .sentence(let line) = self { return line }; return nil }
}

// MARK: - The microphone

/// The Mac's current input (whatever macOS has selected), mono, written to an
/// AAC file and handed to the listener. Runs only while recording.
final class NativeNarrationMic: @unchecked Sendable {
    let file: URL
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var writer: AVAudioFile?
    private var converter: AVAudioConverter?
    private var frames: AVAudioFramePosition = 0
    private var sink: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
    private(set) var mono: AVAudioFormat?
    private var tapped = false

    init(file: URL) { self.file = file }

    /// The microphone's format, checked BEFORE AVAudioEngine sees it. With no usable input (a Mac
    /// mini has no microphone; none selected; a device that just went away) installTap raises an
    /// Objective-C exception instead of an error. Swift cannot catch that; AppKit swallows it and the
    /// app is left broken until it crashes on the next mouse move (PFRAME crash, 9 Oct 17:38:
    /// "input hw format invalid" → SIGSEGV in hit-testing). So nothing invalid ever reaches the engine.
    static func usableInput(_ engine: AVAudioEngine) throws -> AVAudioFormat {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw NarrationListenerError.sentence("This Mac has no microphone, so the recording has no voice.")
        }
        let node = engine.inputNode
        let hardware = node.inputFormat(forBus: 0), tap = node.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0, tap.sampleRate > 0, tap.channelCount > 0,
              hardware.sampleRate == tap.sampleRate else {
            throw NarrationListenerError.sentence("The microphone can't be used right now, so the recording has no voice.")
        }
        return tap
    }

    /// The microphone's own format, mono.
    func prepare() throws -> AVAudioFormat {
        let input = try Self.usableInput(engine)
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false) else {
            throw NarrationListenerError.sentence("The microphone's sound could not be read.")
        }
        self.mono = mono
        return mono
    }

    func start(sink: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) throws {
        // Checked again here: the input can change between prepare and start.
        let input = try Self.usableInput(engine)
        guard let mono = mono ?? (try? prepare()) else { throw NarrationListenerError.sentence("The microphone's sound could not be read.") }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: mono.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        let writer = try AVAudioFile(forWriting: file, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let converter = AVAudioConverter(from: input, to: mono)
        converter?.downmix = true
        lock.withLock {
            self.writer = writer
            self.converter = converter
            self.sink = sink
            self.frames = 0
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input) { [weak self] buffer, _ in
            self?.take(buffer)
        }
        tapped = true
        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0); tapped = false
            throw NarrationListenerError.sentence("The microphone could not start: \(error.localizedDescription)")
        }
    }

    private func take(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let mono, let converter, let writer else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * mono.sampleRate / buffer.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else { return }
        var given = false
        let status = converter.convert(to: out, error: nil) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        try? writer.write(from: out)
        let at = Double(frames) / mono.sampleRate
        frames += AVAudioFramePosition(out.frameLength)
        sink?(out, at)
    }

    /// Stop listening. The file, when anything was heard.
    @discardableResult
    func stop() -> URL? {
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
        let heard = lock.withLock { () -> Bool in
            let any = frames > 0
            writer = nil // closes the file
            converter = nil
            sink = nil
            return any
        }
        return heard && FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}

// MARK: - On this Mac: SpeechAnalyzer

final class NarrationAppleListener: NarrationListener, @unchecked Sendable {
    private let locale: Locale
    private let heard: @Sendable (NarrationHeard) -> Void
    private let lock = NSLock()
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var results: Task<Void, Never>?
    /// What the microphone gave before the engine was ready (the first time, a download).
    private var backlog: [AVAudioPCMBuffer] = []
    private var stopped = false

    init(locale: Locale, heard: @escaping @Sendable (NarrationHeard) -> Void) {
        self.locale = locale
        self.heard = heard
    }

    /// The locale this Mac's transcriber can write, for `wanted`; nil when it cannot.
    static func supported(_ wanted: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
    }

    func start(format: AVAudioFormat) async throws {
        guard let locale = await Self.supported(locale) else {
            throw NarrationListenerError.sentence("This Mac cannot write \(Self.languageName(locale)) on its own.")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.audioTimeRange])
        // The language's model is downloaded once, by the system, the first time.
        if await AssetInventory.status(forModules: [transcriber]) < .installed {
            heard(.status("Getting \(Self.languageName(locale)) ready on this Mac…"))
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            heard(.status(""))
        }
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: format) ?? format
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let converter = target == format ? nil : AVAudioConverter(from: format, to: target)
        lock.withLock {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.converter = converter
            self.target = target
            self.input = continuation
            // In order, before anything newer: the lock keeps the microphone out meanwhile.
            if !stopped { for buffer in backlog { push(buffer) } }
            backlog = []
        }
        let heard = self.heard
        results = Task {
            do {
                for try await result in transcriber.results {
                    let words = Self.words(result.text, fallback: result.range)
                    if result.isFinal {
                        heard(.final(words, from: result.range.start.seconds, to: result.range.end.seconds))
                    } else {
                        heard(.volatile(words))
                    }
                }
            } catch {
                heard(.status("Words stopped: \(error.localizedDescription)"))
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buffer: AVAudioPCMBuffer, at seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard input != nil else {
            // Not ready yet: kept, up to about two minutes.
            if !stopped, backlog.count < 1_500 { backlog.append(buffer) }
            return
        }
        push(buffer)
    }

    /// Into the analyzer, in its format. The lock is held.
    private func push(_ buffer: AVAudioPCMBuffer) {
        guard let input else { return }
        guard let converter, let target else { input.yield(AnalyzerInput(buffer: buffer)); return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        let status = converter.convert(to: out, error: nil) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return buffer
        }
        if status != .error, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() async {
        let (analyzer, input) = lock.withLock { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?) in
            defer { self.input = nil; stopped = true; backlog = [] }
            return (self.analyzer, self.input)
        }
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
    }

    /// Each word with its own time, punctuation joined to the word before.
    static func words(_ text: AttributedString, fallback: CMTimeRange) -> [NarrationWord] {
        var out: [NarrationWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let token = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
                for (index, part) in token.split(whereSeparator: \.isWhitespace).enumerated() {
                    out.append(NarrationWord(start: range.start.seconds + Double(index) * 0.001, end: range.end.seconds, text: String(part)))
                }
            } else if var last = out.popLast() {
                last.text += token.first.map { CharacterSet.punctuationCharacters.contains($0.unicodeScalars.first!) } == true ? token : " " + token
                out.append(last)
            } else {
                out.append(contentsOf: NarrationWord.spread(token, from: fallback.start.seconds, to: fallback.end.seconds))
            }
        }
        return out
    }

    static func languageName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

// MARK: - On this Mac, older engine: SFSpeechRecognizer

final class NarrationSFListener: NarrationListener, @unchecked Sendable {
    private let locale: Locale
    private let heard: @Sendable (NarrationHeard) -> Void
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var done: CheckedContinuation<Void, Never>?
    private var ended = false

    init(locale: Locale, heard: @escaping @Sendable (NarrationHeard) -> Void) {
        self.locale = locale
        self.heard = heard
    }

    func start(format: AVAudioFormat) async throws {
        let allowed: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: allowed = true
        case .notDetermined:
            allowed = await withCheckedContinuation { answer in
                SFSpeechRecognizer.requestAuthorization { answer.resume(returning: $0 == .authorized) }
            }
        default: allowed = false
        }
        guard allowed else { throw NarrationListenerError.sentence("Speech recognition is not allowed for Terminal Deck (System Settings › Privacy).") }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw NarrationListenerError.sentence("This Mac cannot write \(NarrationAppleListener.languageName(locale)).")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let heard = self.heard
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let words = result.bestTranscription.segments.map {
                    NarrationWord(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
                }
                heard(result.isFinal ? .final(words, from: nil, to: nil) : .volatile(words))
            }
            if result?.isFinal == true || error != nil { self?.end() }
        }
        lock.withLock { self.request = request; self.task = task }
    }

    func feed(_ buffer: AVAudioPCMBuffer, at seconds: Double) {
        lock.withLock { request }?.append(buffer)
    }

    private func end() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            ended = true
            defer { done = nil }
            return done
        }
        waiting?.resume()
    }

    func finish() async {
        let request = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in defer { self.request = nil }; return self.request }
        request?.endAudio()
        // The last words come with the final result; never wait more than a few seconds.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { waiting in
                    guard let self else { waiting.resume(); return }
                    let already = self.lock.withLock { () -> Bool in
                        if self.ended { return true }
                        self.done = waiting
                        return false
                    }
                    if already { waiting.resume() }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(4)) }
            await group.next()
            group.cancelAll()
            self.end()
        }
        lock.withLock { task }?.finish()
    }
}

// MARK: - His transcription key: phrase by phrase

/// Cuts the microphone at his pauses and sends each phrase through the app's
/// `voice:transcribe` (the provider and key he saved for voice input). The key
/// stays inside the engine; this side only ever sees text.
final class NarrationKeyListener: NarrationListener, @unchecked Sendable {
    private let heard: @Sendable (NarrationHeard) -> Void
    private let transcribe: @Sendable (Data) async -> Result<String, NarrationListenerError>
    private let lock = NSLock()
    private var cutter = NarrationPhraseCutter()
    private var samples: [Float] = []
    private var samplesStart = 0.0
    private var rate = 16_000.0
    private var pending: [Task<Void, Never>] = []

    init(heard: @escaping @Sendable (NarrationHeard) -> Void,
         transcribe: @escaping @Sendable (Data) async -> Result<String, NarrationListenerError>) {
        self.heard = heard
        self.transcribe = transcribe
    }

    func start(format: AVAudioFormat) async throws {
        lock.withLock { rate = format.sampleRate }
    }

    func feed(_ buffer: AVAudioPCMBuffer, at seconds: Double) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let slice = Array(UnsafeBufferPointer(start: channel, count: count))
        let level = sqrt(slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, count)))
        let phrase: (ClosedRange<Double>, [Float])? = lock.withLock {
            if samples.isEmpty { samplesStart = seconds }
            samples.append(contentsOf: slice)
            guard let cut = cutter.feed(level: level, from: seconds, to: seconds + Double(count) / rate) else {
                // Quiet before he speaks is let go, so a phrase starts near his first word.
                if cutter.phraseStart == nil || samples.count > Int(rate * 30) { samples.removeAll() }
                return nil
            }
            let from = max(0, Int((cut.lowerBound - samplesStart) * rate))
            let taken = from < samples.count ? Array(samples[from...]) : []
            samples.removeAll()
            return (cut, taken)
        }
        if let phrase { send(phrase.0, phrase.1) }
    }

    private func send(_ range: ClosedRange<Double>, _ audio: [Float]) {
        guard !audio.isEmpty else { return }
        let wav = Self.wav(audio, rate: lock.withLock { rate })
        let heard = self.heard, transcribe = self.transcribe
        heard(.waiting(true))
        let task = Task {
            switch await transcribe(wav) {
            case .success(let text):
                heard(.final(NarrationWord.spread(text, from: range.lowerBound, to: range.upperBound),
                             from: range.lowerBound, to: range.upperBound))
            case .failure(let error):
                heard(.status(error.errorDescription ?? "A phrase could not be written."))
            }
            heard(.waiting(false))
        }
        lock.withLock { pending.append(task) }
    }

    func finish() async {
        let last: (ClosedRange<Double>, [Float])? = lock.withLock {
            let end = samplesStart + Double(samples.count) / rate
            guard let cut = cutter.flush(at: end) else { return nil }
            let from = max(0, Int((cut.lowerBound - samplesStart) * rate))
            defer { samples.removeAll() }
            return (cut, from < samples.count ? Array(samples[from...]) : [])
        }
        if let last { send(last.0, last.1) }
        for task in lock.withLock({ pending }) { await task.value }
    }

    /// 16-bit mono WAV of the phrase, at the microphone's rate.
    static func wav(_ samples: [Float], rate: Double) -> Data {
        let size = samples.count * 2
        var data = Data(capacity: 44 + size)
        func text(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let sampleRate = UInt32(rate.rounded())
        text("RIFF"); u32(UInt32(36 + size)); text("WAVE"); text("fmt "); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16); text("data"); u32(UInt32(size))
        for sample in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32_767))) }
        return data
    }
}
