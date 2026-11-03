import AVFoundation
import CoreGraphics
import Foundation

/// The finished screen recording's media steps, AVFoundation only: lay the narration
/// under the video, crop it to a rectangle, and read its size, length and first picture.
/// The recording itself is the session simulator's own recorder (simctl recordVideo).
enum NativeSimRecordingMedia {
    struct Info: Equatable {
        var width: Int
        var height: Int
        var seconds: Double
        var hasAudio: Bool
    }

    static func info(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        var size = CGSize.zero
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let turned = natural.applying(transform)
            size = CGSize(width: abs(turned.width), height: abs(turned.height))
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        return Info(width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                    seconds: duration.seconds.isFinite ? duration.seconds : 0, hasAudio: !audio.isEmpty)
    }

    static func poster(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        return try? await generator.image(at: CMTime(value: 1, timescale: 10)).image
    }

    /// The video with `audio` (the narration, and any other sound already mixed into it)
    /// as its sound track, written to `output`. The picture is copied, not re-encoded.
    /// `lead`: seconds the sound started before the video (that much of its start is left out).
    static func addAudio(video: URL, audio: URL, to output: URL, lead: Double = 0) async throws {
        let picture = AVURLAsset(url: video), sound = AVURLAsset(url: audio)
        guard let videoTrack = try await picture.loadTracks(withMediaType: .video).first else { throw failure("The recording has no picture.") }
        let videoLength = try await picture.load(.duration)
        let composition = AVMutableComposition()
        guard let outVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw failure("The recording could not be prepared.")
        }
        try outVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoLength), of: videoTrack, at: .zero)
        outVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        let skip = CMTime(seconds: max(0, lead), preferredTimescale: 44_100)
        for track in try await sound.loadTracks(withMediaType: .audio) {
            let length = min(try await sound.load(.duration) - skip, videoLength)
            guard length > .zero,
                  let outAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try outAudio.insertTimeRange(CMTimeRange(start: skip, duration: length), of: track, at: .zero)
        }
        try await export(composition, preset: AVAssetExportPresetPassthrough, to: output)
    }

    /// The video cut to `rect` (in the video's pixels, top-left origin), sound kept, written to `output`.
    static func crop(video: URL, to rect: CGRect, output: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("The recording has no picture.") }
        let duration = try await asset.load(.duration)
        let transform = try await track.load(.preferredTransform)
        // Even sizes: H.264 refuses odd ones.
        let width = max(2, (rect.width / 2).rounded(.down) * 2), height = max(2, (rect.height / 2).rounded(.down) * 2)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        composition.instructions = [instruction]
        try await export(asset, preset: AVAssetExportPresetHighestQuality, to: output, video: composition)
    }

    private static func export(_ asset: AVAsset, preset: String, to output: URL, video: AVVideoComposition? = nil) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw failure("This Mac cannot write the video.") }
        session.videoComposition = video
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: output, as: .mp4)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TerminalDeck.SimulatorRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
