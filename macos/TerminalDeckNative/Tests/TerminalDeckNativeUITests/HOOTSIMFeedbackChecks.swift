import AppKit
import Foundation
import ImageIO
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Invoked by the hidden HOOTSIM native fixture only. No engine, AI, device,
/// installed app, preferences, clipboard, or menus are used by these checks.
@MainActor enum HOOTSIMFeedbackChecks {
    /// Run before any scratch bridge is configured. It never resets or disconnects
    /// another test's bridge and refuses to run if a bridge is already attached.
    static func runNilBridgeCheck() async throws -> Int {
        guard !EngineBridge.shared.isReady else { throw failure("Nil-bridge check needs the isolated unconfigured test bridge") }
        do {
            try await NativeHOOTSIMFeedback.sendScreenToHoot(deviceId: "ios:HOOTSIM-STUB")
            throw failure("An unconfigured bridge accepted a screen send")
        } catch let error as NSError {
            try require(error.domain != "HOOTSIM.FeedbackCheck", "Unconfigured bridge refuses before capture")
        }
        return 1
    }

    static func runRPCChecks() async throws -> Int {
        let png = try image(width: 120, height: 240, noisy: false)
        let sessionID = "HOOTSIM-session"
        let deviceID = "ios:HOOTSIM-STUB"
        let ticket = UIGSessionSimulatorTicket(value: ["sessionId": sessionID, "attachmentToken": UUID().uuidString,
            "deviceId": deviceID, "slot": 0], for: sessionID)!
        let source = NativeRPCValue.object([.init("folder", .string("/scratch/CRM")),
            .init("projectId", .string("crm")), .init("path", .string("/scratch/shot.png")),
            .init("title", .string("Sign in"))])

        let scoped = RPCStub(png: png)
        try await NativeHOOTSIMFeedback.sendScreenToHoot(deviceId: deviceID, ticket: ticket, source: source,
            invoke: scoped.invoke)
        try require(scoped.channels == ["session-simulator:validate", "session-simulator:device",
            "session-simulator:validate", "session-simulator:send-hoot"], "Scoped capture uses exact checked channel order")
        try require(scoped.sentTicket?["attachmentToken"].string == ticket.token && scoped.enqueued == 1, "Actual capture token reaches scoped enqueue")
        try require(scoped.sentSource["folder"] == source["folder"] && scoped.sentSource["projectId"] == source["projectId"]
            && scoped.sentSource["path"] == source["path"] && scoped.sentSource["title"] == source["title"], "Structured source survives unchanged")
        try require(scoped.sentSource["sessionId"].string == sessionID && scoped.sentSource["deviceId"].string == deviceID, "Source identities are explicit")
        try require(scoped.sentBlocks.count == 1 && Data(base64Encoded: scoped.sentBlocks[0]["source"]["data"].string ?? "") == png, "Screenshot bytes survive native RPC")
        try require(scoped.sentText.contains("sign-in") && scoped.sentText.contains("Accessibility tree"), "Accessibility tree accompanies screen")

        let ordinary = RPCStub(png: png)
        try await NativeHOOTSIMFeedback.sendScreenToHoot(deviceId: deviceID, source: source, invoke: ordinary.invoke)
        try require(ordinary.channels == ["devices:freeze", "hoot:chat:say"], "Ordinary device uses existing chat ingress")
        try require(ordinary.sentTicket == nil && ordinary.sentSource["sessionId"].isNullish && ordinary.enqueued == 1, "Ordinary row never guesses a source session")

        // Asad, 12 Oct: Hoot may always use simulators and phones. An old "Use simulators" switch left off (or a
        // settings read that fails) no longer stops a capture: the setting is never read.
        for mode in [RPCStub.Mode.accessOff, .settingUnavailable] {
            let allowed = RPCStub(png: png, mode: mode)
            try await NativeHOOTSIMFeedback.sendScreenToHoot(deviceId: deviceID, ticket: ticket, invoke: allowed.invoke)
            try require(!allowed.channels.contains("hoot:settings:read") && allowed.enqueued == 1, "No device setting is read; the screen is sent")
        }

        let changed = RPCStub(png: png, mode: .changedAfterCapture)
        do {
            try await NativeHOOTSIMFeedback.sendScreenToHoot(deviceId: deviceID, ticket: ticket, source: source, invoke: changed.invoke)
            throw failure("Changed attachment after capture was accepted")
        } catch let error as NativeRPCError { try require(error.code == "stale-attachment", "Changed attachment refused") }
        try require(changed.channels.last == "session-simulator:validate" && changed.enqueued == 0, "Changed source never reaches chat")

        // The new backend door models detach while Hoot ensure is awaiting. Its
        // refusal must return to the card, with no direct-chat fallback.
        let changedAtEnqueue = RPCStub(png: png, mode: .changedAtEnqueue)
        do {
            try await NativeHOOTSIMFeedback.sendScreenToHoot(deviceId: deviceID, ticket: ticket, source: source, invoke: changedAtEnqueue.invoke)
            throw failure("Backend late validation was ignored")
        } catch let error as NativeRPCError { try require(error.code == "stale-attachment", "Late backend refusal propagates") }
        try require(changedAtEnqueue.channels.last == "session-simulator:send-hoot" && changedAtEnqueue.enqueued == 0,
            "Late refusal never falls back to direct chat")
        return 6
    }

    static func run() throws -> Int {
        var count = 0
        let small = try image(width: 120, height: 240, noisy: false)
        let direct = try NativeHOOTSIMFeedback.attachments(images: [small])
        try require(direct.count == 1 && direct[0]["type"].string == "image", "Image content block")
        try require(direct[0]["source"]["type"].string == "base64" && direct[0]["source"]["media_type"].string == "image/png", "PNG MIME and base64")
        try require(Data(base64Encoded: direct[0]["source"]["data"].string ?? "") == small, "Small image pixels kept exactly")
        count += 1

        let full = try image(width: 1206, height: 2622, noisy: true)
        try require(full.count > 500_000, "Large image really exceeds composer cap")
        let bounded = try NativeHOOTSIMFeedback.attachments(images: [full])
        let body = Data(base64Encoded: bounded[0]["source"]["data"].string ?? "") ?? Data()
        try require(!body.isEmpty && body.count <= 500_000, "Full phone capture fits composer cap")
        let source = CGImageSourceCreateWithData(body as CFData, nil)
        try require(source != nil && CGImageSourceCreateImageAtIndex(source!, 0, nil) != nil, "Bounded image really decodes")
        count += 1

        let screens = Array(repeating: small, count: 9)
        let packed = try NativeHOOTSIMFeedback.attachments(images: screens)
        try require(packed.count <= 4 && packed.count > 0, "Long recording fits existing attachment count")
        for block in packed {
            let bytes = Data(base64Encoded: block["source"]["data"].string ?? "") ?? Data()
            try require(bytes.count <= 500_000, "Every numbered screen sheet fits byte cap")
            let source = CGImageSourceCreateWithData(bytes as CFData, nil)
            try require(source != nil && CGImageSourceCreateImageAtIndex(source!, 0, nil) != nil, "Every sheet decodes")
        }
        count += 1

        do {
            _ = try NativeHOOTSIMFeedback.attachments(images: [Data("not a picture".utf8)])
            throw failure("Malformed image was accepted")
        } catch let error as NativeRPCError { try require(error.code == "invalid-arguments", "Malformed image refused clearly") }
        count += 1

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HOOTSIM-feedback-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = folder.appendingPathComponent("phone.png")
        try full.write(to: saved)
        let attachment = try NativeHOOTSIMFeedback.attachment(url: saved)
        try require(attachment["type"].string == "image", "Saved local screenshot becomes image content")
        try require(try Data(contentsOf: saved) == full, "Sending a smaller copy leaves original file unchanged")
        count += 1
        return count
    }

    private static func image(width: Int, height: Int, noisy: Bool) throws -> Data {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 0xABCDEF
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                bytes[pixel * 4 + channel] = noisy ? UInt8(truncatingIfNeeded: seed >> 24) : UInt8(channel == 2 ? 240 : 180)
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData), let cgImage = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw failure("Image fixture could not be made")
        }
        return png
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw failure(message) }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "HOOTSIM.FeedbackCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor private final class RPCStub {
        enum Mode: Equatable { case allowed, accessOff, settingUnavailable, changedAfterCapture, changedAtEnqueue }
        let png: Data
        let mode: Mode
        var channels: [String] = []
        var enqueued = 0
        var captured = false
        var sentTicket: NativeRPCValue?
        var sentSource: NativeRPCValue = .object([])
        var sentBlocks: [NativeRPCValue] = []
        var sentText = ""
        init(png: Data, mode: Mode = .allowed) { self.png = png; self.mode = mode }
        func invoke(_ channel: String, _ arguments: [Any?]) async throws -> Any {
            channels.append(channel)
            switch channel {
            case "hoot:settings:read":
                return ["capabilities": ["useDevices": mode != .settingUnavailable], "useDevices": mode != .accessOff]
            case "session-simulator:validate":
                if mode == .changedAfterCapture, captured { throw NativeRPCError(code: "stale-attachment", message: "The attachment changed.") }
                return arguments[0] ?? NSNull()
            case "devices:freeze", "session-simulator:device":
                captured = true
                if channel == "session-simulator:device" {
                    guard arguments.count == 3, arguments[1] as? String == "devices:freeze" else {
                        throw HOOTSIMFeedbackChecks.failure("Scoped capture contract changed")
                    }
                }
                return ["image": "data:image/png;base64," + png.base64EncodedString(), "where": ["name": "Stub phone"],
                    "tree": ["role": "button", "identifier": "sign-in"], "treeError": ""]
            case "session-simulator:send-hoot":
                guard arguments.count == 4 else { throw HOOTSIMFeedbackChecks.failure("Scoped send contract changed") }
                sentTicket = try NativeRPCValue.fromFoundation(arguments[0] ?? NSNull())
                sentText = arguments[1] as? String ?? ""
                sentBlocks = try NativeRPCValue.fromFoundation(arguments[2] ?? NSNull()).requireArray("blocks")
                sentSource = try NativeRPCValue.fromFoundation(arguments[3] ?? NSNull())
                if mode == .changedAtEnqueue { throw NativeRPCError(code: "stale-attachment", message: "Detached while Hoot started.") }
                enqueued += 1
                return ["ok": true]
            case "hoot:chat:say":
                guard arguments.count == 3 else { throw HOOTSIMFeedbackChecks.failure("Ordinary send context missing") }
                sentText = arguments[0] as? String ?? ""
                sentBlocks = try NativeRPCValue.fromFoundation(arguments[1] ?? NSNull()).requireArray("blocks")
                sentSource = try NativeRPCValue.fromFoundation(arguments[2] ?? NSNull())["source"]
                enqueued += 1
                return ["ok": true]
            default:
                throw HOOTSIMFeedbackChecks.failure("Unexpected channel: " + channel)
            }
        }
    }
}
