import Foundation

struct DKTDockerTestResources: Sendable {
    let containerID: String
    let imageID: String
    let volumeName: String
    let networkID: String
}

/// Deliberately includes synthetic secrets in Engine data so channel redaction is testable.
/// State lives in this fixture, never in a user's Docker installation.
final class DKTDockerFake: @unchecked Sendable {
    static let containerID = "dkt-container-1"
    static let ttyContainerID = "dkt-tty-1"
    static let secret = "DKT-fixture-secret-7f8"
    static let imageID = "sha256:dkt-image-1"
    static let volumeName = "dkt-data"
    static let networkID = "dkt-network-1"

    let server: DKTUnixHTTPServer
    private let state: DKTDockerFakeState

    init(socketPath: String? = nil) {
        let state = DKTDockerFakeState()
        self.state = state
        server = DKTUnixHTTPServer(socketPath: socketPath) { state.respond(to: $0) }
    }

    var socketPath: String { server.socketPath }
    var requests: [DKTHTTPRequest] { server.requests }
    var activeConnectionCount: Int { server.activeConnectionCount }
    var hijackedBytes: [Data] { server.hijackedBytes }
    func start() throws { try server.start() }
    func stop() { server.stop() }
    func respond(to request: DKTHTTPRequest) -> DKTHTTPResponse { state.respond(to: request) }
    /// Canonical complete state permits before/after proof without touching a real server.
    func snapshotInventory() -> Data { state.snapshotInventory() }
    @discardableResult
    func seedTestResources(prefix: String = "td-test-dkt") -> DKTDockerTestResources { state.seedTestResources(prefix: prefix) }

    /// A path-only override matches negotiated API versions; a query override is exact.
    func setResponse(method: String, target: String, response: DKTHTTPResponse) {
        state.setResponse(method: method, target: target, response: response)
    }
    func clearResponses() { state.clearResponses() }
    func seedContainer(id: String, name: String, tty: Bool = false,
                       environment: [String: String] = [:], labels: [String: String] = [:], network: String? = nil) {
        state.seedContainer(id: id, name: name, tty: tty, environment: environment, labels: labels, network: network)
    }
    func seedImage(id: String, tags: [String], labels: [String: String] = [:]) {
        state.seedImage(id: id, tags: tags, labels: labels)
    }
    func seedNetwork(id: String, name: String, labels: [String: String] = [:], internalNetwork: Bool = false) {
        state.seedNetwork(id: id, name: name, labels: labels, internalNetwork: internalNetwork)
    }

    static func multiplexedFrame(stream: UInt8, payload: Data) -> Data {
        precondition(payload.count <= Int(UInt32.max), "A test log frame exceeds Docker's length field")
        let length = UInt32(payload.count)
        var bytes = Data([stream, 0, 0, 0, UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                          UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
        bytes.append(payload)
        return bytes
    }

    static func multiplexedFrame(stream: UInt8, text: String) -> Data {
        multiplexedFrame(stream: stream, payload: Data(text.utf8))
    }

    /// Splits bytes at explicit sizes, then appends the remainder. It may split UTF-8/header bytes.
    static func segmented(_ bytes: Data, sizes: [Int] = [1, 2, 4, 3, 1, 5, 2]) -> [Data] {
        var parts: [Data] = []
        var offset = 0
        for size in sizes where size > 0 && offset < bytes.count {
            let count = min(size, bytes.count - offset)
            parts.append(Data(bytes.dropFirst(offset).prefix(count)))
            offset += count
        }
        if offset < bytes.count { parts.append(Data(bytes.dropFirst(offset))) }
        return parts
    }
}

private final class DKTDockerFakeState: @unchecked Sendable {
    private let lock = NSLock()
    private var containers: [String: [String: Any]] = [:]
    private var images: [String: [String: Any]] = [:]
    private var volumes: [String: [String: Any]] = [:]
    private var networks: [String: [String: Any]] = [:]
    private var executions: [String: [String: Any]] = [:]
    private var overrides: [String: DKTHTTPResponse] = [:]
    private var sequence = 0

    init() {
        seedContainer(id: DKTDockerFake.containerID, name: "dkt-web", tty: false, environment: ["API_TOKEN": DKTDockerFake.secret, "LANG": "C.UTF-8"],
                      labels: ["com.docker.compose.project": "dkt-demo", "com.docker.compose.service": "web"])
        seedContainer(id: DKTDockerFake.ttyContainerID, name: "dkt-console", tty: true,
                      environment: ["API_TOKEN": DKTDockerFake.secret], labels: [:])
        images[DKTDockerFake.imageID] = ["Id": DKTDockerFake.imageID, "RepoTags": ["dkt/web:latest"], "Size": 1_048_576,
                                       "Created": 1_790_000_000, "Labels": ["dkt.fixture": "true"]]
        volumes[DKTDockerFake.volumeName] = Self.volume(name: DKTDockerFake.volumeName)
        networks[DKTDockerFake.networkID] = ["Id": DKTDockerFake.networkID, "Name": "dkt-private", "Driver": "bridge",
                                           "Scope": "local", "Internal": true, "Labels": ["dkt.fixture": "true"], "Containers": [:] as [String: Any]]
    }

    func seedContainer(id: String, name: String, tty: Bool, environment: [String: String], labels: [String: String], network: String? = nil) {
        lock.withLock {
            containers[id] = [
                "Id": id, "Name": "/" + name, "Image": DKTDockerFake.imageID,
                "Created": "2026-10-07T00:00:00.000000000Z",
                "State": ["Status": "running", "Running": true, "Paused": false, "Restarting": false,
                          "OOMKilled": false, "Dead": false, "ExitCode": 0, "Health": ["Status": "healthy"]],
                "Config": ["Image": "dkt/web:latest", "Tty": tty,
                           "Env": environment.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + $0.value },
                           "Labels": labels, "Cmd": ["/bin/sh", "--synthetic-secret=" + DKTDockerFake.secret]],
                "Mounts": [["Type": "volume", "Name": DKTDockerFake.volumeName, "Source": "/synthetic/secret-mount",
                            "Destination": "/data", "RW": true]],
                "NetworkSettings": ["Ports": ["8080/tcp": [["HostIp": "127.0.0.1", "HostPort": "8080"]]],
                                    "Networks": [network ?? "bridge": ["IPAddress": "172.18.0.2"]]],
            ]
            if let network, let networkID = networkID(network) { attach(container: id, network: networkID) }
        }
    }

    func seedImage(id: String, tags: [String], labels: [String: String]) {
        lock.withLock {
            images[id] = ["Id": id, "RepoTags": tags, "Size": 1_048_576, "Created": 1_790_000_000,
                          "Labels": labels, "Config": ["Labels": labels]]
        }
    }

    func seedNetwork(id: String, name: String, labels: [String: String], internalNetwork: Bool) {
        lock.withLock {
            networks[id] = ["Id": id, "Name": name, "Driver": "bridge", "Scope": "local", "Internal": internalNetwork, "Labels": labels,
                            "IPAM": ["Driver": "default", "Config": [["Subnet": "172.18.0.0/16"]]], "Containers": [:] as [String: Any]]
            for container in containers.keys.sorted() {
                let connected = (containers[container]?["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any] ?? [:]
                if connected[name] != nil { attach(container: container, network: id) }
            }
        }
    }

    func setResponse(method: String, target: String, response: DKTHTTPResponse) {
        let request = DKTHTTPRequest(method: method, target: target)
        lock.withLock { overrides[Self.key(request)] = response }
    }
    func clearResponses() { lock.withLock { overrides.removeAll() } }

    func snapshotInventory() -> Data {
        lock.withLock {
            DKTHTTPResponse.json(["containers": containers, "images": images, "volumes": volumes,
                                  "networks": networks, "executions": executions] as [String: Any]).body
        }
    }

    func seedTestResources(prefix: String) -> DKTDockerTestResources {
        precondition(prefix.hasPrefix("td-test-"), "Live-shaped fixture names must stay in the td-test namespace")
        let resources = DKTDockerTestResources(containerID: prefix + "-container", imageID: "sha256:" + prefix + "-image",
                                              volumeName: prefix + "-data", networkID: prefix + "-network")
        seedContainer(id: resources.containerID, name: prefix + "-web", tty: false, environment: [:], labels: ["terminaldeck.test": "true"])
        lock.withLock {
            var container = containers[resources.containerID] ?? [:]
            container["Image"] = resources.imageID
            var config = container["Config"] as? [String: Any] ?? [:]
            config["Image"] = prefix + ":latest"
            container["Config"] = config
            container["Mounts"] = [["Type": "volume", "Name": resources.volumeName, "Destination": "/data", "RW": true]] as [[String: Any]]
            containers[resources.containerID] = container
            images[resources.imageID] = ["Id": resources.imageID, "RepoTags": [prefix + ":latest"], "Size": 1_024,
                                         "Created": 1_790_000_000, "Labels": ["terminaldeck.test": "true"]]
            volumes[resources.volumeName] = Self.volume(name: resources.volumeName, labels: ["terminaldeck.test": "true"])
            networks[resources.networkID] = ["Id": resources.networkID, "Name": prefix + "-network", "Driver": "bridge", "Scope": "local",
                                              "Internal": true, "Labels": ["terminaldeck.test": "true"]]
        }
        return resources
    }

    func respond(to request: DKTHTTPRequest) -> DKTHTTPResponse {
        lock.withLock {
            if let override = overrides[Self.key(request)] ?? overrides[request.method + " " + request.enginePath] { return override }
            let path = request.enginePath
            let pieces = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]

            switch (request.method, path) {
            case ("GET", "/_ping"), ("HEAD", "/_ping"):
                return .init(headers: ["API-Version": "1.47", "Docker-Experimental": "false", "OSType": "linux"], body: Data("OK".utf8))
            case ("GET", "/version"):
                return .json(["Version": "27.3.1", "ApiVersion": "1.47", "MinAPIVersion": "1.24", "Os": "linux", "Arch": "amd64"])
            case ("GET", "/info"):
                return .json(["ID": "dkt-engine", "Name": "DKT private fixture", "OSType": "linux", "Architecture": "x86_64",
                              "NCPU": 2, "MemTotal": 1_073_741_824, "Containers": containers.count, "ServerVersion": "27.3.1"])
            case ("GET", "/containers/json"):
                let includeStopped = request.query["all"] != "false" && request.query["all"] != "0"
                let items = containers.values.map(Self.summary).filter {
                    (includeStopped || $0["State"] as? String == "running") && Self.matchesFilters($0, request: request)
                }.sorted { ($0["Id"] as? String ?? "") < ($1["Id"] as? String ?? "") }
                return .json(items)
            case ("POST", "/containers/create"):
                guard let image = body["Image"] as? String, !image.isEmpty,
                      let name = request.query["name"], !name.isEmpty else { return Self.error(400, "An image and container name are required") }
                guard containerID(name) == nil else { return Self.error(409, "A container with this fixture name already exists") }
                sequence += 1
                let id = String(format: "%064llx", UInt64(sequence))
                var hostConfig = body["HostConfig"] as? [String: Any] ?? [:]
                // Engine inspect materializes false defaults, even when a
                // create request omitted them. Preserve explicit bad values.
                if hostConfig["Privileged"] == nil { hostConfig["Privileged"] = false }
                if hostConfig["PublishAllPorts"] == nil { hostConfig["PublishAllPorts"] = false }
                let endpoints = (body["NetworkingConfig"] as? [String: Any])?["EndpointsConfig"] as? [String: Any] ?? [:]
                let networkNames = endpoints.isEmpty ? [hostConfig["NetworkMode"] as? String ?? "bridge"] : endpoints.keys.sorted()
                let networkValues = Dictionary(uniqueKeysWithValues: networkNames.map { ($0, ["IPAddress": "172.18.0.\(sequence % 250 + 2)"]) })
                let exposedPorts = body["ExposedPorts"] as? [String: Any] ?? [:]
                let portBindings = hostConfig["PortBindings"] as? [String: Any] ?? [:]
                var ports: [String: Any] = [:]
                for port in exposedPorts.keys { ports[port] = portBindings[port] ?? NSNull() }
                var config = body
                config["Labels"] = body["Labels"] as? [String: String] ?? [:]
                config["Env"] = body["Env"] as? [String] ?? []
                config["Tty"] = body["Tty"] as? Bool ?? false
                let mounts = (hostConfig["Mounts"] as? [[String: Any]] ?? []).map { mount -> [String: Any] in
                    ["Type": mount["Type"] as? String ?? "volume", "Name": mount["Source"] as? String ?? "",
                     "Source": "/synthetic/volumes/" + (mount["Source"] as? String ?? ""),
                     "Destination": mount["Target"] as? String ?? mount["Destination"] as? String ?? "/data",
                     "RW": !(mount["ReadOnly"] as? Bool ?? false)]
                }
                containers[id] = ["Id": id, "Name": "/" + name,
                                  "Image": images[image] != nil ? image : images.first(where: { ($0.value["RepoTags"] as? [String])?.contains(image) == true })?.key ?? image,
                                  "Created": "2026-10-07T00:00:00Z", "Config": config, "HostConfig": hostConfig,
                                  "State": ["Status": "created", "Running": false, "ExitCode": 0, "Health": ["Status": "starting"]],
                                  "Mounts": mounts,
                                  "NetworkSettings": ["Ports": ports, "Networks": networkValues]]
                for name in networkNames {
                    if let networkID = networkID(name) {
                        attach(container: id, network: networkID, endpoint: endpoints[name] as? [String: Any] ?? [:])
                    }
                }
                return .json(["Id": id, "Warnings": []] as [String: Any], statusCode: 201)
            case ("GET", "/images/json"):
                return .json(images.values.sorted { ($0["Id"] as? String ?? "") < ($1["Id"] as? String ?? "") })
            case ("GET", "/volumes"):
                return .json(["Volumes": volumes.values.sorted { ($0["Name"] as? String ?? "") < ($1["Name"] as? String ?? "") }, "Warnings": []] as [String: Any])
            case ("POST", "/volumes/create"):
                guard let name = body["Name"] as? String, !name.isEmpty else { return Self.error(400, "A volume name is required") }
                let value = Self.volume(name: name, driver: body["Driver"] as? String ?? "local", labels: body["Labels"] as? [String: String] ?? [:])
                volumes[name] = value
                return .json(value, statusCode: 201)
            case ("GET", "/networks"):
                return .json(networks.values.sorted { ($0["Id"] as? String ?? "") < ($1["Id"] as? String ?? "") })
            case ("POST", "/networks/create"):
                guard let name = body["Name"] as? String, !name.isEmpty else { return Self.error(400, "A network name is required") }
                sequence += 1
                let id = "dkt-network-created-\(sequence)"
                networks[id] = ["Id": id, "Name": name, "Driver": body["Driver"] as? String ?? "bridge", "Scope": "local",
                                "Internal": body["Internal"] as? Bool ?? false, "Labels": body["Labels"] as? [String: String] ?? [:], "Containers": [:] as [String: Any]]
                return .json(["Id": id, "Warning": ""], statusCode: 201)
            case ("GET", "/events"):
                return Self.events(holdOpen: request.query["until"] == nil)
            default: break
            }

            if pieces.first == "containers", pieces.count >= 2 {
                guard let id = containerID(pieces[1]), let container = containers[id] else { return Self.error(404, "No such container") }
                if pieces.count == 2, request.method == "DELETE" {
                    if (container["State"] as? [String: Any])?["Running"] as? Bool == true,
                       request.query["force"] != "true", request.query["force"] != "1" { return Self.error(409, "Stop the running fixture before removing it") }
                    containers[id] = nil
                    for networkID in networks.keys.sorted() { detach(container: id, network: networkID) }
                    return .init(statusCode: 204)
                }
                guard pieces.count == 3 else { return Self.error(404, "No such test endpoint") }
                switch (request.method, pieces[2]) {
                case ("GET", "json"): return .json(container)
                case ("POST", "start"), ("POST", "stop"), ("POST", "restart"):
                    let running = pieces[2] != "stop"
                    var updated = container
                    var current = container["State"] as? [String: Any] ?? [:]
                    let alreadyInState = current["Running"] as? Bool == running
                    current["Running"] = running
                    current["Status"] = running ? "running" : "exited"
                    current["Health"] = ["Status": running ? "healthy" : "unhealthy"]
                    updated["State"] = current
                    containers[id] = updated
                    return .init(statusCode: pieces[2] != "restart" && alreadyInState ? 304 : 204)
                case ("GET", "logs"):
                    return Self.logs(tty: (container["Config"] as? [String: Any])?["Tty"] as? Bool ?? false,
                                     holdOpen: request.query["follow"] == "1" || request.query["follow"] == "true")
                case ("GET", "stats"):
                    return Self.stats(id: id, holdOpen: request.query["stream"] != "0" && request.query["stream"] != "false")
                case ("POST", "exec"):
                    sequence += 1
                    let execID = "dkt-exec-\(sequence)"
                    executions[execID] = ["ID": execID, "ContainerID": id, "Running": false, "ExitCode": 0,
                                          "OpenStdin": true, "OpenStdout": true, "OpenStderr": true,
                                          "ProcessConfig": ["tty": body["Tty"] as? Bool ?? true, "entrypoint": "/bin/sh", "arguments": []]]
                    return .json(["Id": execID], statusCode: 201)
                default: return Self.error(404, "No such test endpoint")
                }
            }

            if pieces.first == "images", pieces.count >= 2 {
                let imagePieces = pieces.last == "json" ? Array(pieces.dropFirst().dropLast()) : Array(pieces.dropFirst())
                let candidate = imagePieces.joined(separator: "/")
                guard let id = images[candidate] != nil ? candidate : images.first(where: { ($0.value["RepoTags"] as? [String])?.contains(candidate) == true })?.key,
                      let image = images[id] else { return Self.error(404, "No such image") }
                if request.method == "GET", pieces.last == "json" { return .json(image.merging(["Config": ["Labels": image["Labels"] ?? [:]]]) { _, new in new }) }
                if request.method == "DELETE" {
                    images[id] = nil
                    return .json((image["RepoTags"] as? [String] ?? []).map { ["Untagged": $0] } + [["Deleted": id]])
                }
            }
            if pieces.first == "volumes", pieces.count == 2 {
                guard let volume = volumes[pieces[1]] else { return Self.error(404, "No such volume") }
                if request.method == "GET" { return .json(volume) }
                if request.method == "DELETE" { volumes[pieces[1]] = nil; return .init(statusCode: 204) }
            }
            if pieces.first == "networks", pieces.count == 2 {
                guard let id = networks[pieces[1]] != nil ? pieces[1] : networks.first(where: { $0.value["Name"] as? String == pieces[1] })?.key,
                      let network = networks[id] else { return Self.error(404, "No such network") }
                if request.method == "GET" { return .json(network) }
                if request.method == "DELETE" {
                    guard (network["Containers"] as? [String: Any] ?? [:]).isEmpty else { return Self.error(409, "The fixture network still has connected containers") }
                    networks[id] = nil
                    return .init(statusCode: 204)
                }
            }
            if pieces.first == "networks", pieces.count == 3, request.method == "POST",
               pieces[2] == "connect" || pieces[2] == "disconnect" {
                guard let networkID = networkID(pieces[1]) else { return Self.error(404, "No such network") }
                guard let candidate = body["Container"] as? String, !candidate.isEmpty else { return Self.error(400, "A container is required") }
                guard let containerID = containerID(candidate), let container = containers[containerID] else { return Self.error(404, "No such container") }
                let name = networks[networkID]?["Name"] as? String ?? networkID
                let connections = (container["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any] ?? [:]
                if pieces[2] == "connect" {
                    guard connections[name] == nil else { return Self.error(409, "The fixture container is already connected") }
                    attach(container: containerID, network: networkID, endpoint: body["EndpointConfig"] as? [String: Any] ?? [:])
                } else {
                    guard connections[name] != nil else { return Self.error(404, "The fixture container is not connected to this network") }
                    detach(container: containerID, network: networkID)
                }
                return .init()
            }
            if pieces.first == "exec", pieces.count == 3 {
                guard var execution = executions[pieces[1]] else { return Self.error(404, "No such exec instance") }
                switch (request.method, pieces[2]) {
                case ("GET", "json"): return .json(execution)
                case ("POST", "resize"): return .init()
                case ("POST", "start"):
                    execution["Running"] = true
                    executions[pieces[1]] = execution
                    if body["Detach"] as? Bool == true { return .init() }
                    return .init(statusCode: 101, headers: ["Connection": "Upgrade", "Upgrade": "tcp", "Content-Type": "application/vnd.docker.raw-stream"],
                                 streamChunks: DKTDockerFake.segmented(Data("DKT shell ready\r\n$ ".utf8)), holdOpen: true)
                default: break
                }
            }
            return Self.error(404, "No such test endpoint")
        }
    }

    private func containerID(_ candidate: String) -> String? {
        if containers[candidate] != nil { return candidate }
        return containers.first { $0.value["Name"] as? String == "/" + candidate }?.key
    }

    private func networkID(_ candidate: String) -> String? {
        if networks[candidate] != nil { return candidate }
        return networks.first { $0.value["Name"] as? String == candidate }?.key
    }

    // These helpers run only while the state lock is held.
    private func attach(container id: String, network networkID: String, endpoint: [String: Any] = [:]) {
        guard var container = containers[id], var network = networks[networkID] else { return }
        let name = network["Name"] as? String ?? networkID
        let ip = (endpoint["IPAMConfig"] as? [String: Any])?["IPv4Address"] as? String ?? "172.18.0.\(sequence % 250 + 2)"
        var settings = container["NetworkSettings"] as? [String: Any] ?? [:]
        var connections = settings["Networks"] as? [String: Any] ?? [:]
        connections[name] = ["NetworkID": networkID, "IPAddress": ip, "Aliases": endpoint["Aliases"] as? [String] ?? []]
        settings["Networks"] = connections
        container["NetworkSettings"] = settings
        containers[id] = container
        var members = network["Containers"] as? [String: Any] ?? [:]
        members[id] = ["Name": String((container["Name"] as? String ?? "").drop(while: { $0 == "/" })),
                       "EndpointID": "dkt-endpoint-" + id, "IPv4Address": ip + "/16", "IPv6Address": ""]
        network["Containers"] = members
        networks[networkID] = network
    }

    private func detach(container id: String, network networkID: String) {
        guard var network = networks[networkID] else { return }
        let name = network["Name"] as? String ?? networkID
        if var container = containers[id] {
            var settings = container["NetworkSettings"] as? [String: Any] ?? [:]
            var connections = settings["Networks"] as? [String: Any] ?? [:]
            connections[name] = nil
            settings["Networks"] = connections
            container["NetworkSettings"] = settings
            containers[id] = container
        }
        var members = network["Containers"] as? [String: Any] ?? [:]
        guard members[id] != nil else { return }
        members[id] = nil
        network["Containers"] = members
        networks[networkID] = network
    }

    private static func key(_ request: DKTHTTPRequest) -> String {
        let query = request.target.firstIndex(of: "?").map { String(request.target[$0...]) } ?? ""
        return request.method + " " + request.enginePath + query
    }

    private static func error(_ status: Int, _ message: String) -> DKTHTTPResponse { .json(["message": message], statusCode: status) }
    private static func volume(name: String, driver: String = "local", labels: [String: String] = [:]) -> [String: Any] {
        ["Name": name, "Driver": driver, "Scope": "local", "Labels": labels, "Mountpoint": "/synthetic/volumes/" + name,
         "CreatedAt": "2026-10-07T00:00:00Z", "Options": [:] as [String: String]]
    }

    private static func summary(_ inspect: [String: Any]) -> [String: Any] {
        let config = inspect["Config"] as? [String: Any] ?? [:]
        let state = inspect["State"] as? [String: Any] ?? [:]
        let running = state["Running"] as? Bool ?? false
        let rawPorts = (inspect["NetworkSettings"] as? [String: Any])?["Ports"] as? [String: Any] ?? [:]
        var ports: [[String: Any]] = []
        for (key, bindings) in rawPorts.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "/")
            guard parts.count == 2, let privatePort = Int(parts[0]) else { continue }
            let publicBindings = bindings as? [[String: Any]] ?? []
            if publicBindings.isEmpty { ports.append(["PrivatePort": privatePort, "Type": String(parts[1])]); continue }
            for binding in publicBindings {
                var port: [String: Any] = ["PrivatePort": privatePort, "Type": String(parts[1])]
                if let number = Int(binding["HostPort"] as? String ?? "") { port["PublicPort"] = number }
                if let ip = binding["HostIp"] as? String { port["IP"] = ip }
                ports.append(port)
            }
        }
        return ["Id": inspect["Id"] ?? "", "Names": [inspect["Name"] as? String ?? ""], "Image": config["Image"] ?? "",
                "ImageID": inspect["Image"] ?? "", "Created": 1_790_000_000, "State": state["Status"] ?? "exited",
                "Status": running ? "Up 2 minutes" : "Exited (0)", "Labels": config["Labels"] ?? [:] as [String: String],
                "Ports": ports]
    }

    private static func matchesFilters(_ container: [String: Any], request: DKTHTTPRequest) -> Bool {
        guard let text = request.query["filters"], let data = text.data(using: .utf8),
              let filters = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return true }
        for (kind, raw) in filters {
            let entries = (raw as? [String]) ?? (raw as? [String: Bool])?.filter { $0.value }.map(\.key) ?? []
            if entries.isEmpty { continue }
            switch kind {
            case "label":
                let labels = container["Labels"] as? [String: String] ?? [:]
                guard entries.allSatisfy({
                    let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    return pair.count == 1 ? labels[pair[0]] != nil : labels[pair[0]] == pair[1]
                }) else { return false }
            case "status": guard entries.contains(container["State"] as? String ?? "") else { return false }
            case "id": guard entries.contains(where: { (container["Id"] as? String ?? "").hasPrefix($0) }) else { return false }
            case "name": guard entries.contains(where: { name in (container["Names"] as? [String] ?? []).contains(where: { $0.contains(name) }) }) else { return false }
            default: break
            }
        }
        return true
    }

    private static func logs(tty: Bool, holdOpen: Bool) -> DKTHTTPResponse {
        // UTF-8 and the synthetic secret cross both Docker frames and HTTP chunks.
        let text = Data(("ready 🙂 token=" + DKTDockerFake.secret + "\n").utf8)
        let emojiStart = Data("ready ".utf8).count
        let firstSplit = emojiStart + 2
        let secondSplit = firstSplit + 12
        let first = Data(text.prefix(firstSplit))
        let second = Data(text.dropFirst(firstSplit).prefix(secondSplit - firstSplit))
        let third = Data(text.dropFirst(secondSplit))
        var wire = Data()
        if tty { wire = text }
        else {
            wire.append(DKTDockerFake.multiplexedFrame(stream: 1, payload: first))
            wire.append(DKTDockerFake.multiplexedFrame(stream: 1, payload: second))
            wire.append(DKTDockerFake.multiplexedFrame(stream: 1, payload: third))
            wire.append(DKTDockerFake.multiplexedFrame(stream: 2, text: "synthetic warning\n"))
        }
        return .init(headers: ["Content-Type": "application/vnd.docker.raw-stream"],
                     streamChunks: DKTDockerFake.segmented(wire, sizes: [1, 2, 4, 3, 2, 5, 1, 7, 2, 3, 1, 8]), holdOpen: holdOpen)
    }

    private static func stats(id: String, holdOpen: Bool) -> DKTHTTPResponse {
        let sample: [String: Any] = [
            "id": id, "name": "/dkt-web", "read": "2026-10-07T00:00:01Z",
            "cpu_stats": ["cpu_usage": ["total_usage": 200_000_000, "percpu_usage": [100_000_000, 100_000_000]],
                          "system_cpu_usage": 2_000_000_000, "online_cpus": 2],
            "precpu_stats": ["cpu_usage": ["total_usage": 100_000_000], "system_cpu_usage": 1_000_000_000],
            "memory_stats": ["usage": 67_108_864, "limit": 268_435_456, "stats": ["cache": 8_388_608, "inactive_file": 8_388_608]],
            "networks": ["eth0": ["rx_bytes": 1_024, "tx_bytes": 2_048]],
            "blkio_stats": ["io_service_bytes_recursive": [["op": "Read", "value": 4_096], ["op": "Write", "value": 8_192]]],
            "pids_stats": ["current": 3],
        ]
        var wire = DKTHTTPResponse.json(sample).body
        wire.append(0x0a)
        return .init(headers: ["Content-Type": "application/json"],
                     streamChunks: DKTDockerFake.segmented(wire, sizes: [1, 3, 2, 5, 11]), holdOpen: holdOpen)
    }

    private static func events(holdOpen: Bool) -> DKTHTTPResponse {
        let events: [[String: Any]] = [
            ["Type": "container", "Action": "start", "status": "start", "id": DKTDockerFake.containerID,
             "Actor": ["ID": DKTDockerFake.containerID, "Attributes": ["name": "dkt-web", "API_TOKEN": DKTDockerFake.secret]],
             "time": 1_790_000_001, "timeNano": 1_790_000_001_000_000_000 as Int64],
            ["Type": "container", "Action": "die", "status": "die", "id": DKTDockerFake.containerID,
             "Actor": ["ID": DKTDockerFake.containerID, "Attributes": ["name": "dkt-web", "exitCode": "1"]],
             "time": 1_790_000_002, "timeNano": 1_790_000_002_000_000_000 as Int64],
        ]
        var wire = Data()
        for event in events { wire.append(DKTHTTPResponse.json(event).body); wire.append(0x0a) }
        return .init(headers: ["Content-Type": "application/json"],
                     streamChunks: DKTDockerFake.segmented(wire, sizes: [2, 1, 4, 3, 8, 2, 13]), holdOpen: holdOpen)
    }
}
