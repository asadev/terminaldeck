import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Opt-in only. DKA runs this after fresh passing fake evidence. Construction
/// starts no process; aliases, transport routes and mutations are all bounded.
final class BackendDockerMCPLiveSmokeTests: XCTestCase {
    func testOptInVolumeNetworkSmoke() async throws {
        let configuration = try BackendDockerMCPLiveSmokeConfiguration.load()
        try BackendDockerMCPLiveSmokeLog.validateWritable()
        let io = DKTLiveRunSession(target: configuration.target)
        let runID = UUID().uuidString.lowercased()
        let transport = BackendDockerMCPLiveSmokeTransport(target: configuration.target, session: io, runID: runID)
        let client = BackendDockerClient(transport: transport)
        let volumeName = "td-test-dka-smoke-" + runID + "-volume"
        let networkName = "td-test-dka-smoke-" + runID + "-network"
        let ledger = BackendDockerMCPLiveSmokeLedger()
        let trace = BackendDockerMCPLiveSmokeTrace()
        _ = try await DKTLiveRunHarness.run(target: configuration.target, evidence: configuration.evidence,
            inventory: {
                try await Self.inventory(client: client, target: configuration.target, session: io)
            }, body: { session in
                let status = try await client.status()
                guard status.os.lowercased() == "linux" else { throw DKTLiveSafetyRefusal("The approved alias did not report a Linux Docker engine.") }
                if configuration.target == .store {
                    try await Self.refuseEveryStoreWrite(session: session, transport: transport, name: volumeName, trace: trace)
                    return true
                }
                let volumes = try await client.listVolumes(), networks = try await client.listNetworks()
                guard !volumes.contains(where: { $0.name == volumeName }), !networks.contains(where: { $0.name == networkName }) else {
                    throw DKTLiveSafetyRefusal("A planned smoke name already exists. No existing resource will be touched.")
                }
                let volumeProof = DKTLiveResourceProof(kind: .volume, id: volumeName, name: volumeName)
                let networkProof = DKTLiveResourceProof(kind: .network, id: networkName, name: networkName)
                let labels = [BackendDockerMCPLiveSmokeTransport.runLabel: runID]
                let volume = try await session.perform(.mutation(channel: "docker:volumes:create", resources: [volumeProof])) {
                    await ledger.attemptVolume()
                    return try await BackendDockerMCPLiveSmokeScope.$mutation.withValue(volumeProof) {
                        try await client.createVolume(name: volumeName, labels: labels)
                    }
                }
                guard volume.name == volumeName, volume.labels[BackendDockerMCPLiveSmokeTransport.runLabel] == runID else {
                    throw DKTLiveSafetyRefusal("The created volume did not have this run's exact public name and label.")
                }
                let network = try await session.perform(.mutation(channel: "docker:networks:create", resources: [networkProof])) {
                    await ledger.attemptNetwork()
                    return try await BackendDockerMCPLiveSmokeScope.$mutation.withValue(networkProof) {
                        try await client.createNetwork(name: networkName, internalNetwork: true, labels: labels)
                    }
                }
                let currentVolumes = try await client.listVolumes(), currentNetworks = try await client.listNetworks()
                guard currentVolumes.contains(where: { $0.name == volumeName && $0.labels[BackendDockerMCPLiveSmokeTransport.runLabel] == runID }),
                      currentNetworks.contains(where: { $0.id == network.id && $0.name == networkName && $0.internalNetwork && $0.labels[BackendDockerMCPLiveSmokeTransport.runLabel] == runID }) else {
                    throw DKTLiveSafetyRefusal("The typed lists did not show both smoke resources with their exact ownership labels.")
                }
                return true
            }, cleanup: { session in
                guard configuration.target == .demo else { return }
                let attempted = await ledger.snapshot()
                var failed = false
                // Attempt both cleanups even when one request or inspection fails.
                if attempted.network {
                    do {
                        let candidates = try await client.listNetworks().filter { $0.name == networkName }
                        guard candidates.count <= 1 else { throw DKTLiveSafetyRefusal("Ambiguous smoke network ownership; no removal attempted.") }
                        if let row = candidates.first {
                            guard row.labels[BackendDockerMCPLiveSmokeTransport.runLabel] == runID else {
                                throw DKTLiveSafetyRefusal("The network with this smoke name belongs to another run; no removal attempted.")
                            }
                            let proof = DKTLiveResourceProof(kind: .network, id: row.id, name: row.name)
                            try await session.perform(.mutation(channel: "docker:networks:remove", resources: [proof])) {
                                try await BackendDockerMCPLiveSmokeScope.$mutation.withValue(proof) { try await client.removeNetwork(row.id) }
                            }
                        }
                    } catch { failed = true }
                }
                if attempted.volume {
                    do {
                        let candidates = try await client.listVolumes().filter { $0.name == volumeName }
                        guard candidates.count <= 1 else { throw DKTLiveSafetyRefusal("Ambiguous smoke volume ownership; no removal attempted.") }
                        if let row = candidates.first {
                            guard row.labels[BackendDockerMCPLiveSmokeTransport.runLabel] == runID else {
                                throw DKTLiveSafetyRefusal("The volume with this smoke name belongs to another run; no removal attempted.")
                            }
                            let proof = DKTLiveResourceProof(kind: .volume, id: row.name, name: row.name)
                            try await session.perform(.mutation(channel: "docker:volumes:remove", resources: [proof])) {
                                try await BackendDockerMCPLiveSmokeScope.$mutation.withValue(proof) { try await client.removeVolume(row.name, force: false) }
                            }
                        }
                    } catch { failed = true }
                }
                guard !failed else { throw DKTLiveSafetyRefusal("One or more owned smoke resources could not be safely removed. Stop and inspect LIVE-LOG.") }
            }, record: { entry in
                let calls = await io.actions
                let notes = await trace.notes
                try BackendDockerMCPLiveSmokeLog.append(.init(time: entry.time, target: entry.target,
                    whatRan: ["volume/network smoke attempt using DKE typed Docker HTTP over approved SSH alias"] + entry.whatRan + calls + notes,
                    before: entry.before, after: entry.after, cleanupPassed: entry.cleanupPassed, outcome: entry.outcome))
            })
    }

    private static func inventory(client: BackendDockerClient, target: DKTLiveTarget, session: DKTLiveRunSession) async throws -> DKTLiveInventory {
        // Raw bounded Engine bodies are used only by the existing inventory
        // collector. LIVE-LOG receives public identities and Caddy's hash.
        let containers = try await client.request("GET", path: "/containers/json", query: ["all": "true"])
        let images = try await client.request("GET", path: "/images/json")
        let volumes = try await client.request("GET", path: "/volumes")
        let networks = try await client.request("GET", path: "/networks")
        let caddy = try await session.perform(.read(channel: "apps:caddy:plan")) {
            try await BackendDockerMCPLiveSmokeSSH.read(target: target, command: BackendDockerMCPLiveSmokeSSH.caddyInventory)
        }
        let paths = try await session.perform(.read(channel: "apps:list")) {
            try await BackendDockerMCPLiveSmokeSSH.read(target: target, command: "sh -s", stdin: Data(BackendDockerMCPLiveSmokeSSH.pathInventory.utf8))
        }
        return try DKTLiveInventoryCollector.collect(.init(containers: containers.body, images: images.body,
            volumes: volumes.body, networks: networks.body, caddy: caddy, serverPaths: String(decoding: paths, as: UTF8.self)))
    }

    private static func refuseEveryStoreWrite(session: DKTLiveRunSession, transport: BackendDockerMCPLiveSmokeTransport, name: String, trace: BackendDockerMCPLiveSmokeTrace) async throws {
        let before = transport.openCount
        var refused = 0
        for channel in DKTLiveSafetyHarness.mutationChannels.sorted() {
            do {
                _ = try await session.perform(.mutation(channel: channel, resources: [.init(kind: .volume, id: name, name: name)])) { () async throws -> Bool in
                    throw DKTLiveSafetyRefusal("BUG: a store mutation reached its transport callback.")
                }
                throw DKTLiveSafetyRefusal("BUG: a store mutation unexpectedly succeeded.")
            } catch let error as DKTLiveSafetyRefusal {
                guard error.message.contains("terminaldeck-store is read-only") else { throw error }
                await trace.refused(channel)
                refused += 1
            }
        }
        for operation in [DKTLiveOperation.caddyRouteMutation(method: "POST", path: "/load", routeID: name, body: Data()), .filesystemMutation(paths: ["/tmp/" + name])] {
            do {
                _ = try await session.perform(operation) { () async throws -> Bool in throw DKTLiveSafetyRefusal("BUG: a store write reached its transport callback.") }
                throw DKTLiveSafetyRefusal("BUG: a store write unexpectedly succeeded.")
            } catch let error as DKTLiveSafetyRefusal {
                guard error.message.contains("terminaldeck-store is read-only") else { throw error }
                await trace.refused("Caddy/filesystem mutation category")
                refused += 1
            }
        }
        guard refused == DKTLiveSafetyHarness.mutationChannels.count + 2, transport.openCount == before else {
            throw DKTLiveSafetyRefusal("The store refusal checks contacted transport or failed to cover every mutation category.")
        }
    }
}

private actor BackendDockerMCPLiveSmokeLedger {
    private var volume = false, network = false
    func attemptVolume() { volume = true }
    func attemptNetwork() { network = true }
    func snapshot() -> (volume: Bool, network: Bool) { (volume, network) }
}

private actor BackendDockerMCPLiveSmokeTrace {
    private(set) var notes: [String] = []
    func refused(_ channel: String) { notes.append("refused before transport: " + channel) }
}

private enum BackendDockerMCPLiveSmokeScope {
    @TaskLocal static var mutation: DKTLiveResourceProof?
}

/// Every HTTP transport call enters the existing live harness. The allowlist
/// is intentionally narrower than Docker's API: this file cannot execute,
/// pull/build/remove images, mutate containers or change Caddy.
private final class BackendDockerMCPLiveSmokeTransport: BackendDockerTransport, @unchecked Sendable {
    typealias HTTP = @Sendable (DKTLiveTarget, BackendDockerRequest) async throws -> BackendDockerResponse
    static let runLabel = "terminaldeck.dka-smoke-run"
    private let target: DKTLiveTarget, session: DKTLiveRunSession
    private let runID: String
    private let fakeHTTP: HTTP?
    private let lock = NSLock()
    private var opens = 0
    init(target: DKTLiveTarget, session: DKTLiveRunSession, runID: String, fakeHTTP: HTTP? = nil) {
        self.target = target; self.session = session; self.runID = runID; self.fakeHTTP = fakeHTTP
    }
    var openCount: Int { lock.withLock { opens } }
    func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse {
        guard await session.target == target else { throw DKTLiveSafetyRefusal("The live smoke guard belongs to another target.") }
        let operation = try operation(request)
        return try await session.perform(operation) { [self] in
            if let fakeHTTP {
                lock.withLock { opens += 1 }
                return try await fakeHTTP(target, request)
            }
            let http = BackendDockerSSHTransport(openDialStdio: { [self] command in
                guard command == BackendDockerSSHTransport.command else { throw DKTLiveSafetyRefusal("Only Docker's fixed dial-stdio command is allowed.") }
                lock.withLock { opens += 1 }
                return try BackendDockerMCPLiveSmokeSSH.open(target: target, command: command)
            })
            return try await http.request(request)
        }
    }
    func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream { throw DKTLiveSafetyRefusal("Live smoke streams are outside this bounded slice.") }
    func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex { throw DKTLiveSafetyRefusal("Live smoke terminal execution is forbidden.") }
    private func operation(_ request: BackendDockerRequest) throws -> DKTLiveOperation {
        let parts = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? ""
        let query = parts.count == 2 ? String(parts[1]) : ""
        var route = path.split(separator: "/").map(String.init)
        if let first = route.first, first.range(of: #"^v[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil { route.removeFirst() }
        if request.method == "GET" {
            switch route {
            case ["version"]: return .read(channel: "docker:status")
            case ["containers", "json"]: return .read(channel: "docker:containers:list")
            case ["images", "json"]: return .read(channel: "docker:images:list")
            case ["volumes"]: return .read(channel: "docker:volumes:list")
            case ["networks"]: return .read(channel: "docker:networks:list")
            default: throw DKTLiveSafetyRefusal("This live smoke HTTP read is not allowlisted.")
            }
        }
        guard let proof = BackendDockerMCPLiveSmokeScope.mutation else { throw DKTLiveSafetyRefusal("A live smoke HTTP write has no inspected/planned ownership proof.") }
        if request.method == "POST", route == ["volumes", "create"] || route == ["networks", "create"] {
            let body = try NativeRPCValue.parseJSON(request.body, maximumBytes: 16384)
            let kind: DKTLiveResourceProof.Kind = route[0] == "volumes" ? .volume : .network
            let keys: Set<String> = kind == .volume ? ["Name", "Driver", "Labels"] : ["Name", "Driver", "Internal", "Labels"]
            guard proof.kind == kind, proof.name == body["Name"].string,
                  query.isEmpty, let fields = body.fields, Set(fields.map(\.key)) == keys, fields.count == keys.count,
                  body["Labels"].fields?.count == 1, body["Labels"][Self.runLabel].string == runID,
                  body["Driver"].string == (kind == .volume ? "local" : "bridge"),
                  kind != .network || body["Internal"].bool == true else { throw DKTLiveSafetyRefusal("The live smoke create payload does not match its owned name, fixed driver or isolated network.") }
            return .mutation(channel: kind == .volume ? "docker:volumes:create" : "docker:networks:create", resources: [proof])
        }
        if request.method == "DELETE", route.count == 2 {
            guard let id = route[1].removingPercentEncoding, id == proof.id,
                  request.body.isEmpty,
                  route[0] == "volumes" && proof.kind == .volume && query == "force=false" || route[0] == "networks" && proof.kind == .network && query.isEmpty else {
                throw DKTLiveSafetyRefusal("The live smoke deletion does not match the freshly inspected resource identity.")
            }
            return .mutation(channel: proof.kind == .volume ? "docker:volumes:remove" : "docker:networks:remove", resources: [proof])
        }
        throw DKTLiveSafetyRefusal("This live smoke HTTP mutation is forbidden.")
    }
}

/// Reuses the production Swift SSH process owner with the same fixed alias and
/// batch/no-retry settings as DKT's private readiness probe. No credential read.
private enum BackendDockerMCPLiveSmokeSSH {
    static func open(target: DKTLiveTarget, command: String) throws -> BackendServersSSHProcess {
        guard command == BackendDockerSSHTransport.command || command == caddyInventory || command == "sh -s" else {
            throw DKTLiveSafetyRefusal("This live smoke SSH command is outside the fixed allowlist.")
        }
        let channel = BackendServersSSHProcess(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
                        "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                        "-o", "ProxyCommand=none", "-o", "ProxyJump=none",
                        "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
                        "-o", "ControlMaster=no", "-o", "ControlPath=none", "-p", "22", "--", target.rawValue, command],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"])
        do { try channel.start() } catch { channel.close(); throw DKTLiveSafetyRefusal("The approved SSH alias could not start; no retry or interactive sign-in is attempted.") }
        _ = channel.stderr.listen { _ in }
        return channel
    }
    static func read(target: DKTLiveTarget, command: String, stdin: Data? = nil) async throws -> Data {
        guard command == caddyInventory || command == "sh -s" && stdin == Data(pathInventory.utf8) else {
            throw DKTLiveSafetyRefusal("Only the fixed read-only cleanup inventory commands are allowed.")
        }
        let channel = try open(target: target, command: command)
        defer { channel.close() }
        let result = try await channel.collect(stdin: stdin, timeoutMilliseconds: 30000, maximumOutputBytes: 2 * 1024 * 1024)
        guard result.code == 0, !result.truncated else { throw DKTLiveSafetyRefusal("The fixed live inventory read failed or exceeded its bound.") }
        return Data(result.stdout.utf8)
    }
    static let caddyInventory = "curl --noproxy '*' --max-time 10 --silent --fail http://127.0.0.1:2019/config/"
    static let pathInventory = #"""
    set -eu
    export LC_ALL=C
    root=/var/lib/terminaldeck/apps
    if test -d "$root"; then
      test -r "$root" && test -x "$root" || exit 1
      find "$root" -mindepth 1 -maxdepth 1 -type d -printf 'APP %f\n'
      find "$root" -mindepth 1 -maxdepth 5 -type d -printf 'FOLDER %p\n'
      find "$root" -mindepth 1 -maxdepth 5 -type f -path '*/backups/*' -printf 'BACKUP %p\n'
    fi
    find /tmp -mindepth 1 -maxdepth 1 -type d -name 'td-test-*' -printf 'FOLDER %p\n'
    if test -d /var/lib/terminaldeck; then
      find /var/lib/terminaldeck -mindepth 1 -maxdepth 1 -type d -name 'td-test-*' -printf 'FOLDER %p\n'
    fi
    find /var/lib -mindepth 1 -maxdepth 1 -type d -name 'td-test-*' -printf 'FOLDER %p\n'
    find /etc/systemd/system -mindepth 1 -maxdepth 1 -name 'td-test-*' -printf 'BACKUP %p\n'
    """#
}

private struct BackendDockerMCPLiveSmokeConfiguration: Sendable {
    let target: DKTLiveTarget, evidence: DKTFakeSuiteEvidence
    static func load() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DKA_DOCKER_LIVE_SMOKE_APPROVED"] == "1" else { throw XCTSkip("Docker live smoke is opt-in; no server contacted.") }
        guard environment["DKT_LIVE_RUN_OWNER"] == "DKA" else { throw DKTLiveSafetyRefusal("Only DKA may execute this live smoke suite.") }
        let target = try DKTLiveTarget.resolve(environment["DKA_DOCKER_LIVE_SMOKE_TARGET"] ?? "")
        guard let path = environment["DKT_LIVE_FAKE_EVIDENCE"], path.hasPrefix("/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, (1...65536).contains(size.intValue) else {
            throw DKTLiveSafetyRefusal("A bounded, readable absolute DKA fake-evidence file is required.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let evidence: DKTFakeSuiteEvidence
        do { evidence = try decoder.decode(DKTFakeSuiteEvidence.self, from: Data(contentsOf: URL(fileURLWithPath: path))) }
        catch { throw DKTLiveSafetyRefusal("The DKA fake-suite evidence file is invalid.") }
        try evidence.validate()
        guard evidence.logPath.hasPrefix("/"), FileManager.default.isReadableFile(atPath: evidence.logPath),
              let logAttributes = try? FileManager.default.attributesOfItem(atPath: evidence.logPath),
              let logSize = logAttributes[.size] as? NSNumber, logSize.intValue > 0 else {
            throw DKTLiveSafetyRefusal("Fake evidence must reference a nonempty, readable absolute DKA test log.")
        }
        return .init(target: target, evidence: evidence)
    }
}

private enum BackendDockerMCPLiveSmokeLog {
    private static let lock = NSLock()
    private static var path: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docker/LIVE-LOG.md")
    }
    static func validateWritable() throws {
        guard FileManager.default.fileExists(atPath: path.path), FileManager.default.isWritableFile(atPath: path.path) else {
            throw DKTLiveSafetyRefusal("The repository LIVE-LOG.md must already exist and be writable before server contact.")
        }
    }
    static func append(_ entry: DKTLiveRunRecord) throws {
        try lock.withLock {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            _ = try handle.seekToEnd(); try handle.write(contentsOf: Data(entry.markdown.utf8)); try handle.synchronize()
        }
    }
}

/// Pure guard tests inject HTTP so even an assertion/regression cannot launch
/// a process or reach either live alias. They need no opt-in environment.
@MainActor
final class BackendDockerMCPLiveSmokeGuardTests: XCTestCase {
    private let runID = "synthetic-guard-run"
    private func transport(_ target: DKTLiveTarget = .demo, guardTarget: DKTLiveTarget? = nil) -> BackendDockerMCPLiveSmokeTransport {
        .init(target: target, session: .init(target: guardTarget ?? target), runID: runID,
              fakeHTTP: { _, _ in .init(status: 200, headers: [:], body: Data("{}".utf8)) })
    }
    private func proof(_ kind: DKTLiveResourceProof.Kind = .volume) -> DKTLiveResourceProof {
        .init(kind: kind, id: kind == .network ? "network-canonical-id" : "td-test-guard-volume", name: kind == .network ? "td-test-guard-network" : "td-test-guard-volume")
    }
    private func body(_ kind: DKTLiveResourceProof.Kind = .volume, label: String? = nil) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("Name", .string(proof(kind).name)), .init("Driver", .string(kind == .network ? "bridge" : "local")),
            .init("Labels", .object([.init(BackendDockerMCPLiveSmokeTransport.runLabel, .string(label ?? runID))]))])
        if kind == .network { value = value.setting("Internal", .bool(true)) }
        return value
    }
    private func refused(_ transport: BackendDockerMCPLiveSmokeTransport, request: BackendDockerRequest,
                         proof: DKTLiveResourceProof) async {
        do {
            _ = try await BackendDockerMCPLiveSmokeScope.$mutation.withValue(proof) { try await transport.request(request) }
            XCTFail("A forbidden live-smoke request reached HTTP")
        } catch { XCTAssertTrue(error is DKTLiveSafetyRefusal) }
        XCTAssertEqual(transport.openCount, 0)
    }

    func testAnotherRunLabelIsRefusedBeforeHTTP() async throws {
        await refused(transport(), request: .init(method: "POST", path: "/v1.47/volumes/create", body: try body(label: "another-run").encodedJSON()), proof: proof())
    }
    func testDriverOptionsIPAMAndExtraLabelsAreRefusedBeforeHTTP() async throws {
        let volume = body().setting("Options", .object([.init("device", .string("/etc")), .init("type", .string("none")), .init("o", .string("bind"))]))
        await refused(transport(), request: .init(method: "POST", path: "/volumes/create", body: try volume.encodedJSON()), proof: proof())
        let network = body(.network).setting("IPAM", .object([.init("Driver", .string("default"))]))
        await refused(transport(), request: .init(method: "POST", path: "/networks/create", body: try network.encodedJSON()), proof: proof(.network))
        let extraLabel = body().setting("Labels", .object([.init(BackendDockerMCPLiveSmokeTransport.runLabel, .string(runID)), .init("extra", .string("not-allowed"))]))
        await refused(transport(), request: .init(method: "POST", path: "/volumes/create", body: try extraLabel.encodedJSON()), proof: proof())
    }
    func testForceDeletionAndUnexpectedBodiesOrQueriesAreRefusedBeforeHTTP() async {
        await refused(transport(), request: .init(method: "DELETE", path: "/volumes/td-test-guard-volume?force=true"), proof: proof())
        await refused(transport(), request: .init(method: "DELETE", path: "/volumes/td-test-guard-volume?force=false", body: Data("{}".utf8)), proof: proof())
        await refused(transport(), request: .init(method: "DELETE", path: "/networks/network-canonical-id?force=true"), proof: proof(.network))
    }
    func testStoreHTTPMutationIsRefusedByTheHarnessBeforeHTTP() async throws {
        await refused(transport(.store), request: .init(method: "POST", path: "/volumes/create", body: try body().encodedJSON()), proof: proof())
    }
    func testGuardCannotBeBorrowedFromDemoToContactStore() async throws {
        await refused(transport(.store, guardTarget: .demo), request: .init(method: "POST", path: "/volumes/create", body: try body().encodedJSON()), proof: proof())
    }
    func testOnlyBoundedVolumeNetworkPayloadsReachInjectedHTTP() async throws {
        let transport = transport()
        for kind in [DKTLiveResourceProof.Kind.volume, .network] {
            let current = proof(kind), collection = kind == .volume ? "volumes" : "networks"
            let create = BackendDockerRequest(method: "POST", path: "/v1.47/" + collection + "/create", body: try body(kind).encodedJSON())
            let created = try await BackendDockerMCPLiveSmokeScope.$mutation.withValue(current) { try await transport.request(create) }
            XCTAssertEqual(created.status, 200)
            let remove = BackendDockerRequest(method: "DELETE", path: "/v1.47/" + collection + "/" + current.id + (kind == .volume ? "?force=false" : ""))
            let removed = try await BackendDockerMCPLiveSmokeScope.$mutation.withValue(current) { try await transport.request(remove) }
            XCTAssertEqual(removed.status, 200)
        }
        XCTAssertEqual(transport.openCount, 4)
    }
}
