import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// 05:28 release blocker: a locked, denied or missing Keychain key must leave only
/// the Receiver unavailable (with a reason and Try again), never the app.
final class RCVStartupTests: XCTestCase {
    /// Identity "encryption" that can be switched to fail like a denied Keychain.
    final class Cipher: BackendAccountVaultCipher, @unchecked Sendable {
        private let lock = NSLock(); private var failing: Bool; private var count = 0
        init(failing: Bool) { self.failing = failing }
        func set(failing value: Bool) { lock.lock(); failing = value; lock.unlock() }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        private func check() throws {
            lock.lock(); count += 1; let fail = failing; lock.unlock()
            if fail { throw BackendAccountFailure("The Receiver's Keychain key is locked or was denied (status -25293).") }
        }
        func available() -> Bool { true }
        func prepareForWrites(existingVault: Bool) throws { try check() }
        func decrypt(_ blob: Data) throws -> String { try check(); return String(decoding: blob, as: UTF8.self) }
        func encrypt(_ text: String, existingVault: Bool) throws -> Data { try check(); return Data(text.utf8) }
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rcv-startup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func service(_ dir: URL, _ cipher: Cipher) throws -> BackendRCVService {
        let store = BackendRCVStore(persistence: try BackendTaskPersistence(directory: dir, ownership: .exclusive), cipher: cipher, saveDelayMilliseconds: 0)
        return BackendRCVService(store: store, dispatch: RCVFakeDispatch(), relayBase: { "https://relay.example" })
    }

    func testADeniedKeyLeavesOnlyTheReceiverUnavailableAndTryAgainRecovers() async throws {
        let dir = try folder()
        // Someone used the Receiver before: there is saved, encrypted data.
        let first = try service(dir, Cipher(failing: false))
        _ = try await first.createSource(preset: "webhook", name: "Shop")

        let cipher = Cipher(failing: true)
        let receiver = try service(dir, cipher)
        do { _ = try await receiver.overview(); XCTFail("expected unavailable") }
        catch let error as NativeRPCError {
            XCTAssertEqual(error.code, "receiver-unavailable")
            XCTAssertTrue(error.message.contains("locked or was denied"), error.message)
        }
        let reason = await receiver.unavailableReason
        XCTAssertNotNil(reason)
        // Nothing else breaks: a relay delivery is simply not acknowledged (the relay keeps it),
        // and Terminal Deck's own events are dropped quietly.
        let frames = RCVFrames()
        await receiver.relayOpened { type, channel, payload in await frames.add(type, channel, payload) }
        let head = try JSONSerialization.data(withJSONObject: ["v": 1, "sourceId": BackendRCVWire.mintSourceID(), "receivedAt": 1])
        var payload = Data([0, UInt8(head.count)]); payload.append(head); payload.append(Data(count: 120))
        await receiver.relayFrame(type: BackendRCVWire.deliver, channel: Data(count: 16), payload: payload)
        await receiver.post(internal: "terminaldeck.servers", .init(kind: "docker.container.died", title: "x"))
        let sent = await frames.frames
        XCTAssertTrue(sent.allSatisfy { $0.0 != BackendRCVWire.ack && $0.0 != BackendRCVWire.sync })
        // "Try again" after the person unlocks or allows the key.
        cipher.set(failing: false)
        let overview = try await receiver.overview()
        XCTAssertTrue(overview.sources.contains { $0.source.name == "Shop" })
        let cleared = await receiver.unavailableReason
        XCTAssertNil(cleared)
    }

    func testANewPersonTouchesNoKeyUntilTheFirstRealSave() async throws {
        let cipher = Cipher(failing: true)
        let receiver = try service(try folder(), cipher)
        let overview = try await receiver.overview()
        XCTAssertEqual(Set(overview.sources.map(\.id)), Set(RCVPresets.internalSources.map(\.id)))
        XCTAssertEqual(cipher.calls, 0, "opening the Receiver with no saved data asks the Keychain nothing")
        do { _ = try await receiver.createSource(preset: "webhook", name: "Shop"); XCTFail("the save should fail while the key is denied") }
        catch let error as NativeRPCError { XCTAssertTrue(error.message.contains("secure storage is unavailable"), error.message) }
        let after = try await receiver.sources()
        XCTAssertEqual(after.count, RCVPresets.internalSources.count, "a failed save keeps nothing half-made")
        cipher.set(failing: false)
        _ = try await receiver.createSource(preset: "webhook", name: "Shop")
        let made = try await receiver.sources()
        XCTAssertEqual(made.count, RCVPresets.internalSources.count + 1)
    }

    func testTheReceiverKeepsItsOwnKeychainItem() {
        XCTAssertEqual(BackendRCVKeychainCipher(appName: "Terminal Deck").service, "Terminal Deck Receiver Key")
    }
}
