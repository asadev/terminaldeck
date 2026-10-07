import Foundation
import Testing
@testable import TerminalDeckNativeCore

struct ChromiumSafeStorageCipherTests {
    // Independently produced with Node's PBKDF2/AES implementation, using an
    // invented password. These tests never access or create a Keychain item.
    private let password = Data("native-storage-fixture".utf8)

    @Test func matchesIndependentV10Fixture() throws {
        let blob = Data(base64Encoded: "djEwjCJfGVNw6j1ySR4pp743BNGhDd0fQOtda7XcZQnZs4E=")!
        #expect(try ChromiumSafeStorageCipher.encrypt("fixture: π/🔐", password: password) == blob)
        #expect(try ChromiumSafeStorageCipher.decrypt(blob, password: password) == "fixture: π/🔐")
    }

    @Test func exactBlockAddsFullPaddingBlock() throws {
        let blob = Data(base64Encoded: "djEwcYfiYQnzm2fD3tYiLn9l26JwNB0Fk3uoi2vRkEyR8kc=")!
        #expect(try ChromiumSafeStorageCipher.encrypt(String(repeating: "A", count: 16), password: password) == blob)
        #expect(blob.count == 35)
    }

    @Test func refusesPlaintextAndTruncatedCiphertext() {
        #expect(throws: (any Error).self) {
            try ChromiumSafeStorageCipher.decrypt(Data("a secret".utf8), password: password)
        }
        #expect(throws: (any Error).self) {
            try ChromiumSafeStorageCipher.decrypt(Data("v10bad".utf8), password: password)
        }
    }

    @Test func emptyStringsKeepElectronFormat() throws {
        #expect(try ChromiumSafeStorageCipher.encrypt("", password: password).isEmpty)
        #expect(try ChromiumSafeStorageCipher.decrypt(Data(), password: password) == "")
    }
}
