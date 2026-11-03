import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// A device's or this Mac's screen as real-time video for a phone (item 61, 1 Nov; Asad: "only the changed part updates…
/// when I move something it shows after some time… a REAL experience, better speed AND better quality").
///
/// Two hardware H.264 encoders: MOTION (real-time rate control with real time stamps, no frame reordering, a keyframe only when asked, the
/// bitrate following the link) for every new picture while the screen moves, and STILL (high quality, one keyframe) for
/// the picture once the screen has been still for a moment, so text is sharp at rest. After a still the next moving
/// picture is a keyframe again (the phone's decoder switches parameter sets on keyframes).
public final class BackendPhoneVideoEncoder: @unchecked Sendable {
    /// One encoded access unit: AVCC (4-byte big-endian NAL lengths), with the parameter sets on keyframes.
    public struct Frame: Sendable, Equatable {
        public var data: Data
        public var key: Bool
        public var sps: Data?
        public var pps: Data?
        public var width: Int
        public var height: Int
        public var still: Bool
        public var encodeMilliseconds: Double
    }

    private let lock = NSLock()
    private var motion: VTCompressionSession?
    private var still: VTCompressionSession?
    private var size = (width: 0, height: 0)
    private var bitrate: Double
    private var fps: Int
    private var needKey = true
    private var frameNumber: Int64 = 0

    public init(bitrate: Double, fps: Int) { self.bitrate = bitrate; self.fps = max(1, fps) }
    deinit { invalidate() }

    public func invalidate() {
        let sessions = lock.withLock { () -> [VTCompressionSession] in
            defer { motion = nil; still = nil }
            return [motion, still].compactMap { $0 }
        }
        for session in sessions { VTCompressionSessionInvalidate(session) }
    }

    /// The next moving picture is a keyframe (a phone asked again, or after a still).
    public func requestKey() { lock.withLock { needKey = true } }

    /// The link's pace changed: the motion encoder follows (bits a second).
    public func setBitrate(_ value: Double) {
        let session = lock.withLock { () -> VTCompressionSession? in
            guard abs(value - bitrate) / max(bitrate, 1) > 0.12 else { return nil }
            bitrate = value
            return motion
        }
        if let session { Self.applyRate(session, bitrate: value) }
    }

    /// A moving picture.
    public func motion(_ pixels: CVPixelBuffer) async -> Frame? {
        guard let session = session(for: pixels, still: false) else { return nil }
        let key = lock.withLock { () -> Bool in defer { needKey = false }; return needKey }
        guard key else { return await encode(session, pixels, key: false, still: false) }
        // A forced keyframe (after a still, or asked for) is the first frame of a change: kept small — about 0.4 s of the
        // link — so it crosses as quickly as a moving frame would (Reviewer M1, 2 Nov: the first key after a pause).
        let bits = lock.withLock { bitrate }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [Int(max(300_000, bits) / 8 * 0.4), 1] as CFArray)
        defer { Self.applyRate(session, bitrate: bits) }
        let frame = await encode(session, pixels, key: true, still: false)
        if frame == nil { requestKey() }   // a key is owed until one goes
        return frame
    }

    /// The still frame's qualities, best first: each next one is tried only when the frame came out larger than allowed.
    static let stillQualities = [0.92, 0.75, 0.6, 0.45]
    /// The most bytes a still frame may ever take (Reviewer M2, 2 Nov): it crosses in at most `mostParts` parts of
    /// `stillPartChars` base64 characters, so a phone (which refuses more than 64 parts) can always join it.
    public static let stillHardCap = BackendPhoneDevices.mostParts * BackendPhoneDevices.stillPartChars * 3 / 4

    /// The picture at rest, in full quality (a keyframe) but never larger than `maxBytes` (lowering the quality step by step;
    /// nil when even the plainest is too large); the next moving picture is a keyframe too.
    public func stillFrame(_ pixels: CVPixelBuffer, maxBytes: Int = BackendPhoneVideoEncoder.stillHardCap) async -> Frame? {
        defer { requestKey() }
        guard let session = session(for: pixels, still: true) else { return nil }
        let limit = max(1, min(maxBytes, Self.stillHardCap))
        // The rate the still session may spend in its one-second window: the frame's own budget (a hint; checked below).
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [limit, 1] as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (limit * 8) as CFNumber)
        for quality in Self.stillQualities {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
            guard let frame = await encode(session, pixels, key: true, still: true) else { return nil }
            if frame.data.count <= limit { return frame }
        }
        return nil
    }

    // MARK: Sessions

    private func session(for pixels: CVPixelBuffer, still wantStill: Bool) -> VTCompressionSession? {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let (existing, stale) = lock.withLock { () -> (VTCompressionSession?, [VTCompressionSession]) in
            if size.width != width || size.height != height {
                let old = [motion, still].compactMap { $0 }
                motion = nil; still = nil; size = (width, height); needKey = true
                return (nil, old)
            }
            return (wantStill ? still : motion, [])
        }
        for session in stale { VTCompressionSessionInvalidate(session) }
        if let existing { return existing }
        guard let made = make(width: Int32(width), height: Int32(height), still: wantStill) else { return nil }
        lock.withLock { if wantStill { still = made } else { motion = made } }
        return made
    }

    private func make(width: Int32, height: Int32, still: Bool) -> VTCompressionSession? {
        let specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        // Not the low-latency rate control (2 Nov): it dropped frames outright when one was over its per-frame budget
        // (every forced keyframe after a pause: slow typing showed nothing). RealTime + no reordering is one in, one out.
        var made: VTCompressionSession?
        var status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        if status != noErr || made == nil {
            // No hardware low-latency mode (an older Mac or a virtual machine): the plain hardware or software encoder.
            status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        }
        guard status == noErr, let session = made else { return nil }
        func set(_ key: CFString, _ value: Any) { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as Any)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as Any)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 100_000)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, lock.withLock { fps })
        if still {
            // Quality and the byte limit are set per still frame (`stillFrame`).
            set(kVTCompressionPropertyKey_Quality, Self.stillQualities[0])
        } else {
            set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue as Any)
            Self.applyRate(session, bitrate: lock.withLock { bitrate })
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    private static func applyRate(_ session: VTCompressionSession, bitrate: Double) {
        let bits = max(300_000, min(40_000_000, bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: Int(bits) as CFNumber)
        // No second may carry more than 1.5 × the rate (bytes, seconds).
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [Int(bits * 1.5 / 8), 1] as CFArray)
    }

    // MARK: Encoding

    private func encode(_ session: VTCompressionSession, _ pixels: CVPixelBuffer, key: Bool, still: Bool) async -> Frame? {
        // Real time stamps (ms of uptime, strictly increasing): the rate control budgets each frame by the time since the
        // last one. Counting frames at 1/600 s each (as before 2 Nov) made it believe 600 frames a second, so each frame got
        // a 600th of the bitrate and a forced keyframe after a pause was dropped outright.
        let number = lock.withLock { () -> Int64 in
            let now = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
            // M5 (3 Nov): a delta made long after the last frame (the link held it back) is budgeted as at most two frame
            // times, so it stays small. Otherwise the rate control spends the whole wait on it, the next one waits longer
            // still, and the picture rate falls instead of the quality (measured, 2 % loss through TURN: about 2 frames a
            // second of ~110 KB each). Keyframes keep real time (their size has its own limit).
            let latest = key || frameNumber == 0 ? now : min(now, frameNumber + 2 * Int64(1_000 / max(1, fps)))
            frameNumber = max(frameNumber + 1, latest)
            return frameNumber
        }
        let pts = CMTime(value: number, timescale: 1_000)
        let started = Date()
        let properties: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        return await withCheckedContinuation { (answer: CheckedContinuation<Frame?, Never>) in
            let once = Once(answer)
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
                                                         frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample, var frame = Self.frame(sample) else { once.resume(nil); return }
                frame.width = width; frame.height = height; frame.still = still
                frame.encodeMilliseconds = Date().timeIntervalSince(started) * 1_000
                once.resume(frame)
            }
            if status != noErr { once.resume(nil) }
        }
    }

    /// The access unit of an encoded sample, with its parameter sets when it is a keyframe.
    static func frame(_ sample: CMSampleBuffer) -> Frame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0, pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let data = Data(bytes: pointer, count: length)
        var key = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, first[kCMSampleAttachmentKey_NotSync] as? Bool == true { key = false }
        var sps: Data?, pps: Data?
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            for index in 0..<2 {
                var set: UnsafePointer<UInt8>?, size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &set,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let set {
                    if index == 0 { sps = Data(bytes: set, count: size) } else { pps = Data(bytes: set, count: size) }
                }
            }
        }
        return Frame(data: data, key: key, sps: sps, pps: pps, width: 0, height: 0, still: false, encodeMilliseconds: 0)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: CheckedContinuation<Frame?, Never>?
        init(_ answer: CheckedContinuation<Frame?, Never>) { self.answer = answer }
        func resume(_ frame: Frame?) {
            let waiting = lock.withLock { () -> CheckedContinuation<Frame?, Never>? in defer { answer = nil }; return answer }
            waiting?.resume(returning: frame)
        }
    }
}

/// A raw screen picture as pixels, as a stream hands it to the video path.
public struct BackendPhoneDevicePixels: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    /// When it was captured (ms since 1970).
    public let capturedAt: Double
    public init(_ buffer: CVPixelBuffer, capturedAt: Double) { self.buffer = buffer; self.capturedAt = capturedAt }
}

/// What a stream gives the video path.
public enum BackendPhoneDevicePixelsAnswer: Sendable {
    case pixels(BackendPhoneDevicePixels)
    case unchanged
    case ended
    case unsupported
}
