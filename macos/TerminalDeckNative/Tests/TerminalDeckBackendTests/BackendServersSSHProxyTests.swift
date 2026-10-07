import Foundation
import Testing
@testable import TerminalDeckBackend

private typealias SSHProxyWire = BackendServersSSHProxyWire
private func sshProxyBody(_ frame: Data) throws -> Data { var f = BackendServersSSHProxyFramer(); return try #require(f.feed(frame).first) }
private func sshProxyReceive(_ frame: Data, _ session: inout BackendServersSSHProxySession) throws -> [Data] { try session.receive(sshProxyBody(frame)) }
private func sshProxyChannel(_ type: UInt8, _ payload: Data = Data()) -> Data { SSHProxyWire.ssh(type, SSHProxyWire.u32(0) + payload) }
private func sshProxyEstablished(stdin: Data = Data(), cap: Int = 4 * 1024 * 1024, window: UInt32 = 65_536, packet: UInt32 = 32_768) throws -> BackendServersSSHProxySession {
    var s = try BackendServersSSHProxySession(command: "printf test", stdin: stdin, maximumOutputBytes: cap)
    _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(1) + SSHProxyWire.u32(4)), &s)
    _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(0x8000000f) + SSHProxyWire.u32(1)), &s)
    _ = try sshProxyReceive(sshProxyChannel(91, SSHProxyWire.u32(37) + SSHProxyWire.u32(window) + SSHProxyWire.u32(packet)), &s)
    _ = try sshProxyReceive(sshProxyChannel(99), &s)
    return s
}
private func sshProxySignal(_ name: String) -> Data {
    sshProxyChannel(98, SSHProxyWire.string("exit-signal") + Data([0]) + SSHProxyWire.string(name) + Data([1]) + SSHProxyWire.string("remote diagnostic") + SSHProxyWire.string("en"))
}

@Suite("Native OpenSSH proxy — fake wire frames only")
struct BackendServersSSHProxyTests {
    @Test func helloProxyOpenAndExecUseActualProtocolAndRemoteChannel() throws {
        var s = try BackendServersSSHProxySession(command: "'sh' '-s'", stdin: Data(), maximumOutputBytes: 1024)
        #expect(s.begin() == Data([0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0, 4]))
        let proxy = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(1) + SSHProxyWire.u32(4)), &s)
        #expect(proxy == [SSHProxyWire.frame(SSHProxyWire.u32(0x1000000f) + SSHProxyWire.u32(1))])
        let opened = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(0x8000000f) + SSHProxyWire.u32(1)), &s)
        #expect(opened == [SSHProxyWire.ssh(90, SSHProxyWire.string("session") + SSHProxyWire.u32(0) + SSHProxyWire.u32(1_048_576) + SSHProxyWire.u32(32_768))])
        let exec = try sshProxyReceive(sshProxyChannel(91, SSHProxyWire.u32(37) + SSHProxyWire.u32(100) + SSHProxyWire.u32(32_768)), &s)
        #expect(exec == [SSHProxyWire.ssh(98, SSHProxyWire.u32(37) + SSHProxyWire.string("exec") + Data([1]) + SSHProxyWire.string("'sh' '-s'"))])
    }
    @Test func muxExtensionsArePairedAndUnsupportedVersionsRefuse() throws {
        var s = try BackendServersSSHProxySession(command: "true", stdin: Data(), maximumOutputBytes: 100)
        let hello = SSHProxyWire.frame(SSHProxyWire.u32(1) + SSHProxyWire.u32(4) + SSHProxyWire.string("future") + SSHProxyWire.string(Data([0, 1, 2])))
        #expect(try sshProxyReceive(hello, &s).count == 1)
        var bad = try BackendServersSSHProxySession(command: "true", stdin: Data(), maximumOutputBytes: 100)
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(1) + SSHProxyWire.u32(5)), &bad) }
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(0x8000000f) + SSHProxyWire.u32(99)), &s) }
    }
    @Test func proxyRefusalNeverFallsBackToPassengerOrWrapper() throws {
        var s = try BackendServersSSHProxySession(command: "true", stdin: Data(), maximumOutputBytes: 100)
        _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(1) + SSHProxyWire.u32(4)), &s)
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(0x80000003) + SSHProxyWire.u32(1) + SSHProxyWire.string("unsupported")), &s) }
    }
    @Test func fragmentedAndCoalescedFramesAreParsedAtByteBoundaries() throws {
        let first = sshProxyChannel(94, SSHProxyWire.string(Data([0xe2])))
        let second = sshProxyChannel(94, SSHProxyWire.string(Data([0x82, 0xac])))
        var framer = BackendServersSSHProxyFramer(); var decoded: [Data] = []
        for byte in first + second { decoded += try framer.feed(Data([byte])) }
        #expect(decoded == [try sshProxyBody(first), try sshProxyBody(second)])
        var coalesced = BackendServersSSHProxyFramer(); #expect(try coalesced.feed(first + second) == decoded)
    }
    @Test func oversizedAndShortStringsFailWithoutAllocatingDeclaredSize() throws {
        var framer = BackendServersSSHProxyFramer()
        #expect(throws: (any Error).self) { _ = try framer.feed(SSHProxyWire.u32(UInt32.max)) }
        var short = BackendServersSSHProxyFramer()
        #expect(throws: (any Error).self) { _ = try short.feed(SSHProxyWire.u32(1) + Data([0])) }
        var s = try sshProxyEstablished()
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(sshProxyChannel(94, SSHProxyWire.u32(65_536)), &s) }
    }
    @Test func stdoutStderrBytesDecodeOnlyOnceAndCapIsCombined() throws {
        var s = try sshProxyEstablished(cap: 8)
        _ = try sshProxyReceive(sshProxyChannel(94, SSHProxyWire.string(Data([0xe2]))), &s)
        _ = try sshProxyReceive(sshProxyChannel(94, SSHProxyWire.string(Data([0x82, 0xac]))), &s)
        _ = try sshProxyReceive(sshProxyChannel(95, SSHProxyWire.u32(1) + SSHProxyWire.string("error-more")), &s)
        #expect(s.result.stdout == "€"); #expect(s.result.stderr == "error-more"); #expect(!s.result.truncated); #expect(s.retainedOutputBytes == 13)
        let ack = try sshProxyReceive(sshProxyChannel(94, SSHProxyWire.string("discarded but acknowledged")), &s)
        #expect(!ack.isEmpty); #expect(s.retainedOutputBytes == 13); #expect(s.result.truncated)
    }
    @Test func receiveCreditsAcknowledgeBothStreamsOnRemoteChannel() throws {
        var s = try sshProxyEstablished()
        let stdout = try sshProxyReceive(sshProxyChannel(94, SSHProxyWire.string("abc")), &s)
        let stderr = try sshProxyReceive(sshProxyChannel(95, SSHProxyWire.u32(1) + SSHProxyWire.string("error")), &s)
        #expect(stdout == [SSHProxyWire.ssh(93, SSHProxyWire.u32(37) + SSHProxyWire.u32(3))])
        #expect(stderr == [SSHProxyWire.ssh(93, SSHProxyWire.u32(37) + SSHProxyWire.u32(5))])
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(sshProxyChannel(94, SSHProxyWire.string(Data(repeating: 1, count: 32_769))), &s) }
    }
    @Test func stdinHonorsRemoteWindowPacketCreditAndSendsEOFAfterFinalByte() throws {
        var s = try sshProxyEstablished(stdin: Data("abcdef".utf8), window: 2, packet: 2)
        #expect(try s.nextInput() == SSHProxyWire.ssh(94, SSHProxyWire.u32(37) + SSHProxyWire.string("ab")))
        #expect(try s.nextInput() == nil)
        _ = try sshProxyReceive(sshProxyChannel(93, SSHProxyWire.u32(4)), &s)
        #expect(try s.nextInput() == SSHProxyWire.ssh(94, SSHProxyWire.u32(37) + SSHProxyWire.string("cd")))
        #expect(try s.nextInput() == SSHProxyWire.ssh(94, SSHProxyWire.u32(37) + SSHProxyWire.string("ef")))
        #expect(try s.nextInput() == SSHProxyWire.ssh(96, SSHProxyWire.u32(37)))
        #expect(try s.nextInput() == nil)
    }
    @Test func nilInputSendsEOFAndWindowOverflowIsRejected() throws {
        var s = try sshProxyEstablished(window: UInt32.max)
        #expect(try s.nextInput() == SSHProxyWire.ssh(96, SSHProxyWire.u32(37)))
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(sshProxyChannel(93, SSHProxyWire.u32(1)), &s) }
    }
    @Test func exactRemoteSignalIsDistinctFromNumericExit137() throws {
        var signal = try sshProxyEstablished()
        _ = try sshProxyReceive(sshProxySignal("KILL"), &signal)
        let close = try sshProxyReceive(sshProxyChannel(97), &signal)
        #expect(signal.finished); #expect(signal.result.code == nil); #expect(signal.result.signal == "SIGKILL")
        #expect(close == [SSHProxyWire.ssh(97, SSHProxyWire.u32(37))])
        var numeric = try sshProxyEstablished()
        _ = try sshProxyReceive(sshProxyChannel(98, SSHProxyWire.string("exit-status") + Data([0]) + SSHProxyWire.u32(137)), &numeric)
        _ = try sshProxyReceive(sshProxyChannel(97), &numeric)
        #expect(numeric.result.code == 137); #expect(numeric.result.signal == nil)
    }
    @Test func vendorSignalAndUnknownExitNeverBecomeSuccessfulCodeZero() throws {
        var vendor = try sshProxyEstablished()
        _ = try sshProxyReceive(sshProxySignal("RTMIN@vendor.example"), &vendor); _ = try sshProxyReceive(sshProxyChannel(97), &vendor)
        #expect(vendor.result.signal == "SIGRTMIN@vendor.example"); #expect(vendor.result.code == nil)
        var unknown = try sshProxyEstablished(); _ = try sshProxyReceive(sshProxyChannel(97), &unknown)
        #expect(unknown.result.code == nil && unknown.result.signal == nil)
    }
    @Test func wrongRecipientPaddingAndDataAfterEOFCannotCrossChannels() throws {
        var wrong = try sshProxyEstablished()
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(SSHProxyWire.ssh(94, SSHProxyWire.u32(1) + SSHProxyWire.string("crossed")), &wrong) }
        var padding = try sshProxyEstablished()
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(SSHProxyWire.frame(Data([1, 94]) + SSHProxyWire.u32(0) + SSHProxyWire.string("bad")), &padding) }
        var eof = try sshProxyEstablished(); _ = try sshProxyReceive(sshProxyChannel(96), &eof)
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(sshProxyChannel(94, SSHProxyWire.string("late")), &eof) }
    }
    @Test func unrequestedChannelsAndUnknownReplyRequestsAreRefused() throws {
        var s = try sshProxyEstablished()
        let opening = SSHProxyWire.ssh(90, SSHProxyWire.string("session") + SSHProxyWire.u32(88) + SSHProxyWire.u32(10) + SSHProxyWire.u32(10))
        let refused = try sshProxyReceive(opening, &s)
        #expect(refused == [SSHProxyWire.ssh(92, SSHProxyWire.u32(88) + SSHProxyWire.u32(1) + SSHProxyWire.string("This proxy did not request that channel.") + SSHProxyWire.string(""))])
        let request = sshProxyChannel(98, SSHProxyWire.string("unknown@example.com") + Data([1]) + SSHProxyWire.string("opaque"))
        #expect(try sshProxyReceive(request, &s) == [SSHProxyWire.ssh(100, SSHProxyWire.u32(37))])
    }
    @Test func channelOpenExecFailureAndInvalidSignalFailExplicitly() throws {
        var open = try BackendServersSSHProxySession(command: "true", stdin: Data(), maximumOutputBytes: 100)
        _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(1) + SSHProxyWire.u32(4)), &open)
        _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(0x8000000f) + SSHProxyWire.u32(1)), &open)
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(sshProxyChannel(92, SSHProxyWire.u32(1) + SSHProxyWire.string("denied") + SSHProxyWire.string("")), &open) }
        var exec = try BackendServersSSHProxySession(command: "true", stdin: Data(), maximumOutputBytes: 100)
        _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(1) + SSHProxyWire.u32(4)), &exec)
        _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(0x8000000f) + SSHProxyWire.u32(1)), &exec)
        _ = try sshProxyReceive(sshProxyChannel(91, SSHProxyWire.u32(37) + SSHProxyWire.u32(100) + SSHProxyWire.u32(100)), &exec)
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(sshProxyChannel(100), &exec) }
        var invalid = try sshProxyEstablished()
        #expect(throws: (any Error).self) { _ = try sshProxyReceive(sshProxySignal(""), &invalid) }
    }
    @Test func callerOwnedInputRemainsUncappedAndOutputCannotBeRaised() throws {
        _ = try BackendServersSSHProxySession(command: "a\0b", stdin: Data(), maximumOutputBytes: 100)
        _ = try BackendServersSSHProxySession(command: "true", stdin: Data(repeating: 0, count: 4 * 1024 * 1024 + 1), maximumOutputBytes: 100)
        #expect(throws: (any Error).self) { _ = try BackendServersSSHProxySession(command: "true", stdin: Data(), maximumOutputBytes: 4 * 1024 * 1024 + 1) }
    }
    @Test func firstExitRecordMatchesSSH2CloseCallback() throws {
        var status = try sshProxyEstablished()
        _ = try sshProxyReceive(sshProxyChannel(98, SSHProxyWire.string("exit-status") + Data([0]) + SSHProxyWire.u32(7)), &status)
        _ = try sshProxyReceive(sshProxySignal("TERM"), &status)
        #expect(status.result.code == 7 && status.result.signal == nil)
        var signal = try sshProxyEstablished()
        _ = try sshProxyReceive(sshProxySignal("TERM"), &signal)
        _ = try sshProxyReceive(sshProxyChannel(98, SSHProxyWire.string("exit-status") + Data([0]) + SSHProxyWire.u32(0)), &signal)
        #expect(signal.result.code == nil && signal.result.signal == "SIGTERM")
    }
    @Test func largeCommandStreamsAsOneCorrectExecPacket() throws {
        let command = String(repeating: "é", count: 20_000)
        var s = try BackendServersSSHProxySession(command: command, stdin: Data(), maximumOutputBytes: 100)
        _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(1) + SSHProxyWire.u32(4)), &s)
        _ = try sshProxyReceive(SSHProxyWire.frame(SSHProxyWire.u32(0x8000000f) + SSHProxyWire.u32(1)), &s)
        var bytes = try #require(sshProxyReceive(sshProxyChannel(91, SSHProxyWire.u32(37) + SSHProxyWire.u32(10) + SSHProxyWire.u32(10)), &s).first)
        while let chunk = try s.nextInput() { #expect(chunk.count <= 32_768); bytes.append(chunk) }
        var r = SSHProxyWire.Reader(bytes)
        #expect(try r.uint32() == UInt32(command.utf8.count + 19)); #expect(try r.byte() == 0); #expect(try r.byte() == 98)
        #expect(try r.uint32() == 37); #expect(try r.text() == "exec"); #expect(try r.boolean()); #expect(try r.text() == command); try r.end()
    }
}
