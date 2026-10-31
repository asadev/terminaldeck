import AVFoundation
import AppKit
import CoreVideo
import XCTest
@testable import TerminalDeckBackend

// PFRAME #57: Android recording for the session phone panel. No emulator runs here: the adb
// commands are checked as a sequence, and the stitching on real (tiny, generated) mp4 files.

private final class AndroidSegmentFake: BackendUIGSessionSimulatorRecordingProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var waiter: CheckedContinuation<Int32, Never>?
    private var result: Int32?
    var running: Bool { lock.withLock { active } }
    func interrupt() { end(130) }
    func end(_ status: Int32) {
        let resume = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            guard active else { return nil }
            active = false; result = status
            defer { waiter = nil }; return waiter
        }
        resume?.resume(returning: status)
    }
    func finished() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Int32? in
                if let result { return result }
                waiter = continuation; return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }
}

private final class AndroidCommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String]] = [], segments: [AndroidSegmentFake] = [], stitched: [URL] = []
    func add(_ e: [String]) { lock.withLock { entries.append(e) } }
    func addSegment(_ s: AndroidSegmentFake) { lock.withLock { segments.append(s) } }
    func setStitched(_ u: [URL]) { lock.withLock { stitched = u } }
    var all: [[String]] { lock.withLock { entries } }
    var segs: [AndroidSegmentFake] { lock.withLock { segments } }
    var stitchedParts: [URL] { lock.withLock { stitched } }
}

/// A recorder that ignores Stop and ends only when terminated.
private final class StubbornRecorderFake: BackendUIGSessionSimulatorRecordingProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Int32, Never>?
    private var result: Int32?
    private var interrupted = 0
    var interrupts: Int { lock.withLock { interrupted } }
    var running: Bool { lock.withLock { result == nil } }
    func interrupt() { lock.withLock { interrupted += 1 } }
    func terminate() {
        let resume = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            guard result == nil else { return nil }
            result = 137; defer { waiter = nil }; return waiter
        }
        resume?.resume(returning: 137)
    }
    func finished() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Int32? in
                if let result { return result }
                waiter = continuation; return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }
}

final class BackendAndroidScreenRecordTests: XCTestCase {
    func testStopEndsARecorderThatIgnoresTheInterrupt() async {
        // #123: Stop hung on a recorder that ignored SIGINT and the process was never killed.
        let stubborn = StubbornRecorderFake()
        let status = await stubborn.stop(grace: .milliseconds(50))
        XCTAssertEqual(status, 137)
        XCTAssertEqual(stubborn.interrupts, 1)
        XCTAssertFalse(stubborn.running)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PFRAME-android-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSerialAndCommands() {
        XCTAssertEqual(BackendAndroidScreenRecord.serial("android:emulator-5554"), "emulator-5554")
        XCTAssertNil(BackendAndroidScreenRecord.serial("ios:6F4E1C2A-1111-4222-8333-944455556666"))
        XCTAssertNil(BackendAndroidScreenRecord.serial("avd:Pixel_9"))
        XCTAssertNil(BackendAndroidScreenRecord.serial("android:"))
        XCTAssertNil(BackendAndroidScreenRecord.serial("android:a b"))
        let remote = BackendAndroidScreenRecord.remotePath(token: "t1", segment: 2)
        XCTAssertEqual(remote, "/sdcard/td-recording-t1-2.mp4")
        XCTAssertEqual(BackendAndroidScreenRecord.record(serial: "emulator-5554", remote: remote),
                       ["-s", "emulator-5554", "shell", "screenrecord", "--time-limit", "180", remote])
        XCTAssertEqual(BackendAndroidScreenRecord.stop(serial: "emulator-5554"), ["-s", "emulator-5554", "shell", "pkill", "-INT", "screenrecord"])
        XCTAssertEqual(BackendAndroidScreenRecord.pull(serial: "s", remote: remote, local: "/tmp/x.mp4"), ["-s", "s", "pull", remote, "/tmp/x.mp4"])
        XCTAssertEqual(BackendAndroidScreenRecord.remove(serial: "s", remotes: ["/a", "/b"]), ["-s", "s", "shell", "rm", "-f", "/a", "/b"])
    }

    /// Segment 1 reaches screenrecord's 3-minute limit, segment 2 is chained; Stop tells the device
    /// (pkill -INT), both parts are pulled, removed from the device and stitched in order.
    func testChainsSegmentsStopsOnTheDevicePullsCleansAndStitches() async throws {
        let dir = try folder(), log = AndroidCommandLog(), out = dir.appendingPathComponent("recording.mp4")
        let process = try BackendAndroidScreenRecordProcess(serial: "emulator-5554", file: out, token: "t1", folder: dir.appendingPathComponent("parts"),
            start: { args in log.add(["start"] + args); let s = AndroidSegmentFake(); log.addSegment(s); return s },
            run: { args in
                log.add(["run"] + args)
                if args.contains("pkill") { log.segs.last?.end(0) }
                if args.count > 4, args[2] == "pull" { try? Data([1]).write(to: URL(fileURLWithPath: args[4])) }
                return 0
            },
            stitch: { parts, file in log.setStitched(parts); try Data([1]).write(to: file) })
        XCTAssertTrue(process.running)
        log.segs[0].end(0) // the time limit: the next segment starts by itself
        for _ in 0..<100 where log.segs.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.segs.count, 2)
        process.interrupt()
        let status = await process.finished()
        XCTAssertEqual(status, 0)
        XCTAssertFalse(process.running)
        let r0 = "/sdcard/td-recording-t1-0.mp4", r1 = "/sdcard/td-recording-t1-1.mp4"
        let parts = dir.appendingPathComponent("parts")
        XCTAssertEqual(log.all, [
            ["start", "-s", "emulator-5554", "shell", "screenrecord", "--time-limit", "180", r0],
            ["start", "-s", "emulator-5554", "shell", "screenrecord", "--time-limit", "180", r1],
            ["run", "-s", "emulator-5554", "shell", "pkill", "-INT", "screenrecord"],
            ["run", "-s", "emulator-5554", "pull", r0, parts.appendingPathComponent("part-0.mp4").path],
            ["run", "-s", "emulator-5554", "pull", r1, parts.appendingPathComponent("part-1.mp4").path],
            ["run", "-s", "emulator-5554", "shell", "rm", "-f", r0, r1],
        ])
        XCTAssertEqual(log.stitchedParts.map(\.lastPathComponent), ["part-0.mp4", "part-1.mp4"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parts.path), "the parts folder is cleaned up")
    }

    func testNothingPulledIsAFailedRecording() async throws {
        let dir = try folder(), log = AndroidCommandLog()
        let process = try BackendAndroidScreenRecordProcess(serial: "emulator-5554", file: dir.appendingPathComponent("r.mp4"), token: "t2",
            start: { _ in let s = AndroidSegmentFake(); log.addSegment(s); return s },
            run: { args in if args.contains("pkill") { log.segs.last?.end(0) }; return args.contains("pull") ? 1 : 0 },
            stitch: { _, _ in XCTFail("nothing to stitch") })
        process.interrupt()
        let status = await process.finished()
        XCTAssertNotEqual(status, 0)
    }

    func testARefusedFirstSegmentIsReportedAtStart() throws {
        let dir = try folder()
        struct Refused: Error {}
        XCTAssertThrowsError(try BackendAndroidScreenRecordProcess(serial: "emulator-5554", file: dir.appendingPathComponent("r.mp4"),
            start: { _ in throw Refused() }, run: { _ in 0 }))
    }

    /// Real stitching on two generated 1-second H.264 files: one video of their total length.
    func testStitchJoinsSegmentsInOrder() async throws {
        let dir = try folder()
        let a = dir.appendingPathComponent("a.mp4"), b = dir.appendingPathComponent("b.mp4"), out = dir.appendingPathComponent("out.mp4")
        try await Self.writeClip(a, frames: 10, gray: 40)
        try await Self.writeClip(b, frames: 15, gray: 200)
        try await BackendAndroidScreenRecord.stitch([a, b], to: out)
        let asset = AVURLAsset(url: out)
        let seconds = try await asset.load(.duration).seconds
        XCTAssertEqual(seconds, 2.5, accuracy: 0.15)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path), "parts are removed once joined")
    }

    func testStitchOfOneSegmentMovesIt() async throws {
        let dir = try folder()
        let a = dir.appendingPathComponent("a.mp4"), out = dir.appendingPathComponent("out.mp4")
        try await Self.writeClip(a, frames: 5, gray: 90)
        try await BackendAndroidScreenRecord.stitch([a], to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }

    /// ANDROID live run: screenrecord on a still screen leaves one frame ("0.0 s"); the video is held to the Stop moment.
    func testAStillScreenIsHeldToTheStopMoment() async throws {
        let dir = try folder()
        let clip = dir.appendingPathComponent("still.mp4")
        try await Self.writeClip(clip, frames: 1, gray: 120)
        await BackendAndroidScreenRecord.extend(clip, toSeconds: 3)
        let asset = AVURLAsset(url: clip)
        let held = try await asset.load(.duration).seconds, tracks = try await asset.loadTracks(withMediaType: .video).count
        XCTAssertEqual(held, 3, accuracy: 0.1)
        XCTAssertEqual(tracks, 1)
        // Already as long as the recording: left alone; not a video: left alone.
        let full = dir.appendingPathComponent("full.mp4")
        try await Self.writeClip(full, frames: 10, gray: 60)
        await BackendAndroidScreenRecord.extend(full, toSeconds: 1.2)
        let kept = try await AVURLAsset(url: full).load(.duration).seconds
        XCTAssertEqual(kept, 1, accuracy: 0.05)
        let junk = dir.appendingPathComponent("junk.mp4")
        try Data([1, 2, 3]).write(to: junk)
        await BackendAndroidScreenRecord.extend(junk, toSeconds: 5)
        XCTAssertEqual(try Data(contentsOf: junk), Data([1, 2, 3]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }, [], "no leftovers")
    }

    /// A screen that never changed: screenrecord wrote no picture at all; the screen itself becomes the video.
    func testAPicturelessRecordingBecomesTheStillScreen() async throws {
        let dir = try folder()
        let image = NSImage(size: NSSize(width: 54, height: 120), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        let out = dir.appendingPathComponent("rec.mp4")
        try Data([1]).write(to: out)
        let empty = await BackendAndroidScreenRecord.hasFrames(out)
        XCTAssertFalse(empty)
        let made = await BackendAndroidScreenRecord.still(png: png, seconds: 2.5, to: out)
        XCTAssertTrue(made)
        let asset = AVURLAsset(url: out)
        let seconds = try await asset.load(.duration).seconds, framed = await BackendAndroidScreenRecord.hasFrames(out)
        XCTAssertEqual(seconds, 2.5, accuracy: 0.1)
        XCTAssertTrue(framed)
        // The recorder asks for the still only when the joined video has no picture.
        let asked = BackendDeckCoreSecurityTestBox<[Double]>([])
        let segment = AndroidSegmentFake()
        let process = try BackendAndroidScreenRecordProcess(serial: "emulator-5554", file: dir.appendingPathComponent("r2.mp4"), folder: dir.appendingPathComponent("parts"),
            start: { _ in segment }, run: { arguments in
                if arguments.contains("pull"), let local = arguments.last { try? Data([7]).write(to: URL(fileURLWithPath: local)) }
                if arguments.contains("pkill") { segment.end(0) }
                return 0 },
            stitch: { parts, file in try FileManager.default.moveItem(at: parts[0], to: file) },
            still: { _, wall in asked.edit { $0.append(wall) } })
        process.interrupt()
        let status = await process.finished()
        XCTAssertEqual(status, 0)
        XCTAssertEqual(asked.get().count, 1)
    }

    /// A tiny H.264 mp4 at 10 frames a second.
    static func writeClip(_ url: URL, frames: Int, gray: UInt8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 128])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 128])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 128, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { XCTFail("pixel buffer"); return }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(gray), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 10))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
