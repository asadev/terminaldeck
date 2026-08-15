package dev.terminaldeck.android.protocol

/**
 * What kind of machine is on the other end, and what this app is allowed to call it.
 *
 * ## The bug this exists to end
 *
 * A phone paired to a Windows PC read **"Send a photo, video or file to the Mac"** while looking at
 * that PC's own sessions, and told its owner to go and approve a device on "the Mac" when the
 * machine three metres away was a tower running Windows. Nothing had gone wrong on the wire: the
 * desktop never said what it was, so the noun was a string constant compiled into this app, and the
 * constant said Mac because the first machine anyone pointed it at was one. `HostLink`'s own header
 * even stated it as a fact — *"a phone genuinely cannot tell a Mac from a Windows PC, because
 * nothing on the wire says"* — which was true when it was written and is the thing that changed.
 *
 * `welcome.hostPlatform` now carries the desktop's raw `process.platform`. It travels raw rather
 * than as a noun on purpose: the desktop writes English sentences of its own and the three clients
 * do not share a language for this, so every client maps it itself. This is that mapping.
 *
 * ## Why [UNKNOWN] is an answer and not a placeholder
 *
 * The field is optional, and optional here means "a desktop released before it existed". Those are
 * still desktops this app has to talk to, and the honest thing to say about one is a word that is
 * true of all of them. **Guessing "Mac" for an absent field is precisely the defect**, so [fromWire]
 * folds everything it does not recognise — absent included — onto [UNKNOWN] and never onto [MAC].
 */
enum class HostPlatform {
    MAC,
    WINDOWS,
    LINUX,
    UNKNOWN;

    /**
     * The noun to drop into a sentence: "Send a file to the **Mac**".
     *
     * No article and no trailing punctuation, so every call site can write `"the ${noun}"` and
     * compose. "PC" rather than "computer" because it is the word a Windows user uses about their
     * own machine, and matching the reader's word is the entire point of doing this at all.
     * [UNKNOWN] reads "desktop", which is true of every host this app can reach and singles out none
     * of them.
     */
    val noun: String
        get() = when (this) {
            MAC -> "Mac"
            WINDOWS -> "PC"
            LINUX -> "machine"
            UNKNOWN -> "desktop"
        }

    companion object {
        /**
         * Map the desktop's raw `process.platform`.
         *
         * `darwin`/`win32`/`linux` are the three Electron ships on. Anything else — a BSD, a future
         * platform, a truncated field, no field at all — is [UNKNOWN] rather than a refusal: a
         * desktop on a platform this build has never heard of is still a desktop worth showing
         * sessions for.
         *
         * Deliberately case-sensitive and deliberately not trimmed. These are literals produced by
         * Node, not user input, and a lenient match here would be this client inventing a second,
         * looser wire vocabulary that the desktop has never agreed to.
         */
        fun fromWire(wire: String?): HostPlatform = when (wire) {
            "darwin" -> MAC
            "win32" -> WINDOWS
            "linux" -> LINUX
            else -> UNKNOWN
        }
    }
}
