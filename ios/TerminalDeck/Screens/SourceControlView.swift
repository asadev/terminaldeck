/**
 * What git says about a folder on the machine — on the phone.
 *
 * > *"what about files, artifacts, source control, store, ai readiness, mcp
 * > servers in ios app too for server"* — and then, when offered two of them:
 * > *"all what i asked for so many times, i need all no exceptions."*
 *
 * This is the *source control* one. It draws exactly what `src/main/git.ts`
 * answers and nothing else: the branch and where it stands against its upstream,
 * then the four lists git itself keeps — **staged, unstaged, untracked,
 * conflicted** — each row carrying the change git named it with.
 *
 * ## Nothing here writes, and that is the capability's own rule
 *
 * `protocol.ts` states it on the `git` capability: *"Read-only, like `files`
 * beside it. Status and a diff, never a commit: a commit is a decision with a
 * message and a body, made in a session where the agent that wrote the change is
 * standing, not tapped out on a phone."* So there is no stage button, no
 * discard, no commit — and, less obviously, **no Init button** either. The
 * desktop panel has one, because `git.ts` exports `initRepository` over IPC;
 * the wire carries no such verb, so a button here would be a control that could
 * only ever refuse. `canInit` is still read, but only to say the true sentence.
 *
 * ## The vocabulary is git's, not mine
 *
 * Group names, change kinds and reasons are `GitFileGroup`, `GitChangeKind` and
 * `GitUnavailableReason` verbatim. Renaming *unstaged* to "not staged" on the
 * phone would mean two products with two names for one list, and the person
 * reading this screen is the person who reads `git status` in the session
 * underneath it.
 *
 * ## A folder with no repository is an answer, not a failure
 *
 * `GitStatusResult` is a union and the *not a repo* half carries a `reason` and
 * a `message`. Drawing it as an error — a red banner, a retry button — would be
 * telling somebody their Documents folder is broken. It gets its own quiet
 * state naming which of the four reasons it was.
 */

import SwiftUI

// MARK: - The shapes the wire carries
/*
 * **There is no second decoder here, and that is the point.**
 *
 * This screen shipped with its own `GitFileChange`, `GitRepoStatus`, `GitNotRepo`
 * and `GitState`, each parsing the same `git.state` frame that
 * `Protocol/PanelsWire.swift` already parses — two vocabularies for one wire,
 * which is two things that have to agree forever and eventually will not.
 * The wire`s types are the ones the codec decodes into, so they are the ones
 * this draws.
 */

// `GitPatch` lives in `Protocol/PanelsWire.swift`, beside the frame it
// carries.

// MARK: - The screen

struct SourceControlView: View {
    let model: DeckModel
    /// The folder this screen is about. Not necessarily the repository root —
    /// git answers for the root above it and says so.
    let path: String

    /// This screen's own answer, or nil while the first one is in flight. Read
    /// off the model rather than held, so a pushed `git.state` redraws it.
    /// Read off the model rather than held, so a pushed `git.state` redraws it.
    private var state: GitState? { model.gitState }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Source control")
        .navigationBarTitleDisplayMode(.inline)
        // `id:` rather than `onAppear`, so a screen pushed for a second folder
        // asks again instead of showing the first folder's answer.
        .task(id: path) { model.gitStatus(path) }
        .refreshable {
            model.gitStatus(path)
            // The pull gesture needs something to hold on to or it snaps back
            // before the answer arrives and reads as having done nothing. The
            // same 450ms the session list and the localhost list wait.
            try? await Task.sleep(for: .milliseconds(450))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .repo(let repo):
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    branchCard(repo)
                    if repo.clean {
                        clean
                    } else {
                        group("Conflicted", repo.conflicted, staged: false)
                        group("Staged", repo.staged, staged: true)
                        group("Unstaged", repo.unstaged, staged: false)
                        group("Untracked", repo.untracked, staged: false)
                    }
                    TabBarClearance()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

        case .notRepo(let missing):
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    noRepo(missing)
                    TabBarClearance()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

        case nil:
            ProgressView().controlSize(.regular)
        }
    }

    // MARK: - Where HEAD is

    @ViewBuilder
    private func branchCard(_ repo: GitRepoStatus) -> some View {
        caption("Branch", about: "the branch", says: """
            Ahead is commits you have that the upstream does not; behind is \
            commits it has that you do not. Both are counted against the \
            upstream branch git is tracking, and neither appears when there is \
            no upstream to count against.
            """)
        card {
            plain("On", branchTitle(repo.branch))
            line
            plain("Commit", repo.branch.oid.map { String($0.prefix(7)) } ?? "No commits yet")
            if let upstream = repo.branch.upstream {
                line
                plain("Upstream", upstream)
                line
                standing(repo.branch)
            }
            // Only when it differs: printing the root under every folder that
            // *is* the root would be a row that says the title again.
            if repo.root != repo.cwd {
                line
                plain("Repository", repo.root)
            }
        }
    }

    /// A detached HEAD has no name, and calling it one would be a lie a person
    /// acts on. `GitBranch.name` is null exactly then.
    private func branchTitle(_ branch: GitBranchState) -> String {
        if let name = branch.name, !name.isEmpty { return name }
        return branch.detached ? "Detached HEAD" : "Unborn branch"
    }

    /// Ahead and behind, as words rather than two arrows somebody has to decode.
    private func standing(_ branch: GitBranchState) -> some View {
        HStack(spacing: 12) {
            Text("Standing")
                .font(.system(size: 16))
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 8)
            if branch.ahead == 0 && branch.behind == 0 {
                Text("Up to date")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.faint)
            } else {
                HStack(spacing: 10) {
                    if branch.ahead > 0 {
                        Text("\(branch.ahead) ahead")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.positive)
                    }
                    if branch.behind > 0 {
                        Text("\(branch.behind) behind")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    // MARK: - The four lists

    /**
     * One of git's four lists, drawn only when it has something in it.
     *
     * An empty *Conflicted* heading over an empty card on every clean-ish
     * repository would be four captions of furniture on a screen that usually
     * has one list. A list that is empty is not information here — `clean`
     * already carries *"nothing has changed"* for the case where that is the
     * whole answer.
     */
    @ViewBuilder
    private func group(_ title: String, _ files: [GitFileChange], staged: Bool) -> some View {
        if !files.isEmpty {
            caption("\(title) · \(files.count)")
            card {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { line }
                    fileRow(file, staged: staged)
                }
            }
        }
    }

    private func fileRow(_ file: GitFileChange, staged: Bool) -> some View {
        NavigationLink {
            DiffView(model: model, path: path, file: file, staged: staged)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(for: file.kind.rawValue))
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(tint(for: file.kind.rawValue))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name(of: file.path))
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle(file))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                stat(file)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("git.file.\(file.id)")
    }

    /// The second line: what git called the change, and where the file is. A
    /// rename says where it came from instead — that is the fact the path alone
    /// cannot carry, and `origPath` is set only on renames and copies.
    private func subtitle(_ file: GitFileChange) -> String {
        let kind = file.kind.rawValue.prefix(1).uppercased() + file.kind.rawValue.dropFirst()
        if let origin = file.origPath, !origin.isEmpty {
            let similarity = file.score.map { " · \($0)%" } ?? ""
            return "\(kind) from \(origin)\(similarity)"
        }
        let folder = (file.path as NSString).deletingLastPathComponent
        return folder.isEmpty ? kind : "\(kind) · \(folder)"
    }

    /// `+n −n`, or *Binary*, or nothing at all.
    ///
    /// Nothing at all is the honest answer for an untracked file: `insertions`
    /// and `deletions` *"stay null"* for those, and drawing `+0 −0` there would
    /// be reporting a measurement nobody took.
    @ViewBuilder
    private func stat(_ file: GitFileChange) -> some View {
        if file.binary {
            Text("Binary")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
        } else if file.insertions != nil || file.deletions != nil {
            HStack(spacing: 6) {
                if let added = file.insertions, added > 0 {
                    Text("+\(added)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.positive)
                }
                if let removed = file.deletions, removed > 0 {
                    Text("−\(removed)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.critical)
                }
            }
        }
    }

    private func name(of path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    /// One glyph per `GitChangeKind`. `unknown` is a real case in that union —
    /// a code this build has not seen — and it gets a neutral mark rather than
    /// being drawn as one of the kinds it might be.
    private func icon(for kind: String) -> String {
        switch kind {
        case "added": return "plus"
        case "modified": return "pencil"
        case "deleted": return "minus"
        case "renamed": return "arrow.turn.down.right"
        case "copied": return "doc.on.doc"
        case "typechange": return "arrow.triangle.2.circlepath"
        case "untracked": return "questionmark"
        case "conflicted": return "exclamationmark.triangle"
        default: return "circle"
        }
    }

    private func tint(for kind: String) -> Color {
        switch kind {
        case "added": return Theme.positive
        case "deleted": return Theme.critical
        case "conflicted": return Theme.critical
        case "untracked": return Theme.warning
        default: return Theme.secondary
        }
    }

    // MARK: - The two quiet answers

    private var clean: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("Changes")
            card {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Theme.positive)
                        .frame(width: 24)
                    Text("Nothing has changed.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
        .accessibilityIdentifier("git.clean")
    }

    /**
     * The folder has no readable repository, and this says which of the four
     * reasons it was.
     *
     * `message` is always printed here, unlike on the desktop. `git.ts` drops it
     * *"when there is a button"* — the button and the title say the whole thing
     * between them — and this screen has no button, so the sentence is the only
     * thing carrying git's own words about, say, dubious ownership.
     */
    private func noRepo(_ missing: GitNotRepo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("Source control")
            card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: glyph(for: missing.reason.rawValue))
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 24)
                        Text(headline(for: missing))
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                    }
                    if !missing.message.isEmpty {
                        Text(missing.message)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 36)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .accessibilityIdentifier("git.norepo.\(missing.reason)")
    }

    /// `GitUnavailableReason`, in a sentence. `not-a-repo` splits on `canInit`
    /// because the two halves are genuinely different facts: an ordinary folder,
    /// versus a repository git can see and is refusing to read.
    private func headline(for missing: GitNotRepo) -> String {
        switch missing.reason.rawValue {
        case "not-a-repo":
            return missing.canInit
                ? "There is no git repository in this folder."
                : "git will not read the repository here."
        case "git-missing":
            return "git is not installed on this machine."
        case "no-such-folder":
            return "That folder is not on this machine any more."
        default:
            return "git could not read this folder."
        }
    }

    private func glyph(for reason: String) -> String {
        switch reason {
        case "not-a-repo": return "folder"
        case "git-missing": return "wrench.and.screwdriver"
        case "no-such-folder": return "questionmark.folder"
        default: return "exclamationmark.triangle"
        }
    }

    // MARK: - Its own chrome

    /*
     * Drawn here rather than borrowed, for the reason `MachineDetailView` states
     * at the same place: `SectionCaption`, `SettingsGroup` and `SettingsDivider`
     * are **private to `DeckTabs.swift`**, so a screen reaching for them would
     * have to live inside that file. Same shapes at the same metrics — an 11pt
     * kerned caption, a `Theme.surface` card at radius 20, and a hairline inset
     * to the label rather than to the card's edge.
     */
    private func caption(_ text: String) -> some View {
        captionBand(text) { EmptyView() }
    }

    /// The same caption with an ⓘ on the end — the only place on this screen an
    /// explanation is allowed to live. See `InfoDot`.
    private func caption(_ text: String, about: String, says: String) -> some View {
        captionBand(text) { InfoDot(about: about, text: says) }
    }

    private func captionBand<Trailing: View>(
        _ title: String,
        @ViewBuilder _ trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)
            trailing()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func plain(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
