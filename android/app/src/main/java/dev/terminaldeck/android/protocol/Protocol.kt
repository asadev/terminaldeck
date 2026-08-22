package dev.terminaldeck.android.protocol

/**
 * The Kotlin half of the wire language defined in `src/main/remote/protocol.ts`.
 *
 * The desktop's copy is the normative one. Every constant here is transcribed from it rather than
 * chosen, and the numbers are repeated as literals rather than derived so that a diff against the
 * TypeScript is a diff a human can read. If the two ever disagree, the TypeScript is right and this
 * file is a bug.
 *
 * The asymmetry worth stating: over there the dangerous direction is inbound, because the phone is
 * not their code. Over here it is also inbound, because a socket on a tailnet is not necessarily
 * the desktop — a frame arrives as bytes either way, and [ServerFrames.parse] narrows rather than
 * casts for the same reason `parseClientMessage` does.
 */
object Protocol {

    /** Bumped only for a breaking change; the server refuses a mismatch. */
    const val VERSION = 1

    /** Largest inbound WebSocket message, fragments included. */
    const val MAX_MESSAGE_BYTES = 64 * 1024

    /** Largest `input` payload. A paste, not a file upload. */
    const val MAX_INPUT_BYTES = 16 * 1024

    /** How much replay or live output the desktop puts in one `output` frame. */
    const val OUTPUT_CHUNK_BYTES = 32 * 1024

    const val MIN_COLS = 20
    const val MAX_COLS = 500
    const val MIN_ROWS = 5
    const val MAX_ROWS = 200

    /** Longest `hello.token`. Opaque bearer secret, so bounded rather than pinned to a shape. */
    const val MAX_TOKEN_LENGTH = 200

    /**
     * Longest `host` and `repo` on an inbound `credential.request`.
     *
     * Transcribed from `MAX_CREDENTIAL_HOST_LENGTH` / `MAX_CREDENTIAL_REPO_LENGTH`. 253 is the
     * longest a DNS name can be; 256 is generous for `owner/name` and both are bounds on text that
     * ends up **on a screen somebody reads before approving a push**. A prompt that can be made
     * arbitrarily long is a prompt whose last line — the machine that asked — can be pushed off it.
     */
    const val MAX_CREDENTIAL_HOST_LENGTH = 253
    const val MAX_CREDENTIAL_REPO_LENGTH = 256

    /**
     * Longest username and secret this phone may answer a credential request with.
     *
     * The desktop's `parseClientMessage` refuses a longer one and answers a refused frame by
     * closing the socket — so a token past this costs the connection rather than one push. It is
     * therefore checked where a person can still do something about it, when the account is
     * connected, and again on the way out.
     */
    const val MAX_CREDENTIAL_USERNAME_LENGTH = 128
    const val MAX_CREDENTIAL_SECRET_LENGTH = 4096

    /**
     * The bounds on an `enroll` frame's login fields, and on the credential that comes back.
     *
     * Transcribed from `MAX_ENROLL_USERNAME_LENGTH` / `MAX_ENROLL_SECRET_BYTES` /
     * `MAX_ENROLL_CREDENTIAL_LENGTH` in `src/main/remote/protocol.ts`, and checked on this side for
     * the same reason the credential caps are: the desktop answers an over-long field by closing
     * the socket, so a phone that sends one spends the connection instead of getting a sentence
     * back. Checked here, the person is still looking at the field they can fix.
     *
     * The username is a genuine SSH login and is capped tight. The secret is capped in **bytes**
     * rather than code units because a `key` sign-in carries a private-key PEM — kilobytes of
     * base64 with real newlines in it — and it is the one field in this protocol where a line break
     * is content rather than something to refuse.
     *
     * [MAX_ENROLL_CREDENTIAL_LENGTH] bounds what a *host* may hand back: real ones are
     * `<id>.<secret>`, well under a hundred characters, and the cap is what stops a hostile machine
     * answering a sign-in with a megabyte for this phone to keep.
     */
    const val MAX_ENROLL_USERNAME_LENGTH = 64
    const val MAX_ENROLL_SECRET_BYTES = 16 * 1024
    const val MAX_ENROLL_CREDENTIAL_LENGTH = 512

    /**
     * Largest slice of a file in one `upload.data`, before base64.
     *
     * The same number as the desktop's `MAX_NET_CHUNK_BYTES`, because it is the same arithmetic:
     * base64 costs a third on top, so 24 KiB of payload is 32 KiB of JSON string and lands inside
     * [MAX_MESSAGE_BYTES] with the envelope and the sealing tag on it.
     */
    const val MAX_UPLOAD_CHUNK_BYTES = 24 * 1024

    /**
     * How many bytes of a file may be unacknowledged before this phone stops reading.
     *
     * Without it a 200 MB video is handed to the socket as fast as flash can be read, and the Mac's
     * own backpressure cap answers by dropping the phone — a feature that fails only on the large
     * files. It is also what makes the progress bar honest: acknowledgements come from the Mac's
     * write callback, so the bar measures the Mac's appetite rather than this phone's read speed.
     */
    const val UPLOAD_WINDOW_BYTES = 256 * 1024

    /** Largest file the desktop will accept. A 4K video is comfortably past 100 MB. */
    const val MAX_UPLOAD_BYTES = 512L * 1024 * 1024

    /** Longest `upload.begin.name`, in UTF-8 bytes. What it becomes on disk is the Mac's decision. */
    const val MAX_UPLOAD_NAME_BYTES = 255

    /**
     * Largest clipboard this app will paste in one gesture.
     *
     * Not a protocol constant. The desktop caps one `input` frame at [MAX_INPUT_BYTES] and says
     * nothing about how many may follow, so [ClientFrames.chunkInput] would turn a 40 MB clipboard
     * into 2,500 frames and the Mac would drop this phone for buffering — a paste that fails as a
     * dropped connection. Refused with both numbers in the sentence instead, because silently
     * sending the first megabyte is the one thing a paste must never do.
     */
    const val MAX_PASTE_BYTES = 1024 * 1024

    /** WebSocket close codes, RFC 6455 §7.4.1 plus the desktop's own reasons. */
    object Close {
        const val NORMAL = 1000
        const val GOING_AWAY = 1001
        const val PROTOCOL_ERROR = 1002
        const val UNSUPPORTED_DATA = 1003
        const val POLICY_VIOLATION = 1008
        const val MESSAGE_TOO_BIG = 1009
        const val INTERNAL_ERROR = 1011
        const val TRY_AGAIN_LATER = 1013
    }

    /**
     * Session ids are UUIDs from the desktop's session layer; treat anything else as hostile.
     *
     * Anchored at both ends. A Kotlin `Regex.matches` is whole-string, unlike `Regex.find`, and the
     * anchors are kept anyway so this reads as the same expression as the TypeScript.
     */
    val ID_PATTERN = Regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")

    fun isValidSessionId(value: String): Boolean = ID_PATTERN.matches(value)

    /**
     * Whether a size is one the desktop will accept, so a broken layout is caught before it becomes
     * a refused frame and a dropped socket.
     */
    fun isValidSize(cols: Int, rows: Int): Boolean =
        cols in MIN_COLS..MAX_COLS && rows in MIN_ROWS..MAX_ROWS

    /** Clamp a measured viewport into the accepted range instead of refusing to attach. */
    fun clampCols(cols: Int): Int = cols.coerceIn(MIN_COLS, MAX_COLS)

    fun clampRows(rows: Int): Int = rows.coerceIn(MIN_ROWS, MAX_ROWS)

    /**
     * UTF-8 length without allocating the encoded copy.
     *
     * The desktop counts this way because `Buffer` is unavailable in one of its two runtimes. Here
     * `String.toByteArray().size` would work, but it allocates a copy of a string we may be about
     * to refuse for being enormous — which is the case the count exists to catch.
     */
    fun utf8Length(value: String): Int {
        var bytes = 0
        var i = 0
        while (i < value.length) {
            val code = value[i].code
            when {
                code < 0x80 -> bytes += 1
                code < 0x800 -> bytes += 2
                code in 0xd800..0xdbff && i + 1 < value.length -> {
                    val low = value[i + 1].code
                    if (low in 0xdc00..0xdfff) {
                        bytes += 4
                        i += 1
                    } else {
                        bytes += 3
                    }
                }
                else -> bytes += 3
            }
            i += 1
        }
        return bytes
    }

    /**
     * Over a byte cap, decided the cheap way first.
     *
     * A UTF-16 code unit is never fewer than one UTF-8 byte, so `length > cap` already proves the
     * string is too big and the counting loop can be skipped. Below that the count has to be exact:
     * 8,192 emoji are 8,192 units and 32,768 bytes.
     */
    fun overBytes(value: String, cap: Int): Boolean =
        if (value.length > cap) true else utf8Length(value) > cap
}

/**
 * Whether a clipboard is too big to paste, and the sentence to say if it is. Null when it will go.
 *
 * A free function next to the protocol rather than a branch inside the view model, so it can be
 * tested without an Android framework — it is the half of pasting that is a pure function and the
 * half with a decision in it.
 *
 * The decision: **refuse, do not shorten.** [ClientFrames.chunkInput] would happily cut a 40 MB
 * clipboard into 2,500 frames, at which point the Mac's own backpressure cap drops this phone and a
 * paste that was too big fails as *the connection dying* — the least actionable failure there is.
 * The other tempting option, sending the first megabyte, is worse still: the user watches text land,
 * believes all of it did, and the command that runs is not the command they copied.
 *
 * Both numbers are in the sentence, because "too large" is not something a person can act on.
 */
fun pasteRefusal(text: String): String? {
    val bytes = Protocol.utf8Length(text)
    if (bytes <= Protocol.MAX_PASTE_BYTES) return null
    return "That clipboard is ${dev.terminaldeck.android.transfer.byteSize(bytes.toLong())} — the most " +
        "this can paste at once is ${dev.terminaldeck.android.transfer.byteSize(Protocol.MAX_PASTE_BYTES.toLong())}. " +
        "Send it as a file instead."
}

/**
 * What a desktop can advertise beyond protocol version 1, in `welcome.capabilities`.
 *
 * A named object rather than loose strings, because a capability string is a **promise about a wire
 * shape** and getting one wrong does not fail to compile — it lights a button up and then closes
 * the socket on the frame that button sends.
 *
 * This build spent a while gated on `session.create`, answering with `{"t":"new"}`, and no desktop
 * ever advertised either: both were invented against this repo's own stand-in host. The real
 * desktop advertises [CREATE] and speaks `{"t":"create"}`. The old name was deliberately *not*
 * reused for the new shape — to an installed build `session.create` still means "answers `new`", so
 * a desktop advertising it would light that button up and then refuse its frame. Capability
 * negotiation doing its job looks exactly like an old build staying dark.
 */
object Capability {
    /** The desktop can start a session. Answers `create` with `created`. */
    const val CREATE = "create"

    /**
     * The desktop can end a session this phone asks it to. Answers `close` with `closed`.
     *
     * Gated like every other verb the phone sends: the ✕ is drawn only when this appeared in
     * `welcome.capabilities`. It matters more here than anywhere else because closing is not
     * undoable — a Close that turned out to be refused would be a control that either did nothing or
     * destroyed something, with no way to tell which until afterwards. Two hosts withhold it and both
     * are real: a session layer that cannot end a session, and the public demo box that hands
     * strangers a shell and offers `create` without this one.
     */
    const val CLOSE = "close"

    /** The desktop can list its own listening ports and tunnel to one. Not implemented here yet. */
    const val LOCALHOST = "localhost"

    /**
     * The desktop can receive a file, and has somewhere to put it.
     *
     * Not every host does — a build handed no downloads folder does not advertise this — and a Send
     * File button on a phone talking to one would produce nothing but a refusal.
     */
    const val UPLOAD = "upload"

    /**
     * Git on the desktop may ask **this phone** for a GitHub login.
     *
     * The only capability that runs backwards, and that changes what the string means on each side.
     * Every other name here is a verb this phone sends and the desktop serves; this one is a
     * question the desktop asks and this phone answers. So it is advertised in *both* directions —
     * the desktop puts it in `welcome.capabilities` to say "I may ask you", and this client puts it
     * in [CLAIMED] to say "I can answer" — and both halves are load bearing. A desktop that asked a
     * phone which had never heard of the frame would sit there until a timer gave up, which is
     * exactly the thirty-second stall on a `git push` the feature exists to not have.
     */
    const val CREDENTIAL = "credential"

    /**
     * The roster of every device signed in here, and the one verb that takes one away.
     *
     * A desktop lists it in `welcome.capabilities` for one of the owner's own devices only — never a
     * guest — and a phone that sees it may ask for the list (`devices.list`), remove a device
     * (`devices.revoke`), and hear the unsolicited `devices.changed` when the roster moves. There is
     * no approve verb: a device is admitted at the trusted surface and nowhere else, so the wire
     * carries revoke, which doubles as deny, and never an approve.
     */
    const val DEVICES = "devices"

    /**
     * The two settings this machine owns rather than each device: the coding tool a fresh session
     * starts with, and whether the last layout is restored at launch.
     *
     * Changing one from the phone is changing the *server*, not the phone's own copy of it — the
     * same on every device that reaches it. The closed allowlist is [dev.terminaldeck.android
     * .protocol.ServerSetting], which is the whole reason `remote.*` and `advanced.*` are
     * unrepresentable here rather than merely refused.
     */
    const val SETTINGS = "settings"

    /**
     * What this build tells a desktop it can do, in `hello.capabilities`.
     *
     * Only names that run desktop→phone belong here. [CREATE], [LOCALHOST] and [UPLOAD] are things
     * this phone *asks for* and are gated on what the desktop advertised, so claiming them would
     * say nothing at all; [CREDENTIAL] is a frame the desktop sends only once it has been told
     * somebody is listening for it.
     */
    val CLAIMED: List<String> = listOf(CREDENTIAL)
}

/** A session as the phone sees it. Enough to draw a list and pick one. */
data class RemoteSessionView(
    val id: String,
    val title: String,
    val cwd: String,
    val provider: String,
    val status: String,
    val exitCode: Int?,
) {
    val isFinished: Boolean get() = exitCode != null
}
