import Foundation
import TerminalDeckNativeCore

/// App-side client of the actual helper-owned ordinary and AGS file leases.
/// It preserves original prepared values; concrete actors still need the
/// shared lease-owner protocol seam described in HOST-FRONTEND-WIRING.md.
public actor BackendHOSTToolLeaseProxy: BackendLaunchCapability {
    public nonisolated let readiness: BackendLaunchReadiness
    private let client: BackendHOSTClient
    private var prepared: [UUID: BackendPreparedToolLease] = [:]
    public var count: Int { prepared.count }
    private struct Binding: Equatable, Sendable { let sessionID: String, machineID: String }
    private var bound: [UUID: Binding] = [:]
    private var settingsDirectories: [UUID: URL] = [:]
    private var settingsSessions: [UUID: String] = [:]
    private var failures: [String] = []
    private var detached = false

    public init(client: BackendHOSTClient) async throws {
        let projection = try await client.resource("mcp.projection", arguments: .object([]))
        guard let text = projection["url"].string, let url = URL(string: text) else { throw BackendSessionFailure.missingCapability("the host's actual listening MCP endpoint") }
        _ = try BackendMCPEndpointDescription(url: url, implementation: .native)
        self.client = client; readiness = .ready
    }
    public func prepareOrdinary() async throws -> BackendPreparedToolLease {
        guard let value = try await prepareOrdinary(restricting: nil, deniedTools: [], taskID: nil, taskProject: nil) else {
            throw BackendSessionFailure.missingCapability("the host's actual ordinary-session tool catalogue")
        }
        return value
    }
    public func prepareOrdinary(restricting allowedTools: [String]?, deniedTools: [String], taskID: String? = nil,
                                taskProject: String? = nil) async throws -> BackendPreparedToolLease? {
        guard !detached else { throw BackendSessionFailure.closed }
        let value = try await client.resource("mcp.prepare", arguments: .object([
            .init("allowed", allowedTools.map { .array($0.map(NativeRPCValue.string)) } ?? .null),
            .init("denied", .array(deniedTools.map(NativeRPCValue.string))),
            .init("taskID", taskID.map(NativeRPCValue.string) ?? .null),
            .init("taskProject", taskProject.map(NativeRPCValue.string) ?? .null)]))
        if value.isNullish { return nil }
        guard let id = value["id"].string.flatMap(UUID.init(uuidString:)), let impl = value["implementation"].string.flatMap(BackendMCPImplementation.init(rawValue:)) else {
            throw BackendHOSTFailure.invalid("The host returned an invalid prepared tool lease.")
        }
        do {
            let arguments = try strings(value["arguments"], name: "tool arguments")
            let files = try strings(value["readableFiles"], name: "private tool file paths")
            guard files.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw BackendHOSTFailure.invalid("Invalid private tool path.") }
            let object = try value["environment"].requireObject("prepared tool environment")
            let fields = object.fields ?? []
            var environment: [String: String] = [:]
            for field in fields {
                let text = try field.value.requireString("prepared tool environment value")
                guard !field.key.isEmpty, !field.key.contains("="), !field.key.contains("\0"), !text.contains("\0") else { throw BackendHOSTFailure.invalid("Invalid prepared tool environment.") }
                environment[field.key] = text
            }
            let lease = BackendPreparedToolLease(id: id, arguments: arguments, environment: environment, readableFiles: files, implementation: impl)
            guard !detached else { await abandon(id); throw BackendSessionFailure.closed }
            prepared[id] = lease; return lease
        } catch {
            _ = try? await client.resource("mcp.abandon", arguments: .object([.init("lease", .string(id.uuidString))]))
            throw error
        }
    }
    public func bind(_ id: UUID, sessionID: String, machineID: String = "") async throws {
        guard !detached, prepared[id] != nil || settingsDirectories[id] != nil else { throw BackendSessionFailure.invalidInput("The prepared host tool lease is not owned by this app transaction.") }
        let binding = Binding(sessionID: sessionID, machineID: machineID)
        if let existing = bound[id] {
            guard existing == binding else { throw BackendSessionFailure.invalidInput("The host tool lease is already bound to a different session or machine.") }
            return
        }
        _ = try await client.resource("mcp.bind", arguments: .object([.init("lease", .string(id.uuidString)),
            .init("id", .string(sessionID)), .init("machine", .string(machineID))]))
        guard !detached else { throw BackendSessionFailure.closed }
        bound[id] = binding
    }
    public func abandon(_ id: UUID) async {
        do {
            _ = try await client.resource("mcp.abandon", arguments: .object([.init("lease", .string(id.uuidString))]))
            forget(id)
        } catch { noteFailure("The host tool lease could not yet be abandoned. Its host owner retains cleanup responsibility.") }
    }
    public func release(sessionID: String) async {
        do {
            _ = try await client.resource("mcp.release", arguments: .object([.init("id", .string(sessionID))]))
            for id in bound.compactMap({ $0.value.sessionID == sessionID ? $0.key : nil }) { forget(id) }
            for id in settingsSessions.compactMap({ $0.value == sessionID ? $0.key : nil }) { forget(id) }
        } catch { noteFailure("The host session still owns its private tool resources, or its cleanup could not be reached.") }
    }
    /// Private config may contain a caller secret. Keep this authenticated
    /// backend result out of public projections and renderer state.
    public func agentSettingsConfiguration(_ id: UUID) async throws -> NativeRPCValue {
        guard !detached, prepared[id] != nil else { throw BackendSessionFailure.closed }
        return try await client.resource("mcp.ags.configuration", arguments: .object([.init("lease", .string(id.uuidString))]))
    }
    public func reserveAgentSettingsFiles() async throws -> BackendAGSLaunchFileLease {
        guard !detached else { throw BackendSessionFailure.closed }
        let value = try await client.resource("mcp.ags.reserve", arguments: .object([]))
        guard let id = value["id"].string.flatMap(UUID.init(uuidString:)) else { throw BackendHOSTFailure.invalid("Invalid actual host AGS file lease.") }
        do {
            let path = try value["directory"].requireString("host AGS directory")
            guard path.hasPrefix("/"), !path.contains("\0") else { throw BackendHOSTFailure.invalid("Invalid actual host AGS directory.") }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            guard !detached, !Task.isCancelled else { throw BackendSessionFailure.closed }
            settingsDirectories[id] = directory
            return BackendAGSLaunchFileLease(id: id, directory: directory, write: { [weak self] files in
                guard let self else { throw BackendSessionFailure.closed }; try await self.writeSettings(id, files: files)
            }, bind: { [weak self] session in
                guard let self else { throw BackendSessionFailure.closed }; try await self.bindSettings(id, sessionID: session)
            }, abandon: { [weak self] in await self?.abandon(id) })
        } catch {
            _ = try? await client.resource("mcp.abandon", arguments: .object([.init("lease", .string(id.uuidString))]))
            throw error
        }
    }
    private func writeSettings(_ id: UUID, files: [String: Data]) async throws {
        guard !detached, settingsDirectories[id] != nil, bound[id] == nil else { throw BackendSessionFailure.closed }
        _ = try await client.resource("mcp.ags.write", arguments: .object([.init("lease", .string(id.uuidString)),
            .init("files", .object(files.map { .init($0.key, .string($0.value.base64EncodedString())) }))]))
    }
    private func bindSettings(_ id: UUID, sessionID: String) async throws {
        guard !detached, settingsDirectories[id] != nil else { throw BackendSessionFailure.closed }
        _ = try await client.resource("mcp.ags.bind", arguments: .object([.init("lease", .string(id.uuidString)), .init("id", .string(sessionID))]))
        guard !detached else { throw BackendSessionFailure.closed }
        settingsSessions[id] = sessionID
        // AGS's existing bind closure has no machine argument; the helper keeps
        // the exact pre-exec machine. Do not cache a fabricated empty identity.
    }
    public func preparedIDs() -> [UUID] { Set(prepared.keys).union(settingsDirectories.keys).sorted { $0.uuidString < $1.uuidString } }
    public func cleanupFailures() -> [String] { failures }
    /// Keep/update detach is not host cleanup. Root's explicit Stop Everything
    /// owns host termination, drain, caller revocation and file deletion.
    public func stop() { detached = true; prepared.removeAll(); bound.removeAll(); settingsDirectories.removeAll(); settingsSessions.removeAll() }
    private func strings(_ value: NativeRPCValue, name: String) throws -> [String] {
        guard let values = value.elements else { throw BackendHOSTFailure.invalid("Missing " + name + ".") }
        return try values.map { let text = try $0.requireString(name); guard !text.contains("\0") else { throw BackendHOSTFailure.invalid("Invalid " + name + ".") }; return text }
    }
    private func forget(_ id: UUID) {
        prepared[id] = nil; settingsDirectories[id] = nil; bound[id] = nil; settingsSessions[id] = nil
    }
    private func noteFailure(_ message: String) { failures.append(message); if failures.count > 32 { failures.removeFirst(failures.count - 32) } }
}

/// Resolves the app's ORIGINAL project source, then asks the helper to retain
/// its actual stdio definition/config. This is a protocol adapter, not the
/// concrete BackendProjectToolComposition actor.
public actor BackendHOSTProjectToolProxy: BackendLaunchCapability {
    public nonisolated let readiness: BackendLaunchReadiness
    private let client: BackendHOSTClient
    private let source: any BackendProjectMCPSource
    private let machineID: String
    private let inherited: [String: String]
    private var prepared: [UUID: BackendPreparedProjectTools] = [:]
    private var bound: [UUID: String] = [:]
    private var detached = false
    private var failures: [String] = []
    public init(client: BackendHOSTClient, source: any BackendProjectMCPSource, machineID: String,
                inheritedEnvironment: [String: String]) async throws {
        guard !machineID.contains("\0") else { throw BackendHOSTFailure.invalid("Invalid actual project machine identity.") }
        let projection = try await client.resource("mcp.projection", arguments: .object([]))
        guard let text = projection["url"].string, let url = URL(string: text) else { throw BackendSessionFailure.missingCapability("the host's actual listening MCP endpoint") }
        _ = try BackendMCPEndpointDescription(url: url, implementation: .native)
        self.client = client; self.source = source; self.machineID = machineID; inherited = inheritedEnvironment
        readiness = source.readiness
    }
    public func prepare(provider: String, cwd: String, loginPath: String, allowedTools: [String]? = nil,
                        deniedTools: [String] = [], taskID: String? = nil, taskProject: String? = nil) async throws -> BackendPreparedProjectTools? {
        guard !detached else { throw BackendSessionFailure.closed }
        guard let actual = try await source.resolve(cwd: cwd, provider: provider, loginPath: loginPath) else { return nil }
        let definition = try BackendHOSTProjectDefinition(actual)
        let wire = try NativeRPCValue.parseJSON(JSONEncoder().encode(definition))
        let reply = try await client.resource("mcp.project.prepare", arguments: .object([
            .init("definition", wire), .init("provider", .string(provider)), .init("cwd", .string(cwd)), .init("path", .string(loginPath)),
            .init("machine", .string(machineID)), .init("environment", .object(inherited.map { .init($0.key, .string($0.value)) })),
            .init("allowed", allowedTools.map { .array($0.map(NativeRPCValue.string)) } ?? .null),
            .init("denied", .array(deniedTools.map(NativeRPCValue.string))), .init("taskID", taskID.map(NativeRPCValue.string) ?? .null),
            .init("taskProject", taskProject.map(NativeRPCValue.string) ?? .null)]))
        if reply.isNullish { return nil }
        guard let id = reply["id"].string.flatMap(UUID.init(uuidString:)) else { throw BackendHOSTFailure.invalid("Invalid actual host project lease.") }
        do {
            let value = try BackendHOSTProjectLeaseWire.decode(reply, id: id)
            guard !detached, !Task.isCancelled else { throw BackendSessionFailure.closed }
            prepared[id] = value; return value
        } catch {
            _ = try? await client.resource("mcp.abandon", arguments: .object([.init("lease", .string(id.uuidString))]))
            throw error
        }
    }
    public func agentSettingsServerName(provider: String, cwd: String, loginPath: String) async throws -> String? {
        guard !detached else { throw BackendSessionFailure.closed }
        guard let actual = try await source.resolve(cwd: cwd, provider: provider, loginPath: loginPath) else { return nil }
        return try BackendHOSTProjectDefinition(actual).name
    }
    public func agentSettingsConfiguration(_ id: UUID) async throws -> NativeRPCValue {
        guard !detached, prepared[id] != nil else { throw BackendSessionFailure.closed }
        return try await client.resource("mcp.project.configuration", arguments: .object([.init("lease", .string(id.uuidString))]))
    }
    public func bind(_ id: UUID, sessionID: String) async throws {
        guard !detached, prepared[id] != nil else { throw BackendSessionFailure.closed }
        if let previous = bound[id] {
            guard previous == sessionID else { throw BackendSessionFailure.invalidInput("The host project lease belongs to a different session.") }
            return
        }
        _ = try await client.resource("mcp.bind", arguments: .object([.init("lease", .string(id.uuidString)),
            .init("id", .string(sessionID)), .init("machine", .string(machineID))]))
        guard !detached else { throw BackendSessionFailure.closed }; bound[id] = sessionID
    }
    public func abandon(_ id: UUID) async {
        do {
            _ = try await client.resource("mcp.abandon", arguments: .object([.init("lease", .string(id.uuidString))]))
            prepared[id] = nil; bound[id] = nil
        } catch { noteFailure("The helper retains cleanup responsibility for an unreached project lease.") }
    }
    public func release(sessionID: String) async {
        do {
            _ = try await client.resource("mcp.release", arguments: .object([.init("id", .string(sessionID))]))
            for id in bound.compactMap({ $0.value == sessionID ? $0.key : nil }) { prepared[id] = nil; bound[id] = nil }
        } catch { noteFailure("The host session still owns its private project resources, or cleanup could not be reached.") }
    }
    public func preparedIDs() -> [UUID] { prepared.keys.sorted { $0.uuidString < $1.uuidString } }
    public func cleanupFailures() -> [String] { failures }
    public func stop() { detached = true; prepared.removeAll(); bound.removeAll() }
    private func noteFailure(_ message: String) { failures.append(message); if failures.count > 32 { failures.removeFirst(failures.count - 32) } }
}

private enum BackendHOSTProjectLeaseWire {
    static func decode(_ reply: NativeRPCValue, id: UUID) throws -> BackendPreparedProjectTools {
        guard let implementation = reply["implementation"].string.flatMap(BackendMCPImplementation.init(rawValue:)) else { throw BackendHOSTFailure.invalid("Invalid actual project implementation.") }
        func strings(_ value: NativeRPCValue) throws -> [String] {
            guard let elements = value.elements else { throw BackendHOSTFailure.invalid("Missing actual project arguments or private file paths.") }
            return try elements.map { let text = try $0.requireString("actual project launch value"); guard !text.contains("\0") else { throw BackendHOSTFailure.invalid("Invalid actual project launch value.") }; return text }
        }
        let arguments = try strings(reply["arguments"]), files = try strings(reply["readableFiles"])
        guard files.allSatisfy({ $0.hasPrefix("/") }) else { throw BackendHOSTFailure.invalid("Invalid actual project private file path.") }
        let fields = try reply["environment"].requireObject("actual project environment").fields ?? []
        var environment: [String: String] = [:]
        for field in fields {
            let text = try field.value.requireString("actual project environment value")
            guard !field.key.isEmpty, !field.key.contains("="), !field.key.contains("\0"), !text.contains("\0") else { throw BackendHOSTFailure.invalid("Invalid actual project environment.") }
            environment[field.key] = text
        }
        return .init(id: id, arguments: arguments, environment: environment, readableFiles: files, implementation: implementation)
    }
}
