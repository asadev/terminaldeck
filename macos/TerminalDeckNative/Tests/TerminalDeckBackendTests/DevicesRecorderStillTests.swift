import AVFoundation
import XCTest
@testable import TerminalDeckBackend

// "The recording on the simulator isn't happening" (Asad, 26 Oct 2026): devices_record start, about 8 s on a still
// screen, stop, and the video held 1 frame and lasted 0.067 s. The recorders write a frame only when the screen
// changes; a still screen (or the still tail before Stop) must still last until Stop, with true frame times.

/// A stand-in recorder segment for Android: ends when told to (its time limit) or when interrupted.
private final class StillSegment: BackendUIGSessionSimulatorRecordingProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?
    var running: Bool { lock.withLock { result == nil } }
    func interrupt() { end(130) }
    func end(_ status: Int32) {
        let resume = lock.withLock { () -> CheckedContinuation<Int32, Never>? in
            guard result == nil else { return nil }
            result = status; defer { waiter = nil }; return waiter
        }
        resume?.resume(returning: status)
    }
    func finished() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Int32? in if let result { return result }; waiter = continuation; return nil }
            if let done { continuation.resume(returning: done) }
        }
    }
}
private final class StillSegments: @unchecked Sendable {
    private let lock = NSLock(); private var all: [StillSegment] = []
    func add(_ segment: StillSegment) { lock.withLock { all.append(segment) } }
    var last: StillSegment? { lock.withLock { all.last } }
    var count: Int { lock.withLock { all.count } }
    var first: StillSegment? { lock.withLock { all.first } }
}

final class DevicesRecorderStillTests: XCTestCase {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-recorder-still-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func times(_ file: URL) async throws -> (duration: Double, samples: [Double]) {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var samples: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if sample.numSamples > 0 { samples.append(sample.presentationTimeStamp.seconds) }
        }
        return (duration, samples)
    }

    /// The regression (iOS, the recorder behind the session panel's Record, devices_record and the floating window):
    /// a still screen for N seconds gives a video of about N seconds, its one frame held, never re-encoded.
    func testAStillScreenForNSecondsGivesAVideoOfAboutNSeconds() async throws {
        let dir = try folder(), video = dir.appendingPathComponent("simulator-recording.mp4")
        // What simctl recordVideo leaves on a still screen: one frame, 0.1 s long.
        try await BackendAndroidScreenRecordTests.writeClip(video, frames: 1, gray: 128)
        // A recorder that finishes its file on SIGINT and exits 0, as simctl recordVideo does.
        let recorder = try BackendUIGSessionSimulatorOwnedRecordingProcess(executable: "/bin/sh",
            arguments: ["-c", "trap 'exit 0' INT; while :; do sleep 0.05; done"], holding: video)
        let n = 2.0
        try await Task.sleep(for: .seconds(n))
        let status = await recorder.stop()
        XCTAssertEqual(status, 0)
        let (duration, samples) = try await times(video)
        XCTAssertEqual(duration, n, accuracy: 0.35, "a still screen lasts until Stop")
        XCTAssertEqual(samples.count, 1, "held, not re-encoded")
        XCTAssertEqual(samples.first ?? -1, 0, accuracy: 0.01)
        // Asking again for the end gives the same answer and does not rewrite the video again.
        let again = await recorder.finished()
        XCTAssertEqual(again, 0)
        let later = try await times(video).duration
        XCTAssertEqual(later, duration, accuracy: 0.01)
    }

    /// Every iOS recorder is made from simctl recordVideo's own arguments, which name the video it holds.
    func testEveryIOSRecorderHoldsItsVideoAndNothingElseIsHeld() throws {
        let file = URL(fileURLWithPath: "/Users/someone/Pictures/Terminal Deck/simulator-recording-1.mp4")
        let arguments = try BackendUIGSessionSimulatorRecording.arguments(deviceID: "ios:999B14C7-E053-4E24-B3A9-731DE849F155", file: file)
        XCTAssertEqual(BackendUIGSessionSimulatorOwnedRecordingProcess.heldFile(arguments), file)
        XCTAssertNil(BackendUIGSessionSimulatorOwnedRecordingProcess.heldFile(BackendAndroidScreenRecord.record(serial: "emulator-5554", remote: "/sdcard/a.mp4")))
        XCTAssertNil(BackendUIGSessionSimulatorOwnedRecordingProcess.heldFile(["simctl", "io", "X", "screenshot", "/tmp/a.png"]))
    }

    /// Android: when the parts cannot be joined, the longest one is kept as the video rather than nothing.
    func testAndroidKeepsTheLongestPartWhenTheJoinFails() async throws {
        struct JoinFailed: Error {}
        let dir = try folder(), out = dir.appendingPathComponent("recording.mp4"), segments = StillSegments()
        let process = try BackendAndroidScreenRecordProcess(serial: "emulator-5554", file: out, token: "join", folder: dir.appendingPathComponent("parts"),
            start: { _ in let segment = StillSegment(); segments.add(segment); return segment },
            run: { arguments in
                if arguments.contains("pkill") { segments.last?.end(0) }
                if arguments.contains("pull"), let local = arguments.last {
                    // part-0 is 0.3 s, part-1 is 0.8 s
                    try? await BackendAndroidScreenRecordTests.writeClip(URL(fileURLWithPath: local), frames: local.hasSuffix("part-1.mp4") ? 8 : 3, gray: 70)
                }
                return 0
            },
            stitch: { _, _ in throw JoinFailed() }, extend: { _, _ in })
        segments.first?.end(0)
        for _ in 0..<100 where segments.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        process.interrupt()
        let status = await process.finished()
        XCTAssertEqual(status, 0)
        let (duration, _) = try await times(out)
        XCTAssertEqual(duration, 0.8, accuracy: 0.05, "the longest part is the video")
    }

    /// Android: a segment that ends on a still screen is held to the next segment's start, so the next segment's
    /// frames keep their true times, and the last is held to Stop.
    func testAndroidFrameTimesStayTrueAcrossSegmentsAndTheEndIsHeldToStop() async throws {
        let dir = try folder(), out = dir.appendingPathComponent("recording.mp4"), segments = StillSegments()
        let process = try BackendAndroidScreenRecordProcess(serial: "emulator-5554", file: out, token: "still", folder: dir.appendingPathComponent("parts"),
            start: { _ in let segment = StillSegment(); segments.add(segment); return segment },
            run: { arguments in
                if arguments.contains("pkill") { segments.last?.end(0) }
                // Each segment comes off the device as one frame (a still screen), 0.1 s long.
                if arguments.contains("pull"), let local = arguments.last {
                    try? await BackendAndroidScreenRecordTests.writeClip(URL(fileURLWithPath: local), frames: 1, gray: 90)
                }
                return 0
            },
            extend: { file, wall in await BackendAndroidScreenRecord.extend(file, toSeconds: wall, minimumGain: 0.1) })
        try await Task.sleep(for: .seconds(1))
        segments.first?.end(0) // screenrecord's time limit: the next segment starts
        for _ in 0..<100 where segments.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .seconds(1))
        process.interrupt()
        let status = await process.finished()
        XCTAssertEqual(status, 0)
        let (duration, samples) = try await times(out)
        XCTAssertEqual(duration, 2, accuracy: 0.35, "held to Stop")
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.last ?? -1, 1, accuracy: 0.25, "the second segment's frame keeps its true time")
    }
}
