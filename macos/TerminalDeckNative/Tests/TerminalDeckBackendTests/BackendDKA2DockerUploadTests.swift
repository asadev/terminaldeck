import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// DKA2: files dropped on a container terminal are copied in like docker cp.
/// A fake Engine transport only; /usr/bin/tar reads the built archive back.
private actor BackendDKA2UploadEngine: BackendDockerTransport {
    private(set) var calls: [BackendDockerRequest] = []
    let existing: Set<String>
    init(existing: Set<String> = []) { self.existing = existing }
    func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse {
        calls.append(request)
        if request.path == "/version" {
            return .init(status: 200, headers: [:], body: Data(#"{"Version":"27.0.0","ApiVersion":"1.47","MinAPIVersion":"1.24","Os":"linux","Arch":"amd64"}"#.utf8))
        }
        if request.path.contains("/json") {
            return .init(status: 200, headers: [:], body: Data(#"{"Id":"box","Name":"/td-test-box","Config":{"Image":"x","WorkingDir":"/app","Env":[],"Labels":{}},"State":{"Status":"running"}}"#.utf8))
        }
        if request.method == "HEAD" {
            let path = URLComponents(string: "http://x" + request.path)?.queryItems?.first { $0.name == "path" }?.value ?? ""
            return .init(status: existing.contains(path) ? 200 : 404, headers: [:], body: Data())
        }
        return .init(status: 200, headers: [:], body: Data())
    }
    func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream { throw NativeRPCError(code: "unavailable", message: "none") }
    func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex { throw NativeRPCError(code: "unavailable", message: "none") }
}
private actor BackendDKA2Approvals {
    private(set) var actions: [BackendDockerAction] = []
    func add(_ action: BackendDockerAction) { actions.append(action) }
}

@Suite("Copying dropped files into a container")
struct BackendDKA2DockerUploadTests {
    private let context = NativeRPCContext(caller: .nativeApp, ownerID: "dka2-upload")
    private func service(_ engine: BackendDKA2UploadEngine, approvals: BackendDKA2Approvals, refuse: Bool = false) -> BackendDockerService {
        BackendDockerService(dependencies: .init(resolve: { _, _ in BackendDockerClient(transport: engine) },
            targets: { _ in [.init(id: "test-server", name: "Fixture", kind: "server", platform: "linux")] },
            authorize: { action, _ in
                guard action.writesServer else { return }
                await approvals.add(action)
                if refuse { throw NativeRPCError(code: "approval-required", message: "Ask first.") }
            }, install: nil))
    }
    private func request(_ files: [(String, String)]) -> NativeRPCValue {
        .object([.init("target", .string("test-server")), .init("id", .string("box")), .init("files", .array(files.map {
            .object([.init("name", .string($0.0)), .init("data", .string(Data($0.1.utf8).base64EncodedString()))])
        }))])
    }

    @Test func copiesIntoTheWorkingFolderAfterApprovalAndReturnsThePaths() async throws {
        let engine = BackendDKA2UploadEngine(), approvals = BackendDKA2Approvals(), registry = NativeChannelRegistry()
        let docker = service(engine, approvals: approvals)
        try await BackendDockerChannels.register(registry: registry, service: docker)
        let reply = try await registry.invoke("docker:containers:upload", context: context, arguments: [request([("notes.txt", "hello"), ("b.csv", "1,2")])])
        #expect(reply["ok"].bool == true && reply["folder"].string == "/app")
        #expect(reply["paths"] == .array([.string("/app/notes.txt"), .string("/app/b.csv")]))
        let approved = await approvals.actions
        #expect(approved.count == 1 && approved[0].channel == "docker:containers:upload" && approved[0].resourceID == "box")
        #expect(approved[0].parameters["folder"].string == "/app")
        #expect(approved[0].parameters.compact.contains("notes.txt") && !approved[0].parameters.compact.contains("aGVsbG8"), "the approval names files, never their contents")
        let put = try #require(await engine.calls.first { $0.method == "PUT" })
        #expect(put.path.contains("/containers/box/archive") && put.path.contains("path=%2Fapp") && put.headers["Content-Type"] == "application/x-tar")
        await docker.shutdown()
    }

    @Test func neverOverwritesAndNeverAsksWhenANameIsTaken() async throws {
        let engine = BackendDKA2UploadEngine(existing: ["/app/notes.txt"]), approvals = BackendDKA2Approvals(), registry = NativeChannelRegistry()
        let docker = service(engine, approvals: approvals)
        try await BackendDockerChannels.register(registry: registry, service: docker)
        do {
            _ = try await registry.invoke("docker:containers:upload", context: context, arguments: [request([("notes.txt", "hello")])])
            Issue.record("an existing file was overwritten")
        } catch let error as NativeRPCError { #expect(error.code == "docker-upload-exists" && error.message.contains("Nothing was copied")) }
        #expect(await approvals.actions.isEmpty)
        #expect(await engine.calls.allSatisfy { $0.method != "PUT" })
        await docker.shutdown()
    }

    @Test func refusedApprovalCopiesNothing() async throws {
        let engine = BackendDKA2UploadEngine(), approvals = BackendDKA2Approvals(), registry = NativeChannelRegistry()
        let docker = service(engine, approvals: approvals, refuse: true)
        try await BackendDockerChannels.register(registry: registry, service: docker)
        await #expect(throws: NativeRPCError.self) {
            _ = try await registry.invoke("docker:containers:upload", context: context, arguments: [request([("a.txt", "x")])])
        }
        #expect(await engine.calls.allSatisfy { $0.method != "PUT" })
        await docker.shutdown()
    }

    @Test func namesAndSizesAreBoundedBeforeAnything() throws {
        for bad in ["", ".", "..", "a/b", "line\nbreak", String(repeating: "x", count: 101)] {
            #expect(!BackendDockerUpload.validName(bad), "\(bad)")
        }
        #expect(BackendDockerUpload.validName("photo 1.png"))
        let twice = NativeRPCValue.array([.object([.init("name", .string("a")), .init("data", .string(""))]),
                                          .object([.init("name", .string("a")), .init("data", .string(""))])])
        #expect(throws: NativeRPCError.self) { _ = try BackendDockerUpload.files(twice) }
        #expect(throws: NativeRPCError.self) { _ = try BackendDockerUpload.files(.array([.object([.init("name", .string("a")), .init("data", .string("%%%"))])])) }
        #expect(throws: NativeRPCError.self) { _ = try BackendDockerUpload.files(.array([])) }
    }

    @Test func archiveIsAValidTarThatUnpacksToTheSameFiles() throws {
        let files = [BackendDockerUpload.File(name: "notes.txt", data: Data("hello\n".utf8)),
                     BackendDockerUpload.File(name: "empty", data: Data()),
                     BackendDockerUpload.File(name: "big.bin", data: Data(repeating: 7, count: 1_300))]
        let archive = BackendDockerUpload.tar(files, modified: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(archive.count % 512 == 0)
        let folder = BackendServersS4RealTemp.directory().appendingPathComponent("dka2-tar-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.tar")
        try archive.write(to: file)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", file.path, "-C", folder.path]
        try tar.run(); tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        for item in files { #expect(try Data(contentsOf: folder.appendingPathComponent(item.name)) == item.data) }
    }

    @Test func mcpToolIsAChangeWithNamesInItsSummary() throws {
        let tool = try #require(try BackendDockerMCP.definitions().first { $0.id == "docker.containers.upload" })
        #expect(tool.tier == .alter && BackendDockerMCP.changes(tool: "docker.containers.upload"))
        let args = NativeRPCValue.object([.init("target", .string("test-server")), .init("id", .string("box")),
            .init("files", .array([.object([.init("name", .string("notes.txt")), .init("data", .string(Data("x".utf8).base64EncodedString()))])]))])
        let summary = try BackendDockerMCP.summary(tool: "docker.containers.upload", arguments: args)
        #expect(summary.contains("notes.txt") && summary.contains("box"))
        #expect(try BackendDockerMCP.channel(tool: "docker.containers.upload") == "docker:containers:upload")
    }
}
