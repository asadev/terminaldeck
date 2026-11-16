import CryptoKit
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Project secret files (14 Nov): two "Macs" of one account (one shared key, each its own holding key), each with its
/// own scratch project folder under the agreed test root. Records go from one store's capture to the other's
/// validate + merge exactly as the saved-passwords adapter hands them. No real home, project, Keychain or network.
struct ProjectSecretFilesFixture {
    let base: URL
    let projectId = "p-" + UUID().uuidString.lowercased().prefix(8)
    let shared = SymmetricKey(size: .bits256)
    final class Gate: @unchecked Sendable { var state = BackendProjectSecretFilesGate.open }
    let gate = Gate()
    /// Each Mac's own holding key, the same across a restart (as the real one, derived from the key and the device id).
    final class Locals: @unchecked Sendable { var keys: [String: SymmetricKey] = [:] }
    let locals = Locals()
    typealias Project = BackendProjectSecretFilesStore.Project
    init() throws {
        base = CloudBrainMemoryFixture.approvedRoot.appendingPathComponent("secret-files/s-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    func close() { try? FileManager.default.removeItem(at: base) }
    /// A project folder as a real one is: never empty (review 15 Nov, decision 11: an EMPTY folder counts as not on this
    /// Mac, so nothing is placed into it). A plain file that is not a secret file.
    func makeProject(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("made-up project\n".utf8).write(to: url.appendingPathComponent("README.md"))
    }
    func folder(_ mac: String) -> URL { base.appendingPathComponent(mac + "/Projects/Shop", isDirectory: true) }
    func keys(_ mac: String, sharedKey: SymmetricKey? = nil) -> CloudSecretsStoreKeys {
        let local = locals.keys[mac] ?? SymmetricKey(size: .bits256)
        locals.keys[mac] = local
        return .init(epoch: 1, sharedKey: sharedKey ?? shared, local: local)
    }
    /// One Mac's store over any project list (`keyed` false: the keys come from the saved-passwords layer instead).
    func store(_ name: String, projects: @escaping @Sendable () -> [Project], home: String? = nil, keyed: Bool = true,
               sharedKey: SymmetricKey? = nil) async -> BackendProjectSecretFilesStore {
        let gate = gate
        let store = BackendProjectSecretFilesStore(stateRoot: base.appendingPathComponent(name + "/state", isDirectory: true),
            projects: { projects() }, deviceName: { name }, gate: { gate.state },
            home: home ?? base.appendingPathComponent(name + "/home").path, walkReuse: 0)
        if keyed { await store.use(keys: keys(name, sharedKey: sharedKey)) }
        return store
    }
    /// One Mac's store with the project "Shop" in one folder. `folders` false: the project is on this Mac with no folder yet.
    func mac(_ name: String, folders: Bool = true, sharedKey: SymmetricKey? = nil, home: String? = nil, keyed: Bool = true) async throws -> BackendProjectSecretFilesStore {
        let folder = folder(name)
        if folders { try makeProject(folder) }
        let id = projectId
        return await store(name, projects: { [.init(id: id, name: "Shop", folders: FileManager.default.fileExists(atPath: folder.path) ? [folder.path] : [])] },
                           home: home, keyed: keyed, sharedKey: sharedKey)
    }
    func write(_ mac: String, _ path: String, _ text: String, mode: mode_t = 0o600) throws {
        try write(folder(mac).appendingPathComponent(path), text, mode: mode)
    }
    func write(_ url: URL, _ text: String, mode: mode_t = 0o600) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        chmod(url.path, mode)
    }
    func read(_ mac: String, _ path: String) -> String? { read(folder(mac).appendingPathComponent(path)) }
    func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
    func mode(_ mac: String, _ path: String) -> Int? {
        var info = stat()
        guard lstat(folder(mac).appendingPathComponent(path).path, &info) == 0 else { return nil }
        return Int(info.st_mode & 0o777)
    }
    func paths(_ records: [CloudSecretRecord]) throws -> [String] {
        try records.map { try value($0).path }.sorted()
    }
    func value(_ record: CloudSecretRecord) throws -> BackendProjectSecretFileValue {
        try BackendCloudSecretsRecords.decode(BackendProjectSecretFileValue.self, record, source: BackendProjectSecretFilesRules.sourceId, domain: .project)
    }
    /// A record a hostile or buggy Mac of the SAME account could make: it holds the shared key, so the record name and
    /// the fingerprint are right, and only the path rules (and caps) can refuse it.
    func forged(_ path: String, _ text: String, folder: String = "", projectId: String? = nil, mode: Int = 0o600, base: String? = nil,
                from: String = "Mac mini") throws -> CloudSecretRecord {
        let keys = CloudSecretsStoreKeys(epoch: 1, sharedKey: shared, local: SymmetricKey(size: .bits256))
        let project = projectId ?? self.projectId, bytes = Data(text.utf8)
        let id = "file/" + project + "/" + keys.shared(Data(("id\n" + project + "\n" + folder + "\n" + path).utf8))
        let value = BackendProjectSecretFileValue(v: 1, projectId: project, folder: folder, path: path, mode: mode, data: bytes.base64EncodedString(),
                                                  mark: keys.shared(Data("content\n".utf8) + bytes), base: base, at: 1_900_000_000_000, from: from)
        return try BackendCloudSecretsRecords.record(BackendProjectSecretFilesRules.sourceId, id, .project, value)
    }
    /// What the adapter does with an arriving record: validate, then merge.
    func deliver(_ records: [CloudSecretRecord], to store: BackendProjectSecretFilesStore) async throws -> [CloudApplyStatus] {
        var outcomes: [CloudApplyStatus] = []
        for record in records {
            try await store.validate(record)
            let outcome = try await store.merge(record)
            #expect(try await store.verify(record, outcome: outcome))
            outcomes.append(outcome)
        }
        return outcomes
    }
    func temporaries(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { BackendProjectSecretFilesRules.isTemporary($0) }
    }
}

@Suite(.serialized) struct ProjectSecretFilesTests {
    @Test func onlyProjectSecretFilesTravelAndArriveWithTheirPermissions() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini"), b = try await f.mac("MacBook")
        try f.write("Mac mini", ".env", "TOKEN=one\n")
        try f.write("Mac mini", "apps/web/.env.local", "KEY=two\n", mode: 0o640)
        try f.write("Mac mini", "README.md", "hello")
        try f.write("Mac mini", "id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----")       // a person's key: never
        try f.write("Mac mini", "deploy/.aws/credentials", "[default]")                   // machine credentials: never
        try f.write("Mac mini", "node_modules/pkg/.env", "X=1")                           // package folder: never
        try f.write("Mac mini", "cert.pem", "-----BEGIN CERTIFICATE-----")                // not a private key: never
        try f.write("Mac mini", ".env.production", String(repeating: "A", count: 40_000)) // too large
        let sent = try await a.capture()
        let paths = try sent.map { try BackendCloudSecretsRecords.decode(BackendProjectSecretFileValue.self, $0,
                                                                            source: BackendProjectSecretFilesRules.sourceId, domain: .project).path }
        #expect(paths.sorted() == [".env", "apps/web/.env.local"])
        // The record id says nothing about the file: project id and an opaque keyed hex.
        for record in sent {
            #expect(record.domain == "project")
            #expect(!record.recordId.contains("env"))
            #expect(record.recordId.hasPrefix("file/" + f.projectId + "/"))
            #expect(record.recordId.split(separator: "/").last?.count == 64)
        }
        let outcomes = try await f.deliver(sent, to: b)
        #expect(outcomes == [.applied, .applied])
        #expect(f.read("MacBook", ".env") == "TOKEN=one\n")
        #expect(f.read("MacBook", "apps/web/.env.local") == "KEY=two\n")
        #expect(f.mode("MacBook", ".env") == 0o600)
        // Review 14 Nov (F1): a new file is owner-only, whatever the sender's permission (0640 there).
        #expect(f.mode("MacBook", "apps/web/.env.local") == 0o600)
        // No temporary file is left beside them.
        #expect(f.temporaries(f.folder("MacBook")).isEmpty)
        #expect(f.temporaries(f.folder("MacBook").appendingPathComponent("apps/web")).isEmpty)
        // The status names them, never their content; the too-large one is named as held.
        let status = try #require(await a.status())
        let names = status.projects.flatMap(\.files).map { $0.path + "|" + $0.state }
        #expect(names.contains(".env.production|" + BackendProjectSecretFilesWords.tooLarge))
        #expect(names.contains(".env|" + BackendProjectSecretFilesWords.travels))
        let arrived = try #require(await b.status())
        #expect(arrived.projects.flatMap(\.files).contains { $0.path == ".env" && $0.state == BackendProjectSecretFilesWords.arrived("Mac mini") })
        // The arrived file is not sent back as new: the same record comes out on the other Mac.
        let echo = try await b.capture()
        #expect(Set(echo.map(\.recordId)) == Set(sent.map(\.recordId)))
    }

    @Test func hisDifferentFileIsNeverOverwrittenAndANewerVersionMadeOnTopReplaces() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini"), b = try await f.mac("MacBook")
        try f.write("Mac mini", ".env", "TOKEN=one\n")
        _ = try await f.deliver(try await a.capture(), to: b)
        // Made on top of the agreed version on the Mac mini: the MacBook takes it.
        try f.write("Mac mini", ".env", "TOKEN=two\n")
        #expect(try await f.deliver(try await a.capture(), to: b) == [.applied])
        #expect(f.read("MacBook", ".env") == "TOKEN=two\n")
        // Both change it apart: each keeps his own; the line says so.
        try f.write("Mac mini", ".env", "TOKEN=three\n")
        try f.write("MacBook", ".env", "TOKEN=mine\n")
        _ = try await b.capture()
        #expect(try await f.deliver(try await a.capture(), to: b) == [.keptBoth])
        #expect(f.read("MacBook", ".env") == "TOKEN=mine\n")
        let status = try #require(await b.status())
        #expect(status.projects.flatMap(\.files).contains { $0.path == ".env" && $0.state == BackendProjectSecretFilesWords.differs("Mac mini") })
        // A different file that was there before anything travelled: kept too.
        try f.write("Mac mini", "secrets.json", "{\"a\":1}")
        try f.write("MacBook", "secrets.json", "{\"b\":2}")
        let second = try await a.capture().filter { record in
            (try? BackendCloudSecretsRecords.decode(BackendProjectSecretFileValue.self, record, source: BackendProjectSecretFilesRules.sourceId,
                                                    domain: .project).path) == "secrets.json"
        }
        #expect(try await f.deliver(second, to: b) == [.keptBoth])
        #expect(f.read("MacBook", "secrets.json") == "{\"b\":2}")
    }

    @Test func aRemovalNeverTravelsAndHisRemovalHereStands() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini"), b = try await f.mac("MacBook")
        try f.write("Mac mini", ".env", "TOKEN=one\n")
        let sent = try await a.capture()
        _ = try await f.deliver(sent, to: b)
        try FileManager.default.removeItem(at: f.folder("Mac mini").appendingPathComponent(".env"))
        #expect(try await a.capture().isEmpty)        // nothing is sent for a removal
        try FileManager.default.removeItem(at: f.folder("MacBook").appendingPathComponent(".env"))
        #expect(try await f.deliver(sent, to: b) == [.alreadyPresent])   // the same version again: stays removed
        #expect(f.read("MacBook", ".env") == nil)
    }

    @Test func nothingIsSentUntilEveryMacUnderstands() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini")
        try f.write("Mac mini", ".env", "TOKEN=one\n")
        f.gate.state = .waitingForMacs
        #expect(try await a.capture().isEmpty)
        let waiting = try #require(await a.status())
        #expect(waiting.waitingForMacs)
        #expect(waiting.waitingWhy == BackendProjectSecretFilesWords.waitingMacs)
        // Review 14 Nov (F11): Cloud memory off here is named as the reason, not "waits for your devices".
        f.gate.state = .cloudMemoryOff
        #expect(try await a.capture().isEmpty)
        #expect(try #require(await a.status()).waitingWhy == BackendProjectSecretFilesWords.waitingMemory)
        f.gate.state = .open
        #expect(try await a.capture().count == 1)
    }

    @Test func anArrivalWithoutItsFolderWaitsSealedAndIsPlacedWhenTheFolderExists() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini"), b = try await f.mac("MacBook", folders: false)
        try f.write("Mac mini", ".env", "TOKEN=one\n")
        #expect(try await f.deliver(try await a.capture(), to: b) == [.alreadyPresent])
        // Waiting on disk: sealed, never the plain text.
        // Every FILE under the state folder, at any depth (the delete rule added the sealed Bin folder `sealed-bin` there).
        let state = f.base.appendingPathComponent("MacBook/state")
        var looked = 0
        for name in try FileManager.default.subpathsOfDirectory(atPath: state.path) {
            let url = state.appendingPathComponent(name)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            #expect(!text.contains("TOKEN=one")); looked += 1
        }
        #expect(looked > 0)
        #expect(try #require(await b.status()).projects.flatMap(\.files).contains { $0.state == BackendProjectSecretFilesWords.waitingFolder })
        try f.makeProject(f.folder("MacBook"))
        _ = try await b.capture()
        #expect(f.read("MacBook", ".env") == "TOKEN=one\n")
        #expect(f.mode("MacBook", ".env") == 0o600)
    }

    @Test func keepOnThisMacOnlySendsNothingAndHoldsArrivals() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini"), b = try await f.mac("MacBook")
        try f.write("Mac mini", ".env", "TOKEN=one\n")
        try f.write("MacBook", "other/.env", "B=1\n")
        let sent = try await a.capture()
        try await b.setKeepOnThisMac(true)
        #expect(try await b.capture().isEmpty)
        #expect(try await f.deliver(sent, to: b) == [.alreadyPresent])
        #expect(f.read("MacBook", ".env") == nil)
        try await b.setKeepOnThisMac(false)
        _ = try await b.capture()
        #expect(f.read("MacBook", ".env") == "TOKEN=one\n")
    }

    @Test func aRecordThatIsNotHisOrClimbsOutIsRefused() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini"), b = try await f.mac("MacBook")
        let stranger = try await f.mac("Other", sharedKey: SymmetricKey(size: .bits256))
        try f.write("Other", ".env", "EVIL=1\n")
        let foreign = try await stranger.capture()
        await #expect(throws: CloudFailure.invalidRequest) { try await b.validate(foreign[0]) }
        try f.write("Mac mini", ".env", "TOKEN=one\n")
        let good = try await a.capture()[0]
        var value = try BackendCloudSecretsRecords.decode(BackendProjectSecretFileValue.self, good, source: BackendProjectSecretFilesRules.sourceId, domain: .project)
        for path in ["../.env", "/etc/.env", ".git/.env", "README.md", "id_rsa"] {
            value = .init(v: 1, projectId: value.projectId, folder: value.folder, path: path, mode: value.mode, data: value.data, mark: value.mark,
                          base: nil, at: value.at, from: value.from)
            let forged = try BackendCloudSecretsRecords.record(BackendProjectSecretFilesRules.sourceId, good.recordId, .project, value)
            await #expect(throws: CloudFailure.invalidRequest) { try await b.validate(forged) }
        }
        // The fixture's own plain README (decision 11: a project folder is never empty) is untouched: no forged record wrote it.
        #expect(f.read("MacBook", "README.md") == "made-up project\n")
        #expect(f.read("MacBook", "id_rsa") == nil && f.read("MacBook", ".git/.env") == nil)
        // Without the key nothing is named or taken.
        await b.use(keys: nil)
        await #expect(throws: CloudFailure.secretsLocked) { try await b.validate(good) }
        await #expect(throws: CloudFailure.secretsLocked) { _ = try await b.capture() }
    }

    @Test func theCodePageSaysTheHeldBackSecretFilesTravel() {
        var project = BackendCodeBackupProject(id: "p1", name: "Shop")
        project.hasFolder = true; project.isRepository = true; project.home = "me/shop"
        project.held = [.init(name: ".env", reason: .looksSecret), .init(name: "big.bin", reason: .tooLarge)]
        let before = BackendCodeBackupWords.summary(project, now: Date())
        #expect(before.contains("1 secret file not sent to GitHub"))
        var status = BackendProjectSecretFilesStatus()
        status.projects = [.init(id: "p1", name: "Shop", files: [.init(folder: "", path: ".env", bytes: 10, at: 1, from: "Mac mini",
                                                                        state: BackendProjectSecretFilesWords.travels, travels: true)])]
        let report = BackendProjectSecretFilesWords.decorate(.init(projects: [project], signedInToGitHub: true, checkedAt: 0), status: status)
        let after = BackendCodeBackupWords.summary(report.projects[0], now: Date())
        #expect(after.contains("1 secret file travels with your saved passwords"))
        #expect(!after.contains("not sent to GitHub"))
        #expect(after.contains("1 file too large"))
        // Review 14 Nov (F11): a file that ARRIVED from another device travels too; it is not "not sent to GitHub".
        status.projects = [.init(id: "p1", name: "Shop", files: [.init(folder: "", path: ".env", bytes: 10, at: 1, from: "Mac mini",
                                                                        state: BackendProjectSecretFilesWords.arrived("Mac mini"), travels: true)])]
        let arrived = BackendCodeBackupWords.summary(BackendProjectSecretFilesWords.decorate(.init(projects: [project], signedInToGitHub: true, checkedAt: 0),
                                                                                              status: status).projects[0], now: Date())
        #expect(arrived.contains("1 secret file travels with your saved passwords"))
        #expect(!arrived.contains("not sent to GitHub"))
    }

    @Test func theToolAnswersNamesAndDatesNeverContent() throws {
        var status = BackendProjectSecretFilesStatus()
        status.projects = [.init(id: "p1", name: "Shop", files: [.init(folder: "", path: ".env", bytes: 10, at: 1_900_000_000_000, from: "Mac mini",
                                                                        state: BackendProjectSecretFilesWords.travels, travels: true)])]
        let answer = BackendProjectSecretFilesTools.answer(status)
        let text = String(decoding: try answer.encodedJSON(), as: UTF8.self)
        #expect(text.contains("\".env\""))
        #expect(text.contains("Shop"))
        #expect(!text.contains("p1"))
        #expect(BackendProjectSecretFilesTools.pageIDs == ["cloud.project_secrets"])
    }

    // MARK: Review 14 Nov fixes (F1 to F11)

    /// F8: a Mac of the same account holds the shared key, so its forged records carry the RIGHT name and fingerprint;
    /// the path rules themselves refuse them.
    @Test func forgedRecordsWithCorrectNamesAreRefusedByThePathRules() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let b = try await f.mac("MacBook")
        for path in ["../.env", "/etc/.env", ".git/hooks/x.env", ".git/.env", "a/.ssh/config.env", "a/.aws/credentials", "id_rsa", "id_ed25519",
                     "node_modules/pkg/.env", "README.md", "a/b/c/d/e/f/g/.env", BackendProjectSecretFilesRules.temporaryName()] {
            await #expect(throws: CloudFailure.invalidRequest) { try await b.validate(try f.forged(path, "X=1\n")) }
        }
        #expect(f.read(f.base.appendingPathComponent("MacBook/Projects/.env")) == nil)
        // The same name check passes for a clean path: the refusals above are the path rules, not the name.
        try await b.validate(try f.forged(".env", "X=1\n"))
    }

    /// F1: an arriving file never widens anything. New: owner-only. Replacing his file: his permission stays.
    @Test func anArrivingFileNeverWidensPermissions() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini"), b = try await f.mac("MacBook")
        try f.write("Mac mini", ".env", "TOKEN=one\n", mode: 0o666)
        #expect(try await f.deliver(try await a.capture(), to: b) == [.applied])
        #expect(f.mode("MacBook", ".env") == 0o600)
        chmod(f.folder("MacBook").appendingPathComponent(".env").path, 0o640)
        try f.write("Mac mini", ".env", "TOKEN=two\n", mode: 0o666)
        #expect(try await f.deliver(try await a.capture(), to: b) == [.applied])
        #expect(f.read("MacBook", ".env") == "TOKEN=two\n")
        #expect(f.mode("MacBook", ".env") == 0o640)
        // A sender's 0777 is not believed either.
        #expect(try await f.deliver([try f.forged("secrets.json", "{}", mode: 0o777)], to: b) == [.applied])
        #expect(f.mode("MacBook", "secrets.json") == 0o600)
    }

    /// F2: files that run programs never travel and are never created on arrival; an .npmrc travels only with
    /// registry and sign-in lines, checked on both sides.
    @Test func filesThatRunProgramsNeverTravelOrArrive() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini"), b = try await f.mac("MacBook")
        try f.write("Mac mini", ".envrc", "export X=1\n")
        try f.write("Mac mini", ".yarnrc.yml", "yarnPath: ./credentials\n")
        try f.write("Mac mini", ".npmrc", "# mine\nregistry=https://registry.example.test/\r\n@shop:registry=https://npm.example.test/\n//npm.example.test/:_authToken=abc\n\nalways-auth=true\n")
        try f.write("Mac mini", "tools/.npmrc", "registry=https://registry.example.test/\nscript-shell=/tmp/run\n")
        try f.write("Mac mini", "ops/.netrc", "machine x login y password z\nmacdef init\n")
        try f.write("Mac mini", "ops/credentials", "[default]\ncredential_process = /tmp/run\n")
        let sent = try await a.capture()
        #expect(try f.paths(sent) == [".npmrc"])
        let held = try #require(await a.status()).projects.flatMap(\.files).filter { $0.state == BackendProjectSecretFilesWords.staysHere }.map(\.path)
        #expect(Set(held) == [".envrc", ".yarnrc.yml", "tools/.npmrc", "ops/.netrc", "ops/credentials"])
        // Arrival: the receiving Mac's own rule refuses them, counts and names them; nothing is created; one bad file
        // does not stop the good one.
        let bad = [try f.forged(".envrc", "export X=1\n"), try f.forged(".yarnrc.yml", "yarnPath: ./x\n"),
                   try f.forged("other/.npmrc", "node-options=--require ./x\n")]
        #expect(try await f.deliver(bad + sent, to: b) == [.alreadyPresent, .alreadyPresent, .alreadyPresent, .applied])
        #expect(f.read("MacBook", ".envrc") == nil)
        #expect(f.read("MacBook", ".yarnrc.yml") == nil)
        #expect(f.read("MacBook", "other/.npmrc") == nil)
        #expect(f.read("MacBook", ".npmrc") != nil)
        let status = try #require(await b.status())
        #expect(status.refusedArrivals == 3)
        #expect(status.projects.flatMap(\.files).filter { $0.state == BackendProjectSecretFilesWords.refusedPrograms }.count == 3)
        // The allow-list itself.
        let rules = BackendProjectSecretFilesRules.self
        #expect(rules.npmrcTravels(Data("//r.example.test/:_password=x\n//r.example.test/:username=me\n//r.example.test/:email=a@b.test\n; c\n".utf8)))
        #expect(!rules.npmrcTravels(Data("email=a@b.test\n".utf8)))
        #expect(!rules.npmrcTravels(Data("onload-script=./x\n".utf8)))
        #expect(!rules.npmrcTravels(Data("[section]\nregistry=x\n".utf8)))
        #expect(!rules.npmrcTravels(Data("registry\n".utf8)))
        #expect(!rules.npmrcTravels(Data("//r.example.test/:certfile=./x\n".utf8)))
        // R2: netrc readers split on ',' and undo quotes and '\': each of these still runs a macro, so it stays.
        for text in ["default,macdef init\n", "\"macdef\" init\n", "mac\\def init\n"] {
            #expect(rules.verdict("ops/.netrc", bytes: Data(("machine x login y password z\n" + text).utf8)) == .staysHere)
        }
    }

    /// F3: the temporary file's name is one the Code page's own secret check holds back (so a crash can never send a
    /// secret to GitHub), the Cloud folder never sends it either, it never travels, and stale ones are cleared.
    @Test func theTemporaryFileIsHeldBackAndStaleOnesAreCleared() async throws {
        let name = BackendProjectSecretFilesRules.temporaryName()
        #expect(BackendCodeBackupGitReader.isSecret(name))
        #expect(BackendCodeBackupGitReader.isSecret("apps/web/" + name))
        #expect(BackendCodeBackupGitReader.holdsBack("apps/web/" + name))
        #expect(CloudFolderRules.isSecret(name))
        #expect(BackendProjectSecretFilesRules.verdict(name, bytes: nil) == .never)
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini")
        let folder = f.folder("Mac mini").appendingPathComponent("apps")
        // R4: a write in progress carries the sender's (old) date as its last-changed date: still left alone.
        let fresh = folder.appendingPathComponent(BackendProjectSecretFilesRules.temporaryName())
        try f.write(fresh, "TOKEN=now\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: fresh.path)
        #expect(try await a.capture().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fresh.path))     // maybe being written right now: left alone
        // Ten minutes later it is a leftover and goes; a file of his with a similar name is never one.
        let his = folder.appendingPathComponent(".env.td-cloud-mine.local")
        try f.write(his, "TOKEN=his\n")
        #expect(!BackendProjectSecretFilesRules.isTemporary(his.lastPathComponent))
        _ = BackendProjectSecretFilesStore.walk(f.folder("Mac mini"), now: Int64(Date().timeIntervalSince1970 * 1000) + 600_000)
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: his.path))
        // A write that fails (his file changed) leaves no temporary file.
        try f.write("Mac mini", ".env", "TOKEN=mine\n")
        #expect(throws: CloudFailure.versionChanged) {
            try BackendProjectSecretFilesStore.write(f.folder("Mac mini"), ".env", bytes: Data("TOKEN=new\n".utf8), expecting: Data("TOKEN=old\n".utf8), at: 1)
        }
        #expect(f.temporaries(f.folder("Mac mini")).isEmpty)
        #expect(f.read("Mac mini", ".env") == "TOKEN=mine\n")
    }

    /// F4: every cap holds on arrival (40 files and 512 KB a project) and on the waiting list.
    @Test func theCapsHoldOnArrival() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let b = try await f.mac("MacBook")
        let many = try (0...40).map { try f.forged("s\($0)/.env", "N=\($0)\n") }
        let outcomes = try await f.deliver(many, to: b)
        #expect(outcomes.filter { $0 == .applied }.count == 40)
        #expect(outcomes.last == .alreadyPresent)
        #expect(f.read("MacBook", "s40/.env") == nil)
        #expect(try #require(await b.status()).refusedArrivals == 1)
        // Bytes: 16 files of 31 KB fit 512 KB, the 17th does not.
        let g = try ProjectSecretFilesFixture(); defer { g.close() }
        let c = try await g.mac("MacBook")
        let big = String(repeating: "A", count: 31 * 1024)
        let large = try (0...16).map { try g.forged("b\($0)/.env", big) }
        let placed = try await g.deliver(large, to: c)
        #expect(placed.filter { $0 == .applied }.count == 16)
        #expect(placed.last == .alreadyPresent)
    }

    @Test func theWaitingListHasACap() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let b = try await f.mac("MacBook", folders: false)
        let many = try (0...40).map { try f.forged("s\($0)/.env", "N=\($0)\n") }
        #expect(try await f.deliver(many, to: b).allSatisfy { $0 == .alreadyPresent })
        let status = try #require(await b.status())
        #expect(status.projects.flatMap(\.files).filter { $0.state == BackendProjectSecretFilesWords.waitingFolder }.count == 40)
        #expect(status.refusedArrivals == 1)
        // A restart (a new store on the same state folder, same keys) keeps what waits, and places it once the folder exists.
        let again = try await f.mac("MacBook", folders: false)
        try f.makeProject(f.folder("MacBook"))
        _ = try await again.capture()
        #expect(f.read("MacBook", "s0/.env") == "N=0\n")
        #expect(f.read("MacBook", "s39/.env") == "N=39\n")
        #expect(f.read("MacBook", "s40/.env") == nil)
    }

    /// F5: two folders of one project with the same name: never a name clash, those folders are skipped and named,
    /// everything else (other folders, other projects) travels; on arrival never "the first folder".
    @Test func sameNamedFoldersAreSkippedAndEverythingElseTravels() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let two = "p-" + UUID().uuidString.lowercased().prefix(8)
        func layout(_ mac: String) throws -> [ProjectSecretFilesFixture.Project] {
            let root = f.base.appendingPathComponent(mac)
            for path in ["x/web", "y/web", "api", "blog"] {
                try f.makeProject(root.appendingPathComponent(path))
            }
            return [.init(id: f.projectId, name: "Shop", folders: ["x/web", "y/web", "api"].map { root.appendingPathComponent($0).path }),
                    .init(id: two, name: "Blog", folders: [root.appendingPathComponent("blog").path])]
        }
        let mine = try layout("Mac mini"), theirs = try layout("MacBook")
        let a = await f.store("Mac mini", projects: { mine }), b = await f.store("MacBook", projects: { theirs })
        let root = f.base.appendingPathComponent("Mac mini")
        try f.write(root.appendingPathComponent("x/web/.env"), "A=1\n")
        try f.write(root.appendingPathComponent("y/web/.env"), "B=1\n")
        try f.write(root.appendingPathComponent("api/.env"), "C=1\n")
        try f.write(root.appendingPathComponent("blog/.env"), "D=1\n")
        let sent = try await a.capture()
        #expect(Set(sent.map(\.recordId)).count == sent.count)
        #expect(try sent.map { try f.value($0) }.map { $0.folder + "|" + $0.path }.sorted() == ["api|.env", "|.env"].sorted())
        #expect(try #require(await a.status()).projects.flatMap(\.files).contains { $0.state == BackendProjectSecretFilesWords.sameName("web") })
        #expect(try await f.deliver(sent, to: b) == [.applied, .applied])
        let there = f.base.appendingPathComponent("MacBook")
        #expect(f.read(there.appendingPathComponent("api/.env")) == "C=1\n")
        #expect(f.read(there.appendingPathComponent("blog/.env")) == "D=1\n")
        // A record for "web" (from a Mac where only one folder has that name) waits here: never the first of the two.
        #expect(try await f.deliver([try f.forged(".env", "W=1\n", folder: "web")], to: b) == [.alreadyPresent])
        #expect(f.read(there.appendingPathComponent("x/web/.env")) == nil)
        #expect(f.read(there.appendingPathComponent("y/web/.env")) == nil)
        #expect(try #require(await b.status()).projects.flatMap(\.files).contains { $0.state == BackendProjectSecretFilesWords.waitingSameName("web") })
    }

    /// R1: a record that names a folder never lands in this Mac's one folder of another name; it waits and is named.
    @Test func aRecordForAnotherFolderNeverLandsInTheOnlyFolderHere() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let b = try await f.mac("MacBook")
        #expect(try await f.deliver([try f.forged(".env", "API=1\n", folder: "api")], to: b) == [.alreadyPresent])
        #expect(f.read("MacBook", ".env") == nil)
        #expect(try #require(await b.status()).projects.flatMap(\.files).contains { $0.state == BackendProjectSecretFilesWords.waitingFolder })
        // The same name (any letter case) is placed.
        #expect(try await f.deliver([try f.forged(".env", "SHOP=1\n", folder: "shop")], to: b) == [.applied])
        #expect(f.read("MacBook", ".env") == "SHOP=1\n")
    }

    /// F6: his projects are registered through links (`~/Projects/<name>` -> `code/<name>`): the ROOT is resolved once
    /// and works both ways; a link BELOW the root is still never followed, on send or on arrival.
    @Test func aProjectRegisteredThroughALinkWorksAndLinksBelowItStayRefused() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        func linked(_ mac: String) throws -> String {
            let real = f.base.appendingPathComponent(mac + "/code/Shop"), link = f.base.appendingPathComponent(mac + "/Projects/Shop")
            try f.makeProject(real)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../code/Shop")
            return link.path
        }
        let id = f.projectId
        let mine = try linked("Mac mini"), theirs = try linked("MacBook")
        let a = await f.store("Mac mini", projects: { [.init(id: id, name: "Shop", folders: [mine])] })
        let b = await f.store("MacBook", projects: { [.init(id: id, name: "Shop", folders: [theirs])] })
        try f.write(f.base.appendingPathComponent("Mac mini/code/Shop/.env"), "TOKEN=one\n")
        // A link below the root, to a folder outside: never followed.
        let outside = f.base.appendingPathComponent("outside")
        try f.write(outside.appendingPathComponent(".env"), "OUT=1\n")
        try FileManager.default.createSymbolicLink(atPath: f.base.appendingPathComponent("Mac mini/code/Shop/linked").path, withDestinationPath: outside.path)
        let sent = try await a.capture()
        #expect(try f.paths(sent) == [".env"])
        #expect(try await f.deliver(sent, to: b) == [.applied])
        #expect(f.read(f.base.appendingPathComponent("MacBook/code/Shop/.env")) == "TOKEN=one\n")
        // Arrival through a linked folder or onto a linked file below the root: nothing outside changes.
        try FileManager.default.createSymbolicLink(atPath: f.base.appendingPathComponent("MacBook/code/Shop/linked").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: f.base.appendingPathComponent("MacBook/code/Shop/.env.local").path,
                                                   withDestinationPath: outside.appendingPathComponent(".env").path)
        #expect(try await f.deliver([try f.forged("linked/.env", "EVIL=1\n"), try f.forged(".env.local", "EVIL=2\n")], to: b) == [.alreadyPresent, .alreadyPresent])
        #expect(f.read(outside.appendingPathComponent(".env")) == "OUT=1\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted() == [".env"])
    }

    /// F7: a project whose folder is the home folder, above it, or a whole disk: nothing travels, nothing is written.
    @Test func aHomeFolderOrAWholeDiskNeverTakesPart() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let home = f.folder("Mac mini")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try f.write("Mac mini", ".netrc", "machine x login y password z\n")
        for asHome in [home.path, home.appendingPathComponent("inner").path] {
            let a = try await f.mac("Mac mini", home: asHome)
            #expect(try await a.capture().isEmpty)
            #expect(try #require(await a.status()).projects.flatMap(\.files).contains { $0.state == BackendProjectSecretFilesWords.wholeFolder })
        }
        // R5: the home folder reached through a link, or under another path of the same disk, is the same folder.
        let link = f.base.appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: home.path)
        #expect(BackendProjectSecretFilesRules.realRoot(link.path, home: home.path) == .forbidden)
        #expect(BackendProjectSecretFilesRules.realRoot(home.path, home: link.path) == .forbidden)
        #expect(BackendProjectSecretFilesRules.realRoot(home.appendingPathComponent("inner").path, home: link.path) != .forbidden)
        let data = "/System/Volumes/Data" + home.path
        if FileManager.default.fileExists(atPath: data) {
            #expect(BackendProjectSecretFilesRules.realRoot(data, home: home.path) == .forbidden)
        }
        let id = f.projectId
        let disk = await f.store("Disk", projects: { [.init(id: id, name: "Disk", folders: ["/"])] })
        #expect(try await disk.capture().isEmpty)
        let b = try await f.mac("MacBook", home: f.folder("MacBook").path)
        #expect(try await f.deliver([try f.forged(".env", "X=1\n")], to: b) == [.alreadyPresent])
        #expect(f.read("MacBook", ".env") == nil)
        #expect(try #require(await b.status()).projects.flatMap(\.files).contains { $0.state == BackendProjectSecretFilesWords.waitingWholeFolder })
    }

    /// Item 3: his own edit that was not captured yet is never overwritten by a newer version from another device; a case
    /// clash is never overwritten either.
    @Test func hisUncapturedEditAndACaseClashAreKept() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let a = try await f.mac("Mac mini"), b = try await f.mac("MacBook")
        try f.write("Mac mini", ".env", "TOKEN=one\n")
        _ = try await f.deliver(try await a.capture(), to: b)
        try f.write("MacBook", ".env", "TOKEN=mine\n")      // not captured on the MacBook yet
        try f.write("Mac mini", ".env", "TOKEN=two\n")
        #expect(try await f.deliver(try await a.capture(), to: b) == [.keptBoth])
        #expect(f.read("MacBook", ".env") == "TOKEN=mine\n")
        try f.write("MacBook", "Secrets.json", "{\"his\":1}")
        #expect(try await f.deliver([try f.forged("secrets.json", "{\"x\":1}")], to: b) == [.keptBoth])
        #expect(f.read("MacBook", "Secrets.json") == "{\"his\":1}")
    }

    /// F13 and the key hand-over: the saved-passwords layer gives this store its keys (the test never does). Two Macs
    /// of one account, one key generation, each its own device: the same record names, a different holding key each.
    @Test func theSavedPasswordsLayerHandsThisStoreItsKeys() async throws {
        let f = try ProjectSecretFilesFixture(); defer { f.close() }
        let sub = CloudSecretsFixtureServer.sub
        let subject = CloudSubject(issuer: CloudWire.issuer, sub: sub)
        let policy = CloudSecretsPolicy(capabilities: {
            .init(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false, expiresAt: Int64(Date().timeIntervalSince1970 * 1000) + 200_000)
        })
        let recovery = try CloudRecoveryKeys(entropy: Data(repeating: 6, count: 32), sub: sub).publicKey
        let root = Data(repeating: 9, count: 32)
        func content(_ device: String) async throws -> CloudSecretsContent {
            let local = CloudSecretsFixtureLocal()
            try await local.saveVerified(.init(subject: subject, deviceId: device, epoch: 1, version: CloudSequence(1), root: root, recoveryPublicKey: recovery))
            return CloudSecretsContent(subject: subject, deviceId: device, local: local, policy: policy)
        }
        let deviceA = UUID().uuidString.lowercased(), deviceB = UUID().uuidString.lowercased()
        let contentA = try await content(deviceA), contentB = try await content(deviceB)
        let keysA = try await contentA.storeKeys(label: BackendProjectSecretFilesRules.sourceId, epoch: 1)
        let keysB = try await contentB.storeKeys(label: BackendProjectSecretFilesRules.sourceId, epoch: 1)
        #expect(keysA.shared(Data("id\nx".utf8)) == keysB.shared(Data("id\nx".utf8)))
        #expect(keysA.local.withUnsafeBytes { Data($0) } != keysB.local.withUnsafeBytes { Data($0) })
        let a = try await f.mac("Mac mini", keyed: false), b = try await f.mac("MacBook", keyed: false)
        func adapter(_ store: BackendProjectSecretFilesStore, _ content: CloudSecretsContent, _ device: String) -> CloudSecretsLogicalAdapter {
            CloudSecretsLogicalAdapter(store: store, content: content, policy: policy, deviceId: device,
                                       keepConflicts: { _ in throw CloudFailure.unavailable }, retainIncomingConflict: { _ in })
        }
        let sender = adapter(a, contentA, deviceA), receiver = adapter(b, contentB, deviceB)
        try f.write("Mac mini", ".env", "TOKEN=one\n")
        let records = try await sender.exportRecords()
        #expect(records.count == 1)
        let snapshot = try await sender.snapshot(records: records, cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:]))
        let prepared = try await receiver.validateIncoming(snapshot.operations, files: [])
        _ = try await receiver.applyPrepared(prepared, origin: .init(deviceId: deviceA, sequence: CloudSequence(1)))
        #expect(f.read("MacBook", ".env") == "TOKEN=one\n")
        #expect(f.mode("MacBook", ".env") == 0o600)
    }
}
