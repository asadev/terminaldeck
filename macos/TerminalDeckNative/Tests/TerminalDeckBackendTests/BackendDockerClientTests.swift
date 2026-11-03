import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendDockerClientFixtureTransport: BackendDockerTransport {
    nonisolated let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    struct Reply: Sendable {
        let status: Int
        let body: String
        init(_ body: String = "", status: Int = 200) { self.status = status; self.body = body }
    }
    enum Failure: Error { case containsSecret }
    private let version: String
    private let routes: [String: Reply]
    private let fail: Bool
    private let refuseWithRPCError: Bool
    private let waitForCancellation: Bool
    private let waitPath: String?
    private let ignoreCancellation: Bool
    private let refuseAfterCancellation: Bool
    private(set) var requests: [BackendDockerRequest] = []
    init(version: String = BackendDockerClientFixtures.version, routes: [String: Reply] = [:], fail: Bool = false,
         refuseWithRPCError: Bool = false, waitForCancellation: Bool = false, waitPath: String? = nil, ignoreCancellation: Bool = false,
         refuseAfterCancellation: Bool = false) {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.started = stream.stream; self.startedContinuation = stream.continuation
        self.version = version; self.routes = routes; self.fail = fail
        self.refuseWithRPCError = refuseWithRPCError; self.waitForCancellation = waitForCancellation
        self.waitPath = waitPath; self.ignoreCancellation = ignoreCancellation
        self.refuseAfterCancellation = refuseAfterCancellation
    }
    func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse {
        requests.append(request)
        if fail { throw Failure.containsSecret }
        if refuseWithRPCError { throw NativeRPCError(code: "docker-permission", message: "SSH stderr fixture-secret", details: .string("private-key-fixture")) }
        let path = String(request.path.prefix(while: { $0 != "?" }))
        if waitForCancellation && (waitPath == nil || waitPath == path) {
            startedContinuation.yield(())
            if ignoreCancellation { try? await Task.sleep(for: .seconds(30)) }
            else { try await Task.sleep(for: .seconds(30)) }
            if refuseAfterCancellation { throw NativeRPCError(code: "docker-api", message: "cancelled-socket fixture-secret") }
        }
        if path == "/version" { return BackendDockerResponse(status: 200, headers: [:], body: Data(version.utf8)) }
        guard let reply = routes["\(request.method) \(path)"] else {
            return BackendDockerResponse(status: 404, headers: [:], body: Data(#"{"message":"fixture-secret"}"#.utf8))
        }
        return BackendDockerResponse(status: reply.status, headers: [:], body: Data(reply.body.utf8))
    }
    func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream {
        throw NativeRPCError(code: "unavailable", message: "The client fixture has no streams.")
    }
    func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex {
        throw NativeRPCError(code: "unavailable", message: "The client fixture has no terminal.")
    }
}

private enum BackendDockerClientFixtures {
    static let version = #"{"Version":"27.5.1","ApiVersion":"1.47","MinAPIVersion":"1.24","Os":"linux","Arch":"amd64"}"#
    static let containers = #"[{"Id":"c1","Names":["/sample"],"Image":"nginx:stable","ImageID":"sha256:image1","State":"running","Status":"Up 3 minutes","Created":1704067200,"Labels":{"com.docker.compose.project":"sample","com.docker.compose.service":"web","api_token":"fixture-secret"},"Ports":[{"PrivatePort":8080,"PublicPort":80,"Type":"tcp","IP":"127.0.0.1"}]}]"#
    static let detail = #"{"Id":"c1","Name":"/sample","Created":"2024-01-01T00:00:00.000000000Z","Config":{"Image":"nginx:stable","Tty":false,"Env":["PASSWORD=p@ss=word","PATH=/usr/local/bin","EMPTY=","BAD NAME=sensitive-name","NO_VALUE"],"Labels":{"description":"has p@ss=word","api-token":"opaque"},"Cmd":["secret command"]},"State":{"Status":"running","Health":{"Status":"healthy"},"Error":"fixture-secret"},"Mounts":[{"Type":"bind","Source":"/Users/asad/.ssh/id_rsa","Destination":"/run/key","RW":false},{"Type":"volume","Name":"sample-data","Source":"/var/lib/docker/volumes/sample-data/_data","Destination":"/data","RW":true}],"NetworkSettings":{"Ports":{"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"80"}],"9090/tcp":null}},"HostConfig":{"Binds":["/Users/asad/.ssh/id_rsa:/run/key"]}}"#
    static let images = #"[{"Id":"sha256:image1","RepoTags":["nginx:stable"],"Created":1704067200,"Size":2048,"Labels":{"password":"fixture-secret"}}]"#
    static let image = #"{"Id":"sha256:image1","RepoTags":["nginx:stable"],"Created":"2024-01-01T00:00:00Z","Size":2048,"Config":{"Env":["PASSWORD=fixture-secret"],"Labels":{"description":"fixture-secret"}}}"#
    static let volume = #"{"Name":"sample-data","Driver":"local","Scope":"local","Labels":{"secret":"fixture-secret"},"Mountpoint":"/private/hidden"}"#
    static let networks = #"[{"Id":"n1","Name":"sample-net","Driver":"bridge","Scope":"local","Internal":true,"Labels":{"credential":"fixture-secret"},"Containers":{"c1":{"Name":"fixture-secret"}}}]"#
    static let compose = #"[{"Id":"c1","Names":["/sample-web-1"],"Image":"nginx","ImageID":"i1","State":"running","Status":"Up","Created":1,"Labels":{"com.docker.compose.project":"sample","com.docker.compose.service":"web"},"Ports":[]},{"Id":"c2","Names":["/sample-db-1"],"Image":"postgres","ImageID":"i2","State":"exited","Status":"Exited","Created":2,"Labels":{"com.docker.compose.project":"sample","com.docker.compose.service":"db"},"Ports":[]},{"Id":"c3","Names":["/other"],"Image":"alpine","ImageID":"i3","State":"running","Status":"Up","Created":3,"Labels":{},"Ports":[]}]"#
}

@Suite("Typed Docker Engine client")
struct BackendDockerClientTests {
    @Test func constructingClientDoesNotConnectAndFirstRequestNegotiatesVersion() async throws {
        let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/json": .init(BackendDockerClientFixtures.containers)])
        let client = BackendDockerClient(transport: transport)
        #expect(await transport.requests.isEmpty)
        let rows = try await client.listContainers()
        let requests = await transport.requests
        #expect(requests.map(\.path) == ["/version", "/v1.47/containers/json?all=true"])
        #expect(rows.count == 1)
        #expect(rows.first?.name == "sample")
        #expect(rows.first?.names == ["/sample"])
        #expect(rows.first?.ports.first?.publicPort == 80)
        #expect(rows.first?.labels["api_token"] == BackendDockerModelValues.mask)
        #expect(rows.first?.value["imageId"].string == "sha256:image1")
    }

    @Test func negotiatesIntegerVersionsAgainstBothServerBounds() async throws {
        let newer = BackendDockerClientFixtureTransport(version: #"{"Version":"new","ApiVersion":"1.100","MinAPIVersion":"1.44","Os":"linux","Arch":"arm64"}"#)
        let newest = try await BackendDockerClient(transport: newer).status()
        #expect(newest.apiVersion == "1.47")
        #expect(newest.value["available"].bool == true)
        let older = BackendDockerClientFixtureTransport(version: #"{"Version":"old","ApiVersion":"1.41","MinAPIVersion":"1.12","Os":"linux","Arch":"amd64"}"#)
        #expect(try await BackendDockerClient(transport: older).status().apiVersion == "1.41")
        for version in [
            #"{"Version":"bad","ApiVersion":"1.40","MinAPIVersion":"1.12","Os":"linux","Arch":"amd64"}"#,
            #"{"Version":"bad","ApiVersion":"1.55","MinAPIVersion":"1.48","Os":"linux","Arch":"amd64"}"#,
            #"{"Version":"bad","ApiVersion":"1.47\r\nInjected","Os":"linux","Arch":"amd64"}"#,
        ] {
            do { _ = try await BackendDockerClient(transport: BackendDockerClientFixtureTransport(version: version)).status(); Issue.record("Expected version refusal") }
            catch let error as NativeRPCError { #expect(error.code == "docker-api-version") }
        }
    }

    @Test func encodesFiltersWithoutTurningTheirValuesIntoRequestParameters() async throws {
        let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/json": .init("[]")])
        let client = BackendDockerClient(transport: transport)
        let value = NativeRPCValue.object([.init("label", .array([.string("name=a&all=false#x"), .string("say \"hi\"/中")]))])
        _ = try await client.listContainers(all: false, filters: value)
        let path = await transport.requests.last?.path ?? ""
        #expect(path.hasPrefix("/v1.47/containers/json?all=false&filters="))
        #expect(!path.contains("#x"))
        #expect(path.contains("%26all%3Dfalse%23x"))
        let query = String(path.split(separator: "?", maxSplits: 1)[1])
        let encodedFilters = String(query.split(separator: "&")[1].dropFirst("filters=".count))
        let parsed = try NativeRPCValue.parseJSON(Data((encodedFilters.removingPercentEncoding ?? "").utf8))
        #expect(parsed == value)
        #expect(await transport.requests.count == 2)
    }

    @Test func malformedFiltersAreRejectedBeforeConnecting() async throws {
        let transport = BackendDockerClientFixtureTransport()
        let client = BackendDockerClient(transport: transport)
        for filter in [NativeRPCValue.string("label=x"), .object([.init("label", .array([.number(2)]))]), .object([.init("label", .array([.string("x\r\nInjected: yes")]))])] {
            do { _ = try await client.listContainers(filters: filter); Issue.record("Expected invalid filters") }
            catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func inspectMasksEnvironmentAndOmitsRawCredentialsCommandsAndHostPaths() async throws {
        let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/c1/json": .init(BackendDockerClientFixtures.detail)])
        let client = BackendDockerClient(transport: transport)
        let detail = try await client.inspectContainer("c1")
        #expect(detail.name == "sample")
        #expect(detail.created == 1704067200)
        #expect(detail.status == "running (healthy)")
        #expect(detail.environment.map(\.name) == ["PASSWORD", "PATH", "EMPTY", "NO_VALUE"])
        #expect(detail.environment.allSatisfy { $0.value["value"].string == BackendDockerModelValues.mask })
        #expect(detail.labels["description"] == "has ••••••")
        #expect(detail.mounts.count == 2)
        #expect(detail.mounts.first?.readOnly == true)
        #expect(detail.ports.count == 2)
        for secret in ["p@ss=word", "/usr/local/bin", "sensitive-name", "secret command", "/Users/asad/.ssh/id_rsa", "fixture-secret", "/var/lib/docker/volumes"] {
            #expect(!detail.value.compact.contains(secret))
        }
        let stream = try await client.containerStreamConfiguration(id: "c1")
        #expect(stream.tty == false)
        #expect(stream.secretValues.contains("p@ss=word"))
        #expect(!stream.secretValues.contains(""))
    }

    @Test func mutationsUseEngineVerbsAndOnlyExplicitDeleteOptions() async throws {
        let transport = BackendDockerClientFixtureTransport(routes: [
            "POST /v1.47/containers/c1/start": .init(status: 304),
            "POST /v1.47/containers/c1/stop": .init(status: 304),
            "POST /v1.47/containers/c1/restart": .init(status: 204),
            "DELETE /v1.47/containers/c1": .init(status: 204),
            "DELETE /v1.47/images/sha256%3Aimage1": .init("[]"),
            "DELETE /v1.47/volumes/sample-data": .init(status: 204),
            "DELETE /v1.47/networks/n1": .init(status: 204),
        ])
        let client = BackendDockerClient(transport: transport)
        try await client.startContainer("c1")
        try await client.stopContainer("c1", timeoutSeconds: 0)
        try await client.restartContainer("c1", timeoutSeconds: 30)
        try await client.removeContainer("c1")
        try await client.removeContainer("c1", force: true, removeVolumes: true)
        try await client.removeImage("sha256:image1")
        try await client.removeVolume("sample-data")
        try await client.removeNetwork("n1")
        let requests = await transport.requests
        #expect(requests.dropFirst().map(\.path) == [
            "/v1.47/containers/c1/start", "/v1.47/containers/c1/stop?t=0", "/v1.47/containers/c1/restart?t=30",
            "/v1.47/containers/c1?force=false&v=false", "/v1.47/containers/c1?force=true&v=true",
            "/v1.47/images/sha256%3Aimage1?force=false", "/v1.47/volumes/sample-data?force=false", "/v1.47/networks/n1",
        ])
        #expect(requests.dropFirst().allSatisfy { $0.body.isEmpty })
        #expect(requests[2].timeoutMilliseconds == 30_000)
        #expect(requests[3].timeoutMilliseconds == 45_000)
    }

    @Test func longStopTimeoutHasEnoughTransportTimeAndInvalidTimeoutsDoNotConnect() async throws {
        let transport = BackendDockerClientFixtureTransport(routes: ["POST /v1.47/containers/c1/stop": .init(status: 204), "POST /v1.47/containers/c1/restart": .init(status: 204)])
        let client = BackendDockerClient(transport: transport)
        try await client.stopContainer("c1", timeoutSeconds: 600)
        let descriptor = await transport.requests.last
        #expect(descriptor?.path == "/v1.47/containers/c1/stop?t=600")
        #expect(descriptor?.timeoutMilliseconds == 615_000)
        try await client.stopContainer("c1")
        let defaultStop = await transport.requests.last
        #expect(defaultStop?.path == "/v1.47/containers/c1/stop")
        #expect(defaultStop?.timeoutMilliseconds == 615_000)
        try await client.restartContainer("c1")
        let defaultRestart = await transport.requests.last
        #expect(defaultRestart?.path == "/v1.47/containers/c1/restart")
        #expect(defaultRestart?.timeoutMilliseconds == 615_000)
        let untouched = BackendDockerClientFixtureTransport()
        let invalid = BackendDockerClient(transport: untouched)
        do { try await invalid.restartContainer("c1", timeoutSeconds: 601); Issue.record("Expected timeout refusal") }
        catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        do { _ = try await invalid.requestDescriptor("GET", path: "/events", timeoutMilliseconds: 660_001); Issue.record("Expected request timeout refusal") }
        catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(await untouched.requests.isEmpty)
    }

    @Test func resourceReadsAndCreationReturnOnlyNormalizedFields() async throws {
        let transport = BackendDockerClientFixtureTransport(routes: [
            "GET /v1.47/images/json": .init(BackendDockerClientFixtures.images),
            "GET /v1.47/images/sha256%3Aimage1/json": .init(BackendDockerClientFixtures.image),
            "GET /v1.47/volumes": .init("{\"Volumes\":[\(BackendDockerClientFixtures.volume)],\"Warnings\":[]}"),
            "GET /v1.47/volumes/sample-data": .init(BackendDockerClientFixtures.volume),
            "POST /v1.47/volumes/create": .init(BackendDockerClientFixtures.volume, status: 201),
            "GET /v1.47/networks": .init(BackendDockerClientFixtures.networks),
            "GET /v1.47/networks/n1": .init(String(BackendDockerClientFixtures.networks.dropFirst().dropLast())),
            "POST /v1.47/networks/create": .init(#"{"Id":"n2","Warning":"fixture-secret /private/hidden"}"#, status: 201),
        ])
        let client = BackendDockerClient(transport: transport)
        let images = try await client.listImages()
        let image = try await client.inspectImage("sha256:image1")
        let volumes = try await client.listVolumes()
        let volume = try await client.inspectVolume("sample-data")
        _ = try await client.createVolume(name: "sample-data", labels: ["owner": "team"])
        let networks = try await client.listNetworks()
        let network = try await client.inspectNetwork("n1")
        let created = try await client.createNetwork(name: "sample-net", internalNetwork: true, labels: ["owner": "team"])
        #expect(images.first?.confirmationName == "nginx:stable")
        #expect(image.created == 1704067200)
        #expect(volumes.count == 1)
        #expect(networks.first?.internalNetwork == true)
        for result in [images.first?.value ?? .null, image.value, volumes.first?.value ?? .null, volume.value, network.value, created.value] {
            #expect(!result.compact.contains("fixture-secret"))
            #expect(!result.compact.contains("/private/hidden"))
        }
        let writes = await transport.requests.filter { $0.method == "POST" }
        let volumeBody = try NativeRPCValue.parseJSON(writes[0].body)
        let networkBody = try NativeRPCValue.parseJSON(writes[1].body)
        #expect(volumeBody["Driver"].string == "local")
        #expect(volumeBody["Labels"]["owner"].string == "team")
        #expect(networkBody["Driver"].string == "bridge")
        #expect(networkBody["Internal"].bool == true)
        #expect(writes.allSatisfy { $0.headers["Content-Type"] == "application/json" })
    }

    @Test func actualEmptyVolumesAreDistinctFromAnInvalidResponse() async throws {
        let empty = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/volumes": .init(#"{"Volumes":null,"Warnings":null}"#)])
        #expect(try await BackendDockerClient(transport: empty).listVolumes().isEmpty)
        let bad = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/volumes": .init("{}")])
        do { _ = try await BackendDockerClient(transport: bad).listVolumes(); Issue.record("Expected malformed volume response") }
        catch let error as NativeRPCError { #expect(error.code == "docker-protocol") }
    }

    @Test(arguments: [NativeRPCValue.null, .missing])
    func imageInspectionAcceptsUnknownCreationDateAndNullConfiguration(_ created: NativeRPCValue) async throws {
        let raw = NativeRPCValue.object([.init("Id", .string("i1")), .init("Size", .number(2_048)),
                                        .init("RepoTags", .null), .init("Config", .null), .init("Created", created)])
        let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/images/i1/json": .init(raw.compact)])
        let image = try await BackendDockerClient(transport: transport).inspectImage("i1")
        #expect(image.created == 0)
        #expect(image.tags.isEmpty)
        #expect(image.labels.isEmpty)
        #expect(image.confirmationName == "i1")
        // API v1.47 explicitly allows an absent ImageInspect.Created timestamp.
        #expect(image.value["created"].number == 0)
    }

    @Test func nullableContainerStateAndConfigurationDoNotInventRunningState() async throws {
        let raw = #"{"Id":"c1","Name":"/new","Image":"sha256:image1","Created":"2024-01-01T00:00:00Z","State":null,"Config":null,"Mounts":null,"NetworkSettings":{"Ports":{"80/tcp":[{"HostIp":"","HostPort":""}]}}}"#
        let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/c1/json": .init(raw)])
        let client = BackendDockerClient(transport: transport)
        let detail = try await client.inspectContainer("c1")
        #expect(detail.state == "unknown")
        #expect(detail.image == "sha256:image1")
        #expect(detail.environment.isEmpty)
        #expect(detail.ports.first?.privatePort == 80)
        #expect(detail.ports.first?.publicPort == nil)
        #expect(detail.ports.first?.ip == nil)
        let stream = try await client.containerStreamConfiguration(id: "c1")
        #expect(!stream.tty)
        #expect(stream.secretValues.isEmpty)
    }

    @Test func inspectMasksKnownEnvironmentValuesAcrossFreeFormDisplayFields() async throws {
        let raw = #"{"Id":"c1","Name":"/resource-name","Created":"2024-01-01T00:00:00Z","Config":{"Image":"registry/fixture-secret:latest","Tty":false,"Env":["PASSWORD=fixture-secret"],"Labels":{"prefix-fixture-secret":"value fixture-secret"}},"State":{"Status":"running","Health":{"Status":"fixture-secret"}},"Mounts":[{"Type":"volume","Name":"fixture-secret-data","Destination":"/fixture-secret","RW":true}],"NetworkSettings":{"Ports":null}}"#
        let image = #"{"Id":"i1","RepoTags":["registry/resource:latest"],"Size":1,"Created":null,"Config":{"Env":["PASSWORD=fixture-secret"],"Labels":{"url":"https://example.test/?api_key=fixture-secret"}}}"#
        let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/c1/json": .init(raw), "GET /v1.47/images/i1/json": .init(image)])
        let client = BackendDockerClient(transport: transport)
        let detail = try await client.inspectContainer("c1")
        #expect(!detail.value.compact.contains("fixture-secret"))
        #expect(detail.name == "resource-name")
        #expect(detail.status == "running")
        #expect(!(try await client.inspectImage("i1")).value.compact.contains("fixture-secret"))
        #expect(BackendDockerModelValues.safeDisplay("https://example.test/?apikey=hidden") == BackendDockerModelValues.mask)
    }

    @Test func canonicalIdentitiesRemainUsableForExactNameConfirmations() async throws {
        let raw = #"{"Id":"c1","Name":"/resource-name","Created":"2024-01-01T00:00:00Z","Config":{"Image":"alpine","Env":["SAME_TEXT=resource-name"],"Labels":{"description":"resource-name"}},"State":{"Status":"running"}}"#
        let image = #"{"Id":"i1","RepoTags":["registry/resource:latest"],"Created":null,"Size":1,"Config":{"Env":["SAME_TEXT=registry/resource:latest"]}}"#
        let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/c1/json": .init(raw), "GET /v1.47/images/i1/json": .init(image)])
        let client = BackendDockerClient(transport: transport)
        let container = try await client.inspectContainer("c1")
        let inspectedImage = try await client.inspectImage("i1")
        #expect(container.name == "resource-name")
        #expect(container.labels["description"] == BackendDockerModelValues.mask)
        #expect(container.environment.first?.value["value"].string == BackendDockerModelValues.mask)
        #expect(inspectedImage.confirmationName == "registry/resource:latest")
    }

    @Test func invalidInspectVariantsStillFailInsteadOfHidingMalformedEnvironment() async throws {
        let base = try NativeRPCValue.parseJSON(Data(BackendDockerClientFixtures.detail.utf8))
        for raw in [
            base.setting("Config", base["Config"].setting("Env", .string("PASSWORD=fixture-secret"))),
            base.setting("Config", .string("fixture-secret")),
            base.setting("State", base["State"].setting("Health", .string("fixture-secret"))),
        ] {
            let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/c1/json": .init(raw.compact)])
            do { _ = try await BackendDockerClient(transport: transport).inspectContainer("c1"); Issue.record("Expected invalid inspect response") }
            catch let error as NativeRPCError { #expect(error.code == "docker-protocol"); #expect(!error.message.contains("fixture-secret")) }
        }
    }

    @Test func preEpochCreationDatesRemainRealDatesAnd304IsOnlyForContainerStartStop() async throws {
        let raw = try NativeRPCValue.parseJSON(Data(BackendDockerClientFixtures.images.utf8))
        let beforeEpoch = NativeRPCValue.array((raw.elements ?? []).map { $0.setting("Created", .number(-1)) })
        let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/images/json": .init(beforeEpoch.compact), "POST /v1.47/exec/e1/start": .init(status: 304)])
        let client = BackendDockerClient(transport: transport)
        #expect(try await client.listImages().first?.created == -1)
        do { _ = try await client.request("POST", path: "/exec/e1/start"); Issue.record("Expected invalid exec response") }
        catch let error as NativeRPCError { #expect(error.code == "docker-api") }
    }

    @Test func composeGroupsOfficialLabelsAndDoesNotInventMissingProjects() async throws {
        let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/json": .init(BackendDockerClientFixtures.compose)])
        let client = BackendDockerClient(transport: transport)
        let projects = try await client.listComposeProjects()
        #expect(projects.count == 1)
        #expect(projects.first?.name == "sample")
        #expect(projects.first?.running == 1)
        #expect(projects.first?.total == 2)
        #expect(projects.first?.services == ["db", "web"])
        let project = try await client.inspectComposeProject("sample")
        #expect(project.total == 2)
        do { _ = try await client.inspectComposeProject("missing"); Issue.record("Expected missing Compose project") }
        catch let error as NativeRPCError { #expect(error.code == "docker-resource-missing") }
        let paths = await transport.requests.map(\.path)
        #expect(paths.contains { $0.contains("com.docker.compose.project%3Dsample") })
    }

    @Test(arguments: ["", "../anything", "c1/json", "c1?force=true", "c1#part", "c1\r\nHost: other", "%2e%2e", "c1\\json"])
    func identifiersCannotInjectAnotherPathOrHeader(_ id: String) async throws {
        let transport = BackendDockerClientFixtureTransport()
        let client = BackendDockerClient(transport: transport)
        do { _ = try await client.inspectContainer(id); Issue.record("Expected invalid identifier") }
        catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(await transport.requests.isEmpty)
    }

    @Test func descriptorsRejectTraversalControlsAndInjectedHeadersBeforeConnection() async throws {
        let transport = BackendDockerClientFixtureTransport()
        let client = BackendDockerClient(transport: transport)
        for path in ["/containers/../json", "/containers/%2e%2e/json", "/containers/%252e%252e/json", "/containers/%0d%0aHost/json", "//other/containers", "/containers/json?all=false"] {
            do { _ = try await client.requestDescriptor("GET", path: path); Issue.record("Expected invalid descriptor") }
            catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        }
        do { _ = try await client.requestDescriptor("GET", path: "/events", query: ["since": "1\r\nInjected: yes"]); Issue.record("Expected invalid query") }
        catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        do { _ = try await client.requestDescriptor("POST", path: "/exec/e1/start", headers: ["Upgrade": "tcp\r\nHost: other"]); Issue.record("Expected invalid headers") }
        catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        do { _ = try await client.requestDescriptor("POST", path: "/exec/e1/start", headers: ["Connection": "Upgrade", "connection": "close"]); Issue.record("Expected duplicate header refusal") }
        catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        do { try await client.stopContainer("c1", timeoutSeconds: -1); Issue.record("Expected invalid timeout") }
        catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(await transport.requests.isEmpty)
        #expect(try BackendDockerClient.pathComponent("sha256:container") == "sha256%3Acontainer")
        #expect(try BackendDockerClient.pathComponent("registry/repo:tag", allowSlash: true) == "registry%2Frepo%3Atag")
    }

    @Test func errorsNeverIncludeEngineBodiesOrTransportDiagnosticText() async throws {
        for (status, code) in [(403, "docker-permission"), (404, "docker-resource-missing"), (409, "docker-api"), (500, "docker-api")] {
            let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/json": .init(#"{"message":"PASSWORD=fixture-secret /private/key"}"#, status: status)])
            do { _ = try await BackendDockerClient(transport: transport).listContainers(); Issue.record("Expected Engine refusal") }
            catch let error as NativeRPCError { #expect(error.code == code); #expect(!error.wireValue.compact.contains("fixture-secret")); #expect(!error.message.contains("/private/key")) }
        }
        let malformed = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/json": .init("fixture-secret invalid-json")])
        do { _ = try await BackendDockerClient(transport: malformed).listContainers(); Issue.record("Expected malformed JSON") }
        catch let error as NativeRPCError { #expect(error.code == "docker-protocol"); #expect(!error.message.contains("fixture-secret")) }
        do { _ = try await BackendDockerClient(transport: BackendDockerClientFixtureTransport(fail: true)).status(); Issue.record("Expected transport failure") }
        catch let error as NativeRPCError { #expect(error.code == "unavailable"); #expect(!error.message.contains("containsSecret")) }
        do { _ = try await BackendDockerClient(transport: BackendDockerClientFixtureTransport(refuseWithRPCError: true)).status(); Issue.record("Expected injected RPC refusal") }
        catch let error as NativeRPCError { #expect(error.code == "docker-permission"); #expect(error.details == .missing); #expect(!error.wireValue.compact.contains("fixture-secret")) }
    }

    @Test func cancellingAStatusReadCancelsTheOwnedTransportRequest() async throws {
        let transport = BackendDockerClientFixtureTransport(waitForCancellation: true)
        let client = BackendDockerClient(transport: transport)
        var started = transport.started.makeAsyncIterator()
        let pending = Task { try await client.status() }
        // An event from the fake makes cancellation deterministic without polling.
        _ = await started.next()
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Expected cancellation") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(await transport.requests.count == 1)
    }

    @Test func aTransportIgnoringCancellationCannotReturnASuccessfulClientRead() async throws {
        let transport = BackendDockerClientFixtureTransport(routes: ["GET /v1.47/containers/json": .init("[]")],
                                                            waitForCancellation: true, waitPath: "/v1.47/containers/json", ignoreCancellation: true)
        let client = BackendDockerClient(transport: transport)
        _ = try await client.status()
        var started = transport.started.makeAsyncIterator()
        let pending = Task { try await client.listContainers() }
        _ = await started.next()
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Expected client cancellation after transport returned") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled") }
        #expect(await transport.requests.count == 2)
    }

    @Test func cancelledSocketFailuresStayCancellationInsteadOfAFalseEngineFailure() async throws {
        let transport = BackendDockerClientFixtureTransport(waitForCancellation: true, ignoreCancellation: true, refuseAfterCancellation: true)
        let client = BackendDockerClient(transport: transport)
        var started = transport.started.makeAsyncIterator()
        let pending = Task { try await client.status() }
        _ = await started.next()
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Expected owner cancellation") }
        catch let error as NativeRPCError { #expect(error.code == "cancelled"); #expect(!error.message.contains("fixture-secret")) }
    }
}
