import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendDockerTarget: Sendable, Equatable {
    public let id: String, name: String, kind: String, platform: String
    public let available: Bool
    public let socketPath: String?
    public init(id: String, name: String, kind: String, platform: String, available: Bool = true, socketPath: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.platform = platform
        self.available = available; self.socketPath = socketPath
    }
    public var value: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("id", .string(id)), .init("name", .string(name)),
            .init("kind", .string(kind)), .init("available", .bool(available))]
        if let socketPath { fields.append(.init("socketPath", .string(socketPath))) }
        return .object(fields)
    }
}

/// Discovery is explicit and filesystem-only: no engine probe or background work.
public enum BackendDockerLocalDiscovery {
    public static func candidatePaths(home: URL) -> [String] {
        [home.appendingPathComponent(".docker/run/docker.sock").path,
         home.appendingPathComponent(".orbstack/run/docker.sock").path,
         home.appendingPathComponent(".colima/default/docker.sock").path, "/var/run/docker.sock"]
    }
    public static func discover(home: URL) -> BackendDockerTarget? {
        // Named Colima profiles are supported too, without reading Docker
        // context files (which may contain credential-store configuration).
        let profiles = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(".colima"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let extraPaths = profiles.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(64)
            .map { $0.appendingPathComponent("docker.sock").path }
        for path in candidatePaths(home: home) + extraPaths {
            var info = stat()
            // stat follows the providers' documented unix-socket symlinks.
            guard Darwin.fstatat(AT_FDCWD, path, &info, 0) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { continue }
            return .init(id: "local", name: "This Mac", kind: "local", platform: "darwin", socketPath: path)
        }
        return nil
    }
}

public enum BackendDockerInstall {
    public static let source = "https://get.docker.com"
    // Fixed server-side command; caller input is never interpolated. A private
    // temporary file prevents another account replacing a predictable /tmp file.
    public static let command = #"set -eu; install_script=$(mktemp /tmp/terminaldeck-install-docker.XXXXXX); trap 'rm -f "$install_script"' EXIT; curl -fsSL https://get.docker.com -o "$install_script"; sh "$install_script""#
    public static var preview: NativeRPCValue {
        .object([.init("command", .string(command)), .init("source", .string(source)),
            .init("requiresApproval", .bool(true)), .init("requiresAdministrator", .bool(true))])
    }
    public static func requireLinux(_ target: BackendDockerTarget) throws {
        guard target.id != "local", target.kind != "local", target.platform.lowercased() == "linux" else {
            throw NativeRPCError(code: "unavailable", message: "Docker's one-click installer is available on Linux servers. This Mac uses its installed Docker provider.")
        }
    }
}

/// Safe approval input; command previews are masked. Submitted environment,
/// secrets and terminal input never enter this approval context.
public struct BackendDockerAction: Sendable {
    public let channel: String, target: String
    public let resourceID: String?, confirmationName: String?
    public let writesServer: Bool, destructive: Bool
    public let parameters: NativeRPCValue
    public var commandPreview: String? {
        if channel == "docker:install" { return BackendDockerInstall.command }
        guard channel == "docker:exec:open", let command = parameters["command"].elements else { return nil }
        return command.compactMap(\.string).map(BackendServersConnections.quote).joined(separator: " ")
    }
    public init(channel: String, target: String, resourceID: String? = nil, confirmationName: String? = nil,
                writesServer: Bool = false, destructive: Bool = false, parameters: NativeRPCValue = .object([])) {
        self.channel = channel; self.target = target; self.resourceID = resourceID; self.confirmationName = confirmationName
        self.writesServer = writesServer; self.destructive = destructive; self.parameters = parameters
    }
}

public struct BackendDockerDependencies: Sendable {
    public typealias Resolve = @Sendable (String, NativeRPCContext) async throws -> BackendDockerClient
    public typealias Targets = @Sendable (NativeRPCContext) async throws -> [BackendDockerTarget]
    public typealias Authorize = @Sendable (BackendDockerAction, NativeRPCContext) async throws -> Void
    public typealias Install = @Sendable (String, String, NativeRPCContext) async throws -> Void
    public let resolve: Resolve, targets: Targets
    public let authorize: Authorize?
    public let install: Install?
    public let secretValues: @Sendable (String, NativeRPCContext) async throws -> [String]
    public init(resolve: @escaping Resolve, targets: @escaping Targets, authorize: Authorize?, install: Install? = nil,
                secretValues: @escaping @Sendable (String, NativeRPCContext) async throws -> [String] = { _, _ in [] }) {
        self.resolve = resolve; self.targets = targets; self.authorize = authorize; self.install = install; self.secretValues = secretValues
    }
}
