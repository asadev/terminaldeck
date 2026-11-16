import Foundation
import Darwin
import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture-only ports are compiled into this test target, never the app.
actor CloudToolsSitePorts: CloudContentPort, CloudOutboxPort {
  private var blobs: [String: Data] = [:]
  func state(storageClass: CloudStorageClass) -> CloudContentState { .init(available: true, epoch: 1) }
  func seal(_ bytes: Data, blobId: String, storageClass: CloudStorageClass, purpose: CloudPurpose, epoch: Int, codec: CloudContentCodec) -> CloudContentEnvelope {
    .init(v: 1, suite: "FIXTURE-ONLY", storageClass: storageClass, purpose: purpose, epoch: epoch, blobId: blobId, codec: .identity, plainBytes: Int64(bytes.count), nonce: "fixture", ciphertext: bytes.base64EncodedString(), tag: "fixture")
  }
  func open(_ value: CloudContentEnvelope) throws -> Data { guard let data = Data(base64Encoded: value.ciphertext) else { throw CloudFailure.checksumMismatch }; return data }
  func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) throws -> CloudLocalReceipt {
    for file in files { blobs[file.blobId] = try Data(contentsOf: file.localURL) }
    return .init(operationIds: operations.map(\.opId), queued: operations.count, bytes: files.reduce(0) { $0 + $1.bytes }, savedAt: 1)
  }
  func read(_ ref: CloudBlobRef) throws -> Data { guard let bytes = blobs[ref.blobId] else { throw CloudFailure.unavailable }; return bytes }
  func coverage(sourceId: String) throws -> CloudCoverage { throw CloudFailure.unsupportedFormat }
  func flush() throws -> [CloudReceipt] { throw CloudFailure.unsupportedFormat }
  func restoreProgress() throws -> CloudRestoreProgress { throw CloudFailure.unsupportedFormat }
  func contextReady(projectId: String) throws -> CloudContextReady { throw CloudFailure.unsupportedFormat }
  func register(adapter: any CloudDomainAdapter) throws { throw CloudFailure.unsupportedFormat }
  func bootstrap(_ snapshots: [CloudDomainSnapshot]) throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
  func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
  func pull() throws -> [CloudImportReceipt] { throw CloudFailure.unsupportedFormat }
  func setPaused(_ paused: Bool) throws { throw CloudFailure.unsupportedFormat }
}

/// Only this test's PTY/process group is owned here. No installed session manager or hook adapter is constructed.
private final class CloudToolsSiteSession: BackendDevSessionAccess, @unchecked Sendable {
  private let queue = DispatchQueue(label: "cloud-backup.fixture-site")
  private var process: BackendPTYProcess?
  private var buffer = "$ "
  private var folder: String?
  private var stopped: CheckedContinuation<Void, Never>?
  private let environment: [String: String]
  init(environment: [String: String]) { self.environment = environment }
  func openShell(folder: String, context: NativeRPCContext) async throws -> String {
    queue.sync { self.folder = folder; buffer = "$ " }
    return "fixture-site"
  }
  func type(sessionID: String, text: String, context: NativeRPCContext) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      queue.async { [self] in
        do {
          guard text == "npm run dev\r", let folder, folder.hasPrefix("/Users/imatch/Deck Dev/notes/cloud-test-20261112/bkp/") else { throw CloudBackupError.unsafePath }
          let child = try BackendPTYProcess.spawn(command: "/usr/bin/env", args: ["npm", "run", "dev"], environment: environment, cwd: folder, cols: 120, rows: 30, queue: queue)
          process = child
          child.onData = { [weak self] data in guard let self else { return }; self.buffer += String(decoding: data, as: UTF8.self) }
          child.onExit = { [weak self] _ in
            guard let self else { return }
            self.process = nil; self.stopped?.resume(); self.stopped = nil
          }
          child.start()
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  func output(sessionID: String, context: NativeRPCContext) async throws -> String { queue.sync { buffer } }
  func alive(sessionID: String) async -> Bool { queue.sync { process != nil || folder != nil && buffer == "$ " } }
  func processID(sessionID: String) async -> Int32? { queue.sync { process?.pid } }
  func stop() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        folder = nil
        guard let process else { continuation.resume(); return }
        stopped = continuation; process.terminate()
      }
    }
  }
}
private struct CloudToolsSiteNoPorts: BackendDevPortScanning {
  func scan(force: Bool) async throws -> [BackendDevPort] { [] }
}

final class CloudToolsSiteTests: XCTestCase, @unchecked Sendable {
  func testRestoredSyntheticSiteStartsAndAnswersOnLocalhost() async throws {
    let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    guard paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/npm") }),
      paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/node") }) else { throw XCTSkip("The existing Node/npm tools are unavailable; no installer is run by this fixture.") }
    let notes = try CloudBackupDirectory(path: "/Users/imatch/Deck Dev/notes")
    if mkdirat(notes.fd, "cloud-test-20261112", 0o700) != 0 && errno != EEXIST { throw CloudBackupError.unsafePath }
    let day = try notes.directory("cloud-test-20261112")
    if mkdirat(day.fd, "bkp", 0o700) != 0 && errno != EEXIST { throw CloudBackupError.unsafePath }
    let scope = try day.directory("bkp"), id = UUID().uuidString
    let owned = try scope.createDirectory(id)
    _ = try owned.createDirectory("source")
    let base = URL(fileURLWithPath: "/Users/imatch/Deck Dev/notes/cloud-test-20261112/bkp").appendingPathComponent(id)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("source")
    let files = [
      "package.json": #"{"name":"cloud-backup-fixture","version":"1.0.0","scripts":{"dev":"node site.cjs"}}"#,
      "package-lock.json": #"{"name":"cloud-backup-fixture","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"cloud-backup-fixture","version":"1.0.0"}}}"#,
      "index.html": "fixture restored site",
      "site.cjs": #"const http=require('node:http');const fs=require('node:fs');const s=http.createServer((q,r)=>{r.writeHead(200,{'Content-Type':'text/plain'});r.end(fs.readFileSync('index.html'));});s.listen(0,'127.0.0.1',()=>console.log('Local: http://127.0.0.1:'+s.address().port));"#
    ]
    for (name, value) in files { try Data(value.utf8).write(to: source.appendingPathComponent(name)) }
    let ports = CloudToolsSitePorts()
    let classifier: CloudBackupEngine.Classifier = { _, _ in .init(storageClass: .brain, purpose: .brain, rule: "fixture-work") }
    let engine = CloudBackupEngine(stateDirectory: base.appendingPathComponent("state"), brain: ports, secrets: ports, classify: classifier, outbox: ports)
    let snapshot = try await engine.snapshot(.init(projectId: "site", rootId: "root", deviceId: "fixture-a", directory: source), eventCursor: "1", at: 1)
    let reader = CloudRestoreReader(fetch: { try await ports.read($0) }, brain: ports, secrets: ports)
    let planner = CloudRestorePlanner(reader: reader)
    let plan = try await planner.plan(manifest: reader.manifest(snapshot.root), sourceManifestHash: snapshot.root.sha256, destination: base.appendingPathComponent("restored"))
    let restored = try await planner.restore(restoreId: plan.restoreId, planDigest: plan.digest)
    XCTAssertTrue(restored.ready)
    let environment = ["HOME": base.path, "TD_NATIVE_DATA_DIR": base.appendingPathComponent("app-data").path, "PATH": paths.joined(separator: ":"),
      "NO_UPDATE_NOTIFIER": "1", "npm_config_update_notifier": "false", "npm_config_audit": "false", "npm_config_fund": "false",
      "npm_config_offline": "true", "npm_config_userconfig": "/dev/null", "npm_config_globalconfig": "/dev/null"]
    let authority = BackendFilesystemAuthority { _ in .init(readRoots: [base], writeRoots: [base]) }
    let fileService = BackendFilesystemService(authority: authority)
    let sessions = CloudToolsSiteSession(environment: environment)
    let servers = BackendDevServers(files: fileService, sessions: sessions, ports: CloudToolsSiteNoPorts())
    let runner = BackendCommandRunner()
    let verifier = BackendCloudToolsRecipe(servers: servers, files: fileService, runner: runner, environment: environment, classify: classifier, observedVersion: { name, _, _ in
      guard ["node", "npm"].contains(name) else { throw CloudBackupError.unsupportedFile }
      let result = try await runner.run(command: "/usr/bin/env", arguments: [name, "--version"], environment: environment, cwd: base.path, timeoutMilliseconds: 3000, outputLimit: 1024)
      let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard result.succeeded else { throw CloudBackupError.unavailable }
      return value.hasPrefix("v") ? String(value.dropFirst()) : value
    })
    let context = NativeRPCContext(caller: .nativeApp, ownerID: "cloud-backup-fixture")
    do {
      let recipe = try await verifier.detect(projectId: "site", rootId: "root", folder: restored.destination, context: context)
      XCTAssertEqual(recipe.start.argv, ["npm", "run", "dev"])
      XCTAssertTrue(recipe.install.argv.isEmpty)
      do { _ = try await verifier.verify(recipe, folder: restored.destination, context: context); XCTFail("Idle project was called startable") }
      catch { XCTAssertEqual(error as? CloudBackupError, .incomplete) }
      await servers.setPreparationHandler { folder, context in
        try await verifier.prepareLibraries(recipe, folder: folder, context: context)
      }
      _ = try await servers.start(folder: restored.destination, context: context)
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        if (try await servers.status(folder: restored.destination, context: context))["status"].string == "ready" { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      let proof = try await verifier.verify(recipe, folder: restored.destination, context: context)
      XCTAssertEqual(proof.httpStatus, 200)
      XCTAssertGreaterThan(proof.listenerPID, 1)
      XCTAssertTrue(proof.localURL.hasPrefix("http://127.0.0.1:"))
      let body = try await runner.run(command: "/usr/bin/curl", arguments: ["--disable", "--silent", "--fail", "--noproxy", "*", "--max-time", "2", proof.localURL + "/"], environment: environment, cwd: restored.destination, timeoutMilliseconds: 4000, outputLimit: 1024)
      XCTAssertTrue(body.succeeded)
      XCTAssertEqual(body.output, "fixture restored site")
      XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("index.html"), encoding: .utf8), "fixture restored site")
      await servers.stop(); await sessions.stop()
    } catch {
      await servers.stop(); await sessions.stop()
      throw error
    }
  }
}
