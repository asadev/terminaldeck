package dev.terminaldeck.android.protocol

/**
 * The device screen's vocabulary, kept out of the composable.
 *
 * Transcribed from `pwa/src/devices.ts`: the pure part — the three sentences a row is drawn from —
 * lives here so it can be tested where the drawing cannot. The `rid` routing of the frames stays in
 * [dev.terminaldeck.android.DeckViewModel].
 */
object DeviceRoster {

    /**
     * Whether the host advertised the roster to this connection.
     *
     * The capability is withheld from a guest at the source — the host only ever puts it in a
     * welcome for one of the owner's own devices — so a phone that sees it is both able to manage the
     * roster and entitled to. There is no second check to make here.
     */
    fun offered(capabilities: Set<String>): Boolean = capabilities.contains(Capability.DEVICES)

    /**
     * What a row *is*, in one line.
     *
     * A pending row leads with the wait, because that is the only thing to do about it — there is no
     * approve on the wire, so the screen says what is true and offers the one act it has, Remove,
     * which doubles as deny. An approved row names its kind, which is the difference between a device
     * that can reach the whole machine and one lent a folder.
     */
    fun standing(row: DeviceRosterRow): String {
        if (row.isPending) return "Waiting to be approved"
        return if (row.isMine) "Your device" else "Guest"
    }

    /**
     * When it was last here, as a person reads it.
     *
     * Connected-now beats any time, because it is the more useful fact and the more current one. A
     * device that has never attached says so rather than printing a time it does not have.
     */
    fun lastSeen(row: DeviceRosterRow, now: Long): String {
        if (row.connected) return "Connected now"
        val seen = row.lastSeenAt ?: return "Never connected"
        val ago = now - seen
        if (ago < 0) return "Seen moments ago"
        val minutes = ago / 60_000
        if (minutes < 2) return "Seen moments ago"
        if (minutes < 60) return "Seen ${minutes}m ago"
        val hours = minutes / 60
        if (hours < 24) return "Seen ${hours}h ago"
        val days = hours / 24
        return if (days == 1L) "Seen yesterday" else "Seen ${days}d ago"
    }

    /**
     * The fingerprint, or the sentence for a device that has none.
     *
     * Shown so a person can check it against the six groups the device itself displays. Null means
     * the device paired before there were keys, which is worth a sentence rather than a blank.
     */
    fun fingerprint(row: DeviceRosterRow): String =
        row.fingerprint ?: "No key — paired before this host kept them"

    /**
     * The sentence above the two buttons, once somebody has asked to remove a row.
     *
     * Says which device, what happens, and — for one of the owner's own — that it is a sign-out that
     * takes the whole machine with it. It deliberately does not say "are you sure": the two buttons
     * underneath already ask that.
     */
    fun removeQuestion(row: DeviceRosterRow): String =
        "Remove ${row.name}? Its access is revoked and its connection dropped. This does not come back."
}

/**
 * The "This server" section's labels, kept out of the composable for the same reason.
 *
 * Transcribed from `pwa/src/server-settings.ts`: the closed allowlist and the wire shapes come from
 * the protocol ([ServerSettingKey]); the only thing kept locally is the label map for the builtin
 * provider ids, and a provider it does not recognise — a `custom:` agent — simply shows its id.
 */
object ServerSettingsLabels {
    private val PROVIDERS = mapOf(
        "claude" to "Claude Code",
        "codex" to "Codex CLI",
        "gemini" to "Gemini CLI",
        "shell" to "Plain shell",
    )

    /** The builtin provider ids in the words the desktop's own picker uses; an unknown id shows as
     *  itself — better a readable id than a guessed label. */
    fun provider(id: String): String = PROVIDERS[id] ?: id
}
