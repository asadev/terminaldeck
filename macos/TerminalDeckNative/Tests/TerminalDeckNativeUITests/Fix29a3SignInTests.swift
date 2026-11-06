import CoreVideo
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend
@testable import TerminalDeckNative

@Suite("fix-29a3 local locked watch sign-in", .serialized)
struct Fix29a3SignInTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        func read() -> Bool { lock.withLock { value } }
        func set(_ next: Bool) { lock.withLock { value = next } }
    }
    private actor Picture: BackendPhoneDeviceStream {
        var reads = 0
        var stops = 0
        let buffer: CVPixelBuffer
        init() throws {
            var made: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 128, 96, kCVPixelFormatType_32BGRA, nil, &made) == kCVReturnSuccess,
                  let made else { throw BackendMacSignInAttempt.failure }
            buffer = made
            CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, 0, CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        func pixels(within seconds: Double) -> BackendPhoneDevicePixelsAnswer {
            reads += 1
            return stops > 0 ? .ended : .pixels(.init(buffer, capturedAt: Date().timeIntervalSince1970 * 1_000))
        }
        func endReason() -> String { "Fixture ended" }
        func stop() { stops += 1 }
    }
    private actor Link {
        var frames = 0
        func carry(_ data: Data) {
            if let value = try? NativeRPCValue.parseJSON(data), value["t"].string == "sims.video" { frames += 1 }
        }
    }
    @MainActor private final class Boundary {
        var state: MacReach.State = .locked
        var trusted = true
        var secure = true
        var bundle = "com.apple.loginwindow"
        var pid: pid_t = 29
        var posted = 0
        var targets: [pid_t] = []
        var cancelAfterFirst = false
        var unlockDuringFocus = false
        func send(_ password: String?) throws {
            let environment = BackendMacReachPassword.Environment(trusted: { self.trusted }, focus: {
                if self.unlockDuringFocus { self.state = .desktop }
                return .init(secure: self.secure, pid: self.pid, bundleID: self.bundle)
            }, post: { pid, _, _ in
                self.posted += 1; self.targets.append(pid)
                if self.cancelAfterFirst { BackendMacSignInAttempt.current?.cancel() }
            })
            try BackendMacReachPassword.send(password, state: { self.state }, environment: environment)
        }
    }
    private final class XPC: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let receiver: BackendMacReachRequest
        init(_ handler: @escaping @Sendable (String, Data) async throws -> Data) {
            receiver = BackendMacReachRequest(handler: handler)
            super.init(); listener.delegate = self; listener.resume()
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: BackendMacReachRPC.self)
            connection.exportedObject = receiver
            connection.resume()
            return true
        }
        func client() -> BackendMacReachClient {
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: BackendMacReachRPC.self)
            connection.resume()
            return BackendMacReachClient(connection: connection)
        }
    }
    private func until(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NativeRPCError(code: "fixture", message: "The local watch did not deliver its picture.")
    }
    private func context(_ connection: UUID, kind: BackendRemoteDeviceKind = .mine,
                         access: BackendINT2PhoneAccessLevel = .full) -> BackendRemoteHostContext {
        .init(connectionID: connection, deviceID: "fixture", kind: kind, address: "fixture", peerPublicKey: nil,
              claimedCapabilities: [], reach: .init(kind: kind, unrestricted: true, folders: [], accounts: nil, drivesWindows: false),
              phoneAccess: access)
    }
    private func unlock() -> BackendRemoteClientMessage {
        .init(.object([.init("t", .string("sims.unlock")), .init("rid", .string("sign-in")),
                       .init("id", .string("mac:main")), .init("password", .string("fixture-only"))]))
    }
    @Test func workingLocalLockedWatchReachesRealPasswordAdmissionWithoutHelperCapture() async throws {
        let picture = try Picture(), link = Link(), control = Flag(), allowed = Flag(), helperOpened = Flag()
        helperOpened.set(false)
        let stream = NativeMacReachSwitchingStream(display: "mac:main", local: { _ in picture }, helper: { _ in
            helperOpened.set(true); throw BackendMacSignInAttempt.failure
        }, isLocked: { true }, helperApproved: { true })
        let boundary = await Boundary()
        let agent = XPC { command, payload in
            // This is the production password admission function used by MacReachAgent, with only OS I/O replaced.
            guard command == "password" else { throw BackendMacSignInAttempt.failure }
            let value = try NativeRPCValue.parseJSON(payload)
            try await boundary.send(value["password"].string)
            return Data()
        }
        let agentClient = agent.client()
        let daemon = XPC { command, payload in try await agentClient.request(command, payload: payload) }
        let client = daemon.client()
        defer { client.close(); agentClient.close(); daemon.listener.invalidate(); agent.listener.invalidate() }
        var source = BackendPhoneDevices.Source(list: { .object([]) }, power: { _, _ in .object([]) },
            stream: { _, _ in stream }, input: { _, _ in }, shot: { _ in throw BackendMacSignInAttempt.failure },
            deliver: { _ in "" }, visibleSessions: { _ in [] }, send: { _, _ in }, macRows: {
                [.object([.init("id", .string("mac:main")), .init("name", .string("Fixture")), .init("state", .string("ready"))])]
            })
        source.macSignIn = { id, password in
            _ = try await client.value("password", .object([.init("id", .string(id)), .init("password", .string(password))]))
        }
        source.macState = { "locked" }; source.macControlNow = { _ in control.read() }; source.macAllowed = { allowed.read() }
        source.linkVideo = { _ in .init(reliableOnly: false) }
        source.direct = { _, data, _ in await link.carry(data); return true }
        let devices = BackendPhoneDevices(source: source), connection = UUID(), owner = context(connection)
        _ = try await devices.handle(.init(.object([.init("t", .string("sims.watch")), .init("id", .string("mac:main")),
            .init("video", .array([.string("h264")]))])), context: owner)
        try await until { await link.frames > 0 }
        #expect(!helperOpened.read())
        // The same working watch cannot sign in as a guest, without Full control, after revocation or after closing.
        await #expect(throws: (any Error).self) { try await devices.handle(unlock(), context: context(connection, kind: .guest)) }
        await #expect(throws: (any Error).self) { try await devices.handle(unlock(), context: context(connection, access: .look)) }
        let answer = try await devices.handle(unlock(), context: owner)
        #expect(answer.first?.value["ok"].bool == true)
        #expect(await boundary.posted == 4)
        #expect(await boundary.targets == [29, 29, 29, 29])
        guard case .pixels = await stream.pixels(within: 0) else { Issue.record("Sign-in discarded the local picture"); await devices.stopAll(); return }
        #expect(await picture.stops == 0)
        #expect(!helperOpened.read())
        control.set(false)
        await #expect(throws: (any Error).self) { try await devices.handle(unlock(), context: owner) }
        allowed.set(false)
        await #expect(throws: (any Error).self) { try await devices.handle(unlock(), context: owner) }
        await devices.stopAll()
        await #expect(throws: (any Error).self) { try await devices.handle(unlock(), context: owner) }
        #expect(await boundary.posted == 4)
    }
    @Test(arguments: ["desktop", "untrusted", "ordinary-field", "wrong-process", "invalid-pid", "focus-unlocked", "expired", "cancelled", "overlong-window"])
    @MainActor func helperAdmissionStillRefusesUnsafePasswords(_ condition: String) throws {
        let boundary = Boundary()
        let attempt = BackendMacSignInAttempt(expiresAt: ProcessInfo.processInfo.systemUptime + (condition == "expired" ? -1 : condition == "overlong-window" ? 3 : 2))
        switch condition {
        case "desktop": boundary.state = .desktop
        case "untrusted": boundary.trusted = false
        case "ordinary-field": boundary.secure = false
        case "wrong-process": boundary.bundle = "fixture.editor"
        case "invalid-pid": boundary.pid = 1
        case "focus-unlocked": boundary.unlockDuringFocus = true
        case "cancelled": attempt.cancel()
        default: break
        }
        #expect(throws: (any Error).self) {
            try BackendMacSignInAttempt.$current.withValue(attempt) { try boundary.send("fixture-only") }
        }
        #expect(boundary.posted == 0)
    }
    @Test @MainActor func cancellationBetweenKeystrokesStopsThePasswordAndReturn() throws {
        let boundary = Boundary(); boundary.cancelAfterFirst = true
        #expect(throws: (any Error).self) {
            try BackendMacSignInAttempt.$current.withValue(BackendMacSignInAttempt()) { try boundary.send("fixture-only") }
        }
        #expect(boundary.posted == 1)
    }
    @Test func helperPasswordCommandUsesIndependentAdmission() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckSessionHostHelper/MacReachAgent.swift"), encoding: .utf8)
        let passwordCase = try #require(source.range(of: "case \"password\":"))
        let inputCase = try #require(source.range(of: "case \"input\":"))
        let admission = source[passwordCase.lowerBound..<inputCase.lowerBound]
        #expect(admission.contains("BackendMacReachPassword.send"))
        #expect(!admission.contains("captures["))
    }
}
