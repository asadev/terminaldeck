import Foundation

/// Safe, normalized Docker Engine values for native UI and RPC consumers.
/// Raw inspect responses and environment values never belong in these models.
public struct BackendDockerStatus: Equatable, Sendable {
    public let version: String
    public let apiVersion: String
    public let os: String
    public let architecture: String
    public init(version: String, apiVersion: String, os: String, architecture: String) {
        self.version = version; self.apiVersion = apiVersion; self.os = os; self.architecture = architecture
    }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([
            ("available", .bool(true)), ("version", .string(version)), ("apiVersion", .string(apiVersion)),
            ("os", .string(os)), ("architecture", .string(architecture)),
        ])
    }
}

public struct BackendDockerPort: Equatable, Sendable {
    public let privatePort: Int
    public let publicPort: Int?
    public let type: String
    public let ip: String?
    public init(privatePort: Int, publicPort: Int? = nil, type: String, ip: String? = nil) {
        self.privatePort = privatePort; self.publicPort = publicPort; self.type = type; self.ip = ip
    }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([
            ("privatePort", .number(Double(privatePort))), ("publicPort", publicPort.map { .number(Double($0)) } ?? .missing),
            ("type", .string(type)), ("ip", ip.map(NativeRPCValue.string) ?? .missing),
        ])
    }
}

public struct BackendDockerContainer: Equatable, Sendable {
    public let id: String
    public let names: [String]
    public let name: String
    public let image: String
    public let imageId: String
    public let state: String
    public let status: String
    /// Seconds since the Unix epoch, matching the Engine list response.
    public let created: Double
    public let labels: [String: String]
    public let ports: [BackendDockerPort]
    public init(id: String, names: [String], name: String, image: String, imageId: String,
                state: String, status: String, created: Double, labels: [String: String], ports: [BackendDockerPort]) {
        self.id = id; self.names = names; self.name = name; self.image = image; self.imageId = imageId
        self.state = state; self.status = status; self.created = created
        self.labels = BackendDockerModelValues.safeLabels(labels); self.ports = ports
    }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([
            ("id", .string(id)), ("names", .array(names.map(NativeRPCValue.string))), ("name", .string(name)),
            ("image", .string(image)), ("imageId", .string(imageId)), ("state", .string(state)), ("status", .string(status)),
            ("created", .number(created)), ("labels", BackendDockerModelValues.labels(labels)), ("ports", .array(ports.map(\.value))),
        ])
    }
}

public struct BackendDockerEnvironment: Equatable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([("name", .string(name)), ("value", .string(BackendDockerModelValues.mask))])
    }
}

public struct BackendDockerMount: Equatable, Sendable {
    public let type: String
    public let name: String?
    public let destination: String
    public let readOnly: Bool
    /// Host source paths are intentionally omitted: inspect can expose credential locations.
    public init(type: String, name: String? = nil, destination: String, readOnly: Bool) {
        self.type = type; self.name = name; self.destination = destination; self.readOnly = readOnly
    }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([
            ("type", .string(type)), ("name", name.map(NativeRPCValue.string) ?? .missing),
            ("destination", .string(destination)), ("readOnly", .bool(readOnly)),
        ])
    }
}

public struct BackendDockerContainerDetail: Equatable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    public let state: String
    public let status: String
    public let created: Double
    public let labels: [String: String]
    public let tty: Bool
    public let environment: [BackendDockerEnvironment]
    public let mounts: [BackendDockerMount]
    public let ports: [BackendDockerPort]
    public init(id: String, name: String, image: String, state: String, status: String, created: Double,
                labels: [String: String], tty: Bool, environment: [BackendDockerEnvironment],
                mounts: [BackendDockerMount], ports: [BackendDockerPort]) {
        self.id = id; self.name = name; self.image = image; self.state = state; self.status = status
        self.created = created; self.labels = BackendDockerModelValues.safeLabels(labels); self.tty = tty
        self.environment = environment; self.mounts = mounts; self.ports = ports
    }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([
            ("id", .string(id)), ("name", .string(name)), ("image", .string(image)), ("state", .string(state)),
            ("status", .string(status)), ("created", .number(created)), ("labels", BackendDockerModelValues.labels(labels)),
            ("tty", .bool(tty)), ("environment", .array(environment.map(\.value))),
            ("mounts", .array(mounts.map(\.value))), ("ports", .array(ports.map(\.value))),
        ])
    }
}

public struct BackendDockerImage: Equatable, Sendable {
    public let id: String
    public let tags: [String]
    public let size: Double
    /// Epoch seconds. Zero represents an image whose optional creation date is absent.
    public let created: Double
    public let labels: [String: String]
    public init(id: String, tags: [String], size: Double, created: Double, labels: [String: String]) {
        self.id = id; self.tags = tags; self.size = size; self.created = created
        self.labels = BackendDockerModelValues.safeLabels(labels)
    }
    /// The name an approval must explicitly confirm before deleting this image.
    public var confirmationName: String { tags.first ?? id }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([
            ("id", .string(id)), ("tags", .array(tags.map(NativeRPCValue.string))), ("size", .number(size)),
            ("created", .number(created)), ("labels", BackendDockerModelValues.labels(labels)),
        ])
    }
}

public struct BackendDockerVolume: Equatable, Sendable {
    public let name: String
    public let driver: String
    public let scope: String
    public let labels: [String: String]
    public init(name: String, driver: String, scope: String, labels: [String: String]) {
        self.name = name; self.driver = driver; self.scope = scope; self.labels = BackendDockerModelValues.safeLabels(labels)
    }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([
            ("name", .string(name)), ("driver", .string(driver)), ("scope", .string(scope)),
            ("labels", BackendDockerModelValues.labels(labels)),
        ])
    }
}

public struct BackendDockerNetwork: Equatable, Sendable {
    public let id: String
    public let name: String
    public let driver: String
    public let scope: String
    public let internalNetwork: Bool
    public let labels: [String: String]
    public init(id: String, name: String, driver: String, scope: String, internalNetwork: Bool, labels: [String: String]) {
        self.id = id; self.name = name; self.driver = driver; self.scope = scope
        self.internalNetwork = internalNetwork; self.labels = BackendDockerModelValues.safeLabels(labels)
    }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([
            ("id", .string(id)), ("name", .string(name)), ("driver", .string(driver)), ("scope", .string(scope)),
            ("internal", .bool(internalNetwork)), ("labels", BackendDockerModelValues.labels(labels)),
        ])
    }
}

public struct BackendDockerNetworkCreation: Equatable, Sendable {
    public let id: String
    public let warnings: [String]
    public init(id: String, warnings: [String]) { self.id = id; self.warnings = warnings }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([("id", .string(id)), ("warnings", .array(warnings.map(NativeRPCValue.string)))])
    }
}

public struct BackendDockerComposeProject: Equatable, Sendable {
    public let name: String
    public let containers: [BackendDockerContainer]
    public let services: [String]
    public var running: Int { containers.filter { $0.state == "running" }.count }
    public var total: Int { containers.count }
    public init(name: String, containers: [BackendDockerContainer], services: [String]) {
        self.name = name; self.containers = containers; self.services = services
    }
    public var value: NativeRPCValue {
        BackendDockerModelValues.object([
            ("name", .string(name)), ("containers", .array(containers.map(\.value))),
            ("services", .array(services.map(NativeRPCValue.string))), ("running", .number(Double(running))),
            ("total", .number(Double(total))),
        ])
    }
}

public enum BackendDockerModelValues {
    public static let mask = "••••••"
    public static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object(fields.filter { $0.1 != .missing }.map { .init($0.0, $0.1) })
    }
    public static func labels(_ labels: [String: String]) -> NativeRPCValue {
        let safe = safeLabels(labels)
        return .object(safe.keys.sorted().map { .init($0, .string(safe[$0] ?? mask)) })
    }
    public static func safeLabels(_ labels: [String: String]) -> [String: String] {
        labels.reduce(into: [:]) { result, row in
            let key = row.key.lowercased()
            let sensitive = ["password", "passwd", "secret", "token", "credential", "authorization", "private_key", "private-key", "api_key", "api-key"]
                .contains { key.contains($0) }
            result[row.key] = sensitive ? mask : safeDisplay(row.value)
        }
    }
    public static func safeDisplay(_ text: String, secretValues: [String] = []) -> String {
        let lower = text.lowercased()
        let embeddedCredential = ["-----begin ", "password=", "passwd=", "token=", "secret=", "api_key=", "apikey=", "api-key=", "access_key=", "authorization:"].contains { lower.contains($0) }
        let credentialURL = lower.contains("://") && lower.contains("@")
        if embeddedCredential || credentialURL { return mask }
        return secretValues.filter { !$0.isEmpty }.sorted { $0.utf8.count > $1.utf8.count }.reduce(text) {
            $0.replacingOccurrences(of: $1, with: mask)
        }
    }
}
