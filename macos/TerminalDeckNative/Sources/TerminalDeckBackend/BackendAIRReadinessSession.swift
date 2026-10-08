import Foundation
import TerminalDeckNativeCore

/// AIR starts through the sole session lifecycle and delivers the saved prompt
/// through the existing observed brief adapter. A created tab is not evidence
/// that its prompt reached the AI.
public struct BackendAIRReadinessSession: Sendable {
    /// The approved prompt path lets the existing launch boundary grant read
    /// access to this one brief without exposing the private specs directory.
    public typealias Create = @Sendable (BackendCreateSessionInput, NativeRPCContext, String) async throws -> BackendSessionMeta
    public typealias Deliver = @Sendable (String, String, NativeRPCContext) async throws -> Void
    public typealias Rename = @Sendable (String, String, NativeRPCContext) async throws -> Bool
    public typealias Gate = @Sendable (String, NativeRPCValue, NativeRPCContext) async throws -> Void
    public typealias LaunchContext = @Sendable (NativeRPCContext, String, String) async throws -> BackendLaunchContext
    public static let channels: Set<String> = ["readiness:startAI"]
    private let projects: BackendProjectService
    private let specs: BackendTaskPersistence
    private let create: Create
    private let deliver: Deliver
    private let rename: Rename
    private let authorize: Gate

    /// Suppliers must point at the existing lifecycle, brief delivery and real
    /// caller/effect gates. There is no permissive or raw-PTY fallback.
    public init(projects: BackendProjectService, specs: BackendTaskPersistence,
                create: @escaping Create, deliver: @escaping Deliver,
                rename: @escaping Rename, authorize: @escaping Gate) {
        self.projects = projects; self.specs = specs; self.create = create
        self.deliver = deliver; self.rename = rename; self.authorize = authorize
    }

    /// Production convenience keeps guest fencing with the existing launch
    /// context supplier instead of inventing a second session owner.
    public init(projects: BackendProjectService, specs: BackendTaskPersistence,
                lifecycle: BackendSessionLifecycleCoordinator, manager: BackendPTYManager,
                authorize: @escaping Gate, launchContext: @escaping LaunchContext) {
        self.init(projects: projects, specs: specs, create: { input, context, promptPath in
            let launch = try await launchContext(context, input.cwd, promptPath)
            try Self.requirePromptAccess(launch, promptPath: promptPath)
            return try await lifecycle.create(input, context: launch, holdOnFailure: false)
        }, deliver: { id, line, _ in
            try await BackendTaskBriefDelivery.deliver(id, line: line, manager: manager,
                write: { text in try await lifecycle.write(sessionID: id, data: text) })
        }, rename: { id, title, _ in
            try await lifecycle.rename(sessionID: id, title: title)
        }, authorize: authorize)
    }

    /// A paired-device boundary must explicitly allow this approved brief.
    /// Granting the directory would expose prompts from other projects.
    static func requirePromptAccess(_ launch: BackendLaunchContext, promptPath: String) throws {
        guard let boundary = launch.deviceBoundary else { return }
        let exact = BackendMacConfinement.kernelPath(promptPath)
        guard boundary.readableFiles.contains(where: { BackendMacConfinement.kernelPath($0) == exact }) else {
            throw NativeRPCError(code: "missing-capability", message: "This paired session cannot read its approved saved prompt. Grant read access to that one prompt file before launching; keep the other saved prompts private.")
        }
    }

    private static func printable(_ value: String, multiline: Bool) -> Bool {
        !value.unicodeScalars.contains { scalar in
            let code = scalar.value
            return code == 127 || code < 32 && !(multiline && [9, 10, 13].contains(code))
        }
    }
    private static func optionalText(_ request: NativeRPCValue, _ key: String, maximum: Int) throws -> String? {
        guard !request[key].isNullish else { return nil }
        let value = try request[key].requireString(key, nonempty: true)
        guard value.utf16.count <= maximum, printable(value, multiline: false) else {
            throw NativeRPCError.invalidArguments("\(key) must be printable text of at most \(maximum) characters.")
        }
        return value
    }
    private static func validateCaller(_ context: NativeRPCContext, core: BackendDeckCoreSecurityCallContext?) throws {
        if let core {
            guard context.ownerID == "core-call:" + core.callID,
                  core.native.allowedTiers.contains(.alter), core.caller.tiers.contains(.alter) else {
                throw NativeRPCError(code: "access-denied", message: "The AI launch needs the original running core call and its alter grant.")
            }
            guard !core.native.cancellation.isCancelled else { throw CancellationError() }
        } else {
            guard context.caller == .nativeApp else {
                throw NativeRPCError(code: "access-denied", message: "Open this AI session from the Mac app, or use readiness.ask_ai with the original running core call.")
            }
        }
    }

    /// coreContext comes only from the existing issuer, never bridge JSON. It
    /// retains the source launch limits and caller provenance for an MCP start.
    public func startAI(request: NativeRPCValue, context: NativeRPCContext,
                        coreContext: BackendDeckCoreSecurityCallContext? = nil) async throws -> NativeRPCValue {
        try Self.validateCaller(context, core: coreContext)
        _ = try request.requireObject("AI session request")
        let allowed: Set<String> = ["cwd", "provider", "profileId", "cols", "rows", "resume", "firstPrompt", "title"]
        guard request.fields?.allSatisfy({ allowed.contains($0.key) }) == true else {
            throw NativeRPCError.invalidArguments("AI readiness only accepts the project, AI, login, size, title and ready prompt fields.")
        }
        guard request["resume"].isNullish || request["resume"].bool == false else {
            throw NativeRPCError.invalidArguments("AI readiness starts a fresh session for its ready prompt.")
        }
        let cwd = try request["cwd"].requireString("project folder", nonempty: true)
        guard cwd.hasPrefix("/"), Self.printable(cwd, multiline: false) else { throw NativeRPCError.invalidArguments("The project folder must be an absolute printable path.") }
        let prompt = try request["firstPrompt"].requireString("ready prompt", nonempty: true)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf16.count <= BackendDeckCoreBrief.maxBriefChars, Self.printable(prompt, multiline: true) else {
            throw NativeRPCError.invalidArguments("The ready prompt must be useful text of at most 8000 characters.")
        }
        let provider = try Self.optionalText(request, "provider", maximum: 200)
        guard provider != "shell" else { throw NativeRPCError.invalidArguments("Choose an AI for the ready prompt.") }
        let profile = try Self.optionalText(request, "profileId", maximum: 200)
        let title = try Self.optionalText(request, "title", maximum: 200) ?? "AI readiness"
        var input = BackendCreateSessionInput(cwd: cwd,
            cols: try BackendTaskValues.whole(request["cols"], label: "columns", min: 1, max: 1000, fallback: 100),
            rows: try BackendTaskValues.whole(request["rows"], label: "rows", min: 1, max: 1000, fallback: 30), provider: provider)
        input.profileId = profile; input.resume = false; input.origin = .user
        if let coreContext {
            let limits = try BackendDeckCoreCatalogueBuiltins.limitsFrom(coreContext.sessionLimits)
            input.deniedTools = limits["deniedTools"].elements?.compactMap(\.string)
            input.noSkills = limits["noSkills"].bool
            input.agentInstructions = limits["agentInstructions"].string
            let origin = coreContext.caller.sessionOrigin
            input.origin = origin["origin"].string.flatMap(BackendSessionOrigin.init(rawValue:))
            input.originApp = origin["originApp"].string
            input.originRunId = coreContext.callID
        }
        _ = try await projects.requireKnown(cwd)
        _ = try await projects.files.authority.authorize(cwd, context: context, intent: .read)
        guard specs.ownership == .exclusive else { throw NativeRPCError(code: "read-only", message: "The native app does not own the saved prompt records yet. Open a normal session and paste the ready prompt.") }
        try Task.checkCancellation()
        try await authorize("sessions.start", request, context)
        try Self.validateCaller(context, core: coreContext)
        try Task.checkCancellation()
        _ = try await projects.requireKnown(cwd)
        _ = try await projects.files.authority.authorize(cwd, context: context, intent: .read)
        let filename = "AIR-readiness-" + UUID().uuidString.lowercased() + ".md"
        let path = try specs.file(filename).path
        let line = BackendDeckCoreBrief.deliveryLine(path)
        guard Self.printable(line, multiline: false), line.utf16.count <= 4000 else {
            throw NativeRPCError(code: "brief-unavailable", message: "The saved prompt folder cannot be safely sent to the AI. Open a normal session and paste the ready prompt.")
        }
        let body = "# \(title)\n\nrepo: \(NativeRPCValue.string(cwd).compact)\n\n---\n\n" + prompt + "\n"
        try specs.writeBytes(filename, data: Data(body.utf8), replace: false)
        try Task.checkCancellation()
        var session = try await create(input, context, path)
        var delivered = false
        let message: String
        do {
            try Self.validateCaller(context, core: coreContext)
            try Task.checkCancellation()
            guard session.cwd == cwd, !session.id.isEmpty, session.exitCode == nil, session.provider != "shell" else {
                throw NativeRPCError(code: "session-unavailable", message: "The created session did not match the requested live project AI.")
            }
            guard provider == nil || session.provider == provider, profile == nil || session.profileId == profile else {
                throw NativeRPCError(code: "session-unavailable", message: "The created session did not match the selected AI and login.")
            }
            coreContext?.noteStarted(session.id)
            guard try await rename(session.id, title, context) else { throw NativeRPCError(code: "rename-failed", message: "The AI session could not be named.") }
            session.title = title
            try Task.checkCancellation()
            try await authorize("sessions.send", .object([.init("sessionId", .string(session.id)), .init("text", .string(line)), .init("promptPath", .string(path))]), context)
            try Self.validateCaller(context, core: coreContext)
            try Task.checkCancellation()
            try await deliver(session.id, line, context)
            delivered = true
            message = "AI session opened with the ready prompt. Return to AI readiness to review the re-check."
        } catch {
            let reason = error is CancellationError ? "The prompt delivery was cancelled." : error.localizedDescription
            message = "Session \(session.id) was kept, but the ready prompt was not delivered. \(reason) Open that session and read or paste the saved prompt at \(path) before starting work."
        }
        return try NativeRPCValue.parseJSON(JSONEncoder().encode(session))
            .setting("promptDelivered", .bool(delivered)).setting("promptPath", .string(path)).setting("message", .string(message))
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard channel == "readiness:startAI" else { throw NativeRPCError(code: "missing-handler", message: "This AIR session action is unavailable.") }
        guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Use readiness.ask_ai with the original running core call to launch an AI session.") }
        try context.requireCount(args, 1...1)
        return try await startAI(request: args[0], context: context)
    }
}
