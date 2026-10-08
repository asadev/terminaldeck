import Foundation
import TerminalDeckNativeCore

/// Internal stream setup only. This type deliberately has no RPC conversion.
struct BackendDockerContainerStreamContext: Sendable {
    let tty: Bool
    let secretValues: [String]
}

/// Typed Engine API client. Construction is inert; the first explicit request negotiates /version.
/// Reference: https://docs.docker.com/reference/api/engine/version/v1.47/
/// Schema: https://raw.githubusercontent.com/moby/moby/v27.5.1/docs/api/v1.47.yaml
/// Negotiation: https://docs.docker.com/reference/api/engine/
public actor BackendDockerClient {
    public nonisolated let transport: any BackendDockerTransport
    public static let minimumAPIVersion = "1.41"
    public static let maximumAPIVersion = "1.47"
    private static let maximumJSONBytes = 16 * 1_024 * 1_024
    private var negotiatedVersion: String?

    public init(transport: any BackendDockerTransport) { self.transport = transport }

    /// Encode exactly one resource path segment; never concatenate user input into an HTTP path.
    public static func pathComponent(_ id: String, allowSlash: Bool = false) throws -> String { try identifier(id, allowSlash: allowSlash) }

    /// A deliberate status read refreshes Engine reachability. Each request belongs to its caller,
    /// so cancellation can close its transport without canceling another owner's request.
    public func status() async throws -> BackendDockerStatus {
        do {
            let status = try await Self.fetchStatus(transport: transport)
            try Task.checkCancellation()
            negotiatedVersion = status.apiVersion
            return status
        } catch {
            throw Self.safeError(error)
        }
    }

    /// For the stream/exec owners. Callers still own approval and stream lifecycle.
    public func requestDescriptor(_ method: String, path: String, query: [String: String] = [:],
                                  body: NativeRPCValue? = nil, headers: [String: String] = [:],
                                  timeoutMilliseconds: Int? = nil) async throws -> BackendDockerRequest {
        try Self.validatePath(path)
        if let timeoutMilliseconds, !(1...660_000).contains(timeoutMilliseconds) {
            throw NativeRPCError.invalidArguments("The Docker request timeout is invalid.")
        }
        guard ["GET", "POST", "DELETE", "PUT", "PATCH", "HEAD"].contains(method) else {
            throw NativeRPCError.invalidArguments("The Docker request method is invalid.")
        }
        var requestHeaders = headers
        var headerNames: Set<String> = []
        for (key, value) in headers {
            guard !key.isEmpty, key.utf8.allSatisfy({ Self.headerToken.contains($0) }),
                  !Self.containsControl(value), value.utf8.count <= 8_192,
                  headerNames.insert(key.lowercased()).inserted,
                  !["host", "content-length", "transfer-encoding", "authorization", "proxy-authorization"].contains(key.lowercased()) else {
                throw NativeRPCError.invalidArguments("The Docker request headers are invalid.")
            }
        }
        var queryParts: [String] = []
        for key in query.keys.sorted() {
            let value = query[key] ?? ""
            guard !key.isEmpty, !Self.containsControl(key), !Self.containsControl(value) else {
                throw NativeRPCError.invalidArguments("The Docker request query is invalid.")
            }
            queryParts.append("\(Self.encodeComponent(key))=\(Self.encodeComponent(value))")
        }
        let queryString = queryParts.joined(separator: "&")
        guard queryString.utf8.count <= 65_536 else { throw NativeRPCError.invalidArguments("The Docker request query is too large.") }
        let payload: Data
        if let body {
            do { payload = try body.encodedJSON() }
            catch { throw NativeRPCError.invalidArguments("The Docker request body is invalid.") }
            guard payload.count <= Self.maximumJSONBytes else { throw NativeRPCError.invalidArguments("The Docker request body is too large.") }
            for key in headers.keys where key.lowercased() == "content-type" { requestHeaders.removeValue(forKey: key) }
            requestHeaders["Content-Type"] = "application/json"
        } else { payload = Data() }
        if negotiatedVersion == nil { _ = try await status() }
        guard let negotiatedVersion else { throw Self.protocolError() }
        try Task.checkCancellation()
        let versionedPath = "/v\(negotiatedVersion)\(path)" + (queryString.isEmpty ? "" : "?\(queryString)")
        return BackendDockerRequest(method: method, path: versionedPath, headers: requestHeaders, body: payload, timeoutMilliseconds: timeoutMilliseconds)
    }

    /// Backend-only raw HTTP seam for exec and app-engine operations; channels use typed methods below.
    public func request(_ method: String, path: String, query: [String: String] = [:],
                        body: NativeRPCValue? = nil, timeoutMilliseconds: Int? = nil) async throws -> BackendDockerResponse {
        let descriptor = try await requestDescriptor(method, path: path, query: query, body: body, timeoutMilliseconds: timeoutMilliseconds)
        do {
            let response = try await transport.request(descriptor)
            try Task.checkCancellation()
            let parts = path.split(separator: "/")
            let unchanged = response.status == 304 && method == "POST" && parts.count == 3 && parts.first == "containers" && (parts.last == "start" || parts.last == "stop")
            guard (200..<300).contains(response.status) || unchanged else { throw Self.httpError(response.status) }
            guard response.body.count <= Self.maximumJSONBytes else { throw Self.protocolError() }
            return response
        } catch { throw Self.safeError(error) }
    }

    public func listContainers(all: Bool = true, filters: NativeRPCValue? = nil) async throws -> [BackendDockerContainer] {
        var query = ["all": all ? "true" : "false"]
        if let filters { query["filters"] = try Self.validatedFilters(filters).compact }
        return try Self.array(try await json("GET", path: "/containers/json", query: query)).map(Self.container)
    }

    public func inspectContainer(_ id: String) async throws -> BackendDockerContainerDetail {
        let raw = try await rawContainer(id)
        let config = try Self.optionalObject(raw["Config"])
        let state = try Self.optionalObject(raw["State"])
        let stateName = Self.stateName(try Self.optionalString(state["Status"]))
        let secrets = try Self.environmentSecrets(config["Env"])
        let healthValue = try Self.optionalString(try Self.optionalObject(state["Health"])["Status"])
        let health = healthValue.flatMap { ["starting", "healthy", "unhealthy"].contains($0) ? $0 : nil }
        let labels = try Self.dictionary(config["Labels"], masking: secrets)
        let configuredImage = try Self.optionalString(config["Image"])
        let fallbackImage = try Self.optionalString(raw["Image"])
        return BackendDockerContainerDetail(
            // Public resource identities remain canonical so destructive approvals name the actual thing.
            id: try Self.text(raw, "Id"), name: Self.containerName(try Self.text(raw, "Name")),
            image: Self.display(configuredImage ?? fallbackImage ?? "unknown", secrets: secrets), state: stateName,
            status: health.map { "\(stateName) (\($0))" } ?? stateName,
            created: try Self.timestamp(raw["Created"]), labels: labels, tty: try Self.optionalBool(config["Tty"]),
            environment: try Self.environmentNames(config["Env"]).map { BackendDockerEnvironment(name: $0) },
            mounts: try Self.optionalArray(raw["Mounts"]).map { mount in
                _ = try Self.object(mount)
                let type = try Self.text(mount, "Type")
                guard ["bind", "volume", "tmpfs", "npipe", "cluster"].contains(type) else { throw Self.protocolError() }
                return BackendDockerMount(type: type, name: try Self.optionalString(mount["Name"]).map { Self.display($0, secrets: secrets) },
                                          destination: Self.display(try Self.text(mount, "Destination"), secrets: secrets), readOnly: !(try Self.optionalBool(mount["RW"])))
            },
            ports: try Self.inspectedPorts(try Self.optionalObject(raw["NetworkSettings"])["Ports"], secrets: secrets)
        )
    }

    /// Raw environment values are only used to mask live data before it leaves the backend.
    func containerStreamContext(_ id: String) async throws -> BackendDockerContainerStreamContext {
        let raw = try await rawContainer(id)
        let config = try Self.optionalObject(raw["Config"])
        return try BackendDockerContainerStreamContext(tty: Self.optionalBool(config["Tty"]), secretValues: Self.environmentSecrets(config["Env"]))
    }

    func containerStreamConfiguration(id: String) async throws -> (tty: Bool, secretValues: [String]) {
        let context = try await containerStreamContext(id)
        return (context.tty, context.secretValues)
    }

    public func startContainer(_ id: String) async throws {
        _ = try await request("POST", path: "/containers/\(Self.identifier(id))/start")
    }
    public func stopContainer(_ id: String, timeoutSeconds: Int? = nil) async throws {
        let query = try Self.timeoutQuery(timeoutSeconds)
        // An omitted t preserves Docker's configured stop timeout. Defaults up to
        // 600 seconds are supported; larger/infinite defaults still have a finite deadline.
        let deadline = timeoutSeconds.map { max(30_000, ($0 + 15) * 1_000) } ?? 615_000
        _ = try await request("POST", path: "/containers/\(Self.identifier(id))/stop", query: query, timeoutMilliseconds: deadline)
    }
    public func restartContainer(_ id: String, timeoutSeconds: Int? = nil) async throws {
        let query = try Self.timeoutQuery(timeoutSeconds)
        let deadline = timeoutSeconds.map { max(30_000, ($0 + 15) * 1_000) } ?? 615_000
        _ = try await request("POST", path: "/containers/\(Self.identifier(id))/restart", query: query, timeoutMilliseconds: deadline)
    }
    public func removeContainer(_ id: String, force: Bool = false, removeVolumes: Bool = false) async throws {
        _ = try await request("DELETE", path: "/containers/\(Self.identifier(id))", query: ["force": String(force), "v": String(removeVolumes)])
    }

    public func listImages() async throws -> [BackendDockerImage] {
        try Self.array(try await json("GET", path: "/images/json")).map { try Self.image($0, inspected: false) }
    }
    public func inspectImage(_ id: String) async throws -> BackendDockerImage {
        try Self.image(try await json("GET", path: "/images/\(Self.identifier(id, allowSlash: true))/json"), inspected: true)
    }
    public func removeImage(_ id: String, force: Bool = false) async throws {
        _ = try await request("DELETE", path: "/images/\(Self.identifier(id, allowSlash: true))", query: ["force": String(force)])
    }

    public func listVolumes() async throws -> [BackendDockerVolume] {
        let value = try await json("GET", path: "/volumes")
        _ = try Self.object(value)
        // Docker explicitly represents an empty volume list as null.
        guard value.has("Volumes") else { throw Self.protocolError() }
        return try Self.optionalArray(value["Volumes"]).map(Self.volume)
    }
    public func inspectVolume(_ name: String) async throws -> BackendDockerVolume {
        try Self.volume(try await json("GET", path: "/volumes/\(Self.identifier(name))"))
    }
    public func createVolume(name: String, driver: String = "local", labels: [String: String] = [:]) async throws -> BackendDockerVolume {
        try Self.validateName(name); try Self.validateDriver(driver); try Self.validateLabels(labels)
        let body = Self.objectValue([("Name", .string(name)), ("Driver", .string(driver)), ("Labels", Self.labelValue(labels))])
        return try Self.volume(try await json("POST", path: "/volumes/create", body: body))
    }
    public func removeVolume(_ name: String, force: Bool = false) async throws {
        _ = try await request("DELETE", path: "/volumes/\(Self.identifier(name))", query: ["force": String(force)])
    }

    public func listNetworks() async throws -> [BackendDockerNetwork] {
        try Self.array(try await json("GET", path: "/networks")).map(Self.network)
    }
    public func inspectNetwork(_ id: String) async throws -> BackendDockerNetwork {
        try Self.network(try await json("GET", path: "/networks/\(Self.identifier(id))"))
    }
    public func createNetwork(name: String, driver: String = "bridge", internalNetwork: Bool = false,
                              labels: [String: String] = [:]) async throws -> BackendDockerNetworkCreation {
        try Self.validateName(name); try Self.validateDriver(driver); try Self.validateLabels(labels)
        let body = Self.objectValue([("Name", .string(name)), ("Driver", .string(driver)),
                                     ("Internal", .bool(internalNetwork)), ("Labels", Self.labelValue(labels))])
        let raw = try await json("POST", path: "/networks/create", body: body)
        let warning = raw["Warning"].string ?? ""
        // Engine warnings may embed driver options or host paths; never return their raw text.
        return BackendDockerNetworkCreation(id: try Self.text(raw, "Id"), warnings: warning.isEmpty ? [] : ["Docker returned a network configuration warning."])
    }
    public func removeNetwork(_ id: String) async throws {
        _ = try await request("DELETE", path: "/networks/\(Self.identifier(id))")
    }

    /// Compose's canonical labels are documented at https://docs.docker.com/reference/compose-file/services/#labels
    public func listComposeProjects() async throws -> [BackendDockerComposeProject] {
        let filter = Self.objectValue([("label", .array([.string("com.docker.compose.project")]))])
        let containers = try await listContainers(all: true, filters: filter)
        let grouped = Dictionary(grouping: containers.filter { !($0.labels["com.docker.compose.project"] ?? "").isEmpty }) {
            $0.labels["com.docker.compose.project"] ?? ""
        }
        return grouped.keys.sorted().map { name in Self.project(name, containers: grouped[name] ?? []) }
    }
    public func inspectComposeProject(_ name: String) async throws -> BackendDockerComposeProject {
        try Self.validateName(name)
        let filter = Self.objectValue([("label", .array([.string("com.docker.compose.project=\(name)")]))])
        let containers = try await listContainers(all: true, filters: filter).filter { $0.labels["com.docker.compose.project"] == name }
        guard !containers.isEmpty else { throw NativeRPCError(code: "docker-resource-missing", message: "The Docker Compose project no longer exists.") }
        return Self.project(name, containers: containers)
    }

    private func rawContainer(_ id: String) async throws -> NativeRPCValue {
        try await json("GET", path: "/containers/\(Self.identifier(id))/json")
    }
    private func json(_ method: String, path: String, query: [String: String] = [:], body: NativeRPCValue? = nil) async throws -> NativeRPCValue {
        let response = try await request(method, path: path, query: query, body: body)
        return try Self.parse(response.body)
    }

    private static func fetchStatus(transport: any BackendDockerTransport) async throws -> BackendDockerStatus {
        do {
            try Task.checkCancellation()
            let response = try await transport.request(BackendDockerRequest(method: "GET", path: "/version"))
            try Task.checkCancellation()
            guard (200..<300).contains(response.status) else { throw httpError(response.status) }
            let value = try parse(response.body)
            let maximum = try APIVersion(text(value, "ApiVersion"))
            let minimum = try APIVersion(optionalString(value["MinAPIVersion"]) ?? "1.12")
            let supportedMinimum = try APIVersion(minimumAPIVersion)
            let supportedMaximum = try APIVersion(maximumAPIVersion)
            let negotiated = min(maximum, supportedMaximum)
            guard minimum <= maximum, minimum <= negotiated, negotiated >= supportedMinimum else {
                throw NativeRPCError(code: "docker-api-version", message: "This Docker Engine API version is not supported.")
            }
            return BackendDockerStatus(version: try text(value, "Version"), apiVersion: negotiated.description,
                                       os: try text(value, "Os"), architecture: try text(value, "Arch"))
        } catch { throw safeError(error) }
    }

    private struct APIVersion: Comparable, Sendable, CustomStringConvertible {
        let major: Int; let minor: Int
        init(_ value: String) throws {
            let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let major = Int(pieces[0]), let minor = Int(pieces[1]), major > 0, major <= 99, minor <= 999 else {
                throw NativeRPCError(code: "docker-api-version", message: "Docker returned an invalid API version.")
            }
            self.major = major; self.minor = minor
        }
        var description: String { "\(major).\(minor)" }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.major == rhs.major ? lhs.minor < rhs.minor : lhs.major < rhs.major }
    }

    private static func container(_ value: NativeRPCValue) throws -> BackendDockerContainer {
        _ = try object(value)
        let names = try optionalArray(value["Names"]).map { try string($0) }
        return BackendDockerContainer(id: try text(value, "Id"), names: names, name: containerName(names.first ?? ""),
                                      image: try text(value, "Image"), imageId: try text(value, "ImageID"),
                                      state: stateName(try optionalString(value["State"])), status: display(try text(value, "Status")),
                                      created: try timestamp(value["Created"]), labels: try dictionary(value["Labels"]),
                                      ports: try optionalArray(value["Ports"]).map(port))
    }
    private static func image(_ value: NativeRPCValue, inspected: Bool) throws -> BackendDockerImage {
        _ = try object(value)
        let config = inspected ? try optionalObject(value["Config"]) : .object([])
        let secrets = inspected ? try environmentSecrets(config["Env"]) : []
        // Tags are canonical image identities, also used by exact-name deletion confirmations.
        let tags = try optionalArray(value["RepoTags"]).map { try string($0) }.filter { $0 != "<none>:<none>" }
        return BackendDockerImage(id: try text(value, "Id"), tags: tags, size: try number(value["Size"]),
                                  created: inspected && value["Created"].isNullish ? 0 : try timestamp(value["Created"]),
                                  labels: try dictionary(inspected ? config["Labels"] : value["Labels"], masking: secrets))
    }
    private static func volume(_ value: NativeRPCValue) throws -> BackendDockerVolume {
        _ = try object(value)
        return BackendDockerVolume(name: try text(value, "Name"), driver: try text(value, "Driver"),
                                   scope: try text(value, "Scope"), labels: try dictionary(value["Labels"]))
    }
    private static func network(_ value: NativeRPCValue) throws -> BackendDockerNetwork {
        _ = try object(value)
        return BackendDockerNetwork(id: try text(value, "Id"), name: try text(value, "Name"), driver: try text(value, "Driver"),
                                    scope: try text(value, "Scope"), internalNetwork: try optionalBool(value["Internal"]),
                                    labels: try dictionary(value["Labels"]))
    }
    private static func project(_ name: String, containers: [BackendDockerContainer]) -> BackendDockerComposeProject {
        let ordered = containers.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        let services = Set(ordered.compactMap { $0.labels["com.docker.compose.service"] }.filter { !$0.isEmpty }).sorted()
        return BackendDockerComposeProject(name: name, containers: ordered, services: services)
    }
    private static func port(_ value: NativeRPCValue) throws -> BackendDockerPort {
        _ = try object(value)
        let type = try text(value, "Type")
        guard ["tcp", "udp", "sctp"].contains(type) else { throw protocolError() }
        return BackendDockerPort(privatePort: try portNumber(value["PrivatePort"]),
                                 publicPort: value["PublicPort"].isNullish ? nil : try portNumber(value["PublicPort"]),
                                 type: type, ip: try optionalString(value["IP"]))
    }
    private static func inspectedPorts(_ value: NativeRPCValue, secrets: [String] = []) throws -> [BackendDockerPort] {
        if value.isNullish { return [] }
        let entries = try object(value).fields ?? []
        var ports: [BackendDockerPort] = []
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            let parts = entry.key.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let privatePort = Int(parts[0]), (1...65_535).contains(privatePort), ["tcp", "udp", "sctp"].contains(String(parts[1])) else {
                throw protocolError()
            }
            let bindings = try optionalArray(entry.value)
            if bindings.isEmpty { ports.append(BackendDockerPort(privatePort: privatePort, type: String(parts[1]))) }
            for binding in bindings {
                let hostPort = try text(binding, "HostPort")
                let ip = try optionalString(binding["HostIp"]).flatMap { $0.isEmpty ? nil : display($0, secrets: secrets) }
                if hostPort.isEmpty {
                    ports.append(BackendDockerPort(privatePort: privatePort, type: String(parts[1]), ip: ip)); continue
                }
                guard let publicPort = Int(hostPort), (1...65_535).contains(publicPort) else { throw protocolError() }
                ports.append(BackendDockerPort(privatePort: privatePort, publicPort: publicPort, type: String(parts[1]), ip: ip))
            }
        }
        return ports
    }

    private static func parse(_ data: Data) throws -> NativeRPCValue {
        do { return try NativeRPCValue.parseJSON(data, maximumBytes: maximumJSONBytes) }
        catch { throw protocolError() }
    }
    private static func object(_ value: NativeRPCValue) throws -> NativeRPCValue {
        guard value.fields != nil else { throw protocolError() }; return value
    }
    private static func optionalObject(_ value: NativeRPCValue) throws -> NativeRPCValue { value.isNullish ? .object([]) : try object(value) }
    private static func array(_ value: NativeRPCValue) throws -> [NativeRPCValue] {
        guard let elements = value.elements else { throw protocolError() }; return elements
    }
    private static func optionalArray(_ value: NativeRPCValue) throws -> [NativeRPCValue] {
        value.isNullish ? [] : try array(value)
    }
    private static func string(_ value: NativeRPCValue) throws -> String {
        guard let text = value.string else { throw protocolError() }; return text
    }
    private static func optionalString(_ value: NativeRPCValue) throws -> String? { value.isNullish ? nil : try string(value) }
    private static func optionalBool(_ value: NativeRPCValue) throws -> Bool {
        if value.isNullish { return false }
        guard let bool = value.bool else { throw protocolError() }; return bool
    }
    private static func text(_ value: NativeRPCValue, _ key: String) throws -> String { try string(value[key]) }
    private static func number(_ value: NativeRPCValue) throws -> Double {
        guard let number = value.number, number >= 0 else { throw protocolError() }; return number
    }
    private static func portNumber(_ value: NativeRPCValue) throws -> Int {
        let number = try number(value)
        guard number.rounded(.towardZero) == number, (1...65_535).contains(number) else { throw protocolError() }
        return Int(number)
    }
    private static func timestamp(_ value: NativeRPCValue) throws -> Double {
        if let number = value.number { return number }
        guard let text = value.string else { throw protocolError() }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { throw protocolError() }
        return date.timeIntervalSince1970
    }
    private static func dictionary(_ value: NativeRPCValue, masking secrets: [String] = []) throws -> [String: String] {
        if value.isNullish { return [:] }
        let fields = try object(value).fields ?? []
        var result: [String: String] = [:]
        for field in fields {
            result[display(field.key, secrets: secrets)] = display(try string(field.value), secrets: secrets)
        }
        return BackendDockerModelValues.safeLabels(result)
    }
    private static func environmentNames(_ value: NativeRPCValue) throws -> [String] {
        try optionalArray(value).map(string).compactMap { env in
            let name = String(env.prefix(while: { $0 != "=" }))
            guard let first = name.utf8.first, (65...90).contains(first) || (97...122).contains(first) || first == 95,
                  name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
            return name
        }
    }
    private static func environmentSecrets(_ value: NativeRPCValue) throws -> [String] {
        Array(Set(try optionalArray(value).map(string).compactMap { text -> String? in
            guard let equals = text.firstIndex(of: "=") else { return nil }
            let secret = String(text[text.index(after: equals)...]); return secret.isEmpty ? nil : secret
        })).sorted { $0.utf8.count > $1.utf8.count }
    }
    private static func containerName(_ name: String) -> String { String(name.drop(while: { $0 == "/" })) }
    private static func stateName(_ value: String?) -> String {
        let normalized = value?.lowercased() ?? "unknown"
        return ["created", "running", "paused", "restarting", "removing", "exited", "dead"].contains(normalized) ? normalized : "unknown"
    }
    private static func display(_ value: String, secrets: [String] = []) -> String { BackendDockerModelValues.safeDisplay(value, secretValues: secrets) }
    private static func objectValue(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    private static func labelValue(_ labels: [String: String]) -> NativeRPCValue { .object(labels.keys.sorted().map { .init($0, .string(labels[$0] ?? "")) }) }

    private static let unreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))
    private static let headerToken: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~".utf8))
    private static func encodeComponent(_ text: String) -> String {
        text.utf8.map { unreserved.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }
    private static func containsControl(_ text: String) -> Bool { text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 4_096,
              !path.contains("?"), !path.contains("#"), !path.contains("\\"), !containsControl(path),
              path.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
              let decoded = path.removingPercentEncoding, !containsControl(decoded), !decoded.contains("\\"), !decoded.contains("%"),
              !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
            throw NativeRPCError.invalidArguments("The Docker request path is invalid.")
        }
    }
    private static func identifier(_ id: String, allowSlash: Bool = false) throws -> String {
        guard !id.isEmpty, id.utf8.count <= 1_024, !containsControl(id), !id.contains("\\"),
              !id.contains("?"), !id.contains("#"), !id.contains("%"),
              (allowSlash || !id.contains("/")),
              !id.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw NativeRPCError.invalidArguments("The Docker resource identifier is invalid.")
        }
        return encodeComponent(id)
    }
    private static func timeoutQuery(_ timeout: Int?) throws -> [String: String] {
        guard let timeout else { return [:] }
        guard (0...600).contains(timeout) else { throw NativeRPCError.invalidArguments("The stop timeout must be between 0 and 600 seconds.") }
        return ["t": String(timeout)]
    }
    static func validateName(_ name: String) throws {
        guard let first = name.utf8.first, (65...90).contains(first) || (97...122).contains(first) || (48...57).contains(first),
              name.utf8.count <= 255, name.utf8.allSatisfy({ unreserved.contains($0) && $0 != 126 }) else {
            throw NativeRPCError.invalidArguments("Use a Docker name with letters, numbers, dots, dashes or underscores.")
        }
    }
    static func validateDriver(_ driver: String) throws {
        _ = try identifier(driver, allowSlash: true)
    }
    static func validateLabels(_ labels: [String: String]) throws {
        guard labels.count <= 256, labels.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 1_024 && $0.value.utf8.count <= 65_536 && !containsControl($0.key) }) else {
            throw NativeRPCError.invalidArguments("The Docker labels are invalid or too large.")
        }
    }
    static func validatedFilters(_ value: NativeRPCValue) throws -> NativeRPCValue {
        guard let fields = value.fields, fields.count <= 64 else { throw NativeRPCError.invalidArguments("Docker filters must be an object.") }
        var output: [NativeRPCValue.Field] = []
        for field in fields {
            guard !field.key.isEmpty, field.key.utf8.count <= 128, !containsControl(field.key) else { throw NativeRPCError.invalidArguments("A Docker filter name is invalid.") }
            let values: [String]
            if let elements = field.value.elements {
                guard elements.count <= 256, elements.allSatisfy({ $0.string != nil }) else { throw NativeRPCError.invalidArguments("Docker filters must contain arrays of strings.") }
                values = elements.compactMap(\.string)
            } else if let map = field.value.fields {
                guard map.count <= 256, map.allSatisfy({ $0.value.bool != nil }) else { throw NativeRPCError.invalidArguments("Docker filter maps must contain booleans.") }
                values = map.filter { $0.value.bool == true }.map(\.key)
            } else { throw NativeRPCError.invalidArguments("Docker filters must contain arrays of strings.") }
            guard values.allSatisfy({ $0.utf8.count <= 4_096 && !containsControl($0) }) else { throw NativeRPCError.invalidArguments("A Docker filter value is invalid.") }
            output.append(.init(field.key, .array(values.map(NativeRPCValue.string))))
        }
        return .object(output)
    }

    private static func protocolError() -> NativeRPCError { NativeRPCError(code: "docker-protocol", message: "Docker returned an invalid response.") }
    private static func httpError(_ status: Int) -> NativeRPCError {
        switch status {
        case 401, 403: NativeRPCError(code: "docker-permission", message: "Docker denied access to this operation.")
        case 404: NativeRPCError(code: "docker-resource-missing", message: "The Docker resource no longer exists.")
        default: NativeRPCError(code: "docker-api", message: "Docker could not complete this operation (HTTP \(status)).")
        }
    }
    private static func safeError(_ error: any Error) -> NativeRPCError {
        if Task.isCancelled || error is CancellationError { return NativeRPCError(code: "cancelled", message: "The Docker request was cancelled.") }
        if let error = error as? NativeRPCError {
            // Transport adapters are injected. Never forward their messages, details or SSH stderr.
            let message: String
            switch error.code {
            case "cancelled": message = "The Docker request was cancelled."
            case "docker-not-found": message = "Docker is not available on this target."
            case "docker-permission": message = "Docker denied access to this operation."
            case "docker-resource-missing": message = "The Docker resource no longer exists."
            case "docker-protocol": message = "Docker returned an invalid response."
            case "docker-api-version": message = "This Docker Engine API version is not supported."
            case "docker-api": message = "Docker could not complete this operation."
            case "docker-stream-overflow": message = "The Docker response exceeded the allowed size."
            case "invalid-arguments": message = "The Docker request is invalid."
            case "unavailable": message = "The Docker connection could not complete this request."
            default: return NativeRPCError(code: "unavailable", message: "The Docker connection could not complete this request.")
            }
            return NativeRPCError(code: error.code, message: message)
        }
        return NativeRPCError(code: "unavailable", message: "The Docker connection could not complete this request.")
    }
}
