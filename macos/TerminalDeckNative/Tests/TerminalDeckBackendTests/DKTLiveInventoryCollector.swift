import Foundation

/// Complete public-name inventory. Parsing does not expose raw Docker/Caddy data.
enum DKTLiveInventoryCollector {
    struct Input: Sendable {
        let containers: Data
        let images: Data
        let volumes: Data
        let networks: Data
        let caddy: Data
        /// Fixed server read command emits `APP id`, `FOLDER absolute-path`,
        /// and `BACKUP absolute-path`. It never reads state/env/backup contents.
        let serverPaths: String
    }

    static func collect(_ input: Input) throws -> DKTLiveInventory {
        var resources: [DKTLiveResourceProof] = []
        let images = try array(input.images)
        var imageReferences: [String: [String]] = [:]
        for image in images {
            let id = try string(image, "Id")
            imageReferences[id] = try strings(image, "RepoTags") + strings(image, "RepoDigests")
        }
        for row in try array(input.containers) {
            let id = try string(row, "Id")
            let names = (row["Names"] as? [String] ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }.sorted()
            guard let name = names.first else { throw DKTLiveSafetyRefusal("A container has no public name for the cleanup inventory.") }
            // Preserve every alias as well as the immutable ID.
            for alias in names { resources.append(.init(kind: .container, id: id, name: alias)) }
            let image = row["Image"] as? String ?? ""
            let references = [image] + (imageReferences[image] ?? []) + (imageReferences[row["ImageID"] as? String ?? ""] ?? [])
            let labels = row["Labels"] as? [String: String] ?? [:]
            let managedDatabase = labels["io.terminaldeck.managed"] == "true" && labels["io.terminaldeck.provision"] != nil
            if managedDatabase || references.contains(where: databaseImage) {
                resources.append(.init(kind: .database, id: id, name: name))
            }
        }
        for row in images {
            let id = try string(row, "Id")
            let tags = try strings(row, "RepoTags").filter { $0 != "<none>:<none>" }
            let digests = try strings(row, "RepoDigests")
            let names = Set(tags + digests)
            for name in names.isEmpty ? [id] : names.sorted() { resources.append(.init(kind: .image, id: id, name: name)) }
        }
        let volumeObject = try object(input.volumes)
        guard volumeObject.keys.contains("Volumes"), volumeObject["Volumes"] is NSNull || volumeObject["Volumes"] is [[String: Any]] else {
            throw DKTLiveSafetyRefusal("The volume inventory is invalid.")
        }
        for row in volumeObject["Volumes"] as? [[String: Any]] ?? [] {
            let name = try string(row, "Name")
            resources.append(.init(kind: .volume, id: name, name: name))
        }
        for row in try array(input.networks) {
            resources.append(.init(kind: .network, id: try string(row, "Id"), name: try string(row, "Name")))
        }
        try collectCaddyRoutes(try object(input.caddy), into: &resources)
        for line in input.serverPaths.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty else { throw DKTLiveSafetyRefusal("Server-path inventory framing is invalid.") }
            let name = String(parts[1])
            switch parts[0] {
            case "APP": resources.append(.init(kind: .app, id: name, name: name))
            case "FOLDER": resources.append(.init(kind: .serverFolder, id: name, name: name))
            case "BACKUP": resources.append(.init(kind: .backup, id: name, name: name))
            default: throw DKTLiveSafetyRefusal("An unknown server-path inventory row was refused.")
            }
        }
        return try DKTLiveInventory(resources: resources, caddyConfig: input.caddy)
    }

    private static func collectCaddyRoutes(_ value: Any, into resources: inout [DKTLiveResourceProof], depth: Int = 0) throws {
        guard depth < 64 else { throw DKTLiveSafetyRefusal("Caddy inventory nesting exceeds the test limit.") }
        if let object = value as? [String: Any] {
            if let id = object["@id"] as? String, object["handle"] != nil || object["match"] != nil {
                resources.append(.init(kind: .caddyRoute, id: id, name: id))
            }
            for nested in object.values { try collectCaddyRoutes(nested, into: &resources, depth: depth + 1) }
        } else if let array = value as? [Any] {
            for nested in array { try collectCaddyRoutes(nested, into: &resources, depth: depth + 1) }
        }
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard bytes.count <= 2 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw DKTLiveSafetyRefusal("A required cleanup inventory object is invalid or too large.")
        }
        return value
    }
    private static func array(_ bytes: Data) throws -> [[String: Any]] {
        guard bytes.count <= 2 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else {
            throw DKTLiveSafetyRefusal("A required cleanup inventory list is invalid or too large.")
        }
        return value
    }
    private static func string(_ row: [String: Any], _ key: String) throws -> String {
        guard let value = row[key] as? String, !value.isEmpty else { throw DKTLiveSafetyRefusal("A cleanup inventory resource is missing its public identity.") }
        return value
    }
    private static func databaseImage(_ reference: String) -> Bool {
        let image = reference.split(separator: "/").last.map(String.init) ?? reference
        return ["postgres", "mysql", "redis", "mongo", "mongodb"].contains { image == $0 || image.hasPrefix($0 + ":") || image.hasPrefix($0 + "@") }
    }
    private static func strings(_ row: [String: Any], _ key: String) throws -> [String] {
        guard let value = row[key], !(value is NSNull) else { return [] }
        guard let strings = value as? [String], strings.allSatisfy({ !$0.isEmpty }) else {
            throw DKTLiveSafetyRefusal("Image aliases in the cleanup inventory are invalid.")
        }
        return strings
    }
}
