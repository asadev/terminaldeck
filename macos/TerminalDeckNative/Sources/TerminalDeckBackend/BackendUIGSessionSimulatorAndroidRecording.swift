import AVFoundation
import ImageIO
import Foundation
import TerminalDeckNativeCore

/// Android screen recording for the session phone panel (PFRAME #57): `adb screenrecord` on the device,
/// in segments (screenrecord stops itself after 3 minutes), stopped cleanly on the device, pulled and
/// stitched into the one video the panel shows. The same owned-process boundary as the iOS recorder.
public enum BackendAndroidScreenRecord {
    /// screenrecord's own limit per run, in seconds.
    public static let segmentSeconds = 180

    /// The adb serial of an Android device id ("android:<serial>"), nil for anything else.
    public static func serial(_ deviceID: String) -> String? {
        guard deviceID.hasPrefix("android:") else { return nil }
        let serial = String(deviceID.dropFirst("android:".count))
        return serial.isEmpty || serial.contains(where: { $0.isWhitespace || $0 == "/" }) ? nil : serial
    }

    /// Where a segment is written on the device.
    public static func remotePath(token: String, segment: Int) -> String { "/sdcard/td-recording-\(token)-\(segment).mp4" }
    public static func record(serial: String, remote: String) -> [String] {
        ["-s", serial, "shell", "screenrecord", "--time-limit", String(segmentSeconds), remote]
    }
    /// Stops the recording on the device itself, so screenrecord finishes its file (killing adb here would not).
    public static func stop(serial: String) -> [String] { ["-s", serial, "shell", "pkill", "-INT", "screenrecord"] }
    public static func pull(serial: String, remote: String, local: String) -> [String] { ["-s", serial, "pull", remote, local] }
    public static func remove(serial: String, remotes: [String]) -> [String] { ["-s", serial, "shell", "rm", "-f"] + remotes }

    /// adb from the Android SDK, as the device inventory finds it.
    public static func adbPath(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String? {
        // The one SDK lookup the device list uses too (ANDROID_HOME, ANDROID_SDK_ROOT, Android Studio's setting, defaults, PATH).
        BackendAppDeviceAndroidSDK.tool(BackendAppDeviceAndroidSDK.adb, environment: environment, home: home)
    }

    /// `adb get-state` says "device": connected and allowed. False when adb is missing, slow (5 s) or says otherwise
    /// (it prints one word; past 64 KiB it is not adb answering).
    public static func connected(serial: String) async -> Bool {
        guard let adb = adbPath(),
              let outcome = try? await BackendAndroidScreenRecordProcess.bounded(5_000, {
                  try await NativeChild.run(.init(URL(fileURLWithPath: adb).path, ["-s", serial, "get-state"], errors: .discard),
                                            timeoutMilliseconds: 5_000, outputLimit: 64 * 1024) }) else { return false }
        return outcome.succeeded && outcome.outputText.trimmingCharacters(in: .whitespacesAndNewlines) == "device"
    }

    /// screenrecord (and simctl recordVideo) writes a frame only when the screen changes, so a still screen at the
    /// end (or a whole still recording: one frame, "0.0 s", seen live 10 Oct) is cut short. The video is rewritten
    /// (no re-encode) so its last picture stays up to the moment Stop was pressed; a tail under `minimumGain`
    /// seconds is left as it is. Any failure leaves the file as it was.
    public static func extend(_ file: URL, toSeconds wall: Double, minimumGain: Double = 0.5) async {
        guard wall.isFinite, wall > 0 else { return }
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let length = try? await asset.load(.duration), wall - length.seconds > minimumGain,
              let reader = try? AVAssetReader(asset: asset) else { return }
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return }
        reader.add(output)
        let held = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).held.mp4")
        try? FileManager.default.removeItem(at: held)
        guard let writer = try? AVAssetWriter(outputURL: held, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        input.transform = transform; input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { try? FileManager.default.removeItem(at: held); return }
        writer.startSession(atSourceTime: .zero)
        var written = 0
        while let sample = output.copyNextSampleBuffer() {
            guard sample.presentationTimeStamp.isNumeric, sample.numSamples > 0, sample.totalSampleSize > 0 else { continue }
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(2)) }
            guard input.append(sample) else { break }
            written += 1
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: wall, preferredTimescale: 600))
        await writer.finishWriting()
        guard written > 0, writer.status == .completed, reader.status == .completed else { try? FileManager.default.removeItem(at: held); return }
        if (try? FileManager.default.replaceItemAt(file, withItemAt: held)) == nil { try? FileManager.default.removeItem(at: held) }
    }

    /// The video holds at least one picture (screenrecord on a screen that never changed writes none).
    public static func hasFrames(_ file: URL) async -> Bool {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() { if sample.numSamples > 0, sample.totalSampleSize > 0 { return true } }
        return false
    }

    /// A video of one picture (PNG bytes) shown for `seconds`: what a recording of a still screen is.
    public static func still(png: Data, seconds: Double, to file: URL) async -> Bool {
        guard seconds.isFinite, seconds > 0, let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let width = image.width / 2 * 2, height = image.height / 2 * 2
        guard width > 0, height > 0 else { return false }
        let made = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).still.mp4")
        try? FileManager.default.removeItem(at: made)
        guard let writer = try? AVAssetWriter(outputURL: made, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer, writer.startWriting() else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        writer.startSession(atSourceTime: .zero)
        while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(2)) }
        let appended = adaptor.append(buffer, withPresentationTime: .zero)
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        guard appended, writer.status == .completed else { try? FileManager.default.removeItem(at: made); return false }
        if (try? FileManager.default.replaceItemAt(file, withItemAt: made)) == nil {
            try? FileManager.default.removeItem(at: file)
            guard (try? FileManager.default.moveItem(at: made, to: file)) != nil else { try? FileManager.default.removeItem(at: made); return false }
        }
        return true
    }

    /// The longest of these videos (by length, then by size), or nil when there is none.
    public static func longest(_ files: [URL]) async -> URL? {
        var best: (url: URL, seconds: Double, bytes: Int)?
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            if best == nil || seconds > best!.seconds || (seconds == best!.seconds && bytes > best!.bytes) { best = (url, seconds, bytes) }
        }
        return best?.url
    }

    /// The segments one after another as one video (one segment is just moved into place).
    public static func stitch(_ segments: [URL], to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let first = segments.first else { throw NativeRPCError(code: "recording-failed", message: "No part of the recording came off the device.") }
        if segments.count == 1 { try FileManager.default.moveItem(at: first, to: output); return }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeRPCError(code: "recording-failed", message: "The recording could not be put together.")
        }
        var at = CMTime.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let length = try await asset.load(.duration)
            try video.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: at)
            if at == .zero { video.preferredTransform = try await track.load(.preferredTransform) }
            at = CMTimeAdd(at, length)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw NativeRPCError(code: "recording-failed", message: "This Mac cannot write the video.")
        }
        try await session.export(to: output, as: .mp4)
        for url in segments { try? FileManager.default.removeItem(at: url) }
    }
}

/// One Android recording: segment after segment until stopped, then pulled, cleaned off the device and stitched.
public final class BackendAndroidScreenRecordProcess: BackendUIGSessionSimulatorRecordingProcess, @unchecked Sendable {
    /// Starts a long-running adb command (one screenrecord segment).
    public typealias Start = @Sendable ([String]) throws -> any BackendUIGSessionSimulatorRecordingProcess
    /// Runs a short adb command to the end; its exit status.
    public typealias Run = @Sendable ([String]) async -> Int32
    public typealias Stitch = @Sendable ([URL], URL) async throws -> Void

    private let lock = NSLock()
    private var stopping = false, isRunning = true
    private var current: (any BackendUIGSessionSimulatorRecordingProcess)?
    private let serial: String
    private let run: Run
    private var work: Task<Int32, Never>!
    /// When recording began and when Stop was pressed: the video's true length.
    private let began = Date()
    private var stoppedAt: Date?
    /// When each segment started: a segment whose screen stood still at its end is held to the next one's start,
    /// so frame times stay true across the joins (26 Oct 2026: a still tail was lost, and later frames came early).
    private var segmentStarts: [Date] = []

    public init(serial: String, file: URL, token: String = UUID().uuidString.prefix(8).lowercased(), folder: URL? = nil,
                start: @escaping Start, run: @escaping Run, stitch: @escaping Stitch = { try await BackendAndroidScreenRecord.stitch($0, to: $1) },
                extend: @escaping @Sendable (URL, Double) async -> Void = { await BackendAndroidScreenRecord.extend($0, toSeconds: $1) },
                still: @escaping @Sendable (URL, Double) async -> Void = { _, _ in }) throws {
        self.serial = serial; self.run = run
        let parts = folder ?? file.deletingLastPathComponent().appendingPathComponent(".td-android-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        // The first segment starts now, so a refused start is reported to the caller straight away.
        let firstRemote = BackendAndroidScreenRecord.remotePath(token: token, segment: 0)
        let first = try start(BackendAndroidScreenRecord.record(serial: serial, remote: firstRemote))
        current = first
        segmentStarts = [began]
        work = Task { [self] in
            var remotes = [firstRemote], segment: any BackendUIGSessionSimulatorRecordingProcess = first
            while true {
                let status = await segment.finished()
                // screenrecord ends by itself at its time limit (status 0): chain the next segment.
                guard status == 0, !isStopping else { break }
                let remote = BackendAndroidScreenRecord.remotePath(token: token, segment: remotes.count)
                guard let next = try? start(BackendAndroidScreenRecord.record(serial: serial, remote: remote)) else { break }
                remotes.append(remote); segment = next; setCurrent(next, startedAt: Date())
                if isStopping { next.interrupt(); _ = await run(BackendAndroidScreenRecord.stop(serial: serial)) }
            }
            var locals: [URL] = []
            let starts = lock.withLock { segmentStarts }
            for (index, remote) in remotes.enumerated() {
                let local = parts.appendingPathComponent("part-\(index).mp4")
                if await run(BackendAndroidScreenRecord.pull(serial: serial, remote: remote, local: local.path)) == 0,
                   FileManager.default.fileExists(atPath: local.path) {
                    // Every segment but the last is held to the next one's start (the last is held to Stop below).
                    if index + 1 < remotes.count, index + 1 < starts.count {
                        await extend(local, starts[index + 1].timeIntervalSince(starts[index]))
                    }
                    locals.append(local)
                }
            }
            _ = await run(BackendAndroidScreenRecord.remove(serial: serial, remotes: remotes))
            var result: Int32 = 1
            if !locals.isEmpty, (try? await stitch(locals, file)) != nil, FileManager.default.fileExists(atPath: file.path) {
                let wall = lock.withLock { stoppedAt ?? Date() }.timeIntervalSince(began)
                // A screen that never changed gives a video with no picture: then the screen as it is, for that long.
                if await BackendAndroidScreenRecord.hasFrames(file) { await extend(file, wall) } else { await still(file, wall) }
                result = 0
            } else if let longest = await BackendAndroidScreenRecord.longest(locals) {
                // The parts could not be joined: the longest one is kept as the video rather than nothing.
                try? FileManager.default.removeItem(at: file)
                if (try? FileManager.default.moveItem(at: longest, to: file)) != nil { result = 0 }
            }
            try? FileManager.default.removeItem(at: parts)
            finish()
            return result
        }
    }

    public var running: Bool { lock.withLock { isRunning } }
    private var isStopping: Bool { lock.withLock { stopping } }
    private func setCurrent(_ process: any BackendUIGSessionSimulatorRecordingProcess, startedAt: Date) {
        lock.withLock { current = process; segmentStarts.append(startedAt) }
    }
    private func finish() { lock.withLock { isRunning = false } }

    /// Stop: screenrecord is told on the device (so its file is finished), then the local adb ends with it.
    public func interrupt() {
        let first = lock.withLock { () -> Bool in let was = stopping; stopping = true; if !was { stoppedAt = Date() }; return !was }
        guard first else { return }
        let serial = serial, run = run, segment = lock.withLock { current }
        Task {
            _ = await run(BackendAndroidScreenRecord.stop(serial: serial))
            // If the device did not end it within a few seconds, end the local adb too.
            try? await Task.sleep(for: .seconds(5))
            if segment?.running == true { segment?.interrupt() }
        }
    }

    /// Stop that hung: end the local adb of the current segment; what was recorded is still pulled.
    public func terminate() { interrupt(); lock.withLock { current }?.terminate() }

    public func finished() async -> Int32 { await work.value }

    /// The real one: adb from the SDK.
    public static func live(serial: String, file: URL) throws -> BackendAndroidScreenRecordProcess {
        guard let adb = BackendAndroidScreenRecord.adbPath() else {
            throw NativeRPCError(code: "unavailable", message: "adb is not installed on this Mac (Android Studio's platform tools).")
        }
        return try BackendAndroidScreenRecordProcess(serial: serial, file: file,
            start: { try BackendUIGSessionSimulatorOwnedRecordingProcess(executable: adb, arguments: $0) },
            // A pull moves a whole segment: up to 3 minutes of video, hundreds of MB at screenrecord's default
            // bit rate, which over wireless adb can take minutes. The rest (stop, rm) answer in seconds.
            run: { arguments in await BackendAndroidScreenRecordProcess.runToEnd(adb, arguments, timeoutMilliseconds: arguments.dropFirst(2).first == "pull" ? 600_000 : 120_000) },
            still: { file, seconds in
                guard let png = await BackendAndroidScreenRecordProcess.output(adb, ["-s", serial, "exec-out", "screencap", "-p"]), !png.isEmpty else { return }
                _ = await BackendAndroidScreenRecord.still(png: png, seconds: seconds, to: file)
            })
    }

    /// A short adb command's output (at most 20 s; a screenshot PNG, so at most 64 MiB), or nil when it failed.
    static func output(_ executable: String, _ arguments: [String]) async -> Data? {
        guard let outcome = try? await bounded(20_000, {
            try await NativeChild.run(.init(URL(fileURLWithPath: executable).path, arguments, errors: .discard),
                                      timeoutMilliseconds: 20_000, outputLimit: 64 << 20) }) else { return nil }
        return outcome.succeeded ? outcome.output : nil
    }

    /// A short command run to its end through the standard child runner; its exit status, -1 when it could
    /// not start or ran past `timeoutMilliseconds` (it had none: a device that stopped answering hung Stop).
    static func runToEnd(_ executable: String, _ arguments: [String], timeoutMilliseconds: Int = 120_000) async -> Int32 {
        guard let outcome = try? await bounded(timeoutMilliseconds, {
            try await NativeChild.run(.init(URL(fileURLWithPath: executable).path, arguments, output: .discard, errors: .discard),
                                      timeoutMilliseconds: timeoutMilliseconds) }) else { return -1 }
        return outcome.timedOut ? -1 : outcome.code
    }

    /// A short adb or simctl run, never waited for past its own limit plus the device grace, even when its end is
    /// never reported (devices freeze, 26 Oct: an unreaped `adb devices` held every device call).
    static func bounded(_ timeoutMilliseconds: Int, _ run: @escaping @Sendable () async throws -> NativeChild.Outcome) async throws -> NativeChild.Outcome {
        try await BackendAppDeviceDeadline.run(within: Double(timeoutMilliseconds + BackendAppDeviceDeadline.commandGraceMilliseconds) / 1_000,
                                               "The device command", run)
    }
}
