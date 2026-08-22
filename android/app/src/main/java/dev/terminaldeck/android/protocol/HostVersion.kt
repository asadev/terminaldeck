package dev.terminaldeck.android.protocol

/**
 * The two version numbers this phone now has — its own, and the one the desktop put on the
 * `welcome` — and the one sentence it is allowed to say about them.
 *
 * Transcribed from `pwa/src/host-version.ts`; the desktop's `src/main/remote/protocol.ts` is the
 * normative source for the fields it reads. `welcome.appVersion` and `welcome.hostKind` are new, so
 * until they arrive a phone paired to a machine has no way to know what build it is talking to.
 *
 * The one thing the phone does with the pair of numbers is decide whether to show a single sentence —
 * *update this server from a desktop* — and that sentence is honest only when this phone's build is
 * genuinely ahead of the host's. There is deliberately no button under it: nothing on this protocol
 * carries an update verb, because replacing a host stays on the SSH and desktop plane. So this
 * object compares and labels; it never acts.
 *
 * Pure Kotlin, no Android, so the comparison — which is where the bugs would be — is unit-testable.
 */
object HostVersion {

    private data class Parts(val release: List<Int>, val prerelease: List<String>)

    /** Split a version into its release numbers and its prerelease identifiers. */
    private fun split(version: String): Parts {
        // Build metadata takes no part in precedence (semver §10), and the leading `v` some tags
        // carry is not part of the number.
        val withoutBuild = version.trim().removePrefix("v").substringBefore('+')
        val dashParts = withoutBuild.split('-')
        val releasePart = dashParts.first()
        val release = releasePart.split('.').map { part -> part.toIntOrNull() ?: 0 }
        val prerelease = dashParts.drop(1)
            .joinToString("-")
            .split('.')
            .filter { it.isNotEmpty() }
        return Parts(release, prerelease)
    }

    /**
     * Semver precedence, enough of it: -1, 0 or 1.
     *
     * Numeric release segments compared left to right, a missing segment treated as zero, and a
     * prerelease sorting *below* the release it belongs to.
     */
    fun compare(a: String, b: String): Int {
        val left = split(a)
        val right = split(b)

        val length = maxOf(left.release.size, right.release.size)
        for (i in 0 until length) {
            val l = left.release.getOrElse(i) { 0 }
            val r = right.release.getOrElse(i) { 0 }
            if (l != r) return if (l < r) -1 else 1
        }

        // 1.0.0-beta precedes 1.0.0; a release with no prerelease wins.
        if (left.prerelease.isEmpty() && right.prerelease.isEmpty()) return 0
        if (left.prerelease.isEmpty()) return 1
        if (right.prerelease.isEmpty()) return -1

        val idents = maxOf(left.prerelease.size, right.prerelease.size)
        for (i in 0 until idents) {
            val l = left.prerelease.getOrNull(i)
            val r = right.prerelease.getOrNull(i)
            if (l == null) return -1
            if (r == null) return 1
            if (l == r) continue
            val ln = if (l.all { it.isDigit() }) l.toIntOrNull() else null
            val rn = if (r.all { it.isDigit() }) r.toIntOrNull() else null
            if (ln != null && rn != null) return if (ln < rn) -1 else 1
            // Numeric identifiers always have lower precedence than alphanumeric ones.
            if (ln != null) return -1
            if (rn != null) return 1
            return if (l < r) -1 else 1
        }
        return 0
    }

    /**
     * A version this phone can actually reason about.
     *
     * `""` is what an older host sends and what this phone holds before a socket is up; `"unknown"`
     * is the placeholder a build that was never stamped carries — both are honest non-answers rather
     * than numbers, and comparing against them would manufacture a verdict out of nothing. A real
     * version has at least one digit somewhere, which both of those lack.
     */
    private fun isReal(version: String): Boolean =
        version != "" && version != "unknown" && version.any { it.isDigit() }

    /**
     * Whether this phone's build is ahead of the host's — the one question the *update this server
     * from a desktop* sentence hangs on.
     *
     * Default-closed: unless both numbers are real and the phone's is strictly the greater, the
     * answer is no. A phone that cannot read one of the two says nothing rather than nudging on a
     * guess.
     */
    fun clientIsAhead(clientVersion: String, hostVersion: String): Boolean {
        if (!isReal(clientVersion) || !isReal(hostVersion)) return false
        return compare(clientVersion, hostVersion) > 0
    }

    /**
     * What to call the shell at the other end, in one word beside its version.
     *
     * A headless host is a `server`, a desktop is a `desktop`, and anything else — including a build
     * older than the field — gets no noun rather than a guessed one.
     */
    fun hostKindNoun(kind: String?): String? = when (kind) {
        "headless" -> "server"
        "desktop" -> "desktop"
        else -> null
    }

    /**
     * The one line that names the host's build, and its kind when it said one.
     *
     * `version 0.10.0 · server`, or just `version 0.10.0` from a host that predates `hostKind`.
     * A host that never reported a version yields the empty string — the caller draws nothing rather
     * than a row with a blank in it.
     */
    fun hostVersionLine(hostVersion: String, kind: String?): String {
        if (hostVersion.isEmpty()) return ""
        val noun = hostKindNoun(kind)
        return if (noun == null) "version $hostVersion" else "version $hostVersion · $noun"
    }

    /**
     * The sentence to show when this phone is ahead of the host, naming the right kind of box, or
     * null when there is nothing honest to say.
     *
     * Null unless [clientIsAhead]: the whole point is to say it only when true.
     */
    fun behindSentence(clientVersion: String, hostVersion: String, kind: String?): String? {
        if (!clientIsAhead(clientVersion, hostVersion)) return null
        val noun = hostKindNoun(kind) ?: "server"
        return "This app is newer than the $noun (version $hostVersion). Update the $noun from a desktop."
    }
}
