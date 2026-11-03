import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
import TerminalDeckNativeCore
import VideoToolbox
@testable import TerminalDeckBackend

/// Item 61 (Asad, 1 Nov: "only the changed part updates … when I move something it shows after some time … a REAL
/// experience, better speed AND better quality"). The same scripted Mac screen (a real 2560 × 1600 code page) goes
/// through the real host to a phone as hardware H.264 on a simulated direct link (3 Nov, m5-direct-only: the only way;
/// the JPEG pictures and the relay video are gone); the "phone" really decodes what arrives (VideoToolbox) and notes
/// when each picture is ready to show. Measured: pictures a second while the screen moves, glass-to-glass (screen
/// changed → picture decoded on the phone), bytes a second, and how soon the screen is sharp again once it stops — on
/// the same network (3 ms each way) and through TURN (20 ms each way).
@Suite("This Mac's screen as real-time video", .serialized)
struct VideoPipelineTests {
    static func now() -> Double { Date().timeIntervalSince1970 * 1_000 }

    /// A scripted display giving raw pixels (BGRA, as a simulator's surface), newest first.
    actor PixelScreen: BackendPhoneDeviceStream {
        let video: Bool
        init(video: Bool) { self.video = video }
        var image: CGImage?
        var changedAt = 0.0
        var generation = 0, seen = 0
        var stopped = false
        func set(_ image: CGImage) { self.image = image; generation += 1; changedAt = VideoPipelineTests.now() }
        private func take() -> (CGImage, Double)? {
            guard generation != seen, let image else { return nil }
            seen = generation
            return (image, changedAt)
        }
        func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer {
            guard video else { return .unsupported }
            let deadline = VideoPipelineTests.now() + seconds * 1_000
            while !stopped, !Task.isCancelled {
                if let (image, at) = take(), let buffer = VideoPipelineTests.buffer(image) { return .pixels(.init(buffer, capturedAt: at)) }
                if VideoPipelineTests.now() >= deadline { return .unchanged }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return .ended
        }
        func endReason() -> String { "gone" }
        func stop() { stopped = true }
    }

    static func buffer(_ image: CGImage) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &made) == kCVReturnSuccess,
              let made else { return nil }
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(made), width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(made), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return made
    }

    /// The phone: joins parts, decodes for real, notes when each picture is ready, acks.
    actor Phone {
        struct Shown { let seq: Int; let changedAt: Double; let readyAt: Double; let bytes: Int; let still: Bool; let width: Int }
        var shown: [Shown] = []
        var pieces: [Int: [Int: String]] = [:]
        var format: CMVideoFormatDescription?
        var session: VTDecompressionSession?
        var lastSPS: Data?
        var decodeFailures = 0
        func decodeVideo(_ value: NativeRPCValue, data: Data) -> Bool {
            if value["key"].bool == true, let sps = value["sps"].string.flatMap({ Data(base64Encoded: $0) }), let pps = value["pps"].string.flatMap({ Data(base64Encoded: $0) }),
               sps != lastSPS || format == nil {
                lastSPS = sps
                if let session { VTDecompressionSessionInvalidate(session) }
                session = nil; format = nil
                var made: CMFormatDescription?
                let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                    let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                        parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &made)
                } }
                guard status == noErr, let made else { return false }
                format = made
                var decoder: VTDecompressionSession?
                guard VTDecompressionSessionCreate(allocator: nil, formatDescription: made, decoderSpecification: nil, imageBufferAttributes: nil,
                                                   outputCallback: nil, decompressionSessionOut: &decoder) == noErr else { return false }
                session = decoder
            }
            guard let format, let session else { return false }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
                                                     offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return false }
            _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
            var sample: CMSampleBuffer?
            var size = data.count
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                            sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
                  let sample else { return false }
            var ok = false
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                ok = status == noErr && image != nil
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            if status != noErr || !ok { decodeFailures += 1 }
            return status == noErr && ok
        }
        /// A frame the viewer drops: its parts are forgotten.
        func discard(_ seq: Int) { pieces[seq] = nil }
        /// Answers the ack to send, if the picture is complete.
        func arrived(_ value: NativeRPCValue, changedAt: Double) -> String? {
            let seq = Int(value["seq"].number ?? -1), parts = Int(value["parts"].number ?? 1), part = Int(value["part"].number ?? 0)
            pieces[seq, default: [:]][part] = value["data"].string ?? ""
            guard pieces[seq]?.count == parts else { return nil }
            let text = (0..<parts).compactMap { pieces[seq]?[$0] }.joined()
            pieces[seq] = nil
            guard let data = Data(base64Encoded: text) else { return nil }
            let ready = value["t"].string == "sims.video" && decodeVideo(value, data: data)
            if ready {
                let w = Int(value["fw"].number ?? value["w"].number ?? 0)
                shown.append(.init(seq: seq, changedAt: changedAt, readyAt: VideoPipelineTests.now(), bytes: data.count,
                                   still: value["still"].bool == true || value["sharp"].bool == true, width: w))
            }
            return #"{"t":"sims.ack","id":"\#(value["id"].string ?? "")","seq":\#(seq)}"#
        }
    }

    /// The link: `capacity` bits a second, `oneWay` ms each way; the phone's acks come back the same way.
    actor Link {
        let capacity: Double, oneWay: Double
        var free = 0.0
        var bytes = 0
        let phone: Phone
        let screen: PixelScreen
        var ack: (@Sendable (String) async -> Void)?
        init(capacity: Double, oneWay: Double, phone: Phone, screen: PixelScreen) { self.capacity = capacity; self.oneWay = oneWay; self.phone = phone; self.screen = screen }
        func setAck(_ ack: @escaping @Sendable (String) async -> Void) { self.ack = ack }
        func carry(_ message: NativeRPCValue) async {
            guard message["t"].string == "sims.video" else { return }
            let chars = message["data"].string?.utf8.count ?? 0
            bytes += chars * 3 / 4
            let now = VideoPipelineTests.now()
            let done = max(now, free) + Double(chars + 160) * 8_000 / capacity
            free = done
            // When the picture in this frame was captured: the Mac stamps it (`ct`).
            let screenChanged = await screen.changedAt
            let changedAt = message["ct"].number ?? screenChanged
            let phone = self.phone, ack = self.ack, back = oneWay
            Task {
                let wait = done + back - VideoPipelineTests.now()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
                guard let answer = await phone.arrived(message, changedAt: changedAt) else { return }
                try? await Task.sleep(nanoseconds: UInt64(back * 1_000_000))
                await ack?(answer)
            }
        }
    }

    static func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
    static func p90(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.9))] }

    /// `typing`: instead of scrolling 30 times a second, one change every 0.6 s for 5 s (slow typing, Reviewer M1): each
    /// change follows a pause long enough for the still frame to start, and its first frame must not wait behind it.
    func run(video: Bool, oneWay: Double, capacity: Double, label: String, typing: Bool = false) async throws -> [String: Double] {
        let screen = PixelScreen(video: video)
        let phone = Phone()
        let link = Link(capacity: capacity, oneWay: oneWay, phone: phone, screen: screen)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VID-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: dir.appendingPathComponent("remote"))
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Phone", address: "fixture", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: dir.path, hostName: "Fixture", appVersion: "test", privateRoots: [], sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        let row = NativeRPCValue.object([.init("id", .string("mac:1")), .init("name", .string("Studio Mac")), .init("platform", .string("mac")),
            .init("kind", .string("display")), .init("state", .string("ready")), .init("canWatch", .bool(true)), .init("canControl", .bool(true))])
        var source = BackendPhoneDevices.Source(
            list: { .object([.init("devices", .array([]))]) }, power: { _, _ in .object([]) }, stream: { _, _ in screen }, input: { _, _ in },
            shot: { _ in throw NativeRPCError(code: "unavailable", message: "no") }, deliver: { _ in "" }, visibleSessions: { _ in [] },
            send: { _, _ in }, macRows: { [row] })
        PhoneScreenFixtures.link(&source) { value in await link.carry(value) }
        let installation = try await BackendPhoneDevices.install(on: host, source: source)
        try await host.start()
        let timer = clock.scheduled.value() + 1
        let welcomed = PhoneScreenFixtures.Welcomed()
        let id = try #require(await host.accept(.init(address: "fixture", send: { text in if text.contains("\"welcome\"") { await welcomed.set() } }, close: { _, _ in })))
        await clock.scheduled.wait(timer)
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Phone")), .init("platform", .string("ios"))])), .init("capabilities", .array([.string("device.access")]))])
        await host.receive(id, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        for _ in 0..<400 where !(await welcomed.done) { try await Task.sleep(for: .milliseconds(10)) }
        await link.setAck { [weak host] text in await host?.receive(id, text: text) }
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }

        var out: [String: Double] = [:]
        await screen.set(PhoneScreenFixtures.screen(offset: 0))
        let t0 = Self.now()
        let watch = #"{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":2560,"quality":60,"fps":60,"video":["h264"]}"#
        await host.receive(id, text: watch)
        try await Task.sleep(for: .milliseconds(3_000))
        out["open.sharpMs"] = (await phone.shown.last { $0.still }?.readyAt).map { $0 - t0 } ?? .nan

        if typing {
            let typeStart = Self.now()
            var changedAt: [Double] = []
            var offset = 0
            while Self.now() - typeStart < 5_000 {
                offset += 24
                await screen.set(PhoneScreenFixtures.screen(offset: offset))
                changedAt.append(await screen.changedAt)
                try await Task.sleep(for: .milliseconds(600))
            }
            try await Task.sleep(for: .milliseconds(2_000))
            let all = await phone.shown
            let firsts = changedAt.compactMap { at in all.filter { !$0.still && abs($0.changedAt - at) < 1 }.map(\.readyAt).min().map { $0 - at } }
            print("MEASURE \(label) typing.firstFrameMs.each=\(firsts.map { Int($0) })")
            out["typing.changes"] = Double(changedAt.count)
            out["typing.shown"] = Double(firsts.count)
            out["typing.firstFrameMs.median"] = Self.median(firsts)
            out["typing.firstFrameMs.max"] = firsts.max() ?? .nan
            let stills = all.filter { $0.still && $0.readyAt > typeStart }
            out["typing.stillsShown"] = Double(stills.count)
            out["still.kb"] = Self.median(all.filter(\.still).map { Double($0.bytes) / 1_000 })
            out["still.kb.max"] = all.filter(\.still).map { Double($0.bytes) / 1_000 }.max() ?? .nan
            out["decodeFailures"] = Double(await phone.decodeFailures)
            await host.receive(id, text: #"{"t":"sims.unwatch","id":"mac:1"}"#)
            for key in out.keys.sorted() { print("MEASURE \(label) \(key)=\(String(format: "%.1f", out[key]!))") }
            return out
        }

        // Moving: 30 screen changes a second for 4 s (scrolling a page).
        let moveStart = Self.now()
        var offset = 0, changes = 0
        while Self.now() - moveStart < 4_000 {
            offset += 24; changes += 1
            await screen.set(PhoneScreenFixtures.screen(offset: offset))
            let wait = moveStart + Double(changes) * 33.3 - Self.now()
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
        }
        let moveEnd = Self.now()
        let bytesBefore = await link.bytes
        try await Task.sleep(for: .milliseconds(3_000))
        let all = await phone.shown
        let moving = all.filter { $0.changedAt >= moveStart && $0.changedAt < moveEnd && !$0.still }
        let seconds = (moveEnd - moveStart) / 1_000
        out["moving.fps"] = Double(moving.count) / seconds
        out["moving.screenChangesPerSecond"] = Double(changes) / seconds
        out["moving.glassMs.median"] = Self.median(moving.map { $0.readyAt - $0.changedAt })
        out["moving.glassMs.p90"] = Self.p90(moving.map { $0.readyAt - $0.changedAt })
        out["moving.kbPerSecond"] = Double(moving.reduce(0) { $0 + $1.bytes }) / 1_000 / seconds
        out["moving.width"] = Self.median(moving.map { Double($0.width) })
        out["sharpAgainMs"] = (all.last { $0.still && $0.readyAt > moveEnd }?.readyAt).map { $0 - moveEnd } ?? .nan
        out["decodeFailures"] = Double(await phone.decodeFailures)
        out["still.kb"] = Self.median(all.filter(\.still).map { Double($0.bytes) / 1_000 })
        _ = bytesBefore
        await host.receive(id, text: #"{"t":"sims.unwatch","id":"mac:1"}"#)
        for key in out.keys.sorted() { print("MEASURE \(label) \(key)=\(String(format: "%.1f", out[key]!))") }
        return out
    }

    @Test func realtimeVideoOnTheLink() async throws {
        let turn = try await run(video: true, oneWay: 20, capacity: 20_000_000, label: "turn-video")
        let lan = try await run(video: true, oneWay: 3, capacity: 100_000_000, label: "lan-video")
        #expect(turn["decodeFailures"]! == 0 && lan["decodeFailures"]! == 0, "every frame decodes")
        // Debug build: the scripted screen itself redraws a 2560 × 1600 page and copies it into a pixel buffer for every
        // change, which caps it near 26 a second here; the real capture hands pixel buffers over directly.
        #expect(turn["moving.fps"]! >= 20, "\(turn)")
        #expect(lan["moving.fps"]! >= 20, "\(lan)")
        #expect(turn["moving.glassMs.median"]! <= 150, "\(turn)")
        #expect(lan["moving.glassMs.median"]! <= 100, "\(lan)")
        #expect(!turn["sharpAgainMs"]!.isNaN && turn["sharpAgainMs"]! < 1_500, "a full-quality frame soon after it stops")
        // Reviewer M2: one still frame stays well under what the phones join (64 parts); target ≤ 1.5 MB.
        #expect(turn["still.kb"]! <= 1_500 && lan["still.kb"]! <= 1_500, "\(turn["still.kb"]!) / \(lan["still.kb"]!) KB")
    }

    /// Reviewer M1 (2 Nov): slow typing — one change every 0.6 s, so a still frame starts after every change; the first
    /// frame of the next change must arrive as quickly as during motion (≤ 250 ms), never behind it.
    @Test func slowTypingIsNotHeldBackByTheStill() async throws {
        let typing = try await run(video: true, oneWay: 20, capacity: 20_000_000, label: "turn-typing", typing: true)
        #expect(typing["decodeFailures"]! == 0)
        #expect(typing["typing.shown"]! == typing["typing.changes"]!, "every change shown: \(typing)")
        #expect(typing["typing.firstFrameMs.max"]! <= 250, "the first frame after each pause: \(typing)")
        #expect(typing["still.kb.max"]!.isNaN || typing["still.kb.max"]! <= 1_500, "\(typing)")
    }

    @Test func theWatchCarriesVideoAndTheMacSendsH264() throws {
        guard case .message(let watch) = BackendRemoteProtocol.parseClientMessage(#"{"t":"sims.watch","id":"mac:1","maxWidth":2560,"quality":60,"fps":30,"video":["h264"]}"#) else {
            Issue.record("refused"); return
        }
        #expect(watch["video"].elements?.first?.string == "h264")
        let frame = BackendPhoneVideoEncoder.Frame(data: Data(repeating: 7, count: 200_000), key: true, sps: Data([1, 2]), pps: Data([3]), width: 2560, height: 1600,
                                                   still: true, encodeMilliseconds: 4)
        let messages = BackendPhoneDevices.videoMessages(id: "mac:1", seq: 3, frame, capturedAt: 1_000)
        #expect(messages.count == 4 && messages.allSatisfy { $0.kind == .simsVideo })
        // Reviewer M2: a frame needing more than 64 parts is never sent; the still's hard cap always fits in 64 small parts.
        var huge = frame; huge.data = Data(repeating: 7, count: 64 * BackendPhoneDevices.partChars * 3 / 4 + 3_000)
        #expect(BackendPhoneDevices.videoMessages(id: "mac:1", seq: 4, huge, capturedAt: 1_000).isEmpty)
        var capped = frame; capped.data = Data(repeating: 7, count: BackendPhoneVideoEncoder.stillHardCap)
        let stillParts = BackendPhoneDevices.videoMessages(id: "mac:1", seq: 5, capped, capturedAt: 1_000, partChars: BackendPhoneDevices.stillPartChars)
        #expect(stillParts.count == 64 && stillParts.allSatisfy { ($0.value["data"].string?.utf8.count ?? .max) <= BackendPhoneDevices.stillPartChars })
        #expect(BackendPhoneDevices.stillBudget(bitrate: 400_000) == 300_000 && BackendPhoneDevices.stillBudget(bitrate: 4_000_000) == 500_000 && BackendPhoneDevices.stillBudget(bitrate: 100_000_000) == BackendPhoneVideoEncoder.stillHardCap)
        #expect(messages[0].value["key"].bool == true && messages[0].value["sps"].string == Data([1, 2]).base64EncodedString() && messages[0].value["still"].bool == true)
        #expect(messages.map { Int($0.value["part"].number ?? -1) } == [0, 1, 2, 3])
    }
}
