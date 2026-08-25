/**
 * Files, git and the four read-only panels, as this client reads them.
 *
 * A port of the `files.*`, `git.*` and `panel.*` families from
 * `src/main/remote/protocol.ts`, and of the `GitStatusResult` union in
 * `src/main/git.ts`. Nothing here reimplements git or a directory listing: the
 * host answers with `readGitStatus` and `readFileDiff` verbatim, and this file
 * is only the narrowing that turns those answers into something a phone can
 * draw.
 *
 * It exists because he asked for the desktop's own panes on the phone —
 *
 * > *"what about files, artifacts, source control, store, ai readiness, mcp
 * > servers in ios app too for server"*
 *
 * — and then, when offered two of them:
 *
 * > *"all what i asked for so many times, i need all no exceptions."*
 *
 * ## Read-only, all of it
 *
 * There is no write verb on any of these frames and this file must not grow
 * one. Files are listed and read; git reports status and prints a diff; a panel
 * hands over rows a person looks at. Editing a file on a machine you cannot see,
 * from a phone keyboard, is a way to break a repository slowly, and a commit is
 * a decision made where the agent that wrote the change is standing. The door
 * for both already exists and it is a session.
 *
 * ## Two rules the decoding keeps
 *
 *  1. **A folder that is not a repository is an answer, not an error.** The wire
 *     carries `GitRepoStatus | GitNotRepo` and both are worth drawing — one has a
 *     branch and four lists of files, the other a reason and a sentence.
 *  2. **One malformed row must not discard the answer.** The rule `WireCodec`
 *     already follows for a session list: a status showing eleven of twelve
 *     changed files is useful, one showing none because the twelfth had a null
 *     `code` is not.
 *
 * Kept free of SwiftUI so the whole wire layer stays testable without a
 * simulator, like every other file in this folder.
 */

import Foundation

/// Bounds this client applies to answers on these three capabilities.
enum PanelsWire {
    /**
     * How much of a file this client asks for in one `files.read`.
     *
     * The host will serve up to 256 KiB (`MAX_FILE_WINDOW`) and that number is
     * the *parser's* bound, not what fits on the wire: the frame carrying it is
     * an ordinary text message, and an inbound message over
     * `Wire.maxFrameMessageBytes` fails the socket outright rather than being
     * dropped — see `Carrier`, which hands that ceiling to
     * `URLSessionWebSocketTask.maximumMessageSize`. JSON escaping only makes
     * that worse: every control byte in a log becomes six characters.
     *
     * So the window is chosen here, small enough that even badly escaping text
     * stays inside the ceiling, and paging is what covers a long file — `at` is
     * on the request precisely so the second screen is a second read rather
     * than a bigger one.
     */
    static let fileReadWindow = 16 * 1024

    /// The most rows this client will draw off one `files.rows`. A directory
    /// with more entries than this is a directory nobody is reading top to
    /// bottom, and an unbounded list is a phone that stops responding.
    static let maxFileRows = 2_000

    /// The most rows this client will draw off one `panel.rows`. The host caps
    /// artifacts at 200 of its own accord; this is the backstop for the three
    /// that do not.
    static let maxPanelRows = 500

    /// The most changed files this client will draw in one git group. A
    /// generated directory that was never ignored produces thousands, and the
    /// list is a list somebody scrolls.
    static let maxGitFiles = 1_000
}

// MARK: - Files

/**
 * One entry in a folder listing.
 *
 * Identified by its **path**, never its name: two rows in one listing cannot
 * share a path, and the path is also what a tap sends back in `files.list` or
 * `files.read`. `size` and `at` are absent for a directory rather than zero,
 * because a directory has no meaningful size and a zero would be drawn as one.
 * `readable` says whether the account behind the host can actually open it, so
 * a row that would fail is drawn dimmed rather than offered and refused.
 */
struct FileRow: Equatable, Identifiable, Hashable {
    /// Cleaned for display — control characters out, bounded. Never the value
    /// sent back; that is `path`, which is kept byte-for-byte.
    let name: String
    let path: String
    let directory: Bool
    let readable: Bool
    let size: Int?
    /// Last modified, from the host's `mtimeMs`. Nil for a directory, and for a
    /// file the host could not stat.
    let at: Date?

    var id: String { path }
}

/**
 * A folder's contents, in answer to a `files.list`.
 *
 * `path` is echoed by the machine rather than remembered here, because two asks
 * can be in flight after a fast double-tap and the second answer must not be
 * drawn under the first heading — the same rule `folders.entries` keeps.
 * `parent` is nil at the filesystem root, which is what an "up" row is drawn
 * from; working it out on the phone would mean a phone that knows where `/` is
 * on Windows.
 */
struct FileListing: Equatable {
    let path: String
    let parent: String?
    let entries: [FileRow]
}

/**
 * A file, as far as it was read.
 *
 * `at` is the **byte offset the read started at**, not a time — it is the paging
 * cursor, and `at + text.utf8.count` is where the next read begins.
 * `truncated` is the whole reason this is not just a string: a screen showing
 * the first 16 KiB of a log must be able to say that is what it is showing.
 * `binary` is the host's answer, decided from a NUL in the bytes rather than
 * guessed from an extension here, and it arrives with `text` empty rather than
 * with mojibake.
 */
struct FileText: Equatable {
    let path: String
    /// Raw file content — deliberately *not* put through `displayLine`. It is a
    /// document to be shown in a monospaced view, where newlines are the point.
    let text: String
    let at: Int
    let truncated: Bool
    let binary: Bool

    /// Where a following `files.read` should start to continue this one.
    var nextOffset: Int { at + text.utf8.count }
}

// MARK: - Panels

/**
 * The four read-only panels this build serves. A port of `PANELS`.
 *
 * Typed rather than stringly because a `panel.read` naming anything else is
 * refused by `parseClientMessage` as `bad-message`, and a refused frame **closes
 * the socket** — which reads to a person as the network dropping. A typo has to
 * be impossible here, not merely unlikely.
 */
enum PanelKind: String, Equatable, Hashable, CaseIterable {
    case artifacts
    case store
    case readiness
    case mcp

    /// What the panel is called on screen, in his words for the two that have
    /// them — *"ai readiness, mcp servers"*.
    var title: String {
        switch self {
        case .artifacts: return "Artifacts"
        case .store: return "Store"
        case .readiness: return "AI readiness"
        case .mcp: return "MCP servers"
        }
    }

    /// The row icon, drawn at 19pt light in the 24pt column the rest of this app
    /// uses. Here rather than in a view so four screens cannot disagree.
    var symbol: String {
        switch self {
        case .artifacts: return "doc.text"
        case .store: return "shippingbox"
        case .readiness: return "checkmark.seal"
        case .mcp: return "server.rack"
        }
    }
}

/**
 * How a panel row is tinted, when it is tinted at all.
 *
 * Absent is a real value and the common one: a row that is merely information
 * carries no status, and drawing a neutral dot for it would invent a judgement
 * the host never made.
 */
enum PanelStatus: String, Equatable, Hashable {
    case ok
    case warn
    case bad

    /// From the wire's own word, or nil. Takes an optional so a decoder can
    /// write `PanelStatus(wire: string(row["status"]))` without a dance, and a
    /// word this build does not know reads as **no status** rather than as a
    /// guess — the three tints mean three different things and there is no
    /// honest default among them.
    init?(wire raw: String?) {
        guard let raw, let known = PanelStatus(rawValue: raw) else { return nil }
        self = known
    }
}

/**
 * One row of a panel, in the one shape all four share.
 *
 * `title` is what the row is, `detail` the sentence under it, `value` the thing
 * on the right, `status` the tint. Four bespoke frame pairs would have been the
 * careful shape and it is the wrong trade: every one of these panels is a list
 * of rows a person reads and does not act on, and the differences between them
 * are in the words, not in the structure.
 *
 * ## Why the identity is an index
 *
 * There is nothing unique on the row itself. Two artifacts can carry the same
 * title, and a panel that repeats a row is not malformed — so identity is the
 * row's **position in the answer it arrived in**, which is unique for that
 * answer and stable while it is on screen. A content-derived id would collide
 * the moment a panel repeated itself, and SwiftUI answers a collision by drawing
 * one of the rows.
 *
 * `index` therefore comes from the decoder, which knows the position. It has a
 * default so a preview can write `PanelRow(title: "git", value: "ok")` and mean
 * it; a hand-built *list* must pass real indices.
 */
struct PanelRow: Equatable, Identifiable, Hashable {
    let title: String
    let detail: String?
    let value: String?
    let status: PanelStatus?
    let index: Int
    /**
     * The name an action calls this row by, when the host gave it one.
     *
     * Not the same thing as `id`. `index` is *where the row is on screen* and is
     * what SwiftUI diffs against; this is *what the row is on the machine* — an
     * MCP server's name, a store item's id, a file's relative path — and it is
     * the only one of the two that survives the list being filtered or reordered
     * between the tap and the frame arriving.
     */
    let key: String?
    /// What can be done to this row. Empty for a row that is only information.
    let actions: [PanelAction]

    var id: Int { index }

    init(title: String, detail: String? = nil, value: String? = nil,
         status: PanelStatus? = nil, index: Int = 0,
         key: String? = nil, actions: [PanelAction] = []) {
        self.title = title
        self.detail = detail
        self.value = value
        self.status = status
        self.index = index
        self.key = key
        self.actions = actions
    }
}

/**
 * A button the host offered, and the form behind it if it needs one.
 *
 * > *"these pages are not just to view the information — exactly all actions
 * > that we have in desktop application, they should be inside each option of
 * > them."*
 *
 * The phone does not know what any of these mean, and that is the design. The
 * host declares a panel's actions in the same answer as its rows; this screen
 * draws them and sends the `id` back on `panel.act`. A panel that grows an
 * action is a change to one file on the host and no change here at all — which
 * is the property that made this worth a generic frame instead of `mcp.add`,
 * `mcp.remove`, `readiness.fix`, `store.install` and a codec case for each,
 * written once in TypeScript and once again in Swift.
 *
 * `kind` is the single thing this end reads for itself: a destructive action is
 * drawn in the warning colour and asks first, because *remove this MCP server*
 * and *connect it* must not look the same under a thumb.
 */
struct PanelAction: Equatable, Hashable, Identifiable {
    let id: String
    let label: String
    let destructive: Bool
    /// One line under the confirmation. Only ever set on a destructive action.
    let confirm: String?
    /// Ask for these before sending. Empty means fire on the tap.
    let fields: [PanelField]

    init(id: String, label: String, destructive: Bool = false,
         confirm: String? = nil, fields: [PanelField] = []) {
        self.id = id
        self.label = label
        self.destructive = destructive
        self.confirm = confirm
        self.fields = fields
    }
}

/**
 * One field of an action's form.
 *
 * `value` prefilled is what lets one action serve both *add* and *edit*: the
 * host sends the same action id with the row's current values in it, and the
 * form comes up filled rather than blank. Nothing here is a secret — a form
 * that wanted a password would need `safeStorage` on the machine and a very
 * different frame, and none of the four panels asks for one.
 */
struct PanelField: Equatable, Hashable, Identifiable {
    let id: String
    let label: String
    let value: String
    let placeholder: String?
    let required: Bool
    /**
     * The only answers this field accepts, when it accepts a fixed set.
     *
     * Empty means free text. Non-empty means a picker rather than a keyboard,
     * which is the difference between choosing a scope and *spelling* one. The
     * MCP panel measured the cost of not having it: its scope field became a
     * text box prefilled with `user` with the three legal words written into the
     * label, and an SSE server could not be added at all because its transport
     * is inferred from which box was filled in.
     */
    let choices: [String]

    init(id: String, label: String, value: String = "",
         placeholder: String? = nil, required: Bool = false, choices: [String] = []) {
        self.id = id
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.required = required
        self.choices = choices
    }
}

/**
 * One of a panel's filters, as the host describes it.
 *
 * Artifacts is the panel that needs these — the desktop's has *made* / *changed*
 * and a per-session scope, and a phone panel that could only ever send its
 * default view is a panel somebody has to leave to answer an ordinary question.
 * Exactly one is `on`; the host guarantees it and the screen does not paper over
 * a list where none is.
 */
struct PanelScope: Equatable, Hashable, Identifiable {
    let id: String
    let label: String
    let on: Bool
}

/**
 * One panel's answer.
 *
 * `note` is how *"No MCP servers are configured for /Users/apple/Projects"*
 * reaches a screen without being mistaken for a failure to load: a panel with
 * nothing to say sends no rows and a sentence, and the two facts — *nothing to
 * show* and *cannot be shown from here* — are different and only one of them is
 * worth a person's time.
 *
 * `path` is echoed by the machine for the reason `FileListing.path` is: two asks
 * can be in flight, and the folder a panel is about is part of what it says.
 */
struct PanelData: Equatable, Hashable, Identifiable {
    let panel: PanelKind
    let path: String
    let note: String?
    /**
     * What just happened, when an action asked for this redraw.
     *
     * Separate from `note`, and the two are different facts: a note explains an
     * empty list — *"No MCP servers are configured for /home/asad"* — and is a
     * standing property of what was read. A notice is an event — *"Added
     * context7."* — and belongs to one answer. Drawn differently and cleared on
     * the next plain read, which is why a screen never shows a stale one.
     */
    let notice: String?
    /// The filters this panel offers. Empty for a panel with none.
    let scopes: [PanelScope]
    /// What can be done to the panel itself — *add a server*, *scan again*.
    let actions: [PanelAction]
    let rows: [PanelRow]

    var id: PanelKind { panel }

    init(panel: PanelKind, path: String, note: String? = nil, notice: String? = nil,
         scopes: [PanelScope] = [], actions: [PanelAction] = [], rows: [PanelRow] = []) {
        self.panel = panel
        self.path = path
        self.note = note
        self.notice = notice
        self.scopes = scopes
        self.actions = actions
        self.rows = rows
    }
}

// MARK: - Git

/// Which of the four lists a change belongs to. A port of `GitFileGroup`.
enum GitFileGroup: String, Equatable, Hashable, CaseIterable {
    case staged
    case unstaged
    case untracked
    case conflicted

    /// The heading that list is drawn under.
    var title: String {
        switch self {
        case .staged: return "Staged"
        case .unstaged: return "Changes"
        case .untracked: return "Untracked"
        case .conflicted: return "Conflicts"
        }
    }
}

/// What happened to the file. A port of `GitChangeKind`, `unknown` included —
/// it is a case the host itself sends for a letter it did not recognise, so it
/// is a value here rather than a decoding failure.
enum GitChangeKind: String, Equatable, Hashable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typechange
    case untracked
    case conflicted
    case unknown
}

/**
 * The branch, as porcelain reported it.
 *
 * `name` is nil when HEAD is detached and `oid` is nil on an unborn branch —
 * both are ordinary states of a real repository, which is why neither is
 * defaulted to a string. `ahead`/`behind` are 0 with no upstream, which is what
 * git says about a branch nobody is tracking.
 */
struct GitBranchState: Equatable, Hashable {
    let name: String?
    let detached: Bool
    let oid: String?
    let upstream: String?
    let ahead: Int
    let behind: Int

    /// The empty branch the host builds before it has parsed a header — the same
    /// starting value `emptyBranch()` uses, so a status frame with no branch
    /// object decodes to what git would have said about a repository with no
    /// commits in it.
    static let empty = GitBranchState(name: nil, detached: false, oid: nil,
                                      upstream: nil, ahead: 0, behind: 0)
}

/**
 * One changed file.
 *
 * Identified by group **and** path, because a file that is both staged and dirty
 * — porcelain `MM` — is genuinely two rows in two lists, exactly as `git status`
 * prints it, and identifying it by path alone would make the second one vanish.
 *
 * `insertions`/`deletions` are nil until the host's numstat pass fills them in
 * and stay nil for an untracked file, so a row prints nothing rather than
 * "+0 −0" for a file whose whole content is new.
 */
struct GitFileChange: Equatable, Identifiable, Hashable {
    /// Repository-root-relative, always — porcelain never reports a path
    /// relative to the folder that was asked about.
    let path: String
    /// Set only on the staged side of a rename or a copy.
    let origPath: String?
    let group: GitFileGroup
    /// The letter git printed — `M A D R C T ?` — or the two-letter `XY` for a
    /// conflict, where `DU` and `UD` mean very different things.
    let code: String
    let kind: GitChangeKind
    /// Rename/copy similarity percentage, when git reported one.
    let score: Int?
    let insertions: Int?
    let deletions: Int?
    let binary: Bool

    var id: String { "\(group.rawValue)\u{0}\(path)" }

    /// The file's own name, for a row that shows the folder separately.
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// A repository, and everything in it that has moved. A port of `GitRepoStatus`.
struct GitRepoStatus: Equatable, Hashable {
    /// The folder that was asked about.
    let cwd: String
    /// The repository root, which may sit above `cwd`.
    let root: String
    let branch: GitBranchState
    let staged: [GitFileChange]
    let unstaged: [GitFileChange]
    let untracked: [GitFileChange]
    let conflicted: [GitFileChange]
    /// The host's own answer, not a count taken here — it is computed over the
    /// lists *before* they were capped for the wire or here.
    let clean: Bool

    /// The four lists in the order they are drawn, each with its heading.
    var groups: [(group: GitFileGroup, files: [GitFileChange])] {
        [(.conflicted, conflicted), (.staged, staged), (.unstaged, unstaged), (.untracked, untracked)]
    }

    var changeCount: Int { staged.count + unstaged.count + untracked.count + conflicted.count }
}

/// Why git had nothing to say. A port of `GitUnavailableReason`.
enum GitUnavailable: String, Equatable, Hashable {
    case notARepo = "not-a-repo"
    case gitMissing = "git-missing"
    case noSuchFolder = "no-such-folder"
    /// The host's own bucket for a failure nobody anticipated — which is why a
    /// word this build does not recognise reads as this rather than dropping the
    /// answer. There is an honest default here, unlike a dev-server status.
    case error
}

/**
 * A folder git will not report on, said in words. A port of `GitNotRepo`.
 *
 * `message` is a sentence somebody wrote and is rendered verbatim, never git's
 * own stderr — the desktop learned that the hard way when its Overview tile
 * printed *"fatal: not a git repository (or any of the parent directories):
 * .git"* on screen, which Asad caught.
 *
 * `canInit` is whether `git init` here would actually change anything. It is
 * **not** the same question as `reason == .notARepo`: a repository git refuses
 * to read for dubious ownership reports that same reason, and running `init`
 * there would create a second repository beside the one already on disk. This
 * client has no init verb on the wire at all — `git.init` is desktop IPC and was
 * deliberately not extended to a phone — so the flag is carried for what it
 * says, not for a button.
 */
struct GitNotRepo: Equatable, Hashable {
    let cwd: String
    let reason: GitUnavailable
    let message: String
    let canInit: Bool
}

/**
 * What git said about a folder: a status, or a reason there is none.
 *
 * Discriminated on the wire's `repo` boolean, so a caller cannot read a branch
 * off a folder that has no repository. **Both cases are answers.** A folder that
 * is not a repository is a true thing about that folder and the screen has a
 * shape for it; converting it into an error would put a failure banner over a
 * fact.
 */
enum GitState: Equatable, Hashable {
    case repo(GitRepoStatus)
    case notRepo(GitNotRepo)

    /**
     * Decoded from whatever `git.state` carried, **leniently**.
     *
     * The host forwards `GitStatusResult` from `src/main/git.ts` verbatim, which
     * is a union: a real status, or a *not a repository* answer with a reason.
     * Both are answers and both are drawn — a folder that is not a repository is
     * a true thing about that folder, and turning it into an error would put a
     * failure banner over a fact.
     *
     * One malformed file row is dropped rather than discarding the status, the
     * rule `WireCodec` already follows for session lists: a screen showing four
     * of five changed files is useful, one showing none because the fifth had a
     * null path is not. And anything unrecognisable answers `notRepo` with
     * `.error` rather than throwing, because this runs on a socket's data path.
     */
    init(wire: Any?) {
        guard let o = wire as? [String: Any] else {
            self = .notRepo(GitNotRepo(cwd: "", reason: .error,
                                       message: "This machine did not say.", canInit: false))
            return
        }
        // `root` is only ever present on a real status, which is the one field
        // that tells the two shapes apart without guessing at the union's tag.
        if let root = o["root"] as? String, let cwd = o["cwd"] as? String {
            let b = o["branch"] as? [String: Any] ?? [:]
            func changes(_ key: String, _ fallback: GitFileGroup) -> [GitFileChange] {
                (o[key] as? [Any] ?? []).compactMap { row -> GitFileChange? in
                    guard let e = row as? [String: Any], let path = e["path"] as? String else { return nil }
                    return GitFileChange(
                        path: path,
                        origPath: e["origPath"] as? String,
                        group: GitFileGroup(rawValue: e["group"] as? String ?? "") ?? fallback,
                        code: e["code"] as? String ?? "",
                        kind: GitChangeKind(rawValue: e["kind"] as? String ?? "") ?? .unknown,
                        score: (e["score"] as? NSNumber)?.intValue,
                        insertions: (e["insertions"] as? NSNumber)?.intValue,
                        deletions: (e["deletions"] as? NSNumber)?.intValue,
                        binary: e["binary"] as? Bool ?? false)
                }
            }
            self = .repo(GitRepoStatus(
                cwd: cwd,
                root: root,
                branch: GitBranchState(name: b["name"] as? String,
                                       detached: b["detached"] as? Bool ?? false,
                                       oid: b["oid"] as? String,
                                       upstream: b["upstream"] as? String,
                                       ahead: (b["ahead"] as? NSNumber)?.intValue ?? 0,
                                       behind: (b["behind"] as? NSNumber)?.intValue ?? 0),
                staged: changes("staged", .staged),
                unstaged: changes("unstaged", .unstaged),
                untracked: changes("untracked", .untracked),
                conflicted: changes("conflicted", .conflicted),
                clean: o["clean"] as? Bool ?? false))
            return
        }
        self = .notRepo(GitNotRepo(
            cwd: o["cwd"] as? String ?? "",
            reason: GitUnavailable(rawValue: o["reason"] as? String ?? "") ?? .error,
            message: o["message"] as? String ?? "This folder is not a git repository.",
            canInit: o["canInit"] as? Bool ?? false))
    }

    var repository: GitRepoStatus? {
        if case let .repo(status) = self { return status }
        return nil
    }

    var unavailable: GitNotRepo? {
        if case let .notRepo(reason) = self { return reason }
        return nil
    }

    /// The folder this is about, whichever answer it is.
    var cwd: String {
        switch self {
        case let .repo(status): return status.cwd
        case let .notRepo(reason): return reason.cwd
        }
    }
}

/**
 * The last `git.state` frame, as a screen holds it.
 *
 * The folder travels beside the answer because one connection can have two of
 * these in flight — a Source control screen and a machine tile asking about
 * different folders — and a screen has to be able to tell *its* answer from the
 * one that arrived a moment earlier for somebody else. The same rule
 * `FileListing.path` and `PanelData.path` keep.
 */
struct GitReport: Equatable, Hashable {
    let path: String
    let status: GitState
}

/**
 * The last `git.patch` frame.
 *
 * `patch` is empty when there was nothing to show, and that is an **answer**
 * rather than a failure: `readFileDiff` returns `''` rather than throwing, *"so
 * a click on a vanished file cannot take the panel down."* All four fields are
 * carried because the staged and unstaged patches for one file are two
 * different answers and only one of them belongs on a given screen.
 */
struct GitPatch: Equatable, Hashable {
    let path: String
    let file: String
    let staged: Bool
    let patch: String
}

/// The one line a branch is drawn as. Here rather than in a view so the source
/// control screen and any tile that names a branch cannot say it differently.
enum GitText {
    /// The branch, or what stands in for one. A detached HEAD is named by its
    /// short oid, because *"detached"* alone tells a person nothing about where
    /// they are; an unborn branch says so rather than printing an empty string.
    static func branch(_ branch: GitBranchState) -> String {
        if let name = branch.name, !name.isEmpty { return name }
        if let oid = branch.oid, !oid.isEmpty { return "detached at \(oid.prefix(7))" }
        return "No commits yet"
    }

    /// `↑2 ↓1`, or nothing at all when there is no upstream to be ahead of.
    static func tracking(_ branch: GitBranchState) -> String? {
        guard branch.upstream != nil, branch.ahead > 0 || branch.behind > 0 else { return nil }
        var parts: [String] = []
        if branch.ahead > 0 { parts.append("↑\(branch.ahead)") }
        if branch.behind > 0 { parts.append("↓\(branch.behind)") }
        return parts.joined(separator: " ")
    }

    /// `+12 −3`, or nothing when the host had no counts for this row — an
    /// untracked file never gets any, and printing `+0 −0` over a whole new file
    /// would be a lie with a number in it.
    static func churn(_ file: GitFileChange) -> String? {
        if file.binary { return "binary" }
        guard let added = file.insertions, let removed = file.deletions,
              added > 0 || removed > 0 else { return nil }
        return "+\(added) −\(removed)"
    }
}

// MARK: - Narrowing

extension WireCodec {

    /* ---- files ------------------------------------------------------------ */

    /**
     * One row of a folder listing, or nil.
     *
     * `path` is required and is taken **verbatim**: it is not display text, it
     * is the value a tap sends back to `files.list` and `files.read`, and
     * stripping a control byte out of it would turn one path into a different
     * legal-looking one — the rule the host's own parser keeps on the way in. A
     * path carrying a control character is therefore dropped rather than
     * cleaned. `name` is display text and is cleaned; a row whose name survives
     * as nothing is dropped too, because a row you cannot read and might tap is
     * worse than a row that is missing.
     */
    static func fileRow(_ value: Any?) -> FileRow? {
        guard let row = value as? [String: Any],
              let path = string(row["path"]), !path.isEmpty,
              !path.unicodeScalars.contains(where: { $0.value <= 0x1f || $0.value == 0x7f }),
              let name = displayLine(row["name"]) else { return nil }
        let directory = row["directory"] as? Bool == true
        return FileRow(
            name: name,
            path: path,
            directory: directory,
            // Unsaid `readable` draws a row somebody may try, and the machine
            // refuses it honestly — the layer that matters. Same default
            // `folders.entries` takes.
            readable: row["readable"] as? Bool ?? true,
            // Absent for a directory by design, and absent for a file the host
            // could not stat. Never defaulted to zero: a zero is drawn as a size.
            size: directory ? nil : whole(row["size"]).flatMap { $0 >= 0 ? $0 : nil },
            at: directory ? nil : epochMillis(row["at"]).map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    /**
     * A whole `files.rows` frame, or nil.
     *
     * `path` is required — an answer that cannot say which folder it describes
     * cannot be drawn under any heading — and the list is not: a readable empty
     * folder is an ordinary answer. A malformed row is dropped rather than
     * taking the listing with it.
     */
    static func fileListing(_ object: [String: Any]) -> FileListing? {
        guard let path = string(object["path"]) else { return nil }
        let rows = (object["entries"] as? [Any] ?? [])
            .prefix(PanelsWire.maxFileRows)
            .compactMap { fileRow($0) }
        return FileListing(path: path, parent: string(object["parent"]), entries: rows)
    }

    /**
     * A whole `files.text` frame, or nil.
     *
     * Only `path` is required. `text` absent reads as empty — which is what a
     * binary file legitimately sends — and `at` absent reads as 0, the offset a
     * read with no cursor started at. `truncated` and `binary` default false,
     * the safe way round: a client that invented "truncated" would put a
     * "shortened" label over a whole file.
     */
    static func fileText(_ object: [String: Any]) -> FileText? {
        guard let path = string(object["path"]) else { return nil }
        return FileText(
            path: path,
            text: string(object["text"]) ?? "",
            at: whole(object["at"]).flatMap { $0 >= 0 ? $0 : nil } ?? 0,
            truncated: object["truncated"] as? Bool == true,
            binary: object["binary"] as? Bool == true)
    }

    /* ---- panels ----------------------------------------------------------- */

    /// One panel row, or nil. `title` is the only required field — a row with no
    /// title is not a shorter row, it is a row about nothing — and it is cleaned
    /// like every other string from another machine that lands on screen.
    static func panelRow(_ value: Any?, index: Int) -> PanelRow? {
        guard let row = value as? [String: Any],
              let title = displayLine(row["title"]) else { return nil }
        return PanelRow(title: title,
                        detail: displayLine(row["detail"]),
                        value: displayLine(row["value"]),
                        status: PanelStatus(wire: string(row["status"])),
                        index: index,
                        // The row's name on the machine, unsanitised on purpose:
                        // it is an id that goes straight back on `panel.act` and
                        // never onto the screen, so cleaning it would change what
                        // is addressed. The parser at the other end bounds it.
                        key: string(row["id"]),
                        actions: panelActions(row["actions"]))
    }

    /**
     * A whole `panel.rows` frame, or nil.
     *
     * The panel name is **required and must be one of the four**, which is the
     * one strict field here. Every panel answers a question this phone asked by
     * name, so an unrecognised one is not a newer host being generous — it is an
     * answer with no screen to be drawn on, and the same call `devServerReport`
     * makes about a status it does not know.
     *
     * `path` is not strict: it is a heading, and a frame that omitted it is
     * still a panel's rows.
     */
    static func panelData(_ object: [String: Any]) -> PanelData? {
        guard let raw = string(object["panel"]), let panel = PanelKind(rawValue: raw) else { return nil }
        let rows = (object["rows"] as? [Any] ?? [])
            .prefix(PanelsWire.maxPanelRows)
            .enumerated()
            .compactMap { panelRow($0.element, index: $0.offset) }
        let scopes = (object["scopes"] as? [Any] ?? []).compactMap { raw -> PanelScope? in
            guard let entry = raw as? [String: Any],
                  let id = string(entry["id"]),
                  let label = displayLine(entry["label"]) else { return nil }
            return PanelScope(id: id, label: label, on: entry["on"] as? Bool == true)
        }
        return PanelData(panel: panel,
                         path: string(object["path"]) ?? "",
                         note: displayLine(object["note"]),
                         notice: displayLine(object["notice"]),
                         scopes: scopes,
                         actions: panelActions(object["actions"]),
                         rows: rows)
    }

    /* ---- git -------------------------------------------------------------- */

    /**
     * The `status` object off a `git.state`, as one of its two answers.
     *
     * The `repo` boolean is the discriminant and is required: a status carrying
     * neither shape is not one of the two answers this union defines, and
     * guessing between them would either hide a repository or invent one.
     * Everything inside each shape is read leniently — one malformed file row
     * must not discard the status.
     */
    static func gitState(_ value: Any?) -> GitState? {
        guard let row = value as? [String: Any], let isRepo = row["repo"] as? Bool else { return nil }
        let cwd = string(row["cwd"]) ?? ""

        if !isRepo {
            let reason = string(row["reason"]).flatMap { GitUnavailable(rawValue: $0) } ?? .error
            return .notRepo(GitNotRepo(
                cwd: cwd,
                reason: reason,
                // A sentence somebody wrote, cleaned and bounded like every
                // other string from another machine. The fallback is this
                // client's own, never a paraphrase of git's stderr.
                message: displayLine(row["message"]) ?? "Git could not read this folder on this machine.",
                canInit: row["canInit"] as? Bool == true))
        }

        let staged = gitFiles(row["staged"], group: .staged)
        let unstaged = gitFiles(row["unstaged"], group: .unstaged)
        let untracked = gitFiles(row["untracked"], group: .untracked)
        let conflicted = gitFiles(row["conflicted"], group: .conflicted)
        return .repo(GitRepoStatus(
            cwd: cwd,
            // A repository root the host did not name is the folder itself,
            // which is what `readGitStatus` falls back to on its own side.
            root: string(row["root"]) ?? cwd,
            branch: gitBranch(row["branch"]),
            staged: staged,
            unstaged: unstaged,
            untracked: untracked,
            conflicted: conflicted,
            // The host's own answer when it gave one, because it was computed
            // over the lists before any of them were capped. Only derived here
            // when it said nothing.
            clean: row["clean"] as? Bool
                ?? (staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && conflicted.isEmpty)))
    }

    /// The branch header, or the empty branch. Never nil: a repository whose
    /// header did not parse is still a repository with files in it, and
    /// discarding the status over a missing branch object would hide them.
    static func gitBranch(_ value: Any?) -> GitBranchState {
        guard let row = value as? [String: Any] else { return .empty }
        return GitBranchState(
            name: displayLine(row["name"]),
            detached: row["detached"] as? Bool == true,
            // Bounded rather than cleaned: an oid is hex, and anything that is
            // not is not one. Kept as-is so it can be compared, and truncated
            // for display where it is drawn.
            oid: string(row["oid"]).flatMap { $0.isEmpty ? nil : String($0.prefix(64)) },
            upstream: displayLine(row["upstream"]),
            ahead: whole(row["ahead"]).flatMap { $0 >= 0 ? $0 : nil } ?? 0,
            behind: whole(row["behind"]).flatMap { $0 >= 0 ? $0 : nil } ?? 0)
    }

    /**
     * One of the four file lists.
     *
     * The **group is taken from the list the row arrived in**, not from the
     * row's own `group` field. That field is redundant on the wire — the host
     * groups by putting the row in one of four arrays — and reading it would
     * introduce a way for a row to claim it belongs somewhere it is not being
     * drawn. Where a row can appear twice (porcelain `MM`), it is two rows in
     * two arrays, and this keeps them distinguishable.
     */
    static func gitFiles(_ value: Any?, group: GitFileGroup) -> [GitFileChange] {
        guard let rows = value as? [Any] else { return [] }
        return rows.prefix(PanelsWire.maxGitFiles).compactMap { gitFile($0, group: group) }
    }

    /**
     * One changed file, or nil.
     *
     * `path` is the only required field: it is the identity, it is what a diff
     * request names, and a row without one could only be filed under a guess.
     * A `kind` this build does not know reads as `.unknown`, which the host
     * itself sends for a letter git printed that it did not recognise — so it is
     * a value, not a reason to drop the row.
     */
    static func gitFile(_ value: Any?, group: GitFileGroup) -> GitFileChange? {
        guard let row = value as? [String: Any],
              let path = string(row["path"]), !path.isEmpty else { return nil }
        return GitFileChange(
            path: path,
            origPath: string(row["origPath"]).flatMap { $0.isEmpty ? nil : $0 },
            group: group,
            // Two characters at most — `M`, or `DU` for a conflict. Bounded
            // because it is drawn in a fixed-width badge beside the name.
            code: String((displayLine(row["code"]) ?? "").prefix(2)),
            kind: string(row["kind"]).flatMap { GitChangeKind(rawValue: $0) } ?? .unknown,
            score: whole(row["score"]),
            insertions: whole(row["insertions"]),
            deletions: whole(row["deletions"]),
            binary: row["binary"] as? Bool == true)
    }
}

// MARK: - Decoding what a panel offered

extension WireCodec {
    /**
     * The buttons on a panel or on one of its rows.
     *
     * Written as one function because the two are the same shape on the wire —
     * `panel.rows` carries `actions` at the top level and again on every row —
     * and because a panel-level action and a row-level one differ only in what
     * they are sent with. `panel.act` names a row through `id` and omits it for
     * the panel's own; nothing about the action itself changes.
     *
     * Every field except `id` and `label` is optional and defaulted, so a host
     * newer than this build can add one without this decoder dropping the
     * action — the rule the rest of this codec follows. An action missing either
     * of those two **is** dropped: a button with no label is a blank control and
     * a button with no id is one that cannot be sent, and both are worse on
     * screen than the absence.
     */
    static func panelActions(_ raw: Any?) -> [PanelAction] {
        (raw as? [Any] ?? []).compactMap { item -> PanelAction? in
            guard let e = item as? [String: Any],
                  let id = string(e["id"]), let label = displayLine(e["label"]) else { return nil }
            let fields = (e["fields"] as? [Any] ?? []).compactMap { fieldRaw -> PanelField? in
                guard let f = fieldRaw as? [String: Any],
                      let fieldID = string(f["id"]), let fieldLabel = displayLine(f["label"]) else { return nil }
                return PanelField(id: fieldID,
                                  label: fieldLabel,
                                  // A prefilled value is edited and sent back, so
                                  // it keeps whatever the host wrote — cleaning it
                                  // would silently rewrite somebody's command line
                                  // the first time they opened the form.
                                  value: string(f["value"]) ?? "",
                                  placeholder: displayLine(f["placeholder"]),
                                  required: f["required"] as? Bool ?? false,
                                  choices: (f["choices"] as? [Any] ?? []).compactMap { string($0) })
            }
            return PanelAction(id: id,
                               label: label,
                               destructive: string(e["kind"]) == "destructive",
                               confirm: displayLine(e["confirm"]),
                               fields: fields)
        }
    }
}
