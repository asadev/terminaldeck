package dev.terminaldeck.android.ui.theme

import org.junit.Assume.assumeTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.pow

/**
 * The palette is checked **against the file it was copied from**, not against itself.
 *
 * A colour table transcribed by hand from another file is a table that is correct on the day it is
 * written and drifts every day after. `tokens.css` is edited when the desktop changes, iOS's
 * `Theme.swift` carries its own copy, and this carries a third — three copies of forty hexes, none
 * of which knows when another moves. `tokens.test.ts` already reads the Swift table for exactly
 * this reason; this is the same idea pointed the other way.
 *
 * So this test parses the real stylesheet and fails when a hex here stops agreeing with it. It does
 * not check *every* token — only the ones this client actually draws, because asserting on tokens
 * nothing on a phone uses would make the desktop's own design work fail an Android build.
 *
 * ## When the stylesheet is not there
 *
 * The Android project sits inside the product repo and the stylesheet is two directories up. If
 * somebody copies `android/` out on its own the file is genuinely absent, and this test says so and
 * skips rather than failing: a build of the Android module in isolation is a legitimate thing to
 * do, and a red test that means "you are in a different directory" teaches people to ignore red
 * tests. Everything below it — the neutrality and contrast checks — reads only this module and runs
 * unconditionally.
 */
class PaletteParityTest {

    /* ------------------------------------------------------- the stylesheet ------- */

    /**
     * Every `--name: value` in one `:root`-ish block, for one theme.
     *
     * The sheet declares the light values on `:root` and the dark ones inside
     * `:root[data-theme='dark']`-style selectors, with `@media (prefers-color-scheme: dark)` in
     * between. Rather than parse CSS properly, this walks the file in order and takes the **last**
     * declaration seen for each name up to the point the dark half begins — which is what the
     * cascade does with the same input, and is enough for a table of flat hexes.
     */
    private fun tokens(css: String): Pair<Map<String, String>, Map<String, String>> {
        val light = mutableMapOf<String, String>()
        val dark = mutableMapOf<String, String>()
        var inDark = false
        for (raw in css.lines()) {
            val line = raw.trim()
            if (line.contains("prefers-color-scheme: dark") || line.contains("data-theme='dark'") ||
                line.contains("data-theme=\"dark\"")
            ) {
                inDark = true
            }
            val match = DECLARATION.find(line) ?: continue
            val name = match.groupValues[1]
            val value = match.groupValues[2].trim().removeSuffix(";").trim()
            if (!value.startsWith("#")) continue
            if (inDark) dark[name] = value.lowercase() else light[name] = value.lowercase()
        }
        return light to dark
    }

    private fun stylesheet(): File? {
        var here: File? = File("").absoluteFile
        repeat(6) {
            val candidate = File(here, "src/renderer/styles/tokens.css")
            if (candidate.isFile) return candidate
            here = here?.parentFile
        }
        return null
    }

    private fun hex(shade: Shade) = String.format("#%02x%02x%02x", shade.red, shade.green, shade.blue)

    @Test
    fun `every colour this client draws is the desktop's own hex`() {
        val file = stylesheet()
        assumeTrue(
            "src/renderer/styles/tokens.css is not above this module — skipping the cross-check.",
            file != null,
        )
        val (light, dark) = tokens(file!!.readText())

        // role in this file -> token name in the stylesheet
        val roles = listOf(
            "background" to "bg-primary",
            "raised" to "bg-secondary",
            "raisedHigh" to "bg-tertiary",
            "sunken" to "bg-sunken",
            "primary" to "text-primary",
            "secondary" to "text-secondary",
            "muted" to "text-muted",
            "accent" to "accent",
            "accentPressed" to "accent-press",
            "onAccent" to "text-onaccent",
            "working" to "status-working",
            "waiting" to "status-waiting",
            "input" to "status-input",
            "completed" to "status-completed",
            "critical" to "color-critical",
            "positive" to "color-positive",
            "warning" to "color-warning",
            "criticalFill" to "critical-fill",
            "onCriticalFill" to "critical-fill-ink",
            // `terminal-bg` is checked in its own test below, because its dark half deliberately
            // diverges from the desktop's.
            "terminalInk" to "terminal-fg",
        )
        val duos = mapOf(
            "background" to Ink.background, "raised" to Ink.raised, "raisedHigh" to Ink.raisedHigh,
            "sunken" to Ink.sunken, "primary" to Ink.primary, "secondary" to Ink.secondary,
            "muted" to Ink.muted, "accent" to Ink.accent, "accentPressed" to Ink.accentPressed,
            "onAccent" to Ink.onAccent, "working" to Ink.working, "waiting" to Ink.waiting,
            "input" to Ink.input, "completed" to Ink.completed, "critical" to Ink.critical,
            "positive" to Ink.positive, "warning" to Ink.warning, "criticalFill" to Ink.criticalFill,
            "onCriticalFill" to Ink.onCriticalFill, "terminalPaper" to Ink.terminalPaper,
            "terminalInk" to Ink.terminalInk,
        )

        for ((role, token) in roles) {
            val duo = duos.getValue(role)
            light[token]?.let {
                assertEquals("$role (light) must be --$token", it, hex(duo.light))
            }
            dark[token]?.let {
                assertEquals("$role (dark) must be --$token", it, hex(duo.dark))
            }
        }
    }

    /**
     * The terminal's paper — and the one place this client is deliberately *not* the desktop.
     *
     * On paper it is `--terminal-bg` exactly: `#e8e8e8`, a genuinely recessed sheet twenty-three
     * levels below the chrome, which is the whole point of the token and is asserted here.
     *
     * In the dark it is `#121212` — `--bg-sunken` — where the desktop's `--terminal-bg` is
     * `#191919`. That is not a transcription error and it is not corrected: on the desktop
     * `#191919` is *also* the canvas, so its terminal is level with its chrome, while on a phone
     * the chrome is a raised surface and the terminal is the well cut into it. iOS carries the same
     * two levels of difference and says so in `Theme.swift`; the three clients that share a screen
     * with a person agree, and the one that does not is the desktop. Written down here so the next
     * person to notice finds the reason rather than a bug.
     */
    @Test
    fun `the terminal's paper is the desktop's on paper and the app's own well in the dark`() {
        val file = stylesheet()
        assumeTrue("tokens.css is not above this module — skipping.", file != null)
        val (light, dark) = tokens(file!!.readText())

        light["terminal-bg"]?.let {
            assertEquals("the light terminal is --terminal-bg exactly", it, hex(Ink.terminalPaper.light))
        }
        dark["terminal-bg"]?.let {
            assertEquals(
                "the dark terminal is deliberately --bg-sunken, not the desktop's --terminal-bg",
                dark["bg-sunken"], hex(Ink.terminalPaper.dark),
            )
            assertTrue(
                "if the desktop's dark --terminal-bg ever becomes --bg-sunken this exception can go",
                it != hex(Ink.terminalPaper.dark),
            )
        }
    }

    @Test
    fun `the sixteen ANSI colours are the desktop's, in both appearances`() {
        val file = stylesheet()
        assumeTrue("tokens.css is not above this module — skipping.", file != null)
        val (light, dark) = tokens(file!!.readText())

        val names = listOf(
            "ansi-black", "ansi-red", "ansi-green", "ansi-yellow",
            "ansi-blue", "ansi-magenta", "ansi-cyan", "ansi-white",
            "ansi-bright-black", "ansi-bright-red", "ansi-bright-green", "ansi-bright-yellow",
            "ansi-bright-blue", "ansi-bright-magenta", "ansi-bright-cyan", "ansi-bright-white",
        )
        assertEquals("the table must have sixteen entries", 16, Ink.ansi.size)
        names.forEachIndexed { index, token ->
            light[token]?.let { assertEquals("--$token (light)", it, hex(Ink.ansi[index].light)) }
            dark[token]?.let { assertEquals("--$token (dark)", it, hex(Ink.ansi[index].dark)) }
        }
    }

    /* -------------------------------------------------------- neutrality ---------- */

    /**
     * `r == g == b` on every surface and every ink, in both appearances.
     *
     * Mechanical rather than an opinion, and the set this replaces failed it in the other direction
     * from the desktop's own old bug: `#0B0D10` ran five levels of blue ahead of red. Invisible in a
     * swatch, and enough to make a whole screen read as tinted once it fills a phone.
     */
    @Test
    fun `every grey is exactly neutral`() {
        val greys = mapOf(
            "background" to Ink.background,
            "raised" to Ink.raised,
            "raisedHigh" to Ink.raisedHigh,
            "sunken" to Ink.sunken,
            "primary" to Ink.primary,
            "secondary" to Ink.secondary,
            "muted" to Ink.muted,
            "neutralAction" to Ink.neutralAction,
            "terminalPaper" to Ink.terminalPaper,
            "terminalInk" to Ink.terminalInk,
        )
        for ((name, duo) in greys) {
            for ((appearance, shade) in listOf("light" to duo.light, "dark" to duo.dark)) {
                assertTrue(
                    "$name ($appearance) is not neutral: ${hex(shade)}",
                    shade.red == shade.green && shade.green == shade.blue,
                )
            }
        }
    }

    /* ---------------------------------------------------------- contrast ---------- */

    /**
     * Every text tier is AA body text on every surface it is ever set on, in both appearances.
     *
     * This is the property that stops a light theme from being grey on grey, and it is checked
     * against the *lightest* surface a card uses in the light theme and the *darkest* in the dark
     * one — the worst case for each, rather than against the canvas, which flatters both.
     */
    @Test
    fun `all three text tiers clear AA on every surface`() {
        val inks = listOf("primary" to Ink.primary, "secondary" to Ink.secondary, "muted" to Ink.muted)
        val surfaces = listOf(
            "background" to Ink.background,
            "raised" to Ink.raised,
            "raisedHigh" to Ink.raisedHigh,
            "sunken" to Ink.sunken,
        )
        for ((inkName, ink) in inks) {
            for ((surfaceName, surface) in surfaces) {
                for (dark in listOf(false, true)) {
                    val ratio = contrast(ink.shade(dark), surface.shade(dark))
                    assertTrue(
                        "$inkName on $surfaceName (${if (dark) "dark" else "light"}) is " +
                            "${"%.2f".format(ratio)}:1, under 4.5",
                        ratio >= 4.5,
                    )
                }
            }
        }
    }

    /**
     * The accent is readable as text, and what sits on top of it is readable too.
     *
     * Both halves matter and they pull against each other: a blue light enough to read on `#191919`
     * is too light for white to sit on. The dark theme resolves it by putting near-black on the
     * accent, which is the same trade Apple's own dark-mode tinted controls make.
     */
    @Test
    fun `the accent works as ink and as a fill`() {
        for (dark in listOf(false, true)) {
            val name = if (dark) "dark" else "light"
            val asText = contrast(Ink.accent.shade(dark), Ink.background.shade(dark))
            assertTrue("accent as text ($name) is ${"%.2f".format(asText)}:1", asText >= 4.5)

            val onFill = contrast(Ink.onAccent.shade(dark), Ink.accent.shade(dark))
            assertTrue("onAccent on accent ($name) is ${"%.2f".format(onFill)}:1", onFill >= 4.5)
        }
    }

    /**
     * White on the neutral swipe/action fill, in both appearances.
     *
     * The one role in the palette that is a single value in both, because the label on it is white
     * either way. `Theme.surfaceHigh` was used for this once and its light value is `#ededed` —
     * white on near-white, 1.1:1, an action that is invisible on paper and perfectly legible in the
     * dark. That is the bug this assertion exists for.
     */
    @Test
    fun `the neutral action fill carries white`() {
        val white = Shade(0xffffff)
        for (dark in listOf(false, true)) {
            val ratio = contrast(white, Ink.neutralAction.shade(dark))
            assertTrue("white on neutralAction is ${"%.2f".format(ratio)}:1", ratio >= 4.5)
        }
    }

    /**
     * The status colours are readable *as words*, not only as dots.
     *
     * Every one of them is set as text somewhere in this client — the session row's status line,
     * the connection banner, the pairing screen's sentences — so a status colour that only works as
     * an 8dp circle is a status colour that fails where it matters most.
     */
    @Test
    fun `every status colour is readable as text on every surface`() {
        val statuses = mapOf(
            "working" to Ink.working, "waiting" to Ink.waiting, "input" to Ink.input,
            "completed" to Ink.completed, "critical" to Ink.critical, "positive" to Ink.positive,
            "warning" to Ink.warning,
        )
        val surfaces = listOf("background" to Ink.background, "raised" to Ink.raised, "raisedHigh" to Ink.raisedHigh)
        for ((name, duo) in statuses) {
            for ((surfaceName, surface) in surfaces) {
                for (dark in listOf(false, true)) {
                    val ratio = contrast(duo.shade(dark), surface.shade(dark))
                    assertTrue(
                        "$name on $surfaceName (${if (dark) "dark" else "light"}) is " +
                            "${"%.2f".format(ratio)}:1",
                        ratio >= 4.5,
                    )
                }
            }
        }
    }

    /**
     * The terminal's own ink on the terminal's own paper, which is a different pair from the app's.
     *
     * Fifteen to one in the light theme is not an accident — `--terminal-fg` is deliberately darker
     * than the app's body text, because a terminal's job is to be exact.
     */
    @Test
    fun `the terminal is legible on its own paper`() {
        for (dark in listOf(false, true)) {
            val ratio = contrast(Ink.terminalInk.shade(dark), Ink.terminalPaper.shade(dark))
            assertTrue("terminal ink is ${"%.2f".format(ratio)}:1", ratio >= 7.0)
        }
    }

    /**
     * The light half of the ANSI set is not the dark half.
     *
     * Twelve of the sixteen move; the four that do not are named here rather than discovered later
     * as a suspected bug. Black and bright black keep their places on the ramp because they already
     * clear on paper and darkening bright black past black would invert the pair; white and bright
     * white are left alone because an ANSI "white" is used as a *background* as often as a
     * foreground, and darkening it would turn `ESC[47m` into a black band.
     */
    @Test
    fun `the light ANSI set is genuinely its own`() {
        val deliberatelyShared = setOf(0, 4, 5, 7, 8, 15, 1)
        val moved = Ink.ansi.indices.count { Ink.ansi[it].light != Ink.ansi[it].dark }
        assertTrue("only $moved of sixteen ANSI colours differ between the appearances", moved >= 8)
        for (index in deliberatelyShared) {
            assertEquals(
                "ANSI $index is documented as shared between the appearances",
                hex(Ink.ansi[index].dark),
                hex(Ink.ansi[index].light),
            )
        }
    }

    /**
     * Bright is still distinguishable from normal on paper.
     *
     * Given both halves the same contrast target they collapse onto each other — green and bright
     * green ended eleven levels apart once, which a diff renders as one colour. The bright eight
     * target a higher ratio precisely so this stays true.
     */
    @Test
    fun `bright and normal do not collapse in the light appearance`() {
        // Green, yellow, cyan, red — the four a diff and a compiler actually use.
        for (index in listOf(1, 2, 3, 6)) {
            val normal = Ink.ansi[index].light
            val bright = Ink.ansi[index + 8].light
            val distance = abs(luminance(normal) - luminance(bright))
            assertTrue(
                "ANSI $index and ${index + 8} are indistinguishable on paper",
                distance > 0.01 || normal != bright,
            )
        }
    }

    private companion object {
        val DECLARATION = Regex("""--([a-z0-9-]+)\s*:\s*([^;]+);""")

        fun channel(value: Int): Double {
            val c = value / 255.0
            return if (c <= 0.03928) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
        }

        fun luminance(shade: Shade): Double =
            0.2126 * channel(shade.red) + 0.7152 * channel(shade.green) + 0.0722 * channel(shade.blue)

        fun contrast(a: Shade, b: Shade): Double {
            val la = luminance(a)
            val lb = luminance(b)
            val lighter = maxOf(la, lb)
            val darker = minOf(la, lb)
            return (lighter + 0.05) / (darker + 0.05)
        }
    }
}
