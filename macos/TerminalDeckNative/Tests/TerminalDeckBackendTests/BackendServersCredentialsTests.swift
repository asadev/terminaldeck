import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Server credentials never cross")
struct BackendServersCredentialsTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("servers-credentials-" + UUID().uuidString) }
    private func cipher(_ available: Bool = true) -> BackendBrowserPasswordsCipher {
        // An obvious reversible test cipher detects any accidental plaintext
        // persistence. Production always injects the original Keychain cipher.
        .init(available: { available }, decrypt: { bytes in String(decoding: bytes.map { $0 ^ 0xa5 }, as: UTF8.self) }, encrypt: { value, _ in Data(value.utf8.map { $0 ^ 0xa5 }) })
    }
    private func credentials(_ root: URL, available: Bool = true) -> BackendServersCredentials {
        .init(dataRoot: root, cipher: cipher(available), policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { text, opener in
            if text == "locked" { return opener == nil ? "That key is locked. What is its passphrase?" : opener == "right" ? nil : "That passphrase does not open the key." }
            return text == "valid" ? nil : "That does not look like a key. Paste the whole file, including its first and last lines."
        })
    }
    @Test func noSecureStoreRefusesSaveButCanHold() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = credentials(directory, available: false)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let saved = try store.save("one", credential: .password("mine"))
        #expect(!saved.ok && saved.message == BackendServersCredentials.noSecureStore)
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        store.holdForSession("one", credential: .password("held"))
        #expect(try store.kindOf("one") == .password && store.isHeldForSessionOnly("one"))
        #expect(try store.read("two") == nil)
    }
    @Test func savedEncryptedBlobRestartsReplacesAndForgets() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = credentials(directory)
        #expect(try store.save("one", credential: .password("first-server-only")).ok)
        #expect(try store.save("two", credential: .key(privateKey: "second-server-only", passphrase: "second-opener")).ok)
        let disk = try String(contentsOf: store.file, encoding: .utf8)
        #expect(!disk.contains("first-server-only") && !disk.contains("second-server-only") && !disk.contains("second-opener"))
        let reopened = credentials(directory)
        #expect(try reopened.read("one") == .password("first-server-only"))
        #expect(try reopened.read("two") == .key(privateKey: "second-server-only", passphrase: "second-opener"))
        #expect(try reopened.read("missing") == nil)
        reopened.holdForSession("one", credential: .password("transient"))
        #expect(try reopened.read("one") == .password("transient"))
        #expect(try reopened.save("one", credential: .password("replacement")).ok)
        #expect(!reopened.isHeldForSessionOnly("one"))
        #expect(try credentials(directory).read("one") == .password("replacement"))
        #expect(try reopened.forget("one").ok && reopened.read("one") == nil)
        #expect(try reopened.read("two") != nil)
        #expect(try reopened.forget("unknown").message == "Nothing was stored.")
    }
    @Test func sessionOnlyIsNeverWrittenOrPromoted() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = credentials(directory)
        store.holdForSession("one", credential: .password("held-one"))
        #expect(try store.save("two", credential: .password("saved-two")).ok)
        #expect(try credentials(directory).read("one") == nil)
        store.close(); #expect(try store.read("one") == nil)
    }
    @Test func malformedAndOversizedFileAreAbsent() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-base64".utf8).write(to: directory.appendingPathComponent("server-credentials.bin"))
        #expect(try credentials(directory).kindOf("one") == .none)
    }
    @Test func draftFailureAndCompleteParseBeforeAccepting() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = credentials(directory)
        let empty = try await store.credentialFromDraft(.object([.init("method", .string("password"))]))
        if case .refused(let problem, let sentence) = empty { #expect(problem == "nothing-typed" && sentence == "Type the password for that server.") } else { Issue.record("Accepted empty sign-in") }
        #expect(try await store.keyProblem("", passphrase: nil) == "Paste the key file, including its first and last lines.")
        #expect(try await store.keyProblem(String(repeating: "x", count: 65537), passphrase: nil) == "That is much too long to be a key file.")
        #expect(try await store.keyProblem("valid", passphrase: nil) == nil)
        #expect(try await store.keyProblem("locked", passphrase: "bad") == "That passphrase does not open the key.")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
