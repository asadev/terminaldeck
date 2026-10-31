import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class ChatProviderVoiceTests: XCTestCase {
    private func json(_ value: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(value.utf8)) }
    func testPCM16LittleEndianStereoKeepsFrameAndChannelOrder() throws {
        // Two stereo frames: min/zero, max/half; decoding never needs audio hardware.
        let data = Data([0x00, 0x80, 0x00, 0x00, 0xff, 0x7f, 0x00, 0x40])
        let envelope = NativeRPCValue.object([.init("data", .string(data.base64EncodedString())),
            .init("sampleRate", .number(24_000)), .init("numChannels", .number(2))])
        let chunk = try XCTUnwrap(NativeChatProviderVoicePCM.decode(envelope))
        XCTAssertEqual(chunk.frames, 2)
        XCTAssertEqual(chunk.channels, 2)
        XCTAssertEqual(NativeChatProviderVoicePCM.sample(chunk.bytes, at: 0), -1)
        XCTAssertEqual(NativeChatProviderVoicePCM.sample(chunk.bytes, at: 1), 0)
        XCTAssertEqual(NativeChatProviderVoicePCM.sample(chunk.bytes, at: 2), 32_767.0 / 32_768.0, accuracy: 0.00001)
        XCTAssertEqual(NativeChatProviderVoicePCM.sample(chunk.bytes, at: 3), 0.5)
    }
    func testMalformedPCMIsRejectedBeforeCreatingAnAudioBuffer() throws {
        for value in [
            #"{"data":"!invalid","sampleRate":24000,"numChannels":1}"#,
            #"{"data":"AA==","sampleRate":24000,"numChannels":1}"#,
            #"{"data":"AAAAAA==","sampleRate":0,"numChannels":1}"#,
            #"{"data":"AAAAAA==","sampleRate":24000,"numChannels":3}"#,
            #"{"data":"AAAAAA==","sampleRate":24000.5,"numChannels":1}"#,
        ] { XCTAssertNil(NativeChatProviderVoicePCM.decode(try json(value))) }
    }
    /// Review chat-ui #1: the microphone tap block must be created outside the @MainActor voice model,
    /// otherwise the first buffer on the audio thread traps (isolation check). A source guard, since
    /// the trap needs real hardware to reproduce.
    func testMicrophoneTapIsNotCreatedInsideTheMainActorVoiceModel() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative/NativeChatProviderVoice.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let modelStart = try XCTUnwrap(source.range(of: "@MainActor @Observable final class NativeChatProviderVoice"))
        let captureStart = try XCTUnwrap(source.range(of: "final class NativeProviderVoiceCapture"))
        let tap = try XCTUnwrap(source.range(of: ".installTap(onBus: 0"))
        XCTAssertGreaterThan(tap.lowerBound, captureStart.lowerBound, "installTap must live in the nonisolated capture class")
        XCTAssertGreaterThan(captureStart.lowerBound, modelStart.lowerBound)
        XCTAssertEqual(source.components(separatedBy: ".installTap(").count, 2)
    }
    /// U47 (#95): a slow send joins the waiting microphone audio into one piece; only seconds of backlog end the call.
    func testASlowSendJoinsMicrophoneAudioAndOnlySecondsOfBacklogEndTheCall() {
        var backlog = NativeProviderVoiceBacklog()
        let chunk = Data(repeating: 1, count: 2_400) // 50 ms of 24 kHz mono PCM16, one microphone tap
        for _ in 0..<10 { XCTAssertTrue(backlog.append(chunk)) } // the send is half a second late
        XCTAssertEqual(backlog.take()?.count, 24_000, "everything waiting goes as one piece")
        XCTAssertNil(backlog.take())
        for _ in 0..<60 { XCTAssertTrue(backlog.append(chunk)) } // three seconds still wait
        XCTAssertFalse(backlog.append(chunk), "past three seconds the provider has fallen behind")
        // One waiting piece always fits a single provider send (its base64 limit).
        XCTAssertLessThanOrEqual((NativeChatProviderVoiceLimits.microphoneBytes + 2) / 3 * 4, 524_288)
    }
    /// U47 (#557): a spoken answer that arrives faster than it is played waits its turn instead of ending the call.
    func testALongSpokenAnswerArrivingInABurstIsQueued() {
        XCTAssertGreaterThanOrEqual(NativeChatProviderVoiceLimits.playbackSeconds, 60)
    }
}
