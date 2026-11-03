import CoreMedia
import CoreVideo
import Foundation
import TerminalDeckNativeCore
import VideoToolbox

// 3 Nov (m5-direct-only; Decker: the Mac-to-Mac screen viewer stays, on the direct link like the phones): this Mac as a
// guest of another computer (Devices › Machines, "Other Macs") speaks exactly the phones' client side of the link
// contract (stream-step2-contract.md §1-§7 and §11 "link only"): hello `link.dc2` + `link.only` from platform `darwin`,
// it answers the host's offer (binding checked), and everything after the welcome rides the link. A host too old to
// offer a link keeps today's relay connection (§11.5). The same wire as the Windows hand's `LinkGuest` (win-27).
//
// The WebRTC half is the app's (`TerminalDeckPeer` answers); this module stays free of it.

/// The app's answering side of a link (TerminalDeckPeer: `PeerLink` as the answerer).
public protocol BackendLinkAnswering: Sendable {
    func answer(servers: [BackendPhonePeerServer], policy: String, events: BackendLinkEvents) throws -> any BackendLinkAnswerConnection
}

/// One answering peer connection.
public protocol BackendLinkAnswerConnection: AnyObject, Sendable {
    /// Applies the host's offer and answers with the local SDP.
    func answer(offer: String) async throws -> String
    func add(candidate: String, mid: String?, index: Int32)
    /// False when the channel is not open or the library refused it.
    func send(_ data: Data, lane: BackendLinkLane) -> Bool
    var isOpen: Bool { get }
    func close()
}

extension BackendRemoteGuest {
    private static let answererLock = NSLock()
    nonisolated(unsafe) private static var installedAnswerer: (any BackendLinkAnswering)?
    /// Set once by the app (TerminalDeckPeer); nil in the session host and in tests without WebRTC (no link asked).
    public static var answerer: (any BackendLinkAnswering)? {
        get { answererLock.withLock { installedAnswerer } }
        set { answererLock.withLock { installedAnswerer = newValue } }
    }
    /// What the person reads when a computer's link cannot be made (§11.3, the same words as Windows).
    public static func unreachable(_ name: String) -> String { "Can't reach \(name) — this network blocks the direct connection." }
    /// No offer this long after a welcome that said `link.dc2`, or no open link this long after the offer.
    static let offerWaitMs = 12_000, linkDeadlineMs = 15_000
    /// Messages waiting for the link: at most this many bytes (more means the link failed).
    static let mostWaitingBytes = 4 * 1024 * 1024
}

/// H.264 as the host sends it (`sims.video`: AVCC NAL units, SPS/PPS on keyframes), decoded here into pictures.
public final class BackendH264Decoder: @unchecked Sendable {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var lastSPS: Data?
    public init() {}
    deinit { invalidate() }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; lastSPS = nil
    }

    /// One whole frame (its parts joined): the picture, or nil (no keyframe yet, or it did not decode). Security M1
    /// (27): empty parameter sets are refused before VideoToolbox sees them (a host's `"sps":""` must not crash this Mac).
    public func decode(_ data: Data, sps: Data?, pps: Data?) -> CGImage? {
        if let sps, let pps, !sps.isEmpty, !pps.isEmpty, sps.count <= 1_024, pps.count <= 1_024, sps != lastSPS || format == nil {
            invalidate()
            lastSPS = sps
            var made: CMFormatDescription?
            let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &made)
            } }
            guard status == noErr, let made else { return nil }
            format = made
            let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
            var decoder: VTDecompressionSession?
            guard VTDecompressionSessionCreate(allocator: nil, formatDescription: made, decoderSpecification: nil,
                                               imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                               decompressionSessionOut: &decoder) == noErr else { return nil }
            session = decoder
        }
        guard let format, let session, !data.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        var picture: CGImage?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            var made: CGImage?
            if VTCreateCGImageFromCVPixelBuffer(image, options: nil, imageOut: &made) == noErr { picture = made }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr ? picture : nil
    }
}

/// The viewers' rules for `sims.video` (contract §6, the same as the iPhone, Android and web): parts joined; a frame at
/// or before the last one handed on is stale (acked, dropped); a delta that is not the next one after the last, or any
/// delta before a watch's first keyframe, is dropped and a keyframe asked for (at once, then at most once a second). Only
/// a frame handed to the decoder moves "the last one handed on".
/// Security M1 (27, the iPhone's own rule, SimsWire): every number is read exactly (`Int(exactly:)`), `seq ≥ 0`,
/// `1 ≤ parts ≤ 64`, `0 ≤ part < parts`, no empty data, at most `mostJoinedBytes` joined; anything else is refused and a
/// keyframe asked for — a host's frame can never trap or grow memory here.
public struct BackendVideoViewerRules: Sendable {
    public enum Outcome: Equatable {
        case waiting, stale(Int), dropped(Int, askKey: Bool), decode(seq: Int, data: Data, key: Bool)
        /// A frame that breaks the rules: dropped unread (nothing to ack); ask a keyframe when `askKey`.
        case refused(askKey: Bool)
    }
    public static let mostParts = 64
    public static let mostJoinedBytes = 4 * 1024 * 1024
    public private(set) var last = -1
    private var awaitingKey = true
    private var askedAt = -Double.infinity
    private var pieces: (seq: Int, parts: [Int: String]) = (-1, [:])
    public init() {}

    /// One `sims.video` message (`now` in ms).
    public mutating func take(_ frame: NativeRPCValue, now: Double) -> Outcome {
        guard let seq = Self.whole(frame["seq"]), seq >= 0, let data = frame["data"].string, !data.isEmpty,
              data.utf8.count <= Self.mostJoinedBytes else { return refuse(now) }
        var text = data
        let parts: Int, part: Int
        if frame["parts"] == .missing { parts = 1 } else {
            guard let given = Self.whole(frame["parts"]), (1...Self.mostParts).contains(given) else { return refuse(now) }
            parts = given
        }
        if frame["part"] == .missing { part = 0 } else {
            guard let given = Self.whole(frame["part"]) else { return refuse(now) }
            part = given
        }
        guard part >= 0, part < parts else { return refuse(now) }
        if parts > 1 {
            // One sequence at a time: a new one forgets the unfinished one.
            if pieces.seq != seq { pieces = (seq, [:]) }
            pieces.parts[part] = data
            let joined = pieces.parts.values.reduce(0) { $0 + $1.utf8.count }
            guard joined <= Self.mostJoinedBytes else { pieces = (-1, [:]); return refuse(now) }
            guard pieces.parts.count == parts else { return .waiting }
            text = (0..<parts).compactMap { pieces.parts[$0] }.joined()
            pieces = (-1, [:])
        }
        if seq <= last { return .stale(seq) }
        let key = frame["key"].bool == true
        if key { awaitingKey = false } else {
            var force = false
            if !awaitingKey, seq != last + 1 { awaitingKey = true; force = true }
            if awaitingKey {
                let ask = (force || now - askedAt > 1_000) && now - askedAt > 250
                if ask { askedAt = now }
                return .dropped(seq, askKey: ask)
            }
        }
        guard let bytes = Data(base64Encoded: text) else { return .dropped(seq, askKey: false) }
        last = seq
        return .decode(seq: seq, data: bytes, key: key)
    }

    /// A new watch (or the same again after the link came back): everything starts over.
    public mutating func reset() { self = .init() }

    /// A whole number exactly as sent, or nil (a fraction, NaN, ±infinity or beyond Int's range never traps).
    static func whole(_ value: NativeRPCValue) -> Int? {
        guard let number = value.number, number.isFinite, number.rounded() == number, abs(number) <= 9_007_199_254_740_991 else { return nil }
        return Int(exactly: number)
    }

    /// A frame that breaks the rules: the watch waits for a keyframe again (asked at once, then at most once a second).
    private mutating func refuse(_ now: Double) -> Outcome {
        awaitingKey = true
        let ask = now - askedAt > 1_000
        if ask { askedAt = now }
        return .refused(askKey: ask)
    }
}
