package dev.terminaldeck.android.ui.theme

import com.termux.terminal.TerminalColors
import com.termux.terminal.TextStyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * The schemes, the emulator they are installed into, and the one file they must not drift from.
 *
 * Three different kinds of check live here, and the split is deliberate:
 *
 *  1. **Shape.** Every scheme has twenty-one colours and every one of them is a colour. This is the
 *     check that catches a transcription with a digit missing, which is the failure mode of a file
 *     that is two hundred hand-typed hexes.
 *  2. **Parity with the shared table.** Every shipped scheme is read out of
 *     `src/shared/terminal-theme.ts` at test time and compared colour for colour, and the default
 *     scheme's sixteen are read out of `tokens.css` besides, in the manner of `PaletteParityTest`.
 *     This is the check that was missing: three copies of one table exist in this product — the
 *     shared declaration, the Swift mirror, this one — and none of them knew when another moved, so
 *     Tango sat black on two clients and a dark grey on this one until somebody diffed them by
 *     hand, which is not a mechanism and happens once. iOS has the
 *     same guard pointed the same way, in `tokens.test.ts`. The direction is deliberate everywhere:
 *     the shared file declares, the clients mirror.
 *  3. **The emulator actually takes them.** `installTerminalPalette` is asserted through
 *     `TerminalColors.COLOR_SCHEME` — the real vendored object, not a stand-in — because the whole
 *     feature is one call into somebody else's static state and "we called it" is not the claim
 *     being made. The claim is that picking Pure black makes the terminal black.
 */
class TerminalSchemeTest {

    /* ----------------------------------------------------------------- shape ------- */

    @Test
    fun `every built-in has twenty-one colours and every one parses`() {
        for (scheme in TerminalSchemes.builtIns) {
            assertEquals("${scheme.id} ANSI count", 16, scheme.ansi.size)
            for (slot in TerminalSlot.entries) {
                val value = slot.read(scheme)
                // Slot-aware: six of the shipped schemes write their selection `#rrggbbaa`, and
                // exactly one slot is allowed to. See `TerminalSlot.carriesAlpha`.
                assertNotNull("${scheme.id}.${slot.name} = '$value' is not a colour",
                    TerminalScheme.parseOrNull(value, slot.carriesAlpha))
                assertEquals(
                    "${scheme.id}.${slot.name} is not written canonically",
                    value,
                    TerminalScheme.normalise(value, slot.carriesAlpha),
                )
            }
        }
    }

    /**
     * Every field of the record is reachable from [TerminalSlot].
     *
     * The editor walks the enum, so a colour with no slot is a colour nobody can change — and it
     * would look exactly like a working screen. Counting rather than listing, because a list here
     * would have to be edited by the same person who forgot to add the slot.
     */
    @Test
    fun `the slots cover the whole record`() {
        assertEquals(TerminalScheme.SLOT_COUNT, TerminalSlot.entries.size)
        val scheme = TerminalSchemes.deckDark
        val reached = TerminalSlot.entries.map { it.read(scheme) }.toSet()
        // Five roles plus sixteen, minus whatever two of them happen to be equal. Reading the
        // record through the slots must produce every distinct value the record holds.
        val declared = (listOf(
            scheme.background, scheme.foreground, scheme.cursor,
            scheme.cursorAccent, scheme.selectionBackground,
        ) + scheme.ansi).toSet()
        assertEquals(declared, reached)
    }

    @Test
    fun `each slot writes only its own field`() {
        val base = TerminalSchemes.nord
        for (slot in TerminalSlot.entries) {
            val changed = slot.write(base, "#123456")
            assertEquals("$slot did not write", "#123456", slot.read(changed))
            val others = TerminalSlot.entries.filter { it != slot }
            for (other in others) {
                assertEquals(
                    "writing $slot also moved $other",
                    other.read(base),
                    other.read(changed),
                )
            }
        }
    }

    /** Exactly two, and the editor's honesty depends on it being exactly these two. */
    @Test
    fun `only the cursor accent and the selection are unpainted here`() {
        val inert = TerminalSlot.entries.filterNot { it.paintedHere }.toSet()
        assertEquals(setOf(TerminalSlot.CursorAccent, TerminalSlot.Selection), inert)
    }

    @Test
    fun `ids and names are unique`() {
        val ids = TerminalSchemes.builtIns.map { it.id }
        val names = TerminalSchemes.builtIns.map { it.name }
        assertEquals(ids.size, ids.toSet().size)
        assertEquals(names.size, names.toSet().size)
        // The reserved choice is not a scheme and must never collide with one.
        assertTrue(TerminalSchemes.MATCH_APPEARANCE !in ids)
    }

    /**
     * The schemes that were asked for by name, present and correct.
     *
     * Named one by one rather than counted, because "there are thirteen" would still pass with the
     * wrong thirteen. Pure black carries its hex in the assertion because that is the one that was
     * specified as a value rather than as a name.
     */
    @Test
    fun `the requested schemes all ship`() {
        val byName = TerminalSchemes.builtIns.associateBy { it.name }
        for (name in listOf(
            "Pure Black", "Deck Dark", "Dark Grey",
            "Solarized Dark", "Solarized Light", "Nord", "Dracula",
            "Gruvbox Dark", "One Half Dark", "One Half Light", "Tango Dark", "Campbell",
        )) {
            assertNotNull("$name is missing", byName[name])
        }
        assertEquals("#000000", TerminalSchemes.pureBlack.background)
    }

    /* --------------------------------------------------------------- the hex ------- */

    @Test
    fun `hex reading is tolerant on the way in and canonical on the way out`() {
        assertEquals("#aabbcc", TerminalScheme.normalise("#AABBCC"))
        assertEquals("#aabbcc", TerminalScheme.normalise("aabbcc"))
        assertEquals("#aabbcc", TerminalScheme.normalise("  #AaBbCc  "))
        // The three-digit short form, expanded the way CSS expands it.
        assertEquals("#ffffff", TerminalScheme.normalise("#fff"))
        assertEquals("#00ff00", TerminalScheme.normalise("#0f0"))
    }

    /**
     * Half-typed text is not a colour, and neither is a colour with an alpha on it.
     *
     * The second is the one worth stating: `TerminalColors.parse` on the emulator side would accept
     * `#80000000` happily, and a translucent background there draws over whatever the last frame
     * left behind instead of compositing — which reads as a rendering bug rather than as a scheme
     * somebody chose.
     */
    @Test
    fun `anything that is not an opaque six-digit colour is refused`() {
        for (bad in listOf("", "#", "#8", "#8a", "#8ae2", "#8ae23", "#8ae2345", "#80ff0000",
                           "rgb(0,0,0)", "#gggggg", "not a colour")) {
            assertNull("'$bad' was accepted", TerminalScheme.parseOrNull(bad))
        }
    }

    /**
     * Eight digits, on the one slot that may have them.
     *
     * The pair below is the whole of the rule: the *string* keeps its alpha, because that is what
     * makes this phone's copy of a scheme the same copy the desktop has, and the *int* does not,
     * because everything that paints with it — the emulator's table, the preview, the editor's
     * swatch — is a surface that cannot express transparency.
     */
    @Test
    fun `the selection may carry an alpha, and only the selection`() {
        assertEquals("#3b8fee29", TerminalScheme.normalise("#3B8FEE29", alpha = true))
        assertEquals("#ffffff40", TerminalScheme.normalise("ffffff40", alpha = true))
        // #rgba doubles the way #rgb does, which is how CSS expands it.
        assertEquals("#33bb8844", TerminalScheme.normalise("#3b84", alpha = true))
        // Opaque out, alpha or not: the swatch and the emulator both need a colour, not a wash.
        assertEquals(0xff3b8fee.toInt(), TerminalScheme.parse("#3b8fee29", alpha = true))
        // And nowhere else. Six digits stay six digits on the other twenty slots.
        assertNull(TerminalScheme.normalise("#3b8fee29"))
        for (slot in TerminalSlot.entries) {
            assertEquals(
                "$slot disagrees with the shared table about who may carry an alpha",
                slot == TerminalSlot.Selection,
                slot.carriesAlpha,
            )
        }
    }

    @Test
    fun `parsing always produces an opaque colour`() {
        assertEquals(0xff000000.toInt(), TerminalScheme.parse("#000000"))
        assertEquals(0xffffffff.toInt(), TerminalScheme.parse("#ffffff"))
        assertEquals(0xff3b8fee.toInt(), TerminalScheme.parse("#3b8fee"))
    }

    /* ------------------------------------------------------------ the copy --------- */

    @Test
    fun `copying for editing keeps every colour and changes only the identity`() {
        val original = TerminalSchemes.dracula
        val copy = original.copyForEditing("custom-abc", "Dracula copy")
        assertEquals("custom-abc", copy.id)
        assertEquals("Dracula copy", copy.name)
        for (slot in TerminalSlot.entries) {
            assertEquals(slot.name, slot.read(original), slot.read(copy))
        }
        // And the original is untouched — the whole reason the copy exists.
        assertEquals("dracula", TerminalSchemes.dracula.id)
        assertEquals("#282a36", TerminalSchemes.dracula.background)
    }

    @Test
    fun `copy names do not collide and are numbered only from the second`() {
        assertEquals("Nord copy", TerminalSchemeStore.copyName("Nord", emptySet()))
        assertEquals("Nord copy 2", TerminalSchemeStore.copyName("Nord", setOf("Nord copy")))
        assertEquals(
            "Nord copy 3",
            TerminalSchemeStore.copyName("Nord", setOf("Nord copy", "Nord copy 2")),
        )
    }

    /* ------------------------------------------------------- the edit rule --------- */

    /**
     * A keystroke that lands on the colour already there is not an edit.
     *
     * This is the guard on copy-on-edit. The editor forks a built-in on the *first* committed
     * change, so a no-op that counted as a change would mean opening Pure black, pressing backspace
     * once — `#000000` becomes `#000`, which normalises straight back to `#000000` — and finding a
     * copy in the list that differs from the original in nothing.
     */
    @Test
    fun `retyping the same colour is not an edit`() {
        val scheme = TerminalSchemes.pureBlack
        assertNull(scheme.withTyped(TerminalSlot.Background, "#000000"))
        assertNull(scheme.withTyped(TerminalSlot.Background, "#000"))
        assertNull(scheme.withTyped(TerminalSlot.Background, "000000"))
        assertNull(scheme.withTyped(TerminalSlot.Background, "#000000  "))
        assertNull(scheme.withTyped(TerminalSlot.Cursor, "#3B8FEE"))
    }

    @Test
    fun `a half-typed colour is not an edit`() {
        val scheme = TerminalSchemes.nord
        for (partial in listOf("", "#", "#8", "#8a", "#8ae2", "#8ae23")) {
            assertNull("'$partial' was committed", scheme.withTyped(TerminalSlot.Green, partial))
        }
    }

    @Test
    fun `a real change is committed, canonically`() {
        val changed = TerminalSchemes.pureBlack.withTyped(TerminalSlot.Background, "#123456")
        assertNotNull(changed)
        assertEquals("#123456", changed!!.background)
        // Written canonically whatever was typed.
        assertEquals(
            "#aabbcc",
            TerminalSchemes.pureBlack.withTyped(TerminalSlot.Background, "AABBCC")!!.background,
        )
        assertEquals(
            "#ffffff",
            TerminalSchemes.pureBlack.withTyped(TerminalSlot.Background, "#fff")!!.background,
        )
    }

    /* --------------------------------------------------------- the fallbacks ------- */

    @Test
    fun `no choice means the scheme follows the app's appearance`() {
        assertEquals(
            TerminalSchemes.deckDark,
            TerminalSchemeStore.resolve(null, emptyList(), dark = true),
        )
        assertEquals(
            TerminalSchemes.deckLight,
            TerminalSchemeStore.resolve(null, emptyList(), dark = false),
        )
        assertEquals(
            TerminalSchemes.deckLight,
            TerminalSchemeStore.resolve(TerminalSchemes.MATCH_APPEARANCE, emptyList(), dark = false),
        )
    }

    /**
     * A stored id naming a scheme that is gone falls back rather than throwing.
     *
     * A real case, not a defensive one: the scheme in use can be deleted from the editor, and a
     * restore from a backup can carry a choice whose custom scheme was never in it.
     */
    @Test
    fun `a choice pointing at nothing falls back to the appearance`() {
        assertEquals(
            TerminalSchemes.deckDark,
            TerminalSchemeStore.resolve("custom-deleted", emptyList(), dark = true),
        )
    }

    @Test
    fun `a chosen scheme wins over the appearance in both directions`() {
        assertEquals(
            TerminalSchemes.pureBlack,
            TerminalSchemeStore.resolve("pure-black", emptyList(), dark = false),
        )
        assertEquals(
            TerminalSchemes.solarizedLight,
            TerminalSchemeStore.resolve("solarized-light", emptyList(), dark = true),
        )
    }

    @Test
    fun `a custom scheme is found by id`() {
        val mine = TerminalSchemes.nord.copyForEditing("custom-1", "Mine")
        assertEquals(mine, TerminalSchemeStore.resolve("custom-1", listOf(mine), dark = true))
    }

    /* ------------------------------------------------------------- on disk --------- */

    @Test
    fun `an unreadable store falls back to the built-ins instead of failing to start`() {
        assertEquals(emptyList<TerminalScheme>(), TerminalSchemeStore.decode(null))
        assertEquals(emptyList<TerminalScheme>(), TerminalSchemeStore.decode(""))
        assertEquals(emptyList<TerminalScheme>(), TerminalSchemeStore.decode("}{ not json"))
        assertEquals(emptyList<TerminalScheme>(), TerminalSchemeStore.decode("""[{"id":"x"}]"""))
    }

    /**
     * A stored scheme cannot claim a shipped id.
     *
     * Otherwise a copy that somehow kept `nord` would shadow Nord: the picker would draw two rows
     * called Nord, and `resolve` would answer with whichever `firstOrNull` reached first — which is
     * the built-in, so the custom one would be permanently uneditable and permanently visible.
     */
    @Test
    fun `a stored scheme cannot shadow a built-in`() {
        val json = """[{"id":"nord","name":"Not Nord","background":"#ff0000","foreground":"#ffffff",
            "cursor":"#ffffff","cursorAccent":"#000000","selectionBackground":"#333333",
            "black":"#000000","red":"#ff0000","green":"#00ff00","yellow":"#ffff00",
            "blue":"#0000ff","magenta":"#ff00ff","cyan":"#00ffff","white":"#ffffff",
            "brightBlack":"#555555","brightRed":"#ff5555","brightGreen":"#55ff55",
            "brightYellow":"#ffff55","brightBlue":"#5555ff","brightMagenta":"#ff55ff",
            "brightCyan":"#55ffff","brightWhite":"#ffffff"}]"""
        assertEquals(emptyList<TerminalScheme>(), TerminalSchemeStore.decode(json))
    }

    /** What is written is what comes back, colour for colour. */
    @Test
    fun `a custom scheme survives a round trip through the stored form`() {
        val mine = TerminalSchemes.gruvboxDark
            .copyForEditing("custom-round", "Mine")
            .copy(background = "#101010")
        val encoded = kotlinx.serialization.json.Json.encodeToString(
            kotlinx.serialization.builtins.ListSerializer(TerminalScheme.serializer()),
            listOf(mine),
        )
        assertEquals(listOf(mine), TerminalSchemeStore.decode(encoded))
    }

    /* ------------------------------------------------------ into the emulator ------ */

    /**
     * Installing a scheme really does change what the emulator will draw.
     *
     * Reading `COLOR_SCHEME.mDefaultColors` rather than a session, because a session needs a real
     * process; the table is the thing a session copies at construction, so asserting on it is
     * asserting on the next terminal that opens.
     */
    @Test
    fun `installing a scheme reaches the vendored emulator`() {
        installTerminalPalette(TerminalSchemes.pureBlack)
        val table = TerminalColors.COLOR_SCHEME.mDefaultColors
        assertEquals(0xff000000.toInt(), table[TextStyle.COLOR_INDEX_BACKGROUND])
        assertEquals(
            TerminalScheme.parse(TerminalSchemes.pureBlack.foreground),
            table[TextStyle.COLOR_INDEX_FOREGROUND],
        )
        assertEquals(
            TerminalScheme.parse(TerminalSchemes.pureBlack.cursor),
            table[TextStyle.COLOR_INDEX_CURSOR],
        )
        for (index in 0 until 16) {
            assertEquals(
                "colour $index",
                TerminalScheme.parse(TerminalSchemes.pureBlack.ansi[index]),
                table[index],
            )
        }
    }

    /**
     * Installing a second scheme replaces the first rather than merging with it.
     *
     * `updateWith` calls `reset()` first, which is what makes this true — but that is somebody
     * else's implementation detail and the feature depends on it: without it, switching from
     * Dracula to Solarized Light would leave Dracula's greens behind wherever the two tables
     * happened not to overlap.
     */
    @Test
    fun `switching schemes leaves nothing of the last one behind`() {
        installTerminalPalette(TerminalSchemes.dracula)
        installTerminalPalette(TerminalSchemes.solarizedLight)
        val table = TerminalColors.COLOR_SCHEME.mDefaultColors
        for (index in 0 until 16) {
            assertEquals(
                "colour $index",
                TerminalScheme.parse(TerminalSchemes.solarizedLight.ansi[index]),
                table[index],
            )
        }
        assertEquals(
            TerminalScheme.parse(TerminalSchemes.solarizedLight.background),
            table[TextStyle.COLOR_INDEX_BACKGROUND],
        )
    }

    /**
     * The cursor is the scheme's, not the one the emulator would have picked.
     *
     * `updateWith` runs `setCursorColorForBackground` when no cursor is given — white on a dark
     * ground — so a scheme whose caret is deliberately not white is the case that proves the key is
     * being sent. Nord's `#d8dee9` is that scheme, and it is read off the scheme rather than typed
     * in: this test used to assert One Half Dark's caret as a literal `#a3b3cc`, which was a value
     * this module had invented and the shared table did not have, so the assertion was pinning the
     * drift in place.
     */
    @Test
    fun `the scheme's own cursor is installed rather than a derived one`() {
        installTerminalPalette(TerminalSchemes.nord)
        assertEquals(
            TerminalScheme.parse(TerminalSchemes.nord.cursor),
            TerminalColors.COLOR_SCHEME.mDefaultColors[TextStyle.COLOR_INDEX_CURSOR],
        )
        // And it is not what the emulator would have derived for a dark ground.
        assertNotEquals(
            TerminalScheme.parse("#ffffff"),
            TerminalColors.COLOR_SCHEME.mDefaultColors[TextStyle.COLOR_INDEX_CURSOR],
        )
    }

    /* ----------------------------------------------- parity with the desktop ------- */

    /**
     * A file in the repository above this module, found by walking up rather than by a relative path.
     *
     * The same walk `PaletteParityTest` does, and for the reason that test's first version taught:
     * a `File("../…")` depends on which directory the runner starts in, so it does not fail when it
     * is wrong — it *skips*, and a cross-check that has silently skipped for a month is worse than
     * no cross-check, because the file it guards looks tested.
     */
    private fun upstream(path: String): File? {
        var here: File? = File("").absoluteFile
        repeat(6) {
            val candidate = File(here, path)
            if (candidate.isFile) return candidate
            here = here?.parentFile
        }
        return null
    }

    private fun stylesheet(): File? = upstream("src/renderer/styles/tokens.css")

    /**
     * The default scheme's sixteen are `tokens.css`'s sixteen, read out of the stylesheet.
     *
     * Skipped when the stylesheet is not there, for the reason `PaletteParityTest` gives: building
     * `android/` copied out on its own is a legitimate thing to do, and a red test meaning "you are
     * in a different directory" teaches people to ignore red tests.
     */
    @Test
    fun `the default scheme still matches the desktop's ANSI table`() {
        val css = stylesheet()
        assumeTrue("tokens.css is not above this module — skipping the cross-check.", css != null)
        val text = css!!.readText()

        val names = listOf(
            "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
            "bright-black", "bright-red", "bright-green", "bright-yellow",
            "bright-blue", "bright-magenta", "bright-cyan", "bright-white",
        )
        // The sheet declares the light values first and the dark ones later in the file, so the
        // last declaration of each token is the dark theme's and the first is the light theme's.
        for ((index, name) in names.withIndex()) {
            val all = Regex("--ansi-$name:\\s*(#[0-9a-fA-F]{6})")
                .findAll(text).map { it.groupValues[1].lowercase() }.toList()
            assumeTrue("--ansi-$name not declared twice", all.size >= 2)
            assertEquals(
                "Deck Dark's colour $index has drifted from --ansi-$name (dark)",
                all.last(),
                TerminalSchemes.deckDark.ansi[index],
            )
            assertEquals(
                "Deck Light's colour $index has drifted from --ansi-$name (light)",
                all.first(),
                TerminalSchemes.deckLight.ansi[index],
            )
        }
    }

    /**
     * And its ground and ink are the desktop's `--terminal-bg` / `--terminal-fg`.
     *
     * This is the assertion that would have caught the drift that was already there: this module's
     * `Ink.terminalPaper` said `#121212` while `tokens.css` said `#191919`, with a comment claiming
     * they were "the same two hexes the desktop paints". They were not, and nothing checked.
     */
    @Test
    fun `the default scheme's paper matches the desktop's terminal background`() {
        val css = stylesheet()
        assumeTrue("tokens.css is not above this module — skipping the cross-check.", css != null)
        val text = css!!.readText()

        fun declarations(token: String) =
            Regex("--$token:\\s*(#[0-9a-fA-F]{6})").findAll(text)
                .map { it.groupValues[1].lowercase() }.toList()

        val backgrounds = declarations("terminal-bg")
        val foregrounds = declarations("terminal-fg")
        assumeTrue("terminal tokens not declared twice", backgrounds.size >= 2 && foregrounds.size >= 2)

        assertEquals(backgrounds.last(), TerminalSchemes.deckDark.background)
        assertEquals(foregrounds.last(), TerminalSchemes.deckDark.foreground)
        assertEquals(backgrounds.first(), TerminalSchemes.deckLight.background)
        assertEquals(foregrounds.first(), TerminalSchemes.deckLight.foreground)
    }

    /* ------------------------------------- parity with the shared table ------------ */

    /**
     * `src/shared/terminal-theme.ts`, with its comments taken out.
     *
     * Load-bearing rather than tidiness, the same way `tokens.test.ts` strips its sheet: the prose
     * in that file quotes hexes — `#0e0f13`, `rgba(59,143,238,0.16)` — and names the palettes it
     * took each scheme from, so a parser that read the comments would read colours that are being
     * discussed rather than declared. Stripping first also means the brace-matching below never has
     * to worry about a brace inside a sentence.
     */
    private fun sharedSource(): String? =
        upstream("src/shared/terminal-theme.ts")?.readText()
            ?.replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            ?.replace(Regex("(?m)^[ \\t]*//.*$"), "")

    /** The `key: 'value'` pairs of one object literal. */
    private fun pairs(block: String): Map<String, String> =
        Regex("([A-Za-z][A-Za-z0-9]*)\\s*:\\s*'([^']*)'").findAll(block)
            .associate { it.groupValues[1] to it.groupValues[2] }

    /**
     * The body of a top-level `const NAME … = { … }`.
     *
     * Ends at the first `}` in column zero, which is enough because nothing declared this way in
     * that file nests. Throws rather than returning null when the declaration is not there: a
     * renamed export is a restructuring somebody has to look at, not a reason to go quiet.
     */
    private fun objectNamed(source: String, name: String): String {
        val start = Regex("const\\s+" + Regex.escape(name) + "[^=]*=\\s*\\{").find(source)?.range?.last
            ?: throw AssertionError("$name is no longer declared in terminal-theme.ts")
        return source.substring(start, source.indexOf("\n}", start))
    }

    /**
     * Every shipped scheme as the shared file declares it, in the order it declares them.
     *
     * Two of the entries there are written as five colours and a `...APP_ANSI_DARK` spread rather
     * than as twenty-one literals, so the spreads are resolved here — otherwise the sixteen that
     * four schemes share would be the sixteen this guard never checked, which is most of the table.
     */
    private fun sharedSchemes(source: String): List<Map<String, String>> {
        val spreads = mapOf(
            "APP_ANSI_DARK" to pairs(objectNamed(source, "APP_ANSI_DARK")),
            "APP_ANSI_LIGHT" to pairs(objectNamed(source, "APP_ANSI_LIGHT")),
        )
        val start = Regex("const\\s+BUILTIN_SCHEMES[^=]*=\\s*\\[").find(source)?.range?.last
            ?: throw AssertionError("BUILTIN_SCHEMES is no longer declared in terminal-theme.ts")
        val body = source.substring(start, source.indexOf("\n]", start))
        return Regex("\\{([^{}]*)\\}").findAll(body).map { match ->
            val block = match.groupValues[1]
            val spread = Regex("\\.\\.\\.([A-Za-z_][A-Za-z0-9_]*)").find(block)?.groupValues?.get(1)
            val base = spread?.let {
                spreads[it] ?: throw AssertionError("terminal-theme.ts spreads an unknown $it")
            } ?: emptyMap()
            base + pairs(block)
        }.toList()
    }

    /** What this slot is called in the shared file. Every name but one is the enum's, decapitalised. */
    private fun sharedKey(slot: TerminalSlot): String = when (slot) {
        TerminalSlot.Selection -> "selectionBackground"
        else -> slot.name.replaceFirstChar { it.lowercase() }
    }

    /**
     * Every shipped scheme is the shared table's scheme, colour for colour and name for name.
     *
     * This is the guard the drift got past. `src/shared/terminal-theme.ts` is the single declaration
     * — the desktop imports it, iOS mirrors it in Swift, this module mirrors it in Kotlin — and
     * there is no import path from TypeScript into either mirror, so the only thing holding the
     * three together is a test that reads the source. Without one, eleven values had moved before
     * anybody noticed: Tango's ground was `#2e3436` here and `#000000` everywhere else, Dark Grey's
     * was `#2b2b2b` against `#262626`, One Half Light's yellow was `#c18401` against `#c18301`, and
     * the four schemes this product owns had different names, different cursor accents and
     * selections that had been flattened opaque.
     *
     * The order is asserted as well as the contents, because the picker on this phone and the picker
     * on the desktop are the same list read top to bottom and *where a scheme sits* is part of what
     * somebody recognises.
     */
    @Test
    fun `every shipped scheme is the shared table's, colour for colour`() {
        val source = sharedSource()
        assumeTrue(
            "src/shared/terminal-theme.ts is not above this module — skipping the cross-check.",
            source != null,
        )
        val declared = sharedSchemes(source!!)
        // A regex that matched nothing would let this test pass by having nothing to compare.
        assertEquals(
            "terminal-theme.ts parsed to a different number of schemes — was it restructured, or " +
                "does this phone ship a different set?",
            declared.size,
            TerminalSchemes.builtIns.size,
        )
        assertEquals(
            "the shipped ids, in the order the picker draws them",
            declared.map { it["id"] },
            TerminalSchemes.builtIns.map { it.id },
        )
        for (entry in declared) {
            val id = entry["id"]!!
            val found = TerminalSchemes.builtIn(id)
            assertNotNull("$id is in the shared table and not on this phone", found)
            val mine = found!!
            assertEquals("$id.name has drifted from the shared table", entry["name"], mine.name)
            for (slot in TerminalSlot.entries) {
                assertEquals(
                    "$id.${slot.name} has drifted from src/shared/terminal-theme.ts",
                    entry[sharedKey(slot)],
                    slot.read(mine),
                )
            }
        }
    }

    /**
     * The choice that is not a scheme is spelt the way every client spells it.
     *
     * It is an id like any other — it is what gets *stored* when somebody has not picked — and this
     * module wrote `auto` where the shared file and iOS both write `follow-app`. A default that
     * spells itself differently on one client is the same defect as a scheme that does, and it is
     * the one an id-level check catches before anybody has to see it.
     */
    @Test
    fun `the reserved choice is spelt the way every client spells it`() {
        val source = sharedSource()
        assumeTrue(
            "src/shared/terminal-theme.ts is not above this module — skipping the cross-check.",
            source != null,
        )
        val shared = Regex("FOLLOW_APP_SCHEME_ID\\s*=\\s*'([^']*)'")
            .find(source!!)?.groupValues?.get(1)
        assertNotNull("FOLLOW_APP_SCHEME_ID is no longer declared in terminal-theme.ts", shared)
        assertEquals(shared, TerminalSchemes.MATCH_APPEARANCE)
    }

    /**
     * And the editor's rows are named what the shared file names them.
     *
     * `SLOT_LABELS` is part of the same declaration and it is the half a person actually reads: the
     * row under the caret used to say *Cursor text* here and *Text under the cursor* on the other
     * two, which is two different answers to what a screenshot of this screen means.
     */
    @Test
    fun `the editor's rows are named the way the shared table names them`() {
        val source = sharedSource()
        assumeTrue(
            "src/shared/terminal-theme.ts is not above this module — skipping the cross-check.",
            source != null,
        )
        val labels = pairs(objectNamed(source!!, "SLOT_LABELS"))
        assertEquals("SLOT_LABELS parsed to the wrong size", TerminalSlot.entries.size, labels.size)
        for (slot in TerminalSlot.entries) {
            assertEquals("$slot's label", labels[sharedKey(slot)], slot.label)
        }
    }
}
