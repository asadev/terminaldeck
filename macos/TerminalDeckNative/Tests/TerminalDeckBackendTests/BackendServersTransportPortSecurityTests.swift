import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Native equivalents of TS transport and credential structural guards")
struct BackendServersTransportPortSecurityTests {
    private let secretNames: Set<String> = ["password", "privateKey", "passphrase"]
    @Test func secretIdentifiersRemainInsideCredentialAndNativeAuthOwners() throws {
        let owners: Set<String> = ["BackendServersCredentials.swift", "BackendServersSSH.swift", "BackendServersSSHAgent.swift"]
        for file in try sources() where !owners.contains(file.lastPathComponent) {
            var text = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent == "BackendServersStore.swift" { text = text.replacingOccurrences(of: #"(?s)public enum BackendServersCredentialKind[^\}]*\}"#, with: "", options: .regularExpression) }
            let found = identifiers(text).intersection(secretNames)
            #expect(found.isEmpty, Comment(rawValue: file.lastPathComponent + " reaches " + found.sorted().joined(separator: ",")))
        }
    }
    @Test func matcherActuallyFindsOwnersAndIgnoresKindStrings() throws {
        let owner = try source("BackendServersCredentials.swift")
        #expect(secretNames.isSubset(of: identifiers(owner)))
        #expect(identifiers("let credential = \"password\"; // passphrase\n let root = \"sudo-password\"").intersection(secretNames).isEmpty)
        #expect(identifiers("let password = value; let privateKey = raw; let passphrase = input").intersection(secretNames) == secretNames)
        let store = try source("BackendServersStore.swift")
        #expect(store.contains("case password"))
        let withoutKind = store.replacingOccurrences(of: #"(?s)public enum BackendServersCredentialKind[^\}]*\}"#, with: "", options: .regularExpression)
        #expect(!identifiers(withoutKind).contains("password"))
    }
    @Test func runtimeNeverImportsAnExecutableProbeHarness() throws {
        for file in try sources() { #expect(!code(try String(contentsOf: file, encoding: .utf8)).contains("servers.electron-probe")) }
        #expect(!code("// import servers.electron-probe\n let x = \"servers.electron-probe\"").contains("servers.electron-probe"))
    }
    @Test func credentialStoreRegistersNoWindowClipboardOrChannel() throws {
        let owner = try source("BackendServersCredentials.swift")
        #expect(!owner.contains("ipcMain") && !owner.contains("webContents") && !owner.contains("clipboard"))
        #expect(!code(owner).contains("registry.register") && !code(owner).contains("NativeChannelRegistry"))
        for file in try sources() where file.lastPathComponent != "BackendServersConnection.swift" { #expect(!code(try String(contentsOf: file, encoding: .utf8)).contains("credentials.read(")) }
    }
    @Test func actualPublicObjectHasExactlyTheSourceFields() throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let stored = try app.store.get("one")
        let row = try #require(stored)
        #expect(row.wireValue.fields?.map(\.key).sorted() == ["addedAt", "address", "credential", "drivesWindows", "hostKey", "id", "lastConnectedAt", "name", "port", "startIn", "username"])
        #expect(row.wireValue.fields?.allSatisfy { !secretNames.contains($0.key) } == true)
    }
    @Test func authenticatedClientConstructionHasOneDoorAndKeyReaderNoRemoteSocket() throws {
        let reaching = try sources().filter { try code(String(contentsOf: $0, encoding: .utf8)).contains("/usr/bin/ssh\"") }.map(\.lastPathComponent)
        // Executable paths are strings: inspect this factual path before string
        // erasure; there is one native transport module, no SSH package import.
        let executableOwners = try sources().filter { try String(contentsOf: $0, encoding: .utf8).contains("/usr/bin/ssh\"") }.map(\.lastPathComponent)
        #expect(reaching.isEmpty && executableOwners == ["BackendServersSSH.swift"])
        let constructing = try sources().filter { try code(String(contentsOf: $0, encoding: .utf8)).contains("BackendServersSSHClient(server:") }.map(\.lastPathComponent)
        #expect(constructing == ["BackendServersSSH.swift"])
        let reader = try source("BackendServersCredentials.swift")
        #expect(!code(reader).contains("BackendServersSSHClient(") && !code(reader).contains("Darwin.connect("))
    }
    @Test func everyAuthenticationUsesAPinnedVerifierAndScanCannotPassEmpty() throws {
        let pool = try source("BackendServersConnection.swift"), ssh = try source("BackendServersSSH.swift")
        #expect(code(pool).contains("dialer.dial(server:") && code(pool).contains("verifyHostKey"))
        #expect(ssh.contains("try verifyHostKey(selected.key)") && ssh.contains("StrictHostKeyChecking=yes") && ssh.contains("UserKnownHostsFile="))
        #expect(ssh.contains("let master = BackendServersSSHProcess") && ssh.contains("arguments: options +"))
        #expect(!ssh.contains("StrictHostKeyChecking=no") && !ssh.contains("accept-new") && !ssh.contains("skipHostKey"))
        #expect(try source("BackendServersStore.swift").contains("record.hostKey == nil"))
    }
    private func sources() throws -> [URL] { try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("BackendServers") && $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckBackend") }
    private func source(_ file: String) throws -> String { try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) }
    private func code(_ text: String) -> String {
        text.replacingOccurrences(of: ##"(?s)\"\"\".*?\"\"\""##, with: " ", options: .regularExpression)
            .replacingOccurrences(of: ##"#*\"(?:\\.|[^\"\\])*\"#*"##, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)//[^\n]*"#, with: " ", options: .regularExpression)
    }
    private func identifiers(_ text: String) -> Set<String> {
        let plain = code(text), regex = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
        return Set(regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).compactMap { Range($0.range, in: plain).map { String(plain[$0]) } })
    }
}
