import CryptoKit
import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAccountEmptyFoldersTests: XCTestCase, @unchecked Sendable {
    private func folder(_ name: String, fixture f: BackendFoundationTestsAccountsFixture, old: Bool = true) throws -> URL {
        let directory = f.configuration.profilesRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if old { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: directory.path) }
        return directory
    }

    func testEmptyAndOnlyOwnProjectsLinkAreRemovedHistoryIsKept() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let empty = try folder("app-imatch-ae-gmail-com", fixture: f)
            let linked = try folder("sherzod-davlatov-gmail-com", fixture: f)
            let projects = URL(fileURLWithPath: f.configuration.systemDirectory("claude")).appendingPathComponent("projects")
            try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("projects"), withDestinationURL: projects)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: linked.path)
            let history = try folder("imzapremium-gmail-com", fixture: f)
            let bytes = Data("real history stays here".utf8)
            try bytes.write(to: history.appendingPathComponent("history.jsonl"))
            let removed = try BackendAccountProfileStore.cleanEmptyAccountFolders(configuration: f.configuration)
            XCTAssertEqual(removed, ["app-imatch-ae-gmail-com", "sherzod-davlatov-gmail-com"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))
            XCTAssertEqual(try Data(contentsOf: history.appendingPathComponent("history.jsonl")), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: projects.path), "a dangling projects link is unlinked, never followed")
        }
    }

    func testReferencedEmptyUnknownProviderAndNestedReferenceArePreserved() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let kept = try folder("kept", fixture: f), nested = try folder("nested", fixture: f)
            let raw: NativeRPCValue = .object([.init("version", .number(1)), .init("profiles", .array([
                BackendFoundationTestsAccountsRawProfile("other-id", provider: "future-ai", directory: kept.path),
                BackendFoundationTestsAccountsRawProfile("nested-id", directory: nested.appendingPathComponent("future-child").path)
            ]))])
            try raw.encodedJSON().write(to: f.configuration.dataDirectory.appendingPathComponent("profiles.json"))
            XCTAssertEqual(try BackendAccountProfileStore.cleanEmptyAccountFolders(configuration: f.configuration), [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        }
    }

    func testCorruptUnreadableAndNewerMetadataNeverCauseFolderRemoval() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let kept = try folder("leftover", fixture: f)
            let file = f.configuration.dataDirectory.appendingPathComponent("profiles.json")
            for bytes in [Data("broken".utf8), Data("{\"version\":2,\"profiles\":[]}".utf8), Data("{\"profiles\":[{}]}".utf8), Data("{\"profiles\":false}".utf8)] {
                try bytes.write(to: file)
                XCTAssertEqual(try BackendAccountProfileStore.cleanEmptyAccountFolders(configuration: f.configuration), [])
                XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
            }
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.root.appendingPathComponent("missing"))
            XCTAssertEqual(try BackendAccountProfileStore.cleanEmptyAccountFolders(configuration: f.configuration), [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        }
    }

    func testRecentDraftNonAppNameRegularProjectsAndForeignLinkArePreserved() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let recent = try folder("signing-in-now", fixture: f, old: false)
            let foreignName = try folder("Personal files", fixture: f)
            let regular = try folder("regular-projects", fixture: f)
            try Data().write(to: regular.appendingPathComponent("projects"))
            let foreign = try folder("foreign-projects", fixture: f)
            try FileManager.default.createSymbolicLink(at: foreign.appendingPathComponent("projects"), withDestinationURL: f.root.appendingPathComponent("somewhere-else"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: foreign.path)
            XCTAssertEqual(try BackendAccountProfileStore.cleanEmptyAccountFolders(configuration: f.configuration), [])
            for directory in [recent, foreignName, regular, foreign] { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path)) }
        }
    }

    func testSymlinkedAccountFolderAndSymlinkedProfilesRootAreNeverFollowed() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let outside = f.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: f.configuration.profilesRoot, withIntermediateDirectories: true)
            let link = f.configuration.profilesRoot.appendingPathComponent("outside-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertEqual(try BackendAccountProfileStore.cleanEmptyAccountFolders(configuration: f.configuration), [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
            try FileManager.default.removeItem(at: f.configuration.profilesRoot)
            try FileManager.default.createSymbolicLink(at: f.configuration.profilesRoot, withDestinationURL: outside)
            let outsideChild = outside.appendingPathComponent("empty-account", isDirectory: true)
            try FileManager.default.createDirectory(at: outsideChild, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: outsideChild.path)
            XCTAssertEqual(try BackendAccountProfileStore.cleanEmptyAccountFolders(configuration: f.configuration), [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: outsideChild.path))
        }
    }

    func testFailedCreateRemovesOnlyNewEmptyFolder() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            await BackendFoundationTestsAccountsExpectError("intentional failure") {
                _ = try await f.profiles.create(name: "New failed", vaultManaged: true) { _ in throw BackendAccountFailure("intentional failure") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.configuration.profilesRoot.appendingPathComponent("new-failed").path))
            let existing = try folder("existing", fixture: f)
            await BackendFoundationTestsAccountsExpectError("intentional failure") {
                _ = try await f.profiles.create(name: "Existing failed", configDir: existing.path, vaultManaged: true) { _ in throw BackendAccountFailure("intentional failure") }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path), "a pre-existing folder is never this attempt's folder")
        }
    }

    func testFailedCreateWithHistoryPreservesTheFolder() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let bytes = Data("keep the history".utf8)
            await BackendFoundationTestsAccountsExpectError("intentional failure") {
                _ = try await f.profiles.create(name: "History failed", vaultManaged: true) { draft in
                    try bytes.write(to: URL(fileURLWithPath: draft.configDir).appendingPathComponent("history.jsonl"))
                    throw BackendAccountFailure("intentional failure")
                }
            }
            XCTAssertEqual(try Data(contentsOf: f.configuration.profilesRoot.appendingPathComponent("history-failed/history.jsonl")), bytes)
            let snapshot = try await f.profiles.snapshot()
            XCTAssertEqual(snapshot.profiles, [])
        }
    }

    func testNewHelperRecognizesAgentKeptAccountLoginsForLaterAdoption() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let directory = f.configuration.accountLoginsRoot.appendingPathComponent("sign-in-draft")
            let profile = try await f.profiles.create(name: "Agent kept", configDir: directory.path, vaultManaged: false)
            XCTAssertNil(profile.loginStore)
            XCTAssertFalse(profile.promised)
            let managed = await f.profiles.managed(profile)
            XCTAssertTrue(managed)
            let systemValue = try await f.profiles.find("system")
            let system = try XCTUnwrap(systemValue)
            let systemManaged = await f.profiles.managed(system)
            XCTAssertFalse(systemManaged)
        }
    }

    func testMetadataRemovalRollsBackTheRowAndAssignmentsOnWriteFailure() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let profile = try await f.create("Kept copy")
            try await f.profiles.setLevel(.app, provider: "claude", id: profile.id)
            try await f.profiles.setLevel(.project(path: "/scratch/project"), provider: "claude", id: profile.id)
            let before = try await f.profiles.snapshot()
            let file = f.configuration.dataDirectory.appendingPathComponent("profiles.json")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            await BackendFoundationTestsAccountsExpectError("saved atomically") { _ = try await f.profiles.removeMetadata(id: profile.id) }
            let after = try await f.profiles.snapshot()
            XCTAssertEqual(after.profiles, before.profiles)
            XCTAssertEqual(after.levels, before.levels)
        }
    }

    /// Install18 release evidence: this fixture is a symlink-preserving copy of install17's actual
    /// profile tree. Its manifest contains filenames and hashes only, never the file contents.
    func testActualInstall17DataCopyRemovesOnlyTheTwoOrphansAndKeepsEveryHistoryByte() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let root = repository.appendingPathComponent("macos/night/codex/accounts18-cleaner-copy", isDirectory: true)
        let manifestFile = root.appendingPathComponent("before-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestFile.path) else {
            throw XCTSkip("The install17 profile copy is local release evidence, supplied for suite18.")
        }
        let manifest = try NativeRPCValue.parseJSON(Data(contentsOf: manifestFile))
        let data = root.appendingPathComponent("data", isDirectory: true)
        // Read-only inspection also found an older app-made projects-only
        // orphan (11 Oct). The audited copy manifest records every such folder.
        let expected = try XCTUnwrap(manifest["expectedOrphans"].elements?.compactMap(\.string)).sorted()
        XCTAssertTrue(expected.contains("app-imatch-ae-gmail-com"))
        XCTAssertTrue(expected.contains("sherzod-davlatov-gmail-com"))
        let configuration = try BackendAccountConfiguration(dataDirectory: data,
            homeDirectory: URL(fileURLWithPath: try XCTUnwrap(manifest["sourceHome"].string), isDirectory: true),
            appName: "Accounts18 Cleaner Copy", appID: "accounts18cleanercopy", helperExecutable: root.appendingPathComponent("unused-helper"), inheritedEnvironment: [:])
        XCTAssertEqual(root.lastPathComponent, "accounts18-cleaner-copy")
        XCTAssertEqual(try hashes(data), (manifest["regularFiles"].fields ?? []).reduce(into: [String: String]()) { result, field in result[field.key] = field.value.string })
        let afterFile = root.appendingPathComponent("after-proof.json")
        let earlier = (try? Data(contentsOf: afterFile)).flatMap { try? NativeRPCValue.parseJSON($0) }
        let alreadyProved = earlier.map {
            $0["removed"].elements?.compactMap(\.string) == expected && $0["allRetainedHashesMatch"] == .bool(true)
        } ?? false
        let removed = try BackendAccountProfileStore.cleanEmptyAccountFolders(configuration: configuration)
        XCTAssertEqual(removed, alreadyProved ? [] : expected)
        for name in expected { XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.profilesRoot.appendingPathComponent(name).path)) }
        let after = try hashes(data)
        let before = (manifest["regularFiles"].fields ?? []).reduce(into: [String: String]()) { result, field in result[field.key] = field.value.string }
        XCTAssertTrue(after == before, "All regular profile files and profile metadata keep their original bytes.")
        let remainingLinks = try symlinks(data)
        let expectedLinks = (manifest["symlinks"].fields ?? []).reduce(into: [String: String]()) { result, field in
            if !expected.contains(where: { field.key == "profiles/\($0)/projects" }) { result[field.key] = field.value.string }
        }
        XCTAssertTrue(remainingLinks == expectedLinks, "The retained history links are unchanged.")
        let result: NativeRPCValue = .object([.init("removed", .array(expected.map(NativeRPCValue.string))),
            .init("removedThisRun", .array(removed.map(NativeRPCValue.string))), .init("idempotent", .bool(alreadyProved)),
            .init("regularFileCount", .number(Double(after.count))), .init("allRetainedHashesMatch", .bool(after == before))])
        try result.encodedJSON(pretty: true).write(to: afterFile)
    }

    private func hashes(_ root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [:] }
        var result: [String: String] = [:]
        for case let file as URL in enumerator {
            let kind = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if kind.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard kind.isRegularFile == true else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            result[relative] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private func symlinks(_ root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return [:] }
        var result: [String: String] = [:]
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else { continue }
            enumerator.skipDescendants()
            result[String(file.path.dropFirst(root.path.count + 1))] = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
        }
        return result
    }
}
