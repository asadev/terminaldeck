package dev.terminaldeck.android

import java.net.URI
import java.util.Locale

/**
 * What somebody typed into a browser address field, turned into a place to go — a port on the
 * machine, a page on the machine, a search — or into the sentence explaining why it is none of those.
 *
 * A 1:1 transcription of `ios/TerminalDeck/Ports/LocalhostAddress.swift`. Android's Localhost tab
 * never had a typed address field — it only opened ports by number — so this pure decision did not
 * exist on this side and is added here rather than in the `protocol` package, mirroring the iOS
 * `Ports/` home. Both the machine-browser address bars and the in-session floating window call it, so
 * `google.com`, `https://…`, `3000` and `what is my ip` mean the same thing everywhere.
 *
 * Asad, having typed a web address and been told the machine could not browse it:
 *
 *   > *"browsers should browse any normal Google or any web internet website also. But it will be
 *   > actually browsing on the server side; here it will be presenting that… So this browser is not
 *   > only for local, it is for internet also, for live websites also. So it should work seamless for
 *   > everything."*
 *
 * Seamless means there is no mode to choose, so [classify] is where the choosing happens — once, over
 * a `String`, with no view and no capability in scope. What a caller decides is only *which door* a
 * [Typed.Page] goes through: a tunnel opens on this phone, a page opens on the machine.
 */
object LocalhostAddress {

    /** One typed line, as the app can act on it. Three outcomes are a place to go; the fourth is a
     *  sentence written to be shown under the field. */
    sealed interface Typed {
        /** One of this machine's own ports — opened over a tunnel. */
        data class Tunnel(val port: Int, val path: String) : Typed

        /** Somewhere on the web, normalised to a URL the machine will accept — opens on the machine. */
        data class Page(val url: String) : Typed

        /** Not an address, so a search: the words as typed (for the sentence that confirms it) and the
         *  URL that performs it. */
        data class Search(val query: String, val url: String) : Typed

        /** It is an address this app will not open — a non-http(s) scheme, a port out of range, a
         *  control character. The sentence is drawn under the field. */
        data class Refused(val why: String) : Typed
    }

    /** [parse]'s narrower answer — *is this one of this machine's own ports* — kept because the
     *  tunnel needs it and its refusals name a real reason. */
    sealed interface Parsed {
        data class Address(val port: Int, val path: String) : Parsed
        data class Refused(val why: String) : Parsed
    }

    /**
     * Where a search goes. One constant rather than a setting, because a setting nobody has asked for
     * is a screen to maintain — every browser has a default and this is that default. It is an https
     * URL on a host the machine resolves, so it goes down the same path as any other typed page.
     */
    const val SEARCH_BASE = "https://www.google.com/search?q="

    /**
     * **The one decision the address bars make.** Which of three things is this?
     *
     * The rules, in the order they are applied (each argued at length in the iOS source):
     *
     *  1. Whitespace inside means a search — a URL percent-encodes a space, so `what is my ip` was
     *     never an address, and refusing to read a question is the flat refusal this exists to delete.
     *  2. A control character means a paste went wrong; refused rather than searched.
     *  3. A bare number is a port; `:3000` is the same habit with a colon. Out of range is refused.
     *  4. A scheme that is not http(s) is refused — and the check comes *before* anything reads the
     *     string as a host, or `file:///etc/passwd` becomes the host `file`. It must not fire on
     *     `localhost:3000`, whose "scheme" is `localhost` — [hostAndPort] is that guard.
     *  5. This machine's own loopback is the tunnel; [parse] owns that answer and its refusals.
     *  6. Anything that looks like a host is a page; anything else is a search.
     */
    fun classify(raw: String): Typed {
        val text = raw.trim()
        if (text.isEmpty()) {
            return Typed.Refused("Type an address, a port on this machine, or something to search for.")
        }

        if (text.any { it.isWhitespace() }) return searching(text)
        if (text.any { it.code < 0x20 || it.code == 0x7f }) {
            return Typed.Refused("That contains characters an address cannot contain.")
        }

        // A bare port, with or without the colon somebody types out of habit — handed to `parse` so
        // the range check and its sentence exist once.
        val bare = if (text.startsWith(":")) text.drop(1) else text
        if (bare.isNotEmpty() && bare.all { it.isDigit() }) return fromParse(text)

        val scheme = explicitScheme(text)
        if (scheme != null && scheme != "http" && scheme != "https") {
            return Typed.Refused("Only http and https pages can be opened, not $scheme:.")
        }

        // Protocol-relative — `//example.com` — is given a scheme rather than a second pair of
        // slashes, matching the host's own `browser-url.ts`.
        val withScheme = when {
            text.contains("://") -> text
            text.startsWith("//") -> "http:$text"
            else -> "http://$text"
        }
        val uri = readUri(withScheme)
        val host = uri?.host
        if (uri == null || host.isNullOrEmpty()) {
            // Not readable as a URL at all — `a b`, `??`, a stray bracket. A browser searches for it
            // rather than lecturing about grammar.
            return searching(text)
        }

        if (isLoopback(host)) return fromParse(text)

        if (!looksLikeAHost(host, hasPort = uri.port != -1)) return searching(text)

        // Lowercased on the way out so `HTTP://GOOGLE.COM` and `google.com` reach the machine as one
        // string. The raw path/query/fragment are carried through untouched — re-encoding a path with
        // a space or a `#` in it silently changes what was asked for.
        val outScheme = (uri.scheme ?: "http").lowercase(Locale.ROOT)
        val out = StringBuilder().append(outScheme).append("://")
        uri.rawUserInfo?.let { out.append(it).append('@') }
        out.append(host.lowercase(Locale.ROOT))
        if (uri.port != -1) out.append(':').append(uri.port)
        out.append(uri.rawPath.orEmpty())
        uri.rawQuery?.let { out.append('?').append(it) }
        uri.rawFragment?.let { out.append('#').append(it) }
        return Typed.Page(out.toString())
    }

    /** The tunnel half, borrowed from [parse] so its answers and sentences exist in one place. */
    private fun fromParse(text: String): Typed = when (val parsed = parse(text)) {
        is Parsed.Address -> Typed.Tunnel(parsed.port, parsed.path)
        is Parsed.Refused -> Typed.Refused(parsed.why)
    }

    /** Words, and the address that searches for them. Encoded to bytes and passing only ASCII
     *  alphanumerics through — it over-encodes, which is always safe, while under-encoding a query
     *  silently changes what was searched for. */
    private fun searching(query: String): Typed {
        val encoded = StringBuilder()
        for (byte in query.toByteArray(Charsets.UTF_8)) {
            val value = byte.toInt() and 0xff
            val ch = value.toChar()
            if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9') {
                encoded.append(ch)
            } else {
                encoded.append('%').append(value.toString(16).uppercase(Locale.ROOT).padStart(2, '0'))
            }
        }
        return Typed.Search(query, SEARCH_BASE + encoded)
    }

    /** `host:port` with an optional path — the shape that fools a URL parser into reading the host as
     *  a scheme. The same expression the host's `browser-url.ts` matches, kept in step deliberately. */
    private val hostAndPort = Regex(
        "^(?:[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*|\\[[0-9A-Fa-f:]+\\]):[0-9]{1,5}(?:[/?#].*)?$"
    )

    /** The scheme a line actually has, or null — including null for the two shapes that only look
     *  like they have one (`localhost:3000`, `127.0.0.1:8080`). */
    private fun explicitScheme(text: String): String? {
        if (hostAndPort.matches(text)) return null
        val colon = text.indexOf(':')
        if (colon < 0) return null
        val scheme = text.substring(0, colon)
        val first = scheme.firstOrNull() ?: return null
        if (!first.isLetter()) return null
        if (!scheme.all { it.isLetter() || it.isDigit() || it == '+' || it == '.' || it == '-' }) return null
        return scheme.lowercase(Locale.ROOT)
    }

    /**
     * Whether a host name is a name somebody meant, rather than a word. Four ways to be one, and the
     * last is the interesting one: a dot with a last label of two or more letters. That is the rule
     * every browser uses and it is deliberately not a list of real top-level domains — the list
     * changes, and being wrong about `.zip` costs nothing next to being wrong about a domain a person
     * is looking at. `git`, `readme` and `1.2.3` are all *not* hosts, which makes them searches.
     */
    private fun looksLikeAHost(host: String, hasPort: Boolean): Boolean {
        if (hasPort) return true
        val name = host.lowercase(Locale.ROOT)
        if (name.startsWith("[")) return true
        if (isIPv4(name)) return true
        val labels = name.split(".")
        if (labels.size < 2 || labels.any { it.isEmpty() }) return false
        val last = labels.last()
        return last.length >= 2 && last.all { it.isLetter() }
    }

    /** A dotted quad, each octet in range. */
    private fun isIPv4(name: String): Boolean {
        val parts = name.split(".")
        if (parts.size != 4 || parts.any { it.isEmpty() || !it.all { c -> c.isDigit() } }) return false
        return parts.all { (it.toIntOrNull() ?: -1) in 0..255 }
    }

    /**
     * Turn a line into a port and a path — the narrower question the tunnel needs. Two of the shapes
     * people type (`3000`, `localhost:3000`) are not URLs at all, so those are handled first and only
     * the rest is handed to a URL parser.
     */
    fun parse(raw: String): Parsed {
        val text = raw.trim()
        if (text.isEmpty()) return Parsed.Refused("Type a port, or an address on this machine.")

        val bare = if (text.startsWith(":")) text.drop(1) else text
        if (bare.isNotEmpty() && bare.all { it.isDigit() }) return port(bare.toIntOrNull() ?: 0, "/")

        val withScheme = if (text.contains("://")) text else "http://$text"
        val uri = readUri(withScheme)
        val host = uri?.host
        if (uri == null || host.isNullOrEmpty()) return Parsed.Refused("That is not an address this phone can read.")

        val scheme = uri.scheme?.lowercase(Locale.ROOT)
        if (scheme != "http" && scheme != "https") {
            return Parsed.Refused("Only http and https pages can be opened here.")
        }

        if (!isLoopback(host)) {
            // A fact about this function and nothing more: a host that is not loopback is a no here.
            // `classify` intercepts this case and opens it on the machine, so nothing draws this
            // string — but a public answer with a reason on it is worth more than a bare no.
            return Parsed.Refused("$host is not a page this machine is serving.")
        }

        if (uri.port == -1) {
            return Parsed.Refused("Which port? A page on this machine is reached by its port number.")
        }

        var path = uri.rawPath?.ifEmpty { "/" } ?: "/"
        uri.rawQuery?.let { if (it.isNotEmpty()) path += "?$it" }
        uri.rawFragment?.let { if (it.isNotEmpty()) path += "#$it" }
        return port(uri.port, path)
    }

    /** The range check in one place, so a bare number and a full URL are refused with the same
     *  sentence. Port 0 is excluded as well as the out-of-range values — nothing listens on it. */
    private fun port(number: Int, path: String): Parsed =
        if (number in 1..65_535) Parsed.Address(number, path)
        else Parsed.Refused("A port is a number between 1 and 65535.")

    /**
     * Whether a host name means this machine's own loopback. `127.0.0.0/8` in full rather than the one
     * address people type, because a dev server bound to `127.0.0.2` is a real thing.
     */
    private fun isLoopback(host: String): Boolean {
        val name = host.lowercase(Locale.ROOT)
        if (name == "localhost" || name == "::1" || name == "[::1]") return true
        if (!isIPv4(name)) return false
        return name.substringBefore(".").toIntOrNull() == 127
    }

    /** Read a URL string without throwing — a line that will not parse is a search, not a crash. */
    private fun readUri(text: String): URI? = try {
        URI(text)
    } catch (e: Exception) {
        null
    }
}
