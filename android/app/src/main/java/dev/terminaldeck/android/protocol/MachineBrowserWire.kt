package dev.terminaldeck.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * **The machine's own browser**, as this phone drives it.
 *
 * A port of the `browser.control` and `browser.profiles` families from `src/main/remote/protocol.ts`
 * (`MachineWindow`, `WindowSession`, `RecordedStep`, `PickedRect`, the browser answer union) and of
 * `browser-profiles.ts`. The distinction this whole file holds: the Browser tab's address bar opens a
 * **tunnel** — a machine port bound on this phone's loopback, the page loading in this phone's own
 * web view — while everything here drives the **machine's** Chromium, on the machine's disk, with the
 * machine's cookies, the phone sending verbs and receiving pictures. Recording a click flow, binding
 * a window to a session, or handing a screenshot to an agent only mean anything against a browser the
 * agent can also see, which is that one and not this phone's.
 *
 * ## Every verb answers with the list
 *
 * A [MachineBrowserState] (`browser.window.rows`) is the answer to every `browser.window.*` verb
 * except the three that carry a payload of their own — the screenshot, the recorder's steps and the
 * picked element — so the screen redrawing is the confirmation and there is nothing to reconcile.
 * `browser.profile.use`/`browser.profile.clear` answer the same way, with a [MachineProfileList].
 */
object MachineBrowserWire {
    /** [Capability.BROWSER_CONTROL] on the host. Owner devices only. */
    const val CAPABILITY = "browser.control"

    /** [Capability.BROWSER_PROFILES] on the host. Owner devices only. */
    const val PROFILES_CAPABILITY = "browser.profiles"

    /** The most windows this client draws off one frame; the host sends what it has, this is where a
     *  strip stops being something a thumb can scan. */
    const val MAX_WINDOWS = 40

    /** The most recorded steps drawn at once. Truncation is reported by the host, not inferred here. */
    const val MAX_STEPS = 500

    /**
     * How many ancestors one `browser.window.pick` may ask to walk up.
     *
     * `MAX_PICK_UP` in `protocol.ts`, mirrored because the host's answer to an out-of-range one is
     * **not a refusal, it is a closed socket** — that check lives in the parser, and `server.ts`
     * answers a parse failure by dropping the connection. So Wider clamps to this on the way out and
     * never sends past it: a phone that walked past 64 would take somebody's whole session down.
     */
    const val MAX_PICK_UP = 64

    /**
     * The rectangle a `browser.window.size` may ask a window to lay its page out in, in **CSS
     * pixels** — `MIN/MAX_PAGE_WIDTH`/`HEIGHT` in `protocol.ts`. These bound the **page**, not the
     * picture: `Protocol.MIN_WATCH_WIDTH`/`MAX_WATCH_WIDTH` bound how many image pixels the host
     * encodes, and treating one as the other is the arithmetic the size verb exists to fix. The host
     * clamps rather than refuses, so these are here for honesty — a phone that sent 12 and was
     * silently given 240 would draw a page it never asked for.
     */
    const val MIN_PAGE_WIDTH = 240
    const val MAX_PAGE_WIDTH = 4096
    const val MIN_PAGE_HEIGHT = 160
    const val MAX_PAGE_HEIGHT = 4096

    /** Clamp a measured page rectangle into the range the host will accept, rather than send one it
     *  will silently change. */
    fun clampPageWidth(width: Int): Int = width.coerceIn(MIN_PAGE_WIDTH, MAX_PAGE_WIDTH)

    fun clampPageHeight(height: Int): Int = height.coerceIn(MIN_PAGE_HEIGHT, MAX_PAGE_HEIGHT)

    /** Clamp a Wider request to what the host walks, so an over-range `up` never costs the socket. */
    fun clampPickUp(up: Int): Int = up.coerceIn(0, MAX_PICK_UP)
}

/**
 * The verbs `browser.window.act` accepts — `WINDOW_ACTIONS` in `protocol.ts`, a **closed** list
 * there. Unlike a panel's actions these are not declared by the host per answer, so a word this build
 * sends that the host does not know is a refused frame; the closed enum is what stops one being sent.
 */
@Serializable
enum class BrowserWindowAction {
    @SerialName("back")
    Back,

    @SerialName("forward")
    Forward,

    @SerialName("reload")
    Reload,

    @SerialName("close")
    Close,

    @SerialName("record.on")
    RecordOn,

    @SerialName("record.off")
    RecordOff,

    @SerialName("share")
    Share,

    @SerialName("isolate")
    Isolate,
}

/**
 * One window open in the machine's browser.
 *
 * Every optional is a real absence: no [slot] is a window no session owns, no [profile] is the
 * machine's default partition, [isolated] false is the ordinary shared case. [recording] is the red
 * dot on the row and the one flag here that is a safety state — the host sends a real boolean and this
 * defaults it off, so a window nobody is recording draws no dot.
 */
@Serializable
data class MachineWindow(
    val id: String,
    val title: String = "",
    val url: String = "",
    /** `B1`, `B2` — the name the binding store gave it. Null when unbound. */
    val slot: String? = null,
    /** The session that owns it, when one does. */
    val session: String? = null,
    val sessionTitle: String? = null,
    val profile: String? = null,
    /** A partition of its own, thrown away when the window closes. */
    val isolated: Boolean = false,
    /** Whether the click flow is being recorded on this window right now. */
    val recording: Boolean = false,
    val loading: Boolean = false,
) {
    /** What the row calls it: the page's own title once it has one, the address until then. */
    val label: String get() = title.ifEmpty { url }

    /** Whether a session owns it. Reads better than `slot != null` at the call sites. */
    val isBound: Boolean get() = slot != null
}

/**
 * A session a window could be bound to.
 *
 * [windows] is how many that session already holds, and it is on the row because the binding store
 * hands a session's tools its windows by slot name — a session that owns three is one where the next
 * binding becomes `B4`. Choosing where to attach a window is choosing what that agent will call it.
 */
@Serializable
data class WindowSession(
    val id: String,
    val title: String = "",
    val windows: Int = 0,
)

/**
 * One step the recorder collected. Flat on purpose: the desktop's recorder produces a richer
 * structure and everything past these fields is either a selector nobody reads on a phone or a
 * payload that belongs in the session the flow is being written for.
 */
@Serializable
data class RecordedStep(
    val at: Double = 0.0,
    val kind: String,
    val detail: String? = null,
    val selector: String? = null,
    val value: String? = null,
)

/**
 * Where a picked element sits, in the page's **own** coordinates — `w`/`h`, not `width`/`height`, to
 * match the geometry `browser.frame` already carries. Document coordinates, not viewport: a viewer
 * draws this over the next frame it receives by subtracting that frame's scroll, so an outline stays
 * on the thing it names while the page moves under it.
 */
@Serializable
data class PickedRect(
    val x: Double = 0.0,
    val y: Double = 0.0,
    val w: Double = 0.0,
    val h: Double = 0.0,
)

/**
 * One element on a machine window's page — the facts the sheet that says *change this* is drawn from.
 *
 * The same facts the desktop's capture popup and the phone's own inspect sheet show — tag, selector,
 * label, where the label came from, and the address. [url] is the **host's** knowledge of where the
 * page is, never the page's own claim about it, because this string reaches an agent's prompt.
 * [depth] greys Narrower at the tap itself and [maxUp] greys Wider at the top of the document.
 */
@Serializable
data class InspectedElement(
    val tag: String = "",
    val selector: String = "",
    val label: String = "",
    /** One of `PICK_LABEL_SOURCES`, drawn as it stands when this build does not know the word. */
    val labelSource: String = "",
    val url: String = "",
    val depth: Int = 0,
    val maxUp: Int = 0,
    val rect: PickedRect? = null,
)

/**
 * What `browser.window.rows` carries — the answer to every `browser.window.*` verb except the three
 * with a payload of their own.
 *
 * The wire has no `sent` field; the host trims to its own ceiling and says so in [notice], and
 * [MachineBrowserWire.MAX_WINDOWS] trims again where a strip is drawn. [notDrawn] answers *how many
 * this screen is not showing* off the list as it arrived.
 */
@Serializable
@SerialName("browser.window.rows")
data class MachineBrowserState(
    val windows: List<MachineWindow> = emptyList(),
    val sessions: List<WindowSession> = emptyList(),
    /** What just happened. Set by a verb, cleared by the next plain list. */
    val notice: String? = null,
) : ServerMessage {
    /** How many past the client's own cap the machine sent — zero is the ordinary case. */
    val notDrawn: Int get() = maxOf(0, windows.size - MachineBrowserWire.MAX_WINDOWS)
}

/**
 * A picture of one window — the answer to `browser.window.shot`, when it was not handed to a session
 * instead. [png] is the base64 on the wire; [bytes] decodes it once, the way [ServerMessage.BrowserFrame]
 * decodes its own, so a screen holding this does not decode on every redraw.
 */
@Serializable
@SerialName("browser.shot")
data class MachineShot(
    val id: String,
    val png: String = "",
    val at: Double = 0.0,
) : ServerMessage {
    /** The decoded PNG, or null when the base64 will not decode — a screen draws nothing rather than
     *  stalling on it. */
    fun bytes(): ByteArray? {
        if (png.isEmpty()) return null
        return try {
            java.util.Base64.getDecoder().decode(png)
        } catch (e: IllegalArgumentException) {
            null
        }
    }
}

/* ---- capability `browser.profiles` ----------------------------------------------------------- */

/** Bounds and names for the machine's browser profiles. */
object MachineProfilesWire {
    /** The id of the profile whose partition predates the feature — `DEFAULT_PROFILE_ID`. Never minted
     *  by the machine, and the fallback a dangling `current` resolves back to. */
    const val DEFAULT_PROFILE_ID = "default"

    /** The most profiles this client draws off one frame — a person makes three of these, not three
     *  hundred, so this is the backstop against a malformed or hostile frame. */
    const val MAX_PROFILES = 100
}

/**
 * One profile on the machine — a `persist:` session partition with its own cookie jar, on that
 * machine's disk. Identified by [id], which is what `browser.profile.use`/`.clear` name, never by
 * [name] (two profiles can share one). [sites]/[cookies] are optional and **never drawn as a zero** —
 * absent and none read the same, which is the honest pair.
 */
@Serializable
data class MachineBrowserProfile(
    val id: String,
    val name: String = "",
    /** The one character the badge draws, or empty for the name's initial. */
    val avatar: String = "",
    /** The Electron partition string, or null. Carried for what it says; drawn nowhere. */
    val partition: String? = null,
    val sites: Int? = null,
    val cookies: Int? = null,
) {
    /** The name to show, falling back the way `readProfileState` does rather than to a blank row. */
    val displayName: String
        get() = name.ifEmpty { if (isDefault) "Default" else "Profile" }

    /** The one profile that cannot be deleted on the machine, holding every login from before profiles
     *  existed. It can still be cleared, so this is a fact a confirmation reads, not a hidden control. */
    val isDefault: Boolean get() = id == MachineProfilesWire.DEFAULT_PROFILE_ID
}

/**
 * A whole `browser.profile.rows` — the machine's profiles and which one it is using.
 *
 * [current] is echoed from the wire; [resolvedCurrent] repairs a dangling one against the rows that
 * arrived — the id the machine named if a row still carries it, else the default if it is in the
 * list, else the first row — which is the same repair `readProfileState` performs over there. A
 * dangling id left as-is would draw a screen where nothing is in use and nothing explains why.
 */
@Serializable
@SerialName("browser.profile.rows")
data class MachineProfileList(
    val current: String = MachineProfilesWire.DEFAULT_PROFILE_ID,
    val profiles: List<MachineBrowserProfile> = emptyList(),
) : ServerMessage {
    /** The id actually in use, repaired against the rows. */
    val resolvedCurrent: String
        get() = when {
            profiles.any { it.id == current } -> current
            profiles.any { it.isDefault } -> MachineProfilesWire.DEFAULT_PROFILE_ID
            else -> profiles.firstOrNull()?.id ?: ""
        }

    /** The profile the machine's browser is using, or null for an empty list. */
    val currentProfile: MachineBrowserProfile?
        get() = profiles.firstOrNull { it.id == resolvedCurrent }

    /** Everything else, in the machine's own order — creation order, default first, not sorted here. */
    val others: List<MachineBrowserProfile>
        get() = profiles.filterNot { it.id == resolvedCurrent }

    /** Whether a row is the one in use. Kept off the row itself, so two rows can never both claim it. */
    fun isCurrent(profile: MachineBrowserProfile): Boolean = profile.id == resolvedCurrent

    val isEmpty: Boolean get() = profiles.isEmpty()
}
