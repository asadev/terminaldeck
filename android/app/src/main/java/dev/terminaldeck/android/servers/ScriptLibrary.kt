package dev.terminaldeck.android.servers

import android.content.Context

/**
 * The two shell scripts this app sends a server, and where they come from.
 *
 * ## Why they are assets rather than Kotlin constants
 *
 * The host probe is generated from the desktop's own `HOST_PROBE` by
 * `src/main/servers/ios-probe-scripts.test.ts`, which asserts on every ordinary run that the
 * committed copy still matches. iOS gets it as a Swift raw literal. Kotlin cannot hold a shell
 * script in a literal at all: its raw strings interpolate `$`, and the script is *made* of `$`.
 * Escaping every one as `${'$'}` would produce a file nobody can read and, worse, one whose bytes
 * are no longer the bytes that run — the exact drift generating it is meant to end.
 *
 * So it is a file, in `assets/`, byte for byte identical to what the desktop executes.
 *
 * The installer is the same argument from the other direction: `scripts/install-headless.sh` is a
 * real file that the desktop uploads over SFTP and iOS references straight out of `project.yml`.
 * Gradle copies that one file into the assets at build time — see `copyHeadlessInstaller` in
 * `app/build.gradle.kts` — so a change to the installer reaches all three clients in the commit
 * that makes it.
 *
 * ## Why it is an interface
 *
 * Because `./gradlew test` runs on a plain JVM with no `AssetManager`, and everything that decides
 * what to *do* with these scripts — [ServerConnector] — has to be testable there. The real one
 * reads assets; a test hands over strings.
 */
interface ScriptLibrary {

    /** `src/main/servers/host.ts` — is the headless host on it, and could it be. */
    fun hostProbe(): String

    /**
     * `scripts/install-headless.sh`, or null when this build does not carry it.
     *
     * Nullable rather than throwing, because "this copy of the app has no installer in it" is a
     * sentence the card can print in place of the Install button, and §4.1 says a control that
     * cannot act is not drawn.
     */
    fun installer(): String?

    companion object {
        const val HOST_PROBE = "probe-host.sh"
        const val INSTALLER = "install-headless.sh"

        /**
         * A library with nothing in it, for a caller that has no `Context`.
         *
         * The default a unit-tested `DeckViewModel` gets. An empty probe reads back as "nothing is
         * installed and this machine said nothing about itself", which the card already has
         * sentences for, and a null installer removes the Install button rather than offering one
         * that would fail — which is §4.1 doing exactly what it is for.
         */
        val none: ScriptLibrary = object : ScriptLibrary {
            override fun hostProbe(): String = ""
            override fun installer(): String? = null
        }
    }
}

/**
 * The real one: both files out of the APK.
 *
 * Each is read once and kept. They are 2 KB and 30 KB, they never change while the process lives,
 * and the alternative is opening an asset stream in the middle of an SSH round trip.
 */
class AssetScriptLibrary(context: Context) : ScriptLibrary {

    private val assets = context.applicationContext.assets

    private val host: String by lazy { readOrEmpty(ScriptLibrary.HOST_PROBE) }
    private val install: String? by lazy { readOrNull(ScriptLibrary.INSTALLER) }

    override fun hostProbe(): String = host

    override fun installer(): String? = install

    private fun readOrNull(name: String): String? = try {
        assets.open(name).use { it.readBytes().toString(Charsets.UTF_8) }
    } catch (e: Exception) {
        null
    }

    /**
     * A missing probe is an empty script rather than a crash.
     *
     * An empty script runs, prints nothing, and the reader answers "nothing is installed and this
     * machine said nothing about itself" — which the card already has sentences for. A phone that
     * throws on the way into a screen has none.
     */
    private fun readOrEmpty(name: String): String = readOrNull(name).orEmpty()
}
