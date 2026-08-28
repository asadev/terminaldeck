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
     * The bounds on an `enroll` frame's login fields, and on the credential that comes back.
     *
     * Transcribed from `MAX_ENROLL_USERNAME_LENGTH` / `MAX_ENROLL_SECRET_BYTES` /
     * `MAX_ENROLL_CREDENTIAL_LENGTH` in `src/main/remote/protocol.ts`, and checked on this side
     * because the desktop answers an over-long field by closing the socket, so a phone that sends
     * one spends the connection instead of getting a sentence back. Checked here, the person is
     * still looking at the field they can fix.
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

    /**
     * The one frame allowed past [MAX_MESSAGE_BYTES], and how far past.
     *
     * A `browser.frame` carries a base64 JPEG of a web page, which is by design larger than the
     * text cap every other frame lives under. `parseServerMessage` over in `protocol.ts` measures
     * the cheap cap first and only a message *over* it pays the second check — and the only message
     * allowed through that second door is a frame. [ServerFrames.parse] does exactly the same, in
     * the same order, so the frame's larger allowance is never borrowed by another message.
     *
     * [MAX_FRAME_DATA_CHARS] is what [MAX_FRAME_BYTES] of JPEG becomes in base64: four characters
     * per three bytes, rounded up to a whole group.
     */
    const val MAX_FRAME_BYTES = 67 * 1024
    const val MAX_FRAME_DATA_CHARS = ((MAX_FRAME_BYTES + 2) / 3) * 4
    const val MAX_FRAME_MESSAGE_BYTES = MAX_FRAME_DATA_CHARS + 2 * 1024

    /**
     * The render width and jpeg quality a watcher may ask a host to cast at.
     *
     * Transcribed from `MIN_WATCH_WIDTH`/`MAX_WATCH_WIDTH`/`MIN_WATCH_QUALITY`/`MAX_WATCH_QUALITY`.
     * A viewer clamps into these rather than sending a number the host would clamp silently, so
     * what is on screen is what was asked for.
     */
    const val MIN_WATCH_WIDTH = 160
    const val MAX_WATCH_WIDTH = 1600
    const val MIN_WATCH_QUALITY = 1
    const val MAX_WATCH_QUALITY = 80

    /** How many surfaces a tab strip will draw, and how long a title or a curtain prompt may be. */
    const val MAX_SURFACES_REPORTED = 64
    const val MAX_SURFACE_TITLE_LENGTH = 512
    const val MAX_WATCH_PROMPT_LENGTH = 256

    /** How many touch points one `browser.input` may name. */
    const val MAX_TOUCH_POINTS = 10

    /** The longest a control's value may be on the wire. A model name is the long one. */
    const val MAX_CONTROL_VALUE_LENGTH = 64

    /* ---- capability `web`, `account`, `chat`: the bounds their frames carry ----------------- */

    /**
     * The longest a `web.open` URL may be. Transcribed from `MAX_URL_LENGTH`.
     *
     * Checked on this side for the reason every other cap is: the host answers an over-long field by
     * closing the socket, so a client that sends one spends the connection instead of getting a
     * sentence back.
     */
    const val MAX_URL_LENGTH = 2048

    /** Longest account id on an `account.switch`. Transcribed from `MAX_ACCOUNT_ID_LENGTH`. */
    const val MAX_ACCOUNT_ID_LENGTH = 200

    /** The most account rows one `account.state` may carry. */
    const val MAX_ACCOUNTS_REPORTED = 64

    /* ---- capability `localhost`: the tunnel's own bounds ------------------------------------ */

    /** Largest chunk of tunnelled bytes in one `net.data`, before base64. */
    const val MAX_NET_CHUNK_BYTES = 24 * 1024

    /** The encoded length of a maximal chunk: base64 is four characters per three bytes. */
    const val MAX_NET_DATA_CHARS = ((MAX_NET_CHUNK_BYTES + 2) / 3) * 4

    /**
     * How many bytes one side may have in flight on a stream before it stops reading.
     *
     * A tunnelled socket has no window of its own, so without this a phone pulling a 40 MB source
     * map would have the whole file buffered in the desktop's heap and the desktop would answer by
     * dropping the phone. Each side acknowledges what it has written to its own socket and the
     * sender pauses when the unacknowledged total passes this.
     */
    const val NET_WINDOW_BYTES = 256 * 1024

    /** A TCP port, as the wire will accept one. */
    const val MIN_PORT = 1
    const val MAX_PORT = 65_535

    /* ---- capability `copilot`: the bounds its frames carry ---------------------------------- */

    /**
     * The longest a `copilot.say` may be, in **bytes**.
     *
     * The same cap `input` gets, and for the same reason: the text ends up typed into a live agent's
     * pty. One emoji is four bytes and the cap is about what gets written into a terminal.
     */
    const val MAX_COPILOT_SAY_BYTES = MAX_INPUT_BYTES

    /** The most rows one `copilot.log` may ask for, or be answered with. */
    const val MAX_COPILOT_LOG_ROWS = 200

    /** How long one chat message may be before the desktop marks it truncated. */
    const val MAX_COPILOT_MESSAGE_CHARS = 8 * 1024

    /**
     * Whether a `copilot.say` carries a control character, which is **refused rather than stripped**.
     *
     * This is the security check on that frame rather than a tidiness one. The text is written into a
     * pty holding an agent CLI: a carriage return inside it would submit early and turn the rest of
     * the message into a *second* prompt, and an escape sequence would drive the CLI's own key
     * handling. Stripping would turn a hostile value into a different, legal-looking message — and
     * the result of that is a turn somebody pays for.
     */
    fun hasControlCharacters(value: String): Boolean = value.any { it.isISOControl() }

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
     * The **host** owns a GitHub login, and this phone drives it — read its status, start a
     * device-flow sign-in on the machine, cancel one in flight, or sign it out — over the `github.*`
     * frames.
     *
     * This is the whole feature the other way round from the old credential proxy: the machine that
     * holds the repository holds the login now, and the phone only triggers and views it. The host
     * advertises this in `welcome.capabilities` to say "I own a GitHub you can connect", and this
     * client claims it back in [CLAIMED] because the host pushes an unsolicited `github.changed`
     * when its login moves — a device that never claimed the name would never be sent one, so the
     * "Connected as @…" line would only ever refresh on the next manual read.
     */
    const val GITHUB = "github"

    /**
     * The host owns its own lifecycle, and this phone drives it **over the relay** — its status,
     * and the restart/stop of the host itself.
     *
     * **"The relay is the network."** A server page reaches one box by two roads: an SSH address it
     * was added with, and the relay it is paired over. The SSH address can be a Tailscale name that
     * drops on its own — then the page reports the box as unreachable while every session on it is
     * still running over the relay. The relay does not drop like that, and a machine whose sessions
     * work is a machine whose host is plainly running. So the status a headless server has no screen
     * to show, and the restart/stop it has no screen to press, are answered over these `host.*`
     * frames when the box is a connected machine, and SSH is the fallback.
     *
     * A machine that advertises this speaks `host.status` / `host.restart` / `host.stop`. There is no
     * `host.start`: a stopped host is not connected over the relay. Not claimed back in [CLAIMED] —
     * there is no unsolicited push to hear; a restarted host simply reconnects.
     */
    const val HOST_CONTROL = "host.control"

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
     * The session's control cluster — model, effort, fast mode, permission — read and changed.
     *
     * Answered by every desktop since 0.5.0; the desktop's own remote window has always sent
     * `controls.read`/`controls.apply`. A phone that never sent them could watch a session and
     * never change what it runs at. Nothing is drawn over a machine that did not name this.
     */
    const val CONTROLS = "controls"

    /**
     * Watching — and driving — a browser window the machine is holding.
     *
     * Dual-listed like `windows`: the host advertises it to say it can cast, and a client that can
     * draw a cast claims it back in [CLAIMED]. Advertised only to one of the owner's own devices,
     * never a guest, because watching a signed-in browser is an owner act.
     */
    const val WATCH = "watch"

    /**
     * The plan and context figures a session's bar draws.
     *
     * Three readings behind one name, and they do not cost the same: `context` is a transcript read
     * on the far side, `plan` is memory the desktop already holds, and `refresh` boots a whole
     * Claude Code over there — which is why the last is only ever sent because a finger pressed the
     * ring. See [dev.terminaldeck.android.protocol.UsageWant].
     */
    const val USAGE = "usage"

    /** Which login a session runs as, and the verb that switches it. */
    const val ACCOUNT = "account"

    /**
     * Typing a whole message at a session as one act, rather than as keystrokes.
     *
     * What a chat composer sends. It is not `input`: `input` is bytes at a pty and carries no
     * request id, so nothing can say whether they landed; `session.send` is answered with
     * `session.sent`, which is what lets a composer keep a draft on a refusal instead of losing it
     * into a socket.
     */
    const val SEND = "send"

    /** Open a page **on the machine**, in its own browser. A tap here is a tab over there. */
    const val WEB = "web"

    /** One project's dev server: what it is doing, and the one verb that starts it. */
    const val DEVSERVER = "devserver"

    /**
     * The machine's own agent, driven from here.
     *
     * The one capability that is advertised and can still be refused: the host names it when it
     * *has* a copilot, and a device is admitted to it by a separate grant the owner approves at the
     * desk. A client that treated the capability as the permission would draw a tab whose every
     * button answered "not allowed" — which is why [dev.terminaldeck.android.protocol.CopilotAccess]
     * is a second reading rather than a boolean derived from this string.
     */
    const val COPILOT = "copilot"

    /**
     * Give a session a name of your own — `rename { id, title }`.
     *
     * Its own capability rather than a corner of [CLOSE], because the two are genuinely separable at
     * the far end: a host that hands out shells and refuses to end them (the public demo box) can
     * still let somebody label one, and a host whose session layer has no writable title cannot
     * however freely it closes. An older host never advertises it, so the Rename row is absent rather
     * than a press that closes the channel.
     */
    const val RENAME = "rename"

    /**
     * The copilot's own files — its instructions, its memory, its contract — read and edited.
     *
     * A **separate** name from [COPILOT], and the separation is about age rather than permission:
     * every desktop that speaks `copilot` today was built before these frames existed and answers one
     * by closing the channel, so the Files card waits for this name even on a machine whose Copilot
     * tab is fully alive. The gate is the same `copilotFor` door — stripped from a guest beside
     * `copilot` itself — so there is no arrangement of grants in which a guest reaches an instruction
     * file. See [CopilotFiles].
     */
    const val COPILOT_FILES = "copilot.files"

    /**
     * The machine's routines — the saved instructions it runs on its own. See [RoutinesWire].
     *
     * Its own name rather than a corner of [COPILOT] because the two are separable: a routine engine
     * is a folder, a scheduler and a budget, and a machine can hold one without holding a copilot a
     * phone may talk to. Withheld from a guest, on the same line and by the same question as `copilot`
     * — a routine is a prompt this machine runs with this machine's tools, and *"the copilot is never
     * shared"* covers what starts one as squarely as the conversation.
     */
    const val ROUTINES = "routines"

    /**
     * List this machine's files, and open one — `files.list` / `files.read`. See [FileListing].
     *
     * Read-only, and that is the whole capability: there is no write verb and there will not be one,
     * because editing a file on a machine you cannot see from a phone keyboard breaks a repository
     * slowly and a session is the better door. Owner devices only, and more sharply than [FOLDER_PICK]
     * — this reads *file contents*, so a guest that held it could read a private key out of a folder
     * it was never lent.
     */
    const val FILES = "files"

    /**
     * What git says about a folder, and what one file changed — `git.status` / `git.diff`. See
     * [GitState]. Read-only, like [FILES] beside it: status and a diff, never a commit, which is a
     * decision made where the agent that wrote the change is standing. Owner devices only; a diff is
     * file contents by another name.
     */
    const val GIT = "git"

    /**
     * The four read-only panels the desktop has and a phone did not — **artifacts, store, AI
     * readiness, MCP servers** — over one `panel.read` / `panel.rows`. See [PanelData]. One capability
     * for four because each is a list of rows a person reads and does not act on, and the differences
     * are in the words rather than the structure. Owner devices only: a transcript is a session's
     * contents and an MCP config names credentials.
     */
    const val PANELS = "panels"

    /**
     * Walk this machine's folders, so a device can name one it cannot see — `folders.browse` /
     * `folders.entries`. See [FoldersWire]. It reads directory names and grants nothing. Advertised to
     * one of the owner's own devices only; its absence means an older host *or* a guest, and the
     * picker draws the same either way.
     */
    const val FOLDER_PICK = "folders.pick"

    /** The machine's own browser profiles — which one it is using, and its cookies. See
     *  [MachineProfileList]. Owner devices only: a profile *is* somebody's signed-in cookie jar. */
    const val BROWSER_PROFILES = "browser.profiles"

    /** Driving the machine's own browser — its windows, not this phone's. See [MachineBrowserState].
     *  Owner-only, and not a close call: a bound window can be told to navigate anywhere and
     *  photographed, and its output is handed to a session running commands. */
    const val BROWSER_CONTROL = "browser.control"

    /**
     * A GitHub login the desktop connected, listed so a device can see whose account a session runs as.
     *
     * Named here because the host advertises it; this build sends no `logins.*` verb yet, so it is
     * carried for completeness of the vocabulary rather than for a screen. Withheld from a guest at
     * the source, like [DEVICES] and [SETTINGS].
     */
    const val LOGINS = "logins"

    /**
     * A session on **this** machine driving a browser window in the app of the device that started it.
     *
     * Runs the other way round from most names here, so the string means two things by which side
     * sent it: a host lists it to say *"I may ask you to act on a window for one of my sessions"*, a
     * client to say *"I hold windows and I will serve those asks"*. This build advertises neither
     * direction yet; the constant exists so the vocabulary matches the host's.
     */
    const val WINDOWS = "windows"

    /**
     * The mirror of [WINDOWS]: a session on **that** machine driving a browser window in the app of the
     * machine it is talking to. A build shipped before this string existed advertises only `windows`
     * and means the old half, so this is a second capability rather than a wider reading of the first.
     * The wire string is lowercase — `hostwindows` — transcribed from `CAPABILITY.hostWindows`.
     */
    const val HOST_WINDOWS = "hostwindows"

    /**
     * What this build tells a desktop it can do, in `hello.capabilities`.
     *
     * Only names that run desktop→phone belong here. [CREATE], [LOCALHOST] and [UPLOAD] are things
     * this phone *asks for* and are gated on what the desktop advertised, so claiming them would
     * say nothing at all.
     *
     * [GITHUB], [DEVICES], [SETTINGS] and [WATCH] each carry a frame the desktop *pushes* rather
     * than answers — `github.changed`, `devices.changed`, `settings.changed`, `browser.frame` — and
     * `server.ts` skips every connection that did not claim the name before pushing one. A build
     * that did not claim one would watch that state go stale the moment another device moved it: it
     * is why an Android roster went stale until `devices` was claimed, and it is why the host's
     * GitHub login is claimed here rather than only read on demand. This list mirrors
     * `CLAIMED_CAPABILITIES` in `pwa/src/protocol-client.ts` and `WireCapability.claimed` on iOS,
     * which flip credential→github alongside this one. [CONTROLS] is deliberately *not* here: it is
     * a pair of verbs this phone sends, gated on what the desktop advertised, so claiming it would
     * say nothing at all.
     */
    val CLAIMED: List<String> = listOf(GITHUB, DEVICES, SETTINGS, WATCH)
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
