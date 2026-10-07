import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import TerminalDeckNativeCore

public struct BackendAppDeviceChannels: Sendable {
    public static let channels: Set<String> = ["devices:list", "devices:boot", "devices:shutdown", "devices:open", "devices:watch", "devices:tap", "devices:touch", "devices:swipe", "devices:type", "devices:key", "devices:button", "devices:rotate", "devices:screenshot", "devices:freeze", "annotate:save", "annotate:sent"]
    private let manager: BackendAppDeviceManager
    private let authorize: @Sendable (NativeRPCContext) throws -> Void
    public init(manager: BackendAppDeviceManager, authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void) {
        self.manager = manager; authorize = authorizeMutation
    }
    public static func deviceID(_ value: NativeRPCValue) throws -> String {
        guard let id = value.string, BackendSharedText.matches(id, #"^(ios|android|avd):[A-Za-z0-9._:-]{1,120}$"#) else { throw BackendAppSessionError("That is not a device this app listed.") }
        return id
    }
    public static func unit(_ value: NativeRPCValue) throws -> Double {
        guard let number = value.number else { throw BackendAppSessionError("A position must be a number.") }; return min(max(number, 0), 1)
    }
    private static func point(_ value: NativeRPCValue) throws -> NativeRPCValue { try BackendAppDeviceParsing.object([("x", .number(unit(value["x"]))), ("y", .number(unit(value["y"])))]) }
    public static func preview(_ png: Data, height: Int = 900) -> String {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.height > 0 else { return "" }
        if image.height <= height { return "data:image/png;base64," + png.base64EncodedString() }
        let maxPixels = max(1, Int(ceil(Double(max(image.width, image.height)) * Double(height) / Double(image.height))))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let resized = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return "" }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return "" }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination) else { return "" }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext, viewer: BackendAppDeviceViewer? = nil) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw BackendAppSessionError("The native device facade does not handle this channel.") }
        func value(_ n: Int) -> NativeRPCValue { args.indices.contains(n) ? args[n] : .missing }
        if channel != "devices:list" { try authorize(context) }
        if ["devices:list", "devices:open", "devices:watch"].contains(channel), let viewer { await manager.registerInterest(viewer) }
        switch channel {
        case "devices:list": return await manager.list()
        case "devices:boot": return try await manager.boot(Self.deviceID(value(0)))
        case "devices:shutdown": return try await manager.shutDown(Self.deviceID(value(0)))
        case "devices:open": return try await manager.open(Self.deviceID(value(0)))
        case "devices:watch":
            guard let viewer else { throw BackendAppSessionError("The native device viewer is unavailable, so its screen stream could not be attached.") }
            let mode: BackendAppDeviceWatchMode = value(1).bool == true ? .on : value(1).string == "paused" ? .paused : .off
            try await manager.watch(viewer, id: Self.deviceID(value(0)), mode: mode)
        case "devices:tap": try await manager.tap(Self.deviceID(value(0)), x: Self.unit(value(1)), y: Self.unit(value(2)), holdMilliseconds: value(3).number.map { min($0, 5_000) })
        case "devices:touch":
            guard let phase = value(1).string, ["down", "move", "up"].contains(phase) else { throw BackendAppSessionError("A touch is down, move or up.") }
            try await manager.touch(Self.deviceID(value(0)), phase: phase, x: Self.unit(value(2)), y: Self.unit(value(3)))
        case "devices:swipe":
            let duration = value(3).number.map { min(max($0, 50), 5_000) } ?? 300
            try await manager.swipe(Self.deviceID(value(0)), from: Self.point(value(1)), to: Self.point(value(2)), durationMilliseconds: duration)
        case "devices:type":
            guard let text = value(1).string, text.utf16.count <= 2_000 else { throw BackendAppSessionError("Text to type must be a short string.") }
            try await manager.type(Self.deviceID(value(0)), text: text)
        case "devices:key":
            guard let key = value(1).string, ["delete", "return", "enter", "tab", "escape", "arrow-up", "arrow-down", "arrow-left", "arrow-right", "select-all"].contains(key) else { throw BackendAppSessionError("That key is not one a device can be sent.") }
            let modifiers = BackendAppDeviceParsing.strings(value(2)).filter { ["command", "shift", "option", "control"].contains($0) }
            try await manager.key(Self.deviceID(value(0)), key: key, modifiers: modifiers)
        case "devices:button":
            guard let button = value(1).string, ["home", "back", "overview", "lock", "volume-up", "volume-down", "action"].contains(button) else { throw BackendAppSessionError("That is not a hardware button.") }
            try await manager.button(Self.deviceID(value(0)), button: button)
        case "devices:rotate": return .string(try await manager.rotate(Self.deviceID(value(0))))
        case "devices:screenshot":
            let shot = try await manager.screenshot(Self.deviceID(value(0)))
            return shot.wireValue.setting("preview", .string(Self.preview(shot.shot.png))).setting("url", .string(""))
        case "devices:freeze": return try await manager.freeze(Self.deviceID(value(0)))
        case "annotate:save": return try await manager.saveRound(png: value(0), round: BackendAppDeviceParsing.round(value(1)))
        case "annotate:sent":
            guard let id = value(0).string else { return .missing }
            await manager.markSent(id, sessionID: value(1)["sessionId"].string ?? "", label: BackendAppDeviceParsing.text(value(1)["label"], maximum: 200))
        default: throw BackendAppSessionError("The native device channel has no implementation.")
        }
        return .missing
    }
}
