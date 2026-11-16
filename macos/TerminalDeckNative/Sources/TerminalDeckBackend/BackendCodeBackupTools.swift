import Foundation
import TerminalDeckNativeCore

/// The Code page's tools (CLOUD-CONTRACTS-1114 §6, L5). `code.projects` reads the page's rows. Slice 2 adds the page's
/// actions, each asking the owner first with a line naming the project and the GitHub address: `code.backup_now`
/// (which also makes a private home when the project has none), `code.get_code` and `code.set_mode`. There is no tool
/// that makes anything public. Names, plain states and dates; never a token, a project id or a path.
public enum BackendCodeBackupTools {
    public static let projectsID = "code.projects"
    public static let backupID = "code.backup_now"
    public static let getCodeID = "code.get_code"
    public static let modeID = "code.set_mode"
    /// The family, supplied whole or not at all (`BackendDeckToolsRegistration.expectedIDs`).
    public static let pageIDs: Set<String> = [projectsID, backupID, getCodeID, modeID]

    public typealias Read = @Sendable (_ refresh: Bool) async -> BackendCodeBackupReport?
    /// The installed model (the app installs it at start); nil before that.
    public static let liveRead: Read = { refresh in
        guard let service = await BackendCodeBackupHolder.shared.service else { return nil }
        let report = await service.withGitHub(await service.report(refresh: refresh))
        guard let actions = await BackendCodeBackupHolder.shared.actions else { return report }
        return await actions.decorate(report)
    }

    /// The actions as the tools use them (the live ones go to the installed `BackendCodeBackupActions`).
    public struct Act: Sendable {
        public var signedIn: @Sendable () async -> Bool
        public var target: @Sendable (_ projectName: String) async -> BackendCodeBackupActions.Target?
        public var backUp: @Sendable (_ projectID: String) async -> BackendCodeBackupActions.Outcome
        public var getCode: @Sendable (_ projectID: String) async -> BackendCodeBackupActions.Outcome
        public var setMode: @Sendable (_ projectID: String, _ mode: BackendCodeBackupMode) async -> Void
        public init(signedIn: @escaping @Sendable () async -> Bool, target: @escaping @Sendable (String) async -> BackendCodeBackupActions.Target?,
                    backUp: @escaping @Sendable (String) async -> BackendCodeBackupActions.Outcome,
                    getCode: @escaping @Sendable (String) async -> BackendCodeBackupActions.Outcome,
                    setMode: @escaping @Sendable (String, BackendCodeBackupMode) async -> Void) {
            self.signedIn = signedIn; self.target = target; self.backUp = backUp; self.getCode = getCode; self.setMode = setMode
        }
        static let unavailable = BackendCodeBackupActions.Outcome(ok: false, line: "The Code page is still starting. Try again in a moment.")
        public static let live = Act(signedIn: {
            guard let actions = await BackendCodeBackupHolder.shared.actions else { return false }
            return await actions.signedIn()
        }, target: { name in
            await BackendCodeBackupHolder.shared.actions?.target(named: name)
        }, backUp: { id in
            await BackendCodeBackupHolder.shared.actions?.backUp(projectID: id) ?? Act.unavailable
        }, getCode: { id in
            await BackendCodeBackupHolder.shared.actions?.getCode(projectID: id) ?? Act.unavailable
        }, setMode: { id, mode in
            await BackendCodeBackupHolder.shared.actions?.setMode(projectID: id, mode)
        })
    }

    static let description = "The Code page as the person sees it: every project on this Mac with when its code was last backed up to GitHub (the newest of their commits that is on GitHub), whether it is all there, its GitHub home and whether that is private or public (\"not checked\" when this Mac is not signed in to GitHub), the branch, and what is not backed up: files changed since the last commit (submodules included), commits not on the project's GitHub home, work set aside with git stash, files that cannot go to GitHub as they are (over 50 MB, or a secret file not in any commit), and secret files that are already in the last commit. A project with several code folders lists each in folders and shows the worst. Reading never changes anything in any folder. project narrows to one project by name; refresh true reads every folder again instead of the answer kept for up to a minute."

    public static func definitions(access: BackendDeckToolsAppAccess, read: @escaping Read = liveRead, act: Act = .live) throws -> [BackendDeckToolsDefinition] {
        let schema = #"{"type":"object","properties":{"project":{"type":"string"},"refresh":{"type":"boolean"}},"additionalProperties":false}"#
        let spec = try BackendMCPTool(id: projectsID, wireName: "code_projects", description: description,
                                      inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: .read)
        let definition = BackendDeckToolsDefinition(spec: spec, title: "See every project's code and whether it is backed up",
            index: "Each project's last backup to GitHub, what is not backed up yet, and private or public.") { context, args in
            try await BackendDeckToolsSupport.reply {
                guard context.allowedTools.contains(spec.id) || context.allowedTools.contains(spec.wireName), context.allowedTiers.contains(.read) else {
                    throw NativeRPCError(code: "not-granted", message: "This caller cannot read the Code page.")
                }
                let caller = try await access.caller(context)
                try BackendDeckToolsAppKit.hereOnly(caller, "Reading the Code page")
                try await access.authorize(context, spec.id, args, .read, "Read the Code page", false)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                guard let report = await read(args["refresh"].bool == true) else {
                    throw NativeRPCError(code: "unavailable", message: "The Code page is still starting. Try again in a moment.")
                }
                let wanted = (args["project"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rows = wanted.isEmpty ? report.projects : report.projects.filter { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
                if !wanted.isEmpty, rows.isEmpty {
                    throw NativeRPCError(code: "not-found", message: "No project is called “\(wanted)”. code_projects without project lists them all.")
                }
                return .value(wire(report, rows: rows, now: Date(timeIntervalSince1970: access.now() / 1000)))
            }
        }
        return [definition] + (try actionDefinitions(access: access, act: act))
    }

    static let backupDescription = "Backs up one project's code to its PRIVATE home on GitHub, as the Code page's Back up now does. It only ever ADDS. On a repository the person already had it writes only private backup references (refs/terminal-deck-backup/<Mac>/…: their branches, tags, uncommitted work and set-aside changes), never a branch or a tag, so no deploy, workflow or CI that hangs on a push can start; pushing their real branches stays their decision. Only on a repository Terminal Deck made, where nothing reacts to a push, do branches and tags go under their real names. It never forces, rewrites, deletes, changes the branch the person is on, their files or their staging area, never sends secret files (.env, keys, tokens, sign-in files) or files over 50 MB, and never sends anything to a public repository. A project with no GitHub home gets a new PRIVATE repository on the person's own account, named after the project. Asks the owner first. project is the project's name as code_projects lists it."
    static let getCodeDescription = "Brings a project's code from its GitHub home into its folder on this Mac, as the Code page's Get the code does, for a project that shows \"code not on this Mac yet\". Files already in the folder (instruction files) are kept; one that differs from GitHub's copy is kept as it is and shows as changed. A download that stopped continues where it stopped. Asks the owner first. project is the project's name."
    static let modeDescription = "Sets how one project's code is backed up: automatic (after its work has not changed for 5 minutes, at most every 15 minutes, on a normal network, never while Git is busy in it; makes a private home if it has none), manual (only when Back up now is pressed) or off. Asks the owner first."

    private static func actionDefinitions(access: BackendDeckToolsAppAccess, act: Act) throws -> [BackendDeckToolsDefinition] {
        let named = #"{"type":"object","properties":{"project":{"type":"string"}},"required":["project"],"additionalProperties":false}"#
        let moded = #"{"type":"object","properties":{"project":{"type":"string"},"mode":{"type":"string","enum":["automatic","manual","off"]}},"required":["project","mode"],"additionalProperties":false}"#
        func spec(_ id: String, _ description: String, _ schema: String) throws -> BackendMCPTool {
            try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description,
                               inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: .alter)
        }
        let backup = try spec(backupID, backupDescription, named), get = try spec(getCodeID, getCodeDescription, named), mode = try spec(modeID, modeDescription, moded)

        let backUp = BackendDeckToolsDefinition(spec: backup, title: "Back up a project's code to GitHub",
            index: "Send what GitHub does not have yet to the project's private home; adds only.") { context, args in
            try await BackendDeckToolsSupport.reply {
                let target = try await prepare(access, act, backup, context, args, "Backing up code")
                guard let address = target.address else {
                    throw NativeRPCError(code: "no-home", message: "“\(target.name)” has no GitHub home this app can use (its code goes somewhere else, or GitHub is not connected).")
                }
                let line = target.newHome
                    ? "Back up “\(target.name)”: make a new private home \(address) on your GitHub account and send its code there (adds only)"
                    : target.organisation.map { "Back up “\(target.name)” to \(address) (organisation: everyone in \($0) can see backups; adds only)" }
                        ?? "Back up “\(target.name)” to \(address) (adds only; nothing on GitHub is changed or removed)"
                try await access.authorize(context, backup.id, args, .alter, line, true)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                let outcome = await act.backUp(target.projectID)
                try await access.record(context, backup.id, args, .object([.init("result", .string(outcome.line))]))
                return .value(try answer(outcome))
            }
        }
        let getCode = BackendDeckToolsDefinition(spec: get, title: "Get a project's code from GitHub onto this Mac",
            index: "Bring the project's code into its folder here; keeps the files already there.") { context, args in
            try await BackendDeckToolsSupport.reply {
                let target = try await prepare(access, act, get, context, args, "Getting code")
                guard let address = target.address else {
                    throw NativeRPCError(code: "no-home", message: "No GitHub home was found for “\(target.name)”.")
                }
                try await access.authorize(context, get.id, args, .alter,
                                           "Get the code of “\(target.name)” from \(address) into \(target.folder ?? "its folder")", true)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                let outcome = await act.getCode(target.projectID)
                try await access.record(context, get.id, args, .object([.init("result", .string(outcome.line))]))
                return .value(try answer(outcome))
            }
        }
        let setMode = BackendDeckToolsDefinition(spec: mode, title: "Set a project's code backup to Automatic, Manual or Off",
            index: "Choose how one project's code is backed up to GitHub.") { context, args in
            try await BackendDeckToolsSupport.reply {
                guard let chosen = args["mode"].string.flatMap(BackendCodeBackupMode.init(rawValue:)) else {
                    throw NativeRPCError.invalidArguments("mode is automatic, manual or off.")
                }
                let target = try await prepare(access, act, mode, context, args, "Changing a project's backup")
                if chosen == .automatic, let organisation = target.organisation {
                    throw NativeRPCError(code: "manual-only", message: "“\(target.name)” has its home on \(organisation)'s account: Back up now only, never Automatic (everyone in \(organisation) can see backups).")
                }
                try await access.authorize(context, mode.id, args, .alter,
                                           chosen == .automatic && target.newHome
                                               ? "Set the backup of “\(target.name)” to Automatic: it will make a new private home \(target.address ?? "") on your GitHub account"
                                               : "Set the backup of “\(target.name)” to \(chosen.word) (\(target.address ?? "no GitHub home yet"))", true)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                await act.setMode(target.projectID, chosen)
                try await access.record(context, mode.id, args, .object([.init("mode", .string(chosen.rawValue))]))
                return .value(BackendDeckToolsSupport.object([("ok", .bool(true)), ("mode", .string(chosen.rawValue))]))
            }
        }
        return [backUp, getCode, setMode]
    }

    /// Granted, on this Mac, signed in to GitHub, and the project found by name.
    private static func prepare(_ access: BackendDeckToolsAppAccess, _ act: Act, _ spec: BackendMCPTool, _ context: BackendMCPCallContext,
                                _ args: NativeRPCValue, _ what: String) async throws -> BackendCodeBackupActions.Target {
            guard context.allowedTools.contains(spec.id) || context.allowedTools.contains(spec.wireName), context.allowedTiers.contains(.alter) else {
                throw NativeRPCError(code: "not-granted", message: "This caller cannot use the Code page's actions.")
            }
            let caller = try await access.caller(context)
            try BackendDeckToolsAppKit.hereOnly(caller, what)
            let wanted = (args["project"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wanted.isEmpty else { throw NativeRPCError.invalidArguments("Give project: the project's name as code_projects lists it.") }
            guard await act.signedIn() else {
                throw NativeRPCError(code: "not-connected", message: "GitHub is not connected on this Mac. The owner connects it on the Code page (Connect GitHub).")
            }
            guard let target = await act.target(wanted) else {
                throw NativeRPCError(code: "not-found", message: "No project is called “\(wanted)”. code_projects lists them.")
            }
            return target
    }

    private static func answer(_ outcome: BackendCodeBackupActions.Outcome) throws -> NativeRPCValue {
        guard outcome.ok else { throw NativeRPCError(code: "not-done", message: outcome.line) }
        return BackendDeckToolsSupport.object([("ok", .bool(true)), ("result", .string(outcome.line))])
    }
    static func iso(_ ms: Int64?) -> NativeRPCValue {
        guard let ms else { return .null }
        let formatter = ISO8601DateFormatter(); formatter.timeZone = .current
        return .string(formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)))
    }

    /// The tool's answer: exactly what the page's rows say, then the three lists.
    public static func wire(_ report: BackendCodeBackupReport, rows: [BackendCodeBackupProject]? = nil, now: Date, timeZone: TimeZone = .current) -> NativeRPCValue {
        typealias W = BackendCodeBackupWords
        func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
        func one(_ row: BackendCodeBackupProject) -> [(String, NativeRPCValue)] {
            let last = W.lastBackedUp(row, now: now, timeZone: timeZone)
            return [
                ("state", .string(row.state.rawValue)),
                ("summary", .string(W.summary(row, now: now, timeZone: timeZone))),
                ("lastBackedUp", text(last.isEmpty ? nil : last)),
                ("lastBackedUpAt", iso(row.lastBackedUpAt)),
                ("codeFolder", text(row.folderName)),
                ("gitHubHome", text(row.home)),
                ("otherHome", text(row.otherHost)),
                ("visibility", row.home == nil ? .null : .string(row.visibility.rawValue)),
                ("branch", row.isRepository ? .string(row.branch ?? W.notOnBranch) : .null),
                ("lastCommitAt", iso(row.lastCommitAt)),
                ("changedSinceLastCommit", BackendDeckToolsSupport.object([("count", .number(Double(row.changedCount))),
                    ("names", .array(row.changedFiles.map(NativeRPCValue.string)))])),
                ("commitsNotOnGitHub", BackendDeckToolsSupport.object([("count", .number(Double(row.commitCount))),
                    ("commits", .array(row.commits.map { BackendDeckToolsSupport.object([("subject", .string($0.subject)), ("at", iso($0.at))]) }))])),
                ("setAsideChanges", .number(Double(row.setAsideCount))),
                ("cannotGoToGitHub", .array(row.held.map { BackendDeckToolsSupport.object([("name", .string($0.name)), ("why", .string(W.reason($0.reason)))]) })),
                ("secretFilesInCommits", .array(row.secretsInCommits.map(NativeRPCValue.string))),
                ("problem", text(row.problem)),
                ("backup", .string(row.mode.rawValue)),
                ("uncommittedWorkBackedUpAt", iso(row.changesCoveredAt)),
                ("setAsideChangesBackedUp", .bool(row.setAsideCovered)),
                ("commitsBackedUpPrivately", BackendDeckToolsSupport.object([("count", .number(Double(row.privateCommitCount))),
                    ("notYetOnTheseGitHubBranches", .array(row.privateBranches.map(NativeRPCValue.string)))])),
                ("getCodeFrom", text(row.getFrom)),
                ("lastAction", text(row.note)),
            ]
        }
        let projects: [NativeRPCValue] = (rows ?? report.projects).map { row in
            var pairs: [(String, NativeRPCValue)] = [("name", .string(row.name))] + one(row)
            if row.parts.count > 1 {
                pairs.append(("folders", .array(row.parts.map { BackendDeckToolsSupport.object(one($0)) })))
            }
            return BackendDeckToolsSupport.object(pairs)
        }
        return BackendDeckToolsSupport.object([
            ("signedInToGitHub", report.signedInToGitHub.map(NativeRPCValue.bool) ?? .null),
            ("note", report.signedInToGitHub == false ? .string(W.signInLine) : .null),
            ("checkedAt", iso(report.checkedAt)),
            ("projects", .array(projects)),
        ])
    }
}
