//
//  deck-speech — the Mac's own voice, as a pipe.
//
//  ## Why this binary exists at all
//
//  `src/renderer/chat/voice/dictation.ts` carries the measurement that decided
//  it: the Web Speech API inside this Electron starts, then emits nothing —
//  no result, no end, and no error — because the cloud path compiled into
//  Chromium is Google's private endpoint and Electron ships none of Google's
//  keys. There is no on-device model behind `SpeechRecognition` either. So the
//  window cannot hear, and the only free ear on this machine is the operating
//  system's.
//
//  macOS 26 added `SpeechAnalyzer` + `SpeechTranscriber`: on-device, long-form,
//  free, no key and no account. Measured on this Mac before any of this was
//  written — 45 supported languages, nine English locales already installed,
//  and a `say`-generated sentence came back word-perfect. That is the engine
//  this wraps.
//
//  ## The shape, and why it is a pipe rather than a native module
//
//  One process, one job, JSON lines on stdout. A native Node addon would have
//  to be compiled per Electron ABI and would take the whole app down with it
//  when Apple changes something; a child process cannot, and its failure is a
//  line on a pipe the caller can print. `src/main/native-speech.ts` owns it.
//
//  Commands:
//    listen  --locale en-US     stream {partial|final} until stdin closes
//    speak   --voice <id>       read text on stdin, say it, exit when done
//    voices                     the installed voices, for a picker
//    probe                      whether any of this works here
//
import Foundation
import Speech
import AVFoundation

/// One JSON object per line. The caller reads this as a stream, so every line
/// has to be complete and self-describing — a half-written object is a parse
/// error at the far end rather than a lost word.
func emit(_ o: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

/// Failure is a line, then a non-zero exit. Never a crash: the caller draws
/// whatever `message` says beside the microphone, and a stack trace is not a
/// sentence anybody can act on.
func fail(_ message: String) -> Never {
    emit(["kind": "error", "message": message])
    exit(1)
}

// MARK: - The model

/// The language model is a download the first time a locale is used, and it is
/// Apple's download rather than ours — nothing here ships a model. `supported`
/// means "installable", `installed` means ready; the gap between them is the
/// one wait a first-time user sees, so it is announced.
func ensureModel(for transcriber: SpeechTranscriber) async {
    let status = await AssetInventory.status(forModules: [transcriber])
    if status == .installed { return }
    if status == .unsupported { fail("This Mac cannot listen in that language.") }
    do {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        emit(["kind": "installing"])
        try await request.downloadAndInstall()
        emit(["kind": "installed"])
    } catch {
        fail("The speech model could not be installed: \(error.localizedDescription)")
    }
}

// MARK: - listen

/**
 * The microphone, open until the caller closes stdin.
 *
 * Two streams meet here. `AVAudioEngine` taps the default input in whatever
 * format the hardware chose, and the analyzer wants one specific format — on
 * this Mac 16 kHz mono Int16 — so every buffer is converted before it is
 * yielded. Getting that wrong is silent: the engine runs, buffers flow, and
 * nothing is ever recognised.
 *
 * Results arrive twice. A `partial` is the sentence so far and will change; a
 * `final` is settled and will not. The caller shows partials live and keeps
 * only finals, which is why both are labelled rather than merged here.
 */
func listen(localeID: String) async {
    guard SpeechTranscriber.isAvailable else { fail("This Mac's speech recognition is not available.") }
    let wanted = Locale(identifier: localeID)
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? wanted

    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    await ensureModel(for: transcriber)

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        fail("No audio format works with the speech model.")
    }

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let analyzer = SpeechAnalyzer(modules: [transcriber])

    let results = Task {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                guard !text.isEmpty else { continue }
                emit(["kind": result.isFinal ? "final" : "partial", "text": text])
            }
        } catch {
            emit(["kind": "error", "message": error.localizedDescription])
        }
    }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let micFormat = input.outputFormat(forBus: 0)
    guard micFormat.sampleRate > 0 else { fail("No microphone is available.") }
    guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
        fail("This microphone's audio cannot be converted for the speech model.")
    }

    input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
        let ratio = analyzerFormat.sampleRate / micFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        // `convert` pulls until it is told there is no more; without the
        // `supplied` latch it re-offers the same buffer forever.
        var supplied = false
        var err: NSError?
        converter.convert(to: converted, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, converted.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    do {
        try await analyzer.start(inputSequence: stream)
        engine.prepare()
        try engine.start()
    } catch {
        fail("The microphone could not be started: \(error.localizedDescription)")
    }
    emit(["kind": "ready"])

    // Stdin is the stop signal. A line or an EOF both mean stop, so a caller
    // that dies takes the microphone with it rather than leaving the recording
    // light on — the same rule the old MediaRecorder path kept.
    let stopped = Task.detached { FileHandle.standardInput.readDataToEndOfFile() }
    _ = await stopped.value

    engine.stop()
    input.removeTap(onBus: 0)
    continuation.finish()
    try? await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = await results.value
    emit(["kind": "done"])
}

// MARK: - speak

/// Speaking is synchronous from the caller's point of view: the process lives
/// exactly as long as the sentence. That is what lets the caller reopen the
/// microphone when this exits without hearing its own voice.
///
/// **The wait has to spin a run loop, not block on a semaphore.** Measured the
/// hard way: a `DispatchSemaphore` waited on the main thread plays the sentence
/// perfectly and then hangs forever, because `AVSpeechSynthesizer` delivers
/// `didFinish` *to the main run loop* — which the blocked thread is no longer
/// serving. The audio is the misleading part; it comes out of the audio system
/// either way, so the bug looks like "it works but never exits".
final class SpeakDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var finished = false
    /// The utterance currently being waited on.
    ///
    /// Identity, not a bare flag, and it is worth the extra field: with a flag
    /// alone a *late* callback for the previous sentence set `finished` on the
    /// next one, and the wait returned in 194 ms for a sentence that takes a
    /// second and a half to say. That reads to the caller as "finished
    /// speaking", so the microphone reopens into live speech — the exact
    /// feedback loop the rest of this file exists to prevent.
    var current: AVSpeechUtterance?

    private func settle(_ u: AVSpeechUtterance) {
        guard u === current else { return }
        finished = true
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { settle(u) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { settle(u) }
}

/// Rate, pitch and volume are the three dials Apple exposes, and all three are
/// clamped here rather than at the caller: `AVSpeechUtterance` accepts an
/// out-of-range pitch by silently ignoring it, which would read as "the setting
/// does nothing" rather than "that number is too high".
func speak(text: String, voiceID: String?, rate: Float, pitch: Float, volume: Float) {
    let synth = AVSpeechSynthesizer()
    let delegate = SpeakDelegate()
    synth.delegate = delegate
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    utterance.pitchMultiplier = min(max(pitch, 0.5), 2.0)
    utterance.volume = min(max(volume, 0.0), 1.0)
    if let voiceID, let v = AVSpeechSynthesisVoice(identifier: voiceID) { utterance.voice = v }
    delegate.current = utterance
    synth.speak(utterance)
    // A ceiling as well as a flag: a synthesiser that never reports finishing
    // would otherwise hold the microphone shut for the rest of the session.
    let deadline = Date().addingTimeInterval(600)
    while !delegate.finished && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    emit(["kind": "done"])
}

/// Quality 2 is Apple's "enhanced" download and 3 is "premium"; a machine with
/// neither still has the whole quality-1 set, so the caller sorts rather than
/// filters and always has something to offer.
/**
 * A speaker that stays alive.
 *
 * ## Why one process per sentence was wrong
 *
 * Measured: `Arthur (Enhanced)` is a 162 MB neural voice, and a fresh process
 * loads it before it can say anything. One short sentence cost **4.5 to 7.8
 * seconds** end to end, of which only about three were speech — and the very
 * first was **23 seconds**. In a conversation loop that overhead lands between
 * every question and its answer, which is exactly where it is least bearable.
 *
 * So the process stays, the synthesiser stays, and the voice is loaded once.
 * Sentences arrive as JSON lines on stdin and each one answers with a `done`
 * carrying the id it was given, so the caller can await a specific sentence
 * rather than the next completion it happens to see.
 *
 * ## Why the id matters
 *
 * The hands-free loop reopens the microphone when speaking ends. If two
 * sentences are in flight — a fast follow-up, an interrupted answer — an
 * un-numbered `done` would reopen the ear on the wrong one and the assistant
 * would hear itself.
 */
/// A thread-safe queue of sentences waiting to be spoken.
final class SentenceQueue: @unchecked Sendable {
    private var items: [[String: Any]] = []
    private let lock = NSLock()
    private var closed = false

    func push(_ item: [String: Any]) {
        lock.lock(); items.append(item); lock.unlock()
    }
    func drain() -> [[String: Any]] {
        lock.lock(); let out = items; items = []; lock.unlock(); return out
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

/**
 * A speaker that stays alive.
 *
 * ## Why one process per sentence was wrong
 *
 * `Arthur (Enhanced)` is a 162 MB neural voice, and a process spawned per
 * sentence pays to page it in every time. Measured: **23 seconds** for the
 * first sentence and 4.5–7.8 for each one after, of which only about three
 * were speech. In a conversation that delay lands between every question and
 * its answer, and the restarts are what Asad heard as *"voice is flickering a
 * lot"*. So the process stays, the voice loads once, and sentences arrive on
 * stdin.
 *
 * ## Why stdin is read on its own thread
 *
 * Because `AVSpeechSynthesizer` delivers everything through the **main run
 * loop**, and a main thread parked in a blocking `read()` is a run loop that is
 * not running. The first version did exactly that and worked perfectly from a
 * shell — and then, spawned by Electron, took the write and never answered it:
 * `ready` out, the sentence in, and no `done`, forever. Whatever the difference
 * in how the pipe is set up, the shape was wrong either way; a program that
 * needs a run loop must never block the thread that serves it.
 *
 * So: a background thread owns the file descriptor and pushes parsed lines onto
 * a queue, and the main thread does nothing but spin its run loop and drain
 * that queue. Every sentence carries a ticket that comes back on `done`,
 * because a sentence cut short by the next one would otherwise settle the wrong
 * promise — and the caller reopens the microphone on that promise.
 */
func serve(voiceID: String?, rate: Float, pitch: Float, volume: Float) {
    let synth = AVSpeechSynthesizer()
    let delegate = SpeakDelegate()
    synth.delegate = delegate

    var voice = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
    var currentRate = rate
    var currentPitch = pitch
    var currentVolume = volume

    let queue = SentenceQueue()

    // The reader. Owns stdin and nothing else; `read(2)` directly rather than
    // through FileHandle, so it behaves the same on a pipe and on a socketpair.
    let reader = Thread {
        var held = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(0, $0.baseAddress, 4096) }
            if n <= 0 { break }
            held.append(contentsOf: buffer[0 ..< n])
            while let cut = held.firstIndex(of: 0x0A) {
                let raw = held.subdata(in: held.startIndex ..< cut)
                held = held.subdata(in: held.index(after: cut) ..< held.endIndex)
                if let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                    queue.push(obj)
                }
            }
        }
        queue.close()
    }
    reader.stackSize = 512 * 1024
    reader.start()

    /// Speak one utterance and return when it is finished. The flag is reset
    /// *before* speaking: an earlier `didFinish` arriving late would otherwise
    /// satisfy this wait, and the caller would reopen the ear into live speech.
    func speakAndWait(_ utterance: AVSpeechUtterance) {
        delegate.finished = false
        delegate.current = utterance
        synth.speak(utterance)
        let deadline = Date().addingTimeInterval(600)
        while !delegate.finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // Load the voice before anybody asks, silently, and wait for it — so that
    // `ready` means "the queue is empty and I am listening", not "I have begun".
    if let voice {
        let warm = AVSpeechUtterance(string: "ready")
        warm.voice = voice
        warm.volume = 0
        warm.rate = AVSpeechUtteranceMaximumSpeechRate
        speakAndWait(warm)
    }
    emit(["kind": "ready"])

    while true {
        // The run loop always turns, whether or not there is anything to say.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        let batch = queue.drain()
        if batch.isEmpty {
            if queue.isClosed { break }
            continue
        }
        for obj in batch {
            if obj["stop"] as? Bool == true {
                synth.stopSpeaking(at: .immediate)
                delegate.finished = true
                delegate.current = nil
                continue
            }
            if let id = obj["voice"] as? String {
                voice = AVSpeechSynthesisVoice(identifier: id)
                continue
            }
            if let r = obj["rate"] as? Double { currentRate = Float(r) }
            if let p = obj["pitch"] as? Double { currentPitch = Float(p) }
            if let v = obj["volume"] as? Double { currentVolume = Float(v) }

            guard let text = obj["say"] as? String, !text.isEmpty else { continue }
            let ticket = obj["id"] as? Int ?? 0
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = min(max(currentRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            utterance.pitchMultiplier = min(max(currentPitch, 0.5), 2.0)
            utterance.volume = min(max(currentVolume, 0.0), 1.0)
            speakAndWait(utterance)
            emit(["kind": "done", "id": ticket])
        }
    }
    synth.stopSpeaking(at: .immediate)
}

func voices() {
    let list = AVSpeechSynthesisVoice.speechVoices().map {
        ["id": $0.identifier, "name": $0.name, "language": $0.language, "quality": $0.quality.rawValue] as [String: Any]
    }
    emit(["kind": "voices", "voices": list])
}

func probe() async {
    guard SpeechTranscriber.isAvailable else {
        emit(["kind": "probe", "listening": false, "reason": "This Mac's speech recognition is not available."])
        return
    }
    let installed = await SpeechTranscriber.installedLocales
    emit(["kind": "probe", "listening": true,
          "locales": installed.map { $0.identifier.replacingOccurrences(of: "_", with: "-") },
          "voices": AVSpeechSynthesisVoice.speechVoices().count])
}

// MARK: - entry

@main
struct DeckSpeech {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { fail("usage: deck-speech listen|speak|serve|voices|probe") }
        args.removeFirst()
        func flag(_ name: String) -> String? {
            guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        switch command {
        case "listen":
            await listen(localeID: flag("locale") ?? "en-US")
        case "speak":
            let text = flag("text")
                ?? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
                ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("nothing to say") }
            speak(text: text,
                  voiceID: flag("voice"),
                  rate: Float(flag("rate") ?? "") ?? AVSpeechUtteranceDefaultSpeechRate,
                  pitch: Float(flag("pitch") ?? "") ?? 1.0,
                  volume: Float(flag("volume") ?? "") ?? 1.0)
        case "serve":
            serve(voiceID: flag("voice"),
                  rate: Float(flag("rate") ?? "") ?? AVSpeechUtteranceDefaultSpeechRate,
                  pitch: Float(flag("pitch") ?? "") ?? 1.0,
                  volume: Float(flag("volume") ?? "") ?? 1.0)
        case "voices":
            voices()
        case "probe":
            await probe()
        default:
            fail("unknown command \(command)")
        }
    }
}
