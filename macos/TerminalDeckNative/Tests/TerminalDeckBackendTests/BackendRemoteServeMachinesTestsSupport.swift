import Foundation
import CryptoKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Test-only scratch state. No fixture refers to the production data directory.
final class BackendRemoteServeMachinesTestsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Double
    init(_ value: Double = 1000) { milliseconds = value }
    func now() -> Double { lock.withLock { milliseconds } }
    func set(_ value: Double) { lock.withLock { milliseconds = value } }
}

enum BackendRemoteServeMachinesTestsFixture {
    static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-machines-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func remove(_ root: URL) { try? FileManager.default.removeItem(at: root) }
    static func secrets(byte: UInt8 = 7, credential: String = "abcdefghijkl.0123456789") -> BackendMachineSecrets {
        .init(hostID: BackendRelayPacketCodec.hostID(for: Data(repeating: byte, count: 32)), hostPublicKey: BackendSealedIdentity.generate().publicKey,
              relayURL: "wss://relay.example.invalid", credential: credential, guestIdentity: .generate())
    }
    static func guest() -> BackendRemoteGuest {
        BackendRemoteGuest(id: "machine-1", secrets: secrets(), localName: "Fixture Mac",
            onState: { _ in }, onOutput: { _, _, _ in }, onWelcome: { _ in })
    }
    static func context(connection: UUID = UUID()) -> BackendRemoteHostContext {
        .init(connectionID: connection, deviceID: "fixture-device", kind: .mine, address: "scratch-test", peerPublicKey: nil,
            claimedCapabilities: ["upload"], reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: true))
    }
    static func message(_ tag: String, _ fields: [NativeRPCValue.Field]) throws -> BackendRemoteClientMessage {
        switch BackendRemoteProtocol.parseClientMessage(.object([.init("t", .string(tag))] + fields)) {
        case .message(let result): return result
        case .refused(let error): throw error
        }
    }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func deterministicBytes(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }
    static func readMachines(_ directory: URL) throws -> NativeRPCValue {
        try NativeRPCValue.parseJSON(Data(contentsOf: directory.appendingPathComponent("machines.json")))
    }
    static func writeMachines(_ value: NativeRPCValue, _ directory: URL) throws {
        try value.encodedJSON(pretty: true).write(to: directory.appendingPathComponent("machines.json"))
    }
    static func responseMessage(_ body: String) throws -> String {
        try NativeRPCValue.parseJSON(Data(body.utf8))["message"].requireString("message")
    }
}

actor BackendRemoteServeMachinesTestsEvents {
    private var storage: [NativeRPCEvent] = []
    func receive(_ event: NativeRPCEvent) { storage.append(event) }
    func values() -> [NativeRPCEvent] { storage }
}

actor BackendRemoteServeMachinesTestsGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    func suspend() async {
        entered = true
        let waiters = enteredWaiters; enteredWaiters = []
        for waiter in waiters { waiter.resume() }
        if !released { await withCheckedContinuation { releaseContinuation = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }
    func release() { released = true; releaseContinuation?.resume(); releaseContinuation = nil }
}
