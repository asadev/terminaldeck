import CoreGraphics
import Foundation

/// The live screen's packets, as `devices:frame` carries them (`session.ts`):
/// the engine's own framing, one packet per frame, tagged with its kind byte.
///
///  - `0x10` — the H.264 decoder configuration (an AVCDecoderConfigurationRecord, "avcC").
///  - `0x11` — one coded picture: an 8-byte big-endian microsecond timestamp, a
///    keyframe flag byte, then the AVCC (length-prefixed) data.
///  - `0x12` — one whole JPEG picture.
///  - `0x20` — one PNG still, sent when an emulator has not drawn a frame yet.
public enum ScreenPacket: Equatable, Sendable {
    case config(Data)
    case picture(timestamp: UInt64, key: Bool, data: Data)
    case jpeg(Data)
    case still(Data)

    public static let configKind: UInt8 = 0x10
    public static let pictureKind: UInt8 = 0x11
    public static let jpegKind: UInt8 = 0x12
    public static let stillKind: UInt8 = 0x20

    public init?(_ packet: Data) {
        guard let kind = packet.first else { return nil }
        let body = packet.dropFirst()
        switch kind {
        case Self.configKind:
            self = .config(Data(body))
        case Self.pictureKind:
            guard body.count >= 10 else { return nil }
            let start = body.startIndex
            var stamp: UInt64 = 0
            for offset in 0..<8 { stamp = (stamp << 8) | UInt64(body[start + offset]) }
            self = .picture(timestamp: stamp, key: body[start + 8] == 1, data: Data(body.dropFirst(9)))
        case Self.jpegKind:
            self = .jpeg(Data(body))
        case Self.stillKind:
            self = .still(Data(body))
        default:
            return nil
        }
    }
}

/// An AVCDecoderConfigurationRecord, read: what a hardware decoder needs to start.
public struct AVCConfiguration: Equatable, Sendable {
    public var profile: UInt8
    public var compatibility: UInt8
    public var level: UInt8
    /// Bytes in each NAL unit's length prefix: 1, 2 or 4.
    public var nalLengthSize: Int
    public var sequenceParameterSets: [Data]
    public var pictureParameterSets: [Data]

    public init?(avcC: Data) {
        let bytes = [UInt8](avcC)
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }
        profile = bytes[1]
        compatibility = bytes[2]
        level = bytes[3]
        nalLengthSize = Int(bytes[4] & 0x03) + 1
        guard nalLengthSize != 3 else { return nil }
        // Byte 5 holds the SPS count; the sets follow it, each with a 2-byte length.
        var at = 6
        func sets(count: Int) -> [Data]? {
            var out: [Data] = []
            for _ in 0..<count {
                guard at + 2 <= bytes.count else { return nil }
                let length = Int(bytes[at]) << 8 | Int(bytes[at + 1])
                at += 2
                guard length > 0, at + length <= bytes.count else { return nil }
                out.append(Data(bytes[at..<at + length]))
                at += length
            }
            return out
        }
        guard let spsSets = sets(count: Int(bytes[5] & 0x1F)), !spsSets.isEmpty, at < bytes.count else { return nil }
        let ppsCount = Int(bytes[at])
        at += 1
        guard let ppsSets = sets(count: ppsCount), !ppsSets.isEmpty else { return nil }
        sequenceParameterSets = spsSets
        pictureParameterSets = ppsSets
    }

    /// Every parameter set, SPS first — the order a format description is made from.
    public var parameterSets: [Data] { sequenceParameterSets + pictureParameterSets }

    /// `avc1.PPCCLL`, as the web page's `codecOf` writes it.
    public var codec: String { String(format: "avc1.%02x%02x%02x", profile, compatibility, level) }
}

// MARK: - The hidden diagnostics readout (Option-click the device's name)

/// What the readout shows, counted from the player's start. Mirrors `PlayerStats` in `screen-player.ts`.
public struct PlayerStats: Equatable, Sendable {
    /// Coded pictures that arrived.
    public var received = 0
    /// Pictures the decoder handed back.
    public var decoded = 0
    /// Pictures painted — fewer than decoded when two arrived within one refresh.
    public var painted = 0
    /// Decoded pictures replaced by a newer one before they could be painted.
    public var dropped = 0
    /// Times the decoder fell behind and started again from a keyframe.
    public var resets = 0
    /// Recent decode times, in ms.
    public var decodeMs: [Double] = []
    /// Recent times from a touch, key or wheel to the next picture painted, in ms.
    public var inputToPictureMs: [Double] = []
    public var stream: CGSize?
    public var canvas: CGSize = .zero
    /// `yes`, `no` or `unknown`.
    public var hardware = "unknown"
    public var codec: String?

    public init() {}

    /// Keep the newest sixty timings, to a tenth of a millisecond.
    public static func remember(_ list: inout [Double], _ value: Double) {
        list.append((value * 10).rounded() / 10)
        if list.count > 60 { list.removeFirst(list.count - 60) }
    }
}

public enum DeviceDiagnostics {
    static func median(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }

    static func p95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[min(values.count - 1, Int(Double(values.count) * 0.95))]
    }

    /// The readout's lines, from two looks at the numbers `seconds` apart — `diagnosticLines`.
    public static func lines(before: PlayerStats?, now: PlayerStats, seconds: Double, scale: Double, paused: Bool) -> [String] {
        func rate(_ key: KeyPath<PlayerStats, Int>) -> String {
            guard let before, seconds > 0 else { return "–" }
            return String(format: "%.1f", Double(now[keyPath: key] - before[keyPath: key]) / seconds)
        }
        func ms(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) ms" } ?? "–" }
        func size(_ box: CGSize?) -> String { box.map { "\(Int($0.width))×\(Int($0.height))" } ?? "–" }
        let density = scale == scale.rounded() ? String(Int(scale)) : String(scale)
        return [
            paused ? "paused — window hidden" : "shown \(rate(\.painted)) fps · arriving \(rate(\.received)) fps",
            "decode \(ms(median(now.decodeMs))) (p95 \(ms(p95(now.decodeMs)))) · hardware \(now.hardware)",
            "touch → picture \(ms(median(now.inputToPictureMs))) (last \(ms(now.inputToPictureMs.last)))",
            "dropped \(now.dropped) · restarts \(now.resets)",
            "stream \(size(now.stream)) → canvas \(size(now.canvas)) @\(density)x\(now.codec.map { " · \($0)" } ?? "")",
        ]
    }
}
