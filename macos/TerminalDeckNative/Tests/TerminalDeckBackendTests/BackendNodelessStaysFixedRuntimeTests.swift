import Foundation
import CryptoKit
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// D2: Stays Fixed's own on-demand Node runtime. Fixture archives replace the
/// network; the real pins are checked against the lockfile/vendored product.
private final class BackendNodelessStaysFixedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
private struct BackendNodelessStaysFixedFakeFetch: BackendNodelessStaysFixedFetching {
    let files: [String: URL]
    let counter: BackendNodelessStaysFixedCounter
    func fetch(_ url: URL, to destination: URL, maximumBytes: Int) async throws {
        counter.bump()
        guard let file = files[url.absoluteString] else { throw NativeRPCError(code: "unavailable", message: "no fixture for \(url)") }
        try FileManager.default.copyItem(at: file, to: destination)
    }
}

final class BackendNodelessStaysFixedRuntimeTests: XCTestCase {
    private let machO = Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(repeating: 0, count: 60)
    private let folder = "node-v24.21.0-darwin-arm64"

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendNodelessStaysFixed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func archive(_ root: URL, _ name: String, top: String, files: [String: Data], link: (String, String)? = nil) throws -> URL {
        let source = root.appendingPathComponent("source-" + name, isDirectory: true)
        for (path, data) in files {
            let file = source.appendingPathComponent(top).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        if let link {
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent(top).appendingPathComponent(link.0).path, withDestinationPath: link.1)
        }
        let output = root.appendingPathComponent(name + ".tgz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.arguments = ["-czf", output.path, "-C", source.path, top]
        try tar.run(); tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        return output
    }
    private func sha256(_ file: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined() }
    private func sri(_ file: URL) throws -> String { Data(SHA512.hash(data: try Data(contentsOf: file))).base64EncodedString() }

    private struct Fixture {
        let root: URL, product: URL, pins: BackendNodelessStaysFixedPins, fetch: BackendNodelessStaysFixedFakeFetch, counter: BackendNodelessStaysFixedCounter
    }
    private func fixture(nodeBinary: Data? = nil, depLink: (String, String)? = nil, corruptDep: Bool = false) throws -> Fixture {
        let root = try scratch()
        let node = try archive(root, "node", top: folder, files: ["bin/node": nodeBinary ?? machO, "LICENSE": Data("MIT".utf8), "include/node/node.h": Data("x".utf8)])
        let product = try archive(root, "staysfixed", top: "package", files: ["package.json": Data(#"{"name":"staysfixed","version":"0.15.0"}"#.utf8), "bin/staysfixed.js": Data("// cli".utf8)])
        let dep = try archive(root, "pngjs", top: "package", files: ["package.json": Data(#"{"name":"pngjs"}"#.utf8)], link: depLink)
        let nodeURL = URL(string: "https://fixture.invalid/node.tgz")!, depURL = URL(string: "https://fixture.invalid/pngjs.tgz")!
        let depSRI = try corruptDep ? "AAAA" : sri(dep)
        let pins = BackendNodelessStaysFixedPins(nodeVersion: "24.21.0", architecture: "arm64", artifacts: [
            .init(name: "node", version: "24.21.0", url: nodeURL, digest: .sha256Hex(try sha256(node)), destination: "node",
                  stripComponents: 1, members: ["\(folder)/bin/node", "\(folder)/LICENSE"], maximumBytes: 1 << 20),
            .init(name: "staysfixed", version: "0.15.0", url: nil, digest: .sha512Base64(try sri(product)),
                  destination: "package/node_modules/staysfixed", stripComponents: 1, members: [], maximumBytes: 1 << 20),
            .init(name: "pngjs", version: "7.0.0", url: depURL, digest: .sha512Base64(depSRI),
                  destination: "package/node_modules/pngjs", stripComponents: 1, members: [], maximumBytes: 1 << 20),
        ])
        let counter = BackendNodelessStaysFixedCounter()
        return .init(root: root, product: product, pins: pins,
                     fetch: .init(files: [nodeURL.absoluteString: node, depURL.absoluteString: dep], counter: counter), counter: counter)
    }
    private func leftovers(_ base: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).sorted()
    }

    func testShippedPinsMatchTheLockfileAndVendoredProduct() throws {
        let arm = try BackendNodelessStaysFixedPins.current(architecture: "arm64")
        XCTAssertEqual(arm.artifacts.map(\.name), ["node", "staysfixed", "playwright-core", "pngjs", "pixelmatch"])
        XCTAssertEqual(arm.artifacts[0].url?.absoluteString, "https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz")
        XCTAssertEqual(arm.artifacts[0].members, ["node-v24.21.0-darwin-arm64/bin/node", "node-v24.21.0-darwin-arm64/LICENSE"])
        XCTAssertNil(arm.artifacts[1].url, "the product comes from the app bundle, never the network")
        XCTAssertTrue(arm.artifacts.dropFirst(2).allSatisfy { $0.url?.host == "registry.npmjs.org" })
        XCTAssertEqual(arm.key, "node-24.21.0-staysfixed-0.15.0-arm64-r2")
        XCTAssertNotEqual(try BackendNodelessStaysFixedPins.current(architecture: "x64").artifacts[0].digest, arm.artifacts[0].digest)
        XCTAssertThrowsError(try BackendNodelessStaysFixedPins.current(architecture: "ppc"))
        let vendored = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/" + BackendNodelessStaysFixedPins.bundledProductName)
        if FileManager.default.fileExists(atPath: vendored.path) {
            XCTAssertTrue(BackendNodelessStaysFixedPins.matches(try Data(contentsOf: vendored), arm.artifacts[1].digest))
        }
    }

    func testFirstUseDownloadsVerifiesAndInstallsOnceWhileStatusNeverDownloads() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let data = f.root.appendingPathComponent("data", isDirectory: true)
        let runtime = try BackendNodelessStaysFixedRuntime(userData: data, bundledProduct: f.product, pins: f.pins, fetcher: f.fetch)
        let before = await runtime.installed()
        XCTAssertNil(before); XCTAssertEqual(f.counter.count, 0)
        XCTAssertTrue(runtime.pendingNote.contains("first time"))
        async let first = runtime.prepare(); async let second = runtime.prepare()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b); XCTAssertEqual(f.counter.count, 2, "one download per network artifact")
        XCTAssertEqual(a.root.lastPathComponent, f.pins.key)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: a.node.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("node/include").path), "only bin/node and LICENSE")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("node/LICENSE").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.packageParent.appendingPathComponent("node_modules/pngjs/package.json").path))
        let home = try a.engineHome()
        XCTAssertEqual(home.version, "0.15.0"); XCTAssertEqual(home.dir.standardizedFileURL, a.package.standardizedFileURL)
        XCTAssertEqual(leftovers(runtime.base), [f.pins.key])
        let again = try await runtime.prepare()
        XCTAssertEqual(again, a); XCTAssertEqual(f.counter.count, 2)
        let installed = await runtime.installed(); XCTAssertEqual(installed, a)
    }

    func testChecksumMismatchLinkOrForeignBinaryInstallsNothing() async throws {
        for f in [try fixture(corruptDep: true), try fixture(depLink: ("escape", "/etc/hosts")), try fixture(nodeBinary: Data("#!/bin/sh\n".utf8))] {
            defer { try? FileManager.default.removeItem(at: f.root) }
            let data = f.root.appendingPathComponent("data", isDirectory: true)
            let runtime = try BackendNodelessStaysFixedRuntime(userData: data, bundledProduct: f.product, pins: f.pins, fetcher: f.fetch)
            do { _ = try await runtime.prepare(); XCTFail("an unverified runtime must not install") }
            catch let error as NativeRPCError { XCTAssertTrue(error.message.contains("Nothing was installed"), error.message) }
            XCTAssertEqual(leftovers(runtime.base), [], "no key folder and no staging left behind")
            let installed = await runtime.installed(); XCTAssertNil(installed)
        }
    }

    /// pngjs 7.0.0's real tarball records its directories as 0666 (no search bit):
    /// unpacked as is, `pngjs/lib` is unreadable and Stays Fixed's picture checks fail.
    func testArchiveDirectoryModesAreNormalisedSoPackagesAreReadable() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let content = f.root.appendingPathComponent("png.js"); try Data("module.exports = 1".utf8).write(to: content)
        let spec = f.root.appendingPathComponent("pngjs.mtree")
        try Data("""
        #mtree
        package type=dir mode=0666
        package/lib type=dir mode=0666
        package/lib/png.js type=file mode=0666 contents=\(content.path)
        package/package.json type=file mode=0666 contents=\(content.path)

        """.utf8).write(to: spec)
        let odd = f.root.appendingPathComponent("odd.tgz")
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.arguments = ["-czf", odd.path, "@" + spec.path]
        try tar.run(); tar.waitUntilExit(); XCTAssertEqual(tar.terminationStatus, 0)
        // Same member shape as the real pngjs-7.0.0.tgz: `package/…`, directories 0666.
        let listing = Process(), pipe = Pipe(); listing.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        listing.arguments = ["-tvzf", odd.path]; listing.standardOutput = pipe; try listing.run(); listing.waitUntilExit()
        let members = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(members.contains("drw-rw-rw-") && members.contains(" package/lib"), members)
        let url = URL(string: "https://fixture.invalid/odd.tgz")!
        var artifacts = f.pins.artifacts
        artifacts[2] = .init(name: "pngjs", version: "7.0.0", url: url, digest: .sha512Base64(try sri(odd)),
                             destination: "package/node_modules/pngjs", stripComponents: 1, members: [], maximumBytes: 1 << 20)
        let pins = BackendNodelessStaysFixedPins(nodeVersion: f.pins.nodeVersion, architecture: f.pins.architecture, artifacts: artifacts)
        var files = f.fetch.files; files[url.absoluteString] = odd
        let runtime = try BackendNodelessStaysFixedRuntime(userData: f.root.appendingPathComponent("data"), bundledProduct: f.product, pins: pins,
            fetcher: BackendNodelessStaysFixedFakeFetch(files: files, counter: f.counter))
        let install = try await runtime.prepare()
        let lib = install.packageParent.appendingPathComponent("node_modules/pngjs/lib")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: lib.appendingPathComponent("png.js").path), "pngjs/lib must be searchable")
        let mode = try FileManager.default.attributesOfItem(atPath: lib.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        let file = try FileManager.default.attributesOfItem(atPath: lib.appendingPathComponent("png.js").path)[.posixPermissions] as? Int
        XCTAssertEqual(file, 0o644)
    }

    func testMissingProductIsNotPartOfThisBuild() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let runtime = try BackendNodelessStaysFixedRuntime(userData: f.root.appendingPathComponent("data"), bundledProduct: nil, pins: f.pins, fetcher: f.fetch)
        do { _ = try await runtime.prepare(); XCTFail("no product, no install") }
        catch let error as NativeRPCError { XCTAssertEqual(error.message, "Stays Fixed is not part of this build.") }
        XCTAssertEqual(f.counter.count, 0)
        XCTAssertThrowsError(try BackendNodelessStaysFixedRuntime(userData: URL(fileURLWithPath: "/"), bundledProduct: nil))
    }

    /// D2: opening the Stays Fixed screen (readiness without refresh) never
    /// downloads the runtime; the person's "Look again" (refresh) may.
    func testReadinessOnOpenNeverDownloads() async throws {
        let project = try scratch()
        let provisioning = BackendNodelessStaysFixedPendingProvisioning()
        let service = BackendStaysFixedService(userData: project.appendingPathComponent("userData"), home: project.path, executable: nil,
            inheritedEnvironment: [:], locate: { throw NativeRPCError(code: "unavailable", message: "unused") }, loginPath: { "/usr/bin" },
            provisioning: provisioning)
        do { _ = try await service.readiness(project.path, refresh: false); XCTFail("readiness ran without a runtime") }
        catch let pending as BackendStaysFixedNotDownloaded { XCTAssertEqual(pending.note, provisioning.pendingNote) }
        XCTAssertEqual(provisioning.prepared.count, 0, "opening the screen must not download")
        let registry = NativeChannelRegistry(); try await BackendStaysFixedChannels.register(registry: registry, ownerID: "owner", service: service)
        let opened = try await registry.invoke("staysfixed:readiness", context: .init(caller: .nativeApp, ownerID: "owner"), arguments: [.string(project.path), .bool(false)])
        XCTAssertEqual(opened["ok"], .bool(false)); XCTAssertEqual(opened["message"], .string(provisioning.pendingNote))
        XCTAssertEqual(provisioning.prepared.count, 0)
        _ = try? await service.readiness(project.path, refresh: true)
        XCTAssertEqual(provisioning.prepared.count, 1, "Look again fetches the runtime")
    }
}

private final class BackendNodelessStaysFixedPendingProvisioning: BackendStaysFixedProvisioning, @unchecked Sendable {
    let prepared = BackendNodelessStaysFixedCounter()
    var pendingNote: String { "Downloaded the first time you set up or check." }
    func installed() async -> BackendNodelessStaysFixedInstall? { nil }
    func prepare() async throws -> BackendNodelessStaysFixedInstall {
        prepared.bump(); throw NativeRPCError(code: "offline", message: "no network in this test")
    }
}
