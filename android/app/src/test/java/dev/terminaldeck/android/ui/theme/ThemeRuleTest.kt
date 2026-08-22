package dev.terminaldeck.android.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The rules the theme only holds if nothing outside it breaks them, checked by reading the source.
 *
 * This is a source walk rather than a runtime assertion because what it is defending against cannot
 * be observed at runtime: a screen that states its own colour scheme looks perfectly correct in the
 * appearance it happens to be tested in, and is wrong for everybody who chose the other one. The
 * iOS client carries the same test (`AppearanceRuleTests`) for the same reason and it was written
 * after eleven `.preferredColorScheme(.dark)` calls were found scattered over its screens.
 *
 * The Android client had four such pins rather than eleven, and every one of them was invisible
 * from any screenshot taken on a dark phone.
 */
class ThemeRuleTest {

    private fun sourceRoot(): File {
        var here: File? = File("").absoluteFile
        repeat(5) {
            for (candidate in listOf(
                File(here, "src/main/java/dev/terminaldeck/android"),
                File(here, "app/src/main/java/dev/terminaldeck/android"),
                File(here, "android/app/src/main/java/dev/terminaldeck/android"),
            )) {
                if (candidate.isDirectory) return candidate
            }
            here = here?.parentFile
        }
        error("the Kotlin sources are not below ${File("").absoluteFile} — this test cannot run")
    }

    private fun kotlinFiles(): List<File> =
        sourceRoot().walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    private fun outsideTheme() = kotlinFiles().filterNot {
        it.path.contains("/ui/theme/")
    }

    /**
     * The file with its comments removed, line for line.
     *
     * Every rule below is about what the code *does*, and every one of these files explains in
     * prose what it stopped doing — `MainActivity` names the `SystemBarStyle.dark` call it replaced,
     * because the reason it is gone is worth more than the line was. A check that could not tell a
     * comment from a statement would make writing that reason down the thing that fails the build,
     * which is exactly backwards.
     *
     * Blanked rather than dropped so the line numbers in a failure still point at the right place.
     */
    private fun statements(file: File): List<String> {
        val out = mutableListOf<String>()
        var inBlock = false
        for (raw in file.readText().lines()) {
            val line = raw.trim()
            when {
                inBlock -> {
                    if (line.contains("*/")) inBlock = false
                    out += ""
                }
                line.startsWith("//") -> out += ""
                line.startsWith("/*") -> {
                    if (!line.contains("*/")) inBlock = true
                    out += ""
                }
                else -> out += raw.substringBefore("//")
            }
        }
        return out
    }

    @Test
    fun `only the theme decides light or dark`() {
        val offenders = outsideTheme().filter { file ->
            statements(file).any {
                it.contains("darkColorScheme(") ||
                    it.contains("lightColorScheme(") ||
                    it.contains("isSystemInDarkTheme(")
            }
        }
        assertEquals(
            "these files decide an appearance for themselves; the window decides it once, in " +
                "TerminalDeckTheme: ${offenders.map { it.name }}",
            emptyList<String>(), offenders.map { it.name },
        )
    }

    @Test
    fun `nothing pins the system bars to one appearance`() {
        val offenders = kotlinFiles().filter { file ->
            statements(file).any {
                it.contains("SystemBarStyle.dark(") || it.contains("SystemBarStyle.light(")
            }
        }
        assertEquals(
            "the bars follow the resolved appearance through SystemBarStyle.auto; these pin one: " +
                "${offenders.map { it.name }}",
            emptyList<String>(), offenders.map { it.name },
        )
    }

    /**
     * No screen invents a colour.
     *
     * `Color(0x…)` outside `ui/theme` is a hex that exists in one appearance and not the other,
     * because a literal cannot flip. The three scrims are the documented exception and they are
     * genuinely appearance-independent: black at an alpha, over whatever is behind it, in both.
     */
    @Test
    fun `no screen carries a colour literal`() {
        val literal = Regex("""Color\(0x[0-9A-Fa-f]{8}\)""")
        // Black at some alpha — a scrim. Anything else is a colour.
        val scrim = Regex("""Color\(0x[0-9A-Fa-f]{2}000000\)""")
        val offenders = mutableListOf<String>()
        for (file in outsideTheme()) {
            for ((index, line) in statements(file).withIndex()) {
                for (match in literal.findAll(line)) {
                    if (!scrim.matches(match.value)) {
                        offenders += "${file.name}:${index + 1} ${match.value}"
                    }
                }
            }
        }
        assertEquals(
            "colours come from DeckTheme.colors, never from a literal: $offenders",
            emptyList<String>(), offenders,
        )
    }

    /**
     * No screen sets a type size by hand.
     *
     * A `fontSize = 19.sp` is a rung nobody else is standing on, and nine of them across four
     * screens is what a type scale is for. The check is on `.sp` used as a *size*, so tracking and
     * the terminal's own pixel size are unaffected.
     */
    @Test
    fun `no screen sets a font size by hand`() {
        val offenders = mutableListOf<String>()
        val fontSize = Regex("""fontSize\s*=\s*\d""")
        for (file in outsideTheme()) {
            for ((index, line) in statements(file).withIndex()) {
                if (fontSize.containsMatchIn(line)) offenders += "${file.name}:${index + 1}"
            }
        }
        assertEquals(
            "sizes come from DeckType, which is the ladder iOS sets: $offenders",
            emptyList<String>(), offenders,
        )
    }

    /**
     * The window background painted before the first frame is the palette's own value.
     *
     * `MainActivity` has to name two hexes outright, because the window is painted before any
     * composition exists to ask. This is the one place that is allowed and this is the assertion
     * that keeps it honest — the failure it prevents is a launch that flashes a colour the app does
     * not use, which nobody notices in a screenshot because it is gone by the time one is taken.
     */
    @Test
    fun `the pre-composition window colour matches the palette`() {
        val main = kotlinFiles().first { it.name == "MainActivity.kt" }.readText()
        val declaration = Regex("""deckWindowColor\(dark: Boolean\): Int = if \(dark\) (0x[0-9A-Fa-f]{8})\.toInt\(\) else (0x[0-9A-Fa-f]{8})\.toInt\(\)""")
            .find(main)
        assertTrue("MainActivity no longer declares deckWindowColor in the expected shape", declaration != null)

        fun rgb(literal: String) = literal.substring(4).lowercase()
        fun expected(shade: Shade) = String.format("%02x%02x%02x", shade.red, shade.green, shade.blue)

        assertEquals("the dark window colour", expected(Ink.background.dark), rgb(declaration!!.groupValues[1]))
        assertEquals("the light window colour", expected(Ink.background.light), rgb(declaration.groupValues[2]))
    }

    /**
     * Every drawn colour role exists in both appearances.
     *
     * Structural rather than textual: `Duo` makes a one-appearance colour unrepresentable, so this
     * asserts the thing that would break if somebody replaced one with a bare `Color`. It also
     * catches the subtler failure — a `Duo` whose two halves were pasted the same by accident —
     * for the roles where identical halves would be a mistake rather than a decision.
     */
    @Test
    fun `no role is the same in both appearances unless it is meant to be`() {
        val mustDiffer = mapOf(
            "background" to Ink.background, "raised" to Ink.raised, "raisedHigh" to Ink.raisedHigh,
            "sunken" to Ink.sunken, "primary" to Ink.primary, "secondary" to Ink.secondary,
            "muted" to Ink.muted, "accent" to Ink.accent, "onAccent" to Ink.onAccent,
            "terminalPaper" to Ink.terminalPaper, "terminalInk" to Ink.terminalInk,
        )
        val same = mustDiffer.filter { (_, duo) -> duo.light == duo.dark }.keys
        assertEquals(
            "these roles have identical light and dark values, which is almost certainly a paste: $same",
            emptySet<String>(), same,
        )
    }
}
