import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import XCTest
@testable import TerminalDeckBackend
@testable import TerminalDeckNative
import TerminalDeckNativeCore

/// Asad, 31 Oct (devices-fix, item 5): "no interactions or scroll is working" on a simulator watched from the phone.
/// A live check of the Mac's half on a REAL simulator: the phone's frames (`sims.watch`, `sims.ack`, `sims.input`)
/// go into the real handler (`BackendPhoneDevices`), whose video (on a fake direct link: 3 Nov, the only way) and input
/// go the app's own way (`NativePhoneDeviceScreens`: the direct helper the phone panel uses). Taps, swipes and a scroll
/// must change the screen, read from a second viewer of the same direct screen. Opt-in: `TD_LIVE_SIM=<udid of a booted scratch simulator>`,
/// `TD_DIRECT_HELPER=<.build/…/TerminalDeckNativeHelper>`, `TD_LIVE_OUT=<folder for the pictures>`.
@MainActor
final class PhoneDevicesLiveSimTests: XCTestCase {
    private actor Sink {
        var frames: [NativeRPCValue] = []
        var inputs: [(String, Bool)] = []
        func add(_ value: NativeRPCValue) { frames.append(value) }
        func input(_ what: String, _ direct: Bool) { inputs.append((what, direct)) }
        func count(_ type: String) -> Int { frames.filter { $0["t"].string == type }.count }
        func all(_ type: String) -> [NativeRPCValue] { frames.filter { $0["t"].string == type } }
    }

    func testPhoneInputDrivesARealSimulator() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let udid = env["TD_LIVE_SIM"], let helper = env["TD_DIRECT_HELPER"] else { throw XCTSkip("Live check: set TD_LIVE_SIM and TD_DIRECT_HELPER.") }
        let out = URL(fileURLWithPath: env["TD_LIVE_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        SimDirectSource.helperOverride = URL(fileURLWithPath: helper)
        NativeCompositionRoot.noteSink = { print("NOTE", $0) }
        let id = "ios:" + udid
        let row = NativeRPCValue.object([.init("id", .string(id)), .init("name", .string("Live check")), .init("platform", .string("ios")),
                                         .init("kind", .string("simulator")), .init("state", .string("ready"))])
        let sink = Sink()
        var source = BackendPhoneDevices.Source(
            list: { .object([.init("devices", .array([row]))]) },
            power: { _, _ in .object([]) },
            stream: { _, row in
                guard let stream = await NativePhoneDeviceScreens.shared.stream(row) else {
                    throw NativeRPCError(code: "unavailable", message: "No direct screen for the live simulator.")
                }
                return stream
            },
            input: { id, input in
                let direct = await NativePhoneDeviceScreens.shared.send(id, input)
                await sink.input(String(describing: input), direct)
                if !direct { throw NativeRPCError(code: "unavailable", message: "The direct helper did not take \(input).") }
            },
            shot: { _ in throw NativeRPCError(code: "unavailable", message: "not used") },
            deliver: { _ in "" },
            visibleSessions: { _ in [] },
            send: { _, message in await sink.add(message.value) })
        source.direct = { _, data, _ in if let value = try? NativeRPCValue.parseJSON(data) { await sink.add(value) }; return true }
        source.linkVideo = { _ in BackendLinkVideo(reliableOnly: false) }
        let devices = BackendPhoneDevices(source: source)
        let context = BackendRemoteHostContext(connectionID: UUID(), deviceID: "live-phone", kind: .mine, address: "live", peerPublicKey: nil,
                                               claimedCapabilities: [], reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: true),
                                               phoneAccess: .work)
        func say(_ json: String) async throws -> [BackendRemoteServerMessage] {
            try await devices.handle(BackendRemoteClientMessage(try NativeRPCValue.parseJSON(Data(json.utf8))), context: context)
        }
        // Acks as the phone sends them once it has drawn a picture, all through the check.
        var acked = 0
        func ackAll() async throws {
            let frames = await sink.all("sims.video").filter { $0["part"].number == nil || $0["part"].number == ($0["parts"].number ?? 1) - 1 }
            while acked < frames.count {
                let seq = Int(frames[acked]["seq"].number ?? 0)
                _ = try await say(#"{"t":"sims.ack","id":"\#(id)","seq":\#(seq)}"#)
                acked += 1
            }
        }
        func settle(_ seconds: Double) async throws {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { try await ackAll(); try await Task.sleep(for: .milliseconds(50)) }
        }
        // The screen as the phone panel's direct path has it now (a second viewer of the same screen).
        let reader = await NativePhoneDeviceScreens.shared.stream(row)
        let viewer = try XCTUnwrap(reader, "no direct screen")
        let imaging = CIContext()
        var shown: CGImage?
        func picture(_ name: String) async throws -> CGImage {
            while case .pixels(let pixels) = await viewer.pixels(within: 0.3) {
                let image = CIImage(cvPixelBuffer: pixels.buffer)
                shown = imaging.createCGImage(image, from: image.extent) ?? shown
            }
            return try XCTUnwrap(shown, "no picture came")
        }

        let opened = try await say(#"{"t":"sims.watch","rid":"w1","id":"\#(id)","maxWidth":390,"quality":60,"fps":15,"video":["h264"]}"#)
        XCTAssertEqual(opened.first?.value["state"].string, "opening")
        let deadline = Date().addingTimeInterval(15)
        while await sink.count("sims.video") == 0, Date() < deadline { try await settle(0.1) }
        let firstCount = await sink.count("sims.video"), states = await sink.all("sims.state")
        XCTAssertGreaterThan(firstCount, 0, "video flows: \(states)")
        try await settle(1.5)
        let framesBefore = await sink.count("sims.video")

        // Each step: the phone's input, then the picture must change.
        // From wherever the simulator is: home first (the swipe up from the bottom edge, which is also the lock
        // screen's), then a page each way, open Settings, scroll it, and home again.
        let steps: [(String, String)] = [
            ("home-first", #""do":"swipe","x":0.5,"y":0.99,"x2":0.5,"y2":0.55,"ms":250"#),
            ("swipe-left", #""do":"swipe","x":0.85,"y":0.55,"x2":0.15,"y2":0.55,"ms":250"#),
            ("swipe-right", #""do":"swipe","x":0.15,"y":0.55,"x2":0.85,"y2":0.55,"ms":250"#),
            ("tap-settings", #""do":"tap","x":0.83,"y":0.475"#),
            // Settings may open where it was left (top or bottom): a scroll each way, and at least one must move it.
            ("scroll-down", #""do":"swipe","x":0.5,"y":0.35,"x2":0.5,"y2":0.85,"ms":300"#),
            ("scroll-up", #""do":"swipe","x":0.5,"y":0.8,"x2":0.5,"y2":0.3,"ms":300"#),
            ("home-gesture", #""do":"swipe","x":0.5,"y":0.995,"x2":0.5,"y2":0.55,"ms":250"#),
        ]
        var previous = try await picture("0-start")
        var report: [String] = []
        // What a gesture does depends on where the simulator was left (home, an app, the switcher), so at least half of the
        // steps must move it, and the edge swipe must (31 Oct: it did nothing without the edge said).
        var moved = 0
        for (index, step) in steps.enumerated() {
            _ = try await say(#"{"t":"sims.input","rid":"i\#(index)","id":"\#(id)",\#(step.1)}"#)
            try await settle(2.0)
            let next = try await picture("\(index + 1)-\(step.0)")
            let change = Self.difference(previous, next)
            report.append("\(step.0): \(String(format: "%.3f", change))")
            if change > 0.01 { moved += 1 }
            if step.0 == "home-first" { XCTAssertGreaterThan(change, 0.01, "the swipe up from the bottom edge did nothing") }
            previous = next
        }
        XCTAssertGreaterThanOrEqual(moved, steps.count / 2, "most phone gestures moved the simulator: \(report)")
        let framesAfter = await sink.count("sims.video")
        let inputs = await sink.inputs
        try (report + ["frames before input \(framesBefore), after \(framesAfter)"] + inputs.map { "\($0.0) direct=\($0.1)" })
            .joined(separator: "\n").write(to: out.appendingPathComponent("live-report.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(inputs.allSatisfy(\.1), "every input went the direct way")
        XCTAssertGreaterThan(framesAfter, framesBefore + steps.count, "video keeps flowing while input comes")
        _ = try await say(#"{"t":"sims.unwatch","id":"\#(id)"}"#)
        await viewer.stop()
        try await Task.sleep(for: .milliseconds(500))
    }

    /// How different two pictures are: the mean difference of small grey copies, 0…1.
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func grey(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 40 * 86)
            let context = CGContext(data: &bytes, width: 40, height: 86, bitsPerComponent: 8, bytesPerRow: 40, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 86))
            return bytes
        }
        let x = grey(a), y = grey(b)
        return zip(x, y).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(x.count) / 255
    }
}
