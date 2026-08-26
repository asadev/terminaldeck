package dev.terminaldeck.android.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/**
 * Files and git, as this client reads them off the wire.
 *
 * A port of the `files.*` and `git.*` families from `src/main/remote/protocol.ts`, and of the
 * `GitStatusResult` union in `src/main/git.ts`. Nothing here reimplements git or a directory
 * listing — the host answers with `readGitStatus` and `readFileDiff` verbatim and this file is only
 * the narrowing that turns those answers into something a phone can draw.
 *
 * The panels that arrived beside these on the same wave live one file over in [PanelData]; they were
 * split out because a file tree and a store listing share a capability negotiation and nothing else.
 *
 * ## Read-only, all of it
 *
 * There is no write verb on any of these frames and this file must not grow one. A file on a machine
 * you cannot see is edited in a session with an agent in it, not on a phone keyboard — see the
 * capability notes on [Capability.FILES] and [Capability.GIT].
 *
 * ## Two rules the decoding keeps, both from the desktop
 *
 *  1. **A folder that is not a repository is an answer, not an error.** The wire carries
 *     `GitRepoStatus | GitNotRepo` and both are worth drawing — one has a branch and four lists of
 *     files, the other a reason and a sentence — so [GitState] is a union rather than a status with
 *     a nullable everything.
 *  2. **A value a newer host grew is folded, never thrown on.** An unknown [GitChangeKind] reads as
 *     [GitChangeKind.Unknown] — the host itself sends that for a porcelain letter it did not know —
 *     and an unknown [GitUnavailable] reads as [GitUnavailable.Error]. `coerceInputValues` on
 *     [ProtocolJson] is what makes that automatic, which is why each of those two carries a default.
 */

/**
 * One entry in a folder listing — a file or a directory.
 *
 * `at` is epoch milliseconds, or null where the host sent no stamp; a screen that wants a `Date`
 * builds one, because the wire carries a number and the app carries whatever it draws. `readable`
 * defaults to **true** so a host that does not annotate a row draws one a tap is worth trying on —
 * the machine refuses an unreadable file honestly, which is the layer that matters.
 */
@Serializable
data class FileRow(
    val name: String,
    val path: String,
    val directory: Boolean = false,
    val readable: Boolean = true,
    /** Bytes on disk, or null for a directory and for a host that did not say. */
    val size: Long? = null,
    /** Last modified, epoch milliseconds, or null when the host sent none. */
    val at: Long? = null,
)

/**
 * A folder's contents — the answer to a `files.list`, and a frame in its own right.
 *
 * Directories and files together; the host returns them directories-first and this end keeps that
 * order rather than sorting, because the order the machine drew is the one a person will recognise.
 * `parent` is null at the filesystem root and is what an "up" row is drawn from — working it out on
 * the phone would mean a phone that knows where the root is on Windows.
 */
@Serializable
@SerialName("files.rows")
data class FileListing(
    val path: String,
    val parent: String? = null,
    val entries: List<FileRow> = emptyList(),
) : ServerMessage

/**
 * One file's bytes as text, the answer to a `files.read`.
 *
 * `truncated` is why this is not just a string: a file read in a window says so rather than showing
 * a body that silently stops. `binary` is the host's answer from the bytes — it includes a NUL — not
 * a guess from an extension, and `text` is empty whenever it is true. [nextOffset] is where the next
 * read begins, so a screen pages a large file forward from the offset the host actually returned
 * rather than from one it computed for itself.
 */
@Serializable
@SerialName("files.text")
data class FileText(
    val path: String,
    val text: String = "",
    /** The offset this slice began at. Bytes, not characters. */
    val at: Int = 0,
    val truncated: Boolean = false,
    val binary: Boolean = false,
) : ServerMessage {
    /** The offset a paging read continues from: this slice's start plus its length in UTF-8 bytes. */
    val nextOffset: Int get() = at + Protocol.utf8Length(text)
}

/* ---- git ------------------------------------------------------------------------------------- */

/** Which of the four lists a changed file arrived in. A word a newer host grows folds to [Unstaged]. */
@Serializable
enum class GitFileGroup {
    @SerialName("staged")
    Staged,

    @SerialName("unstaged")
    Unstaged,

    @SerialName("untracked")
    Untracked,

    @SerialName("conflicted")
    Conflicted,
}

/**
 * What kind of change a file has.
 *
 * [Unknown] is not a failure to parse: the host itself sends it for a porcelain letter git printed
 * that it did not recognise, so it is a value the row draws rather than a reason to drop the row.
 */
@Serializable
enum class GitChangeKind {
    @SerialName("added")
    Added,

    @SerialName("modified")
    Modified,

    @SerialName("deleted")
    Deleted,

    @SerialName("renamed")
    Renamed,

    @SerialName("copied")
    Copied,

    @SerialName("typechange")
    Typechange,

    @SerialName("untracked")
    Untracked,

    @SerialName("conflicted")
    Conflicted,

    /** The host's own bucket for a letter it did not recognise, and where an unknown one folds. */
    @SerialName("unknown")
    Unknown,
}

/**
 * The branch header of a repository.
 *
 * `name` is null when HEAD is detached and `oid` is null on an unborn branch — both are ordinary
 * states of a real repository, which is why neither is defaulted to a string. `ahead`/`behind` are 0
 * with no upstream, which is what git says about a branch nobody is tracking.
 */
@Serializable
data class GitBranchState(
    val name: String? = null,
    val detached: Boolean = false,
    val oid: String? = null,
    val upstream: String? = null,
    val ahead: Int = 0,
    val behind: Int = 0,
) {
    companion object {
        /** The empty branch the host builds before it has parsed a header — a repository with no
         *  commits in it decodes to this rather than to a missing object. */
        val EMPTY = GitBranchState()
    }
}

/**
 * One changed file.
 *
 * Identified by group **and** path, because a file that is both staged and dirty — porcelain `MM` —
 * is genuinely two rows in two lists, exactly as `git status` prints it. `insertions`/`deletions`
 * stay null until the host's numstat pass fills them in, and stay null for an untracked file, so a
 * row prints nothing rather than `+0 −0` for a file whose whole content is new.
 */
@Serializable
data class GitFileChange(
    /** Repository-root-relative, always. The only field the host guarantees on every row. */
    val path: String,
    /** Set only on the staged side of a rename or a copy. */
    val origPath: String? = null,
    val group: GitFileGroup = GitFileGroup.Unstaged,
    /** The letter git printed — `M A D R C T ?` — or the two-letter `XY` for a conflict. */
    val code: String = "",
    val kind: GitChangeKind = GitChangeKind.Unknown,
    /** Rename/copy similarity percentage, when git reported one. */
    val score: Int? = null,
    val insertions: Int? = null,
    val deletions: Int? = null,
    val binary: Boolean = false,
) {
    /** The file's own name, for a row that shows the folder separately. */
    val name: String get() = path.substringAfterLast('/')
}

/** A repository, and everything in it that has moved. A port of `GitRepoStatus`. */
@Serializable
data class GitRepoStatus(
    /** The folder that was asked about. */
    val cwd: String = "",
    /** The repository root, which may sit above [cwd]. Empty is read as [cwd] by [rootOrCwd]. */
    val root: String = "",
    val branch: GitBranchState = GitBranchState.EMPTY,
    val staged: List<GitFileChange> = emptyList(),
    val unstaged: List<GitFileChange> = emptyList(),
    val untracked: List<GitFileChange> = emptyList(),
    val conflicted: List<GitFileChange> = emptyList(),
    /** The host's own answer, computed over the lists before they were capped for the wire. */
    val clean: Boolean = false,
) {
    /** The repository root, falling back to the folder itself — what `readGitStatus` does over there. */
    val rootOrCwd: String get() = root.ifEmpty { cwd }

    val changeCount: Int get() = staged.size + unstaged.size + untracked.size + conflicted.size
}

/** Why git had nothing to say. A port of `GitUnavailableReason`. */
@Serializable
enum class GitUnavailable {
    @SerialName("not-a-repo")
    NotARepo,

    @SerialName("git-missing")
    GitMissing,

    @SerialName("no-such-folder")
    NoSuchFolder,

    /** The host's own bucket for a failure nobody anticipated, and where an unknown word folds. */
    @SerialName("error")
    Error,
}

/**
 * A folder git will not report on, said in words. A port of `GitNotRepo`.
 *
 * `message` is a sentence somebody wrote and is rendered verbatim, never git's own stderr. `canInit`
 * is whether `git init` here would actually change anything — **not** the same question as
 * `reason == NotARepo`, because a repository git refuses to read for dubious ownership reports that
 * same reason and running init there would make a second repository beside the one on disk. There is
 * no init verb on this wire, so the flag is carried for what it says, not for a button.
 */
@Serializable
data class GitNotRepo(
    val cwd: String = "",
    val reason: GitUnavailable = GitUnavailable.Error,
    val message: String = "This folder is not a git repository.",
    val canInit: Boolean = false,
)

/**
 * What git said about a folder: a status, or a reason there is none.
 *
 * Discriminated on the wire's `repo` boolean — `GitRepoStatus` carries `repo: true` and `GitNotRepo`
 * `repo: false` in `src/main/git.ts`, which is the authority the two iOS decoders were split over —
 * so a caller cannot read a branch off a folder that has no repository. **Both cases are answers.**
 * Converting the not-a-repository one into an error would put a failure banner over a fact.
 *
 * A malformed status is answered as [NotRepo] with [GitUnavailable.Error] rather than thrown on,
 * because this runs on a socket's data path; see [GitStateSerializer].
 */
@Serializable(with = GitStateSerializer::class)
sealed interface GitState {
    data class Repo(val status: GitRepoStatus) : GitState
    data class NotRepo(val status: GitNotRepo) : GitState

    /** The status when this is a repository, else null. */
    val repository: GitRepoStatus? get() = (this as? Repo)?.status

    /** The reason when this is not a repository, else null. */
    val unavailable: GitNotRepo? get() = (this as? NotRepo)?.status

    /** The folder this is about, whichever answer it is. */
    val cwd: String get() = repository?.cwd ?: unavailable?.cwd ?: ""
}

/**
 * Decodes the `status` object off a `git.state`, leniently, into one of its two shapes.
 *
 * `repo` is the discriminant and it is read the strict way — only a literal boolean `true` is a
 * repository — because everything else about the two shapes differs and guessing between them would
 * either hide a repository or invent one. Everything *inside* each shape is read leniently by the
 * ordinary [ProtocolJson], so one malformed file row does not discard the status. Anything that is
 * not even a JSON object answers [GitState.NotRepo] with [GitUnavailable.Error] rather than throwing.
 */
object GitStateSerializer : KSerializer<GitState> {
    override val descriptor: SerialDescriptor =
        buildClassSerialDescriptor("dev.terminaldeck.android.protocol.GitState")

    override fun deserialize(decoder: Decoder): GitState {
        val input = decoder as? JsonDecoder ?: return notSaid()
        val element = input.decodeJsonElement()
        val obj = element as? JsonObject ?: return notSaid()
        val isRepo = (obj["repo"] as? JsonPrimitive)?.booleanOrNull == true
        return if (isRepo) {
            GitState.Repo(input.json.decodeFromJsonElement(GitRepoStatus.serializer(), element))
        } else {
            GitState.NotRepo(input.json.decodeFromJsonElement(GitNotRepo.serializer(), element))
        }
    }

    override fun serialize(encoder: Encoder, value: GitState) {
        // This end never sends a git.state; the branch exists so the type is a complete serializer
        // rather than a decode-only one, which is what keeps `@Serializable(with = …)` honest.
        val output = encoder as? JsonEncoder ?: error("GitState only encodes to JSON")
        when (value) {
            is GitState.Repo -> output.encodeSerializableValue(GitRepoStatus.serializer(), value.status)
            is GitState.NotRepo -> output.encodeSerializableValue(GitNotRepo.serializer(), value.status)
        }
    }

    private fun notSaid(): GitState =
        GitState.NotRepo(GitNotRepo(cwd = "", reason = GitUnavailable.Error, message = "This machine did not say."))
}
