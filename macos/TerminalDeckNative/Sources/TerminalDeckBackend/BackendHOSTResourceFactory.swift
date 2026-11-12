import Foundation
import Darwin
import TerminalDeckNativeCore

/// The bundled helper's actual resource bootstrap. No readiness bit is
/// synthesized here: the real runtime/app joins supply mandatory callbacks.
public enum BackendHOSTResourceFactory {
    public struct AppControls: Sendable {
        public var verifyClaims: @Sendable ([BackendSessionMeta], BackendMCPCancellation) async throws -> Bool
        public var hookContext: @Sendable (NativeRPCValue, BackendMCPCancellation) async throws -> String?
        public var openLink: @Sendable (URL, String?, BackendMCPCancellation) async throws -> BackendSessionHookOpenAnswer
        public var authorizeAccount: (@Sendable (NativeRPCValue, BackendMCPCancellation) async throws -> NativeRPCValue)?
        public init(verifyClaims: @escaping @Sendable ([BackendSessionMeta], BackendMCPCancellation) async throws -> Bool,
                    hookContext: @escaping @Sendable (NativeRPCValue, BackendMCPCancellation) async throws -> String?,
                    openLink: @escaping @Sendable (URL, String?, BackendMCPCancellation) async throws -> BackendSessionHookOpenAnswer,
                    authorizeAccount: (@Sendable (NativeRPCValue, BackendMCPCancellation) async throws -> NativeRPCValue)? = nil) {
            self.verifyClaims = verifyClaims; self.hookContext = hookContext; self.openLink = openLink
            self.authorizeAccount = authorizeAccount
        }
    }
    public struct Callbacks: Sendable {
        public var verifyClaims: @Sendable ([BackendSessionMeta]) async throws -> Bool
        public var confirmDescendants: @Sendable (String) async throws -> Bool
        public var metadataChanged: @Sendable (BackendSessionMeta) -> Void
        public var additionalContext: @Sendable (BackendSessionHookEvent) async throws -> String?
        public var openLink: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)?

        public init(verifyClaims: @escaping @Sendable ([BackendSessionMeta]) async throws -> Bool,
                    confirmDescendants: @escaping @Sendable (String) async throws -> Bool,
                    metadataChanged: @escaping @Sendable (BackendSessionMeta) -> Void,
                    additionalContext: @escaping @Sendable (BackendSessionHookEvent) async throws -> String?,
                    openLink: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)? = nil) {
            self.verifyClaims = verifyClaims; self.confirmDescendants = confirmDescendants
            self.metadataChanged = metadataChanged; self.additionalContext = additionalContext; self.openLink = openLink
        }
    }
    public typealias BrokerFactory = @Sendable (BackendAccountConfiguration, BackendAccountProfileStore, BackendAccountVault) async throws -> BackendAccountBroker

    /// App-side adapter. These mandatory closures are the app's CURRENT real
    /// task/Receiver, hook context and open routing authority, not grant defaults.
    public static func installAppControls(client: BackendHOSTAppRelayClient, controls: AppControls) {
        let decisionBroker = try? BackendPCDecisionHostValidation.register(client: client)
        client.setControlHandler { request in
            guard !request.cancellation.isCancelled else { throw CancellationError() }
            switch request.operation {
            case .decisionValidate:
                guard let decisionBroker else { throw BackendPCDecisionHostValidation.held() }
                let (envelope, effect) = try BackendPCDecisionHostValidation.decode(request.arguments)
                let receipt = try await decisionBroker.consume(envelope, effect: effect, cancellation: request.cancellation)
                return try NativeRPCValue.parseJSON(JSONEncoder().encode(receipt))
            case .verifyClaims:
                let values = try JSONDecoder().decode([BackendSessionMeta].self, from: request.arguments["sessions"].encodedJSON())
                let adopted = try await controls.verifyClaims(values, request.cancellation)
                guard !request.cancellation.isCancelled else { throw CancellationError() }
                return .object([.init("adopted", .bool(adopted))])
            case .hookContext:
                _ = try request.arguments["event"].requireObject("safe hook metadata")
                let value = try await controls.hookContext(request.arguments["event"], request.cancellation)
                guard !request.cancellation.isCancelled else { throw CancellationError() }
                return .object([.init("context", value.map(NativeRPCValue.string) ?? .null)])
            case .hookOpen:
                guard let text = request.arguments["url"].string, let url = URL(string: text),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw BackendHOSTFailure.invalid("Invalid host open address.") }
                let opened = try await controls.openLink(url, request.arguments["sessionID"].string, request.cancellation)
                guard !request.cancellation.isCancelled else { throw CancellationError() }
                return .object([.init("route", .string(opened.route.rawValue)), .init("line", .string(opened.line))])
            case .accountAuthorize:
                guard let authorize = controls.authorizeAccount else { throw BackendHOSTFailure.unavailable }
                let answer = try await authorize(request.arguments, request.cancellation)
                guard !request.cancellation.isCancelled else { throw CancellationError() }
                return answer
            }
        }
    }

    /// Bundled-helper factory: claim/context/open callbacks travel through the
    /// actual authenticated app attachment. Disconnection never implies ready.
    public static func makeUsingAppRelay(paths: BackendHOSTPaths, manager: BackendPTYManager,
                                        nativeAccountOwnerDisabled: Bool,
                                        makeHookCoordinator: @escaping BackendHOSTHookService.CoordinatorFactory,
                                        peerBelongs: @escaping @Sendable (Int32, Int32) -> Bool,
                                        confirmDescendants: @escaping @Sendable (String) async throws -> Bool,
                                        metadataChanged: @escaping @Sendable (BackendSessionMeta) -> Void,
                                        vaultCipher: (any BackendAccountVaultCipher)? = nil,
                                        brokerFactory: BrokerFactory? = nil) -> BackendHOSTRuntime.ResourceFactory {
        let binding = BackendHOSTResourceFactoryRelayBinding()
        let callbacks = Callbacks(verifyClaims: { sessions in
            let values = try NativeRPCValue.parseJSON(JSONEncoder().encode(sessions))
            let answer = try await binding.invoke(.verifyClaims, .object([.init("sessions", values)]))
            return answer["adopted"].bool == true
        }, confirmDescendants: confirmDescendants, metadataChanged: metadataChanged, additionalContext: { event in
            let answer = try await binding.invoke(.hookContext, .object([.init("event", event.metadata)]))
            return answer["context"].string
        }, openLink: { url, session in
            let answer = try await binding.invoke(.hookOpen, .object([.init("url", .string(url.absoluteString)),
                .init("sessionID", session.map(NativeRPCValue.string) ?? .null)]))
            guard let route = answer["route"].string.flatMap(BackendSessionHookOpenAnswer.Route.init(rawValue:)),
                  let line = answer["line"].string else { throw BackendHOSTFailure.invalid("Missing authorized host open result.") }
            return .init(route: route, line: line)
        })
        let factory = make(paths: paths, manager: manager, nativeAccountOwnerDisabled: nativeAccountOwnerDisabled,
            makeHookCoordinator: makeHookCoordinator, peerBelongs: peerBelongs, callbacks: callbacks, vaultCipher: vaultCipher, brokerFactory: brokerFactory)
        return { payload, host in
            let resources = try await factory(payload, host); binding.bind(resources.mcp); return resources
        }
    }

    public static func make(paths: BackendHOSTPaths, manager: BackendPTYManager,
                            nativeAccountOwnerDisabled: Bool,
                            makeHookCoordinator: @escaping BackendHOSTHookService.CoordinatorFactory,
                            peerBelongs: @escaping @Sendable (Int32, Int32) -> Bool,
                            callbacks: Callbacks,
                            vaultCipher: (any BackendAccountVaultCipher)? = nil,
                            brokerFactory: BrokerFactory? = nil) -> BackendHOSTRuntime.ResourceFactory {
        { payload, host in
            guard nativeAccountOwnerDisabled, host.hostPID == getpid(), host.protocolVersion == BackendHOSTProtocol.version,
                  !payload.isEmpty, payload.count <= BackendHOSTProtocol.maximumRequestBytes else {
                throw BackendHOSTFailure.invalid("The private helper bootstrap identity or account ownership is invalid.")
            }
            let dto = try JSONDecoder().decode(BackendHOSTConfiguration.self, from: payload)
            guard dto.home.hasPrefix("/"), !dto.home.contains("\0"),
                  dto.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }),
                  !dto.tools.isEmpty, dto.tools.count <= 4_096 else {
                throw BackendHOSTFailure.invalid("The private helper bootstrap has invalid home, environment or catalogue fields.")
            }
            let tools = try dto.tools.map { try $0.spec() }
            var names: Set<String> = []
            for tool in tools {
                guard !names.contains(tool.id), !names.contains(tool.wireName) else { throw BackendHOSTFailure.invalid("The real tool catalogue contains conflicting names.") }
                names.insert(tool.id); names.insert(tool.wireName)
            }
            let configuration = try dto.accountConfiguration(paths: paths, hostVersion: host.hostVersion)
            try validatePinnedHelper(configuration.helperExecutable, paths: paths, version: host.hostVersion)
            return try await BackendHOSTResources.start(configuration: configuration, host: host, manager: manager, realTools: tools,
                paths: paths,
                nativeAccountOwnerDisabled: nativeAccountOwnerDisabled, makeHookCoordinator: makeHookCoordinator, peerBelongs: peerBelongs,
                additionalContext: callbacks.additionalContext, openLink: callbacks.openLink, vaultCipher: vaultCipher, brokerFactory: brokerFactory,
                verifyClaims: callbacks.verifyClaims, confirmDescendants: callbacks.confirmDescendants, metadataChanged: callbacks.metadataChanged)
        }
    }

    private static func validatePinnedHelper(_ helper: URL, paths: BackendHOSTPaths, version: String) throws {
        let expected = BackendHOSTLaunchAgent.keeperExecutable(in: paths.directory.appendingPathComponent(version, isDirectory: true))
        guard helper.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path else {
            throw BackendHOSTFailure.invalid("The account helper was not pinned to the running host version.")
        }
        var info = stat()
        for directory in [paths.directory, expected.deletingLastPathComponent()] {
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                throw BackendHOSTFailure.invalid("The pinned helper directory is not private and owned.")
            }
        }
        guard lstat(expected.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700, access(expected.path, X_OK) == 0 else {
            throw BackendHOSTFailure.invalid("The pinned native helper is missing or not an owned executable.")
        }
    }
}

private final class BackendHOSTResourceFactoryRelayBinding: @unchecked Sendable {
    private let lock = NSLock()
    private weak var owner: BackendHOSTMCPPersistence?
    func bind(_ owner: BackendHOSTMCPPersistence) { lock.withLock { self.owner = owner } }
    func invoke(_ operation: BackendHOSTAppRelayControl.Operation, _ arguments: NativeRPCValue) async throws -> NativeRPCValue {
        guard let owner = lock.withLock({ owner }) else { throw BackendHOSTFailure.unavailable }
        return try await owner.invokeControl(operation: operation, arguments: arguments)
    }
}
