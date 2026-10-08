import Foundation

/// Projects DKE's normalized contract replies into the Advanced view's models.
/// This is a display allowlist, not an Engine DTO or a raw-inspect decoder.
public enum NativeDockerContractProjection {
    public static func items(section: NativeDockerSection, reply: CodingAIJSON) throws -> [NativeDockerItem] {
        try requireObject(reply)
        let rows = try requireArray(reply[section.rawValue], field: section.rawValue)
        let result = try rows.map { row in
            switch section {
            case .containers: try container(row)
            case .images: try image(row)
            case .volumes: try volume(row)
            case .networks: try network(row)
            case .projects: try project(row)
            }
        }
        guard Set(result.map(\.id)).count == result.count else {
            throw malformed("The Docker list has repeated identifiers.")
        }
        return result
    }

    public static func container(_ reply: CodingAIJSON) throws -> NativeDockerItem {
        try requireObject(reply)
        let id = try requireString(reply["id"], field: "id", nonempty: true)
        let name = try requireString(reply["name"], field: "name", nonempty: true)
        let image = try requireString(reply["image"], field: "image")
        let state = try requireString(reply["state"], field: "state")
        let status = try requireString(reply["status"], field: "status")
        let labels = reply["labels"]
        try requireObject(labels)
        let composeProject = try optionalString(labels["com.docker.compose.project"], field: "compose project")
        let composeService = try optionalString(labels["com.docker.compose.service"], field: "compose service")

        var facts = [
            NativeDockerFact(label: "Name", value: name),
            NativeDockerFact(label: "ID", value: id),
            NativeDockerFact(label: "Image", value: image),
            NativeDockerFact(label: "State", value: state),
            NativeDockerFact(label: "Status", value: status),
        ]
        if let composeProject, !composeProject.isEmpty {
            facts.append(NativeDockerFact(label: "Compose project", value: composeProject))
        }
        if let composeService, !composeService.isEmpty {
            facts.append(NativeDockerFact(label: "Compose service", value: composeService))
        }

        let ports = try requireArray(reply["ports"], field: "ports").map(port)
        if !ports.isEmpty { facts.append(NativeDockerFact(label: "Ports", value: ports.joined(separator: "\n"))) }

        // Lists do not contain environment or mounts. Inspect does. When either
        // is supplied, validate its safe fields; never read values or host paths.
        if let environment = reply.object?["environment"] {
            let names = try requireArray(environment, field: "environment").map { row in
                try requireObject(row)
                let name = try requireString(row["name"], field: "environment name", nonempty: true)
                guard !name.contains("="), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw malformed("A Docker environment name is invalid.")
                }
                return "\(name)=\(BackendDockerModelValues.mask)"
            }
            if !names.isEmpty {
                facts.append(NativeDockerFact(label: "Environment", value: names.joined(separator: "\n")))
            }
        }
        if let mounts = reply.object?["mounts"] {
            let destinations = try requireArray(mounts, field: "mounts").map { row in
                try requireObject(row)
                let destination = try requireString(row["destination"], field: "mount destination", nonempty: true)
                let readOnly = try requireBool(row["readOnly"], field: "mount readOnly")
                return destination + (readOnly ? " (read-only)" : "")
            }
            if !destinations.isEmpty {
                facts.append(NativeDockerFact(label: "Mount destinations", value: destinations.joined(separator: "\n")))
            }
        }

        let subtitle = [image, composeProject ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let running: Bool?
        switch state {
        case "running": running = true
        case "created", "exited", "dead", "paused", "restarting": running = false
        default: running = nil
        }
        return NativeDockerItem(id: id, name: name, subtitle: subtitle, state: state, running: running, facts: facts)
    }

    public static func project(_ reply: CodingAIJSON) throws -> NativeDockerItem {
        try requireObject(reply)
        let name = try requireString(reply["name"], field: "name", nonempty: true)
        let containers = try requireArray(reply["containers"], field: "containers").map(container)
        let services = try strings(reply["services"], field: "services")
        let running = try count(reply["running"], field: "running")
        let total = try count(reply["total"], field: "total")
        guard running <= total, total == containers.count,
              running == containers.filter({ $0.state == "running" }).count,
              Set(containers.map(\.id)).count == containers.count else {
            throw malformed("The Docker compose project has inconsistent container counts.")
        }
        let state = total == 0 ? "No containers" : running == 0 ? "Stopped" : running == total ? "Running" : "Partly running"
        let summary = "\(running) of \(total) running"
        return NativeDockerItem(id: name, name: name, subtitle: summary, state: state, running: running > 0, facts: [
            NativeDockerFact(label: "Name", value: name),
            NativeDockerFact(label: "Services", value: services.isEmpty ? "None" : services.joined(separator: ", ")),
            NativeDockerFact(label: "Running", value: summary),
            NativeDockerFact(label: "Total containers", value: String(total)),
        ], members: containers)
    }

    public static func usage(_ reply: CodingAIJSON) throws -> NativeDockerUsage {
        try requireObject(reply)
        let cpu = try nonnegativeNumber(reply["cpuPercent"], field: "cpuPercent")
        let memory = try unsignedBytes(reply["memoryBytes"], field: "memoryBytes")
        let limit = try unsignedBytes(reply["memoryLimitBytes"], field: "memoryLimitBytes")
        // Docker uses 100% per CPU core; a reading above 100% is valid.
        return NativeDockerUsage(cpuPercent: cpu, memoryBytes: memory, memoryLimitBytes: limit)
    }

    private static func image(_ reply: CodingAIJSON) throws -> NativeDockerItem {
        try requireObject(reply)
        let id = try requireString(reply["id"], field: "id", nonempty: true)
        // Match the channel service's canonical confirmation name; Docker's
        // <none> placeholders are not tags the person can confirm removing.
        let tags = try strings(reply["tags"], field: "tags").filter { !$0.hasPrefix("<none>") }
        let size = try unsignedBytes(reply["size"], field: "size")
        let confirmationName = tags.first ?? id
        let displayName = tags.first ?? String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
        let sizeText = bytes(size)
        return NativeDockerItem(id: id, name: displayName, subtitle: sizeText, facts: [
            NativeDockerFact(label: "ID", value: id),
            NativeDockerFact(label: "Tags", value: tags.isEmpty ? "None" : tags.joined(separator: "\n")),
            NativeDockerFact(label: "Size", value: sizeText),
            NativeDockerFact(label: "Confirmation name", value: confirmationName),
        ])
    }

    private static func volume(_ reply: CodingAIJSON) throws -> NativeDockerItem {
        try requireObject(reply)
        let name = try requireString(reply["name"], field: "name", nonempty: true)
        let driver = try requireString(reply["driver"], field: "driver", nonempty: true)
        let scope = try requireString(reply["scope"], field: "scope", nonempty: true)
        return NativeDockerItem(id: name, name: name, subtitle: driver, state: scope, facts: [
            NativeDockerFact(label: "Name", value: name),
            NativeDockerFact(label: "Driver", value: driver),
            NativeDockerFact(label: "Scope", value: scope),
        ])
    }

    private static func network(_ reply: CodingAIJSON) throws -> NativeDockerItem {
        try requireObject(reply)
        let id = try requireString(reply["id"], field: "id", nonempty: true)
        let name = try requireString(reply["name"], field: "name", nonempty: true)
        let driver = try requireString(reply["driver"], field: "driver", nonempty: true)
        let scope = try requireString(reply["scope"], field: "scope", nonempty: true)
        let internalNetwork = try requireBool(reply["internal"], field: "internal")
        return NativeDockerItem(id: id, name: name, subtitle: "\(driver) · \(scope)", state: internalNetwork ? "Internal" : "", facts: [
            NativeDockerFact(label: "Name", value: name),
            NativeDockerFact(label: "ID", value: id),
            NativeDockerFact(label: "Driver", value: driver),
            NativeDockerFact(label: "Scope", value: scope),
            NativeDockerFact(label: "Internal", value: internalNetwork ? "Yes" : "No"),
        ])
    }

    private static func port(_ reply: CodingAIJSON) throws -> String {
        try requireObject(reply)
        let privatePort = try portNumber(reply["privatePort"], field: "privatePort")
        let type = try requireString(reply["type"], field: "port type", nonempty: true)
        guard ["tcp", "udp", "sctp"].contains(type) else { throw malformed("A Docker port protocol is invalid.") }
        var address = "\(privatePort)/\(type)"
        if let publicValue = reply.object?["publicPort"], !publicValue.isNull {
            let publicPort = try portNumber(publicValue, field: "publicPort")
            let ip = try optionalString(reply["ip"], field: "port ip") ?? ""
            let host = ip.contains(":") ? "[\(ip)]" : ip
            address = "\(host.isEmpty ? "" : host + ":")\(publicPort) → \(address)"
        }
        return address
    }

    private static func portNumber(_ value: CodingAIJSON, field: String) throws -> Int {
        let number = try count(value, field: field)
        guard (1...65_535).contains(number) else { throw malformed("A Docker port number is invalid.") }
        return number
    }

    private static func strings(_ value: CodingAIJSON, field: String) throws -> [String] {
        try requireArray(value, field: field).map { try requireString($0, field: field, nonempty: true) }
    }

    private static func requireObject(_ value: CodingAIJSON) throws {
        guard value.isObject else { throw malformed("Docker returned an invalid object.") }
    }

    private static func requireArray(_ value: CodingAIJSON, field: String) throws -> [CodingAIJSON] {
        guard let rows = value.array else { throw malformed("Docker returned an invalid \(field) list.") }
        return rows
    }

    private static func requireString(_ value: CodingAIJSON, field: String, nonempty: Bool = false) throws -> String {
        guard let text = value.string, !nonempty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw malformed("Docker returned an invalid \(field).")
        }
        return text
    }

    private static func optionalString(_ value: CodingAIJSON, field: String) throws -> String? {
        value.isNull ? nil : try requireString(value, field: field)
    }

    private static func requireBool(_ value: CodingAIJSON, field: String) throws -> Bool {
        guard let flag = value.bool else { throw malformed("Docker returned an invalid \(field).") }
        return flag
    }

    private static func nonnegativeNumber(_ value: CodingAIJSON, field: String) throws -> Double {
        guard let number = value.number, number >= 0 else { throw malformed("Docker returned an invalid \(field).") }
        return number
    }

    private static func count(_ value: CodingAIJSON, field: String) throws -> Int {
        let number = try nonnegativeNumber(value, field: field)
        guard let result = Int(exactly: number) else { throw malformed("Docker returned an invalid \(field).") }
        return result
    }

    private static func unsignedBytes(_ value: CodingAIJSON, field: String) throws -> UInt64 {
        let number = try nonnegativeNumber(value, field: field)
        // Double(UInt64.max) rounds up to 2^64. An exact initializer refuses it,
        // fractions, infinity and negative values instead of trapping or wrapping.
        guard let result = UInt64(exactly: number) else { throw malformed("Docker returned an invalid \(field).") }
        return result
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private static func malformed(_ message: String) -> NativeRPCError { .malformed(message) }
}
