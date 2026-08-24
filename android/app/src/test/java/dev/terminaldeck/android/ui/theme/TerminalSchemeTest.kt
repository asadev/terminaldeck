package dev.terminaldeck.android.ui.theme

import com.termux.terminal.TerminalColors
import com.termux.terminal.TextStyle
import org.junit.Assert.assertEquals
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
 *  2. **Parity with the desktop.** The default scheme's sixteen are read out of `tokens.css` rather
 *     than repeated here, in the manner of `PaletteParityTest`: three copies of the same table exist
 *     in this product and none of them knows when another moves.
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
                assertNotNull("${scheme.id}.${slot.name} = '$value' is not a colour",
                    TerminalScheme.parseOrNull(value))
                assertEquals(
                    "${scheme.id}.${slot.name} is not written canonically",
                    value,
                    TerminalScheme.normalise(value),
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
        val scheme = TerminalSchemes.terminalDeck
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
            "Pure black", "Terminal Deck", "Dark grey",
            "Solarized Dark", "Solarized Light", "Nord", "Dracula",
            "Gruvbox Dark", "One Half Dark", "One Half Light", "Tango", "Campbell",
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
            TerminalSchemes.terminalDeck,
            TerminalSchemeStore.resolve(null, emptyList(), dark = true),
        )
        assertEquals(
            TerminalSchemes.terminalDeckLight,
            TerminalSchemeStore.resolve(null, emptyList(), dark = false),
        )
        assertEquals(
            TerminalSchemes.terminalDeckLight,
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
            TerminalSchemes.terminalDeck,
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
     * ground — so a scheme whose caret is deliberately not white (Nord's `#d8dee9`, One Half Dark's
     * `#a3b3cc`) is the case that proves the key is being sent.
     */
    @Test
    fun `the scheme's own cursor is installed rather than a derived one`() {
        installTerminalPalette(TerminalSchemes.oneHalfDark)
        assertEquals(
            TerminalScheme.parse("#a3b3cc"),
            TerminalColors.COLOR_SCHEME.mDefaultColors[TextStyle.COLOR_INDEX_CURSOR],
        )
    }

    /* ----------------------------------------------- parity with the desktop ------- */

    /**
     * The stylesheet, found by walking up rather than by a relative path.
     *
     * The same walk `PaletteParityTest` does, and for the reason that test's first version taught:
     * a `File("../…")` depends on which directory the runner starts in, so it does not fail when it
     * is wrong — it *skips*, and a cross-check that has silently skipped for a month is worse than
     * no cross-check, because the file it guards looks tested.
     */
    private fun stylesheet(): File? {
        var here: File? = File("").absoluteFile
        repeat(6) {
            val candidate = File(here, "src/renderer/styles/tokens.css")
            if (candidate.isFile) return candidate
            here = here?.parentFile
        }
        return null
    }

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
                "Terminal Deck's colour $index has drifted from --ansi-$name (dark)",
                all.last(),
                TerminalSchemes.terminalDeck.ansi[index],
            )
            assertEquals(
                "Terminal Deck Light's colour $index has drifted from --ansi-$name (light)",
                all.first(),
                TerminalSchemes.terminalDeckLight.ansi[index],
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

        assertEquals(backgrounds.last(), TerminalSchemes.terminalDeck.background)
        assertEquals(foregrounds.last(), TerminalSchemes.terminalDeck.foreground)
        assertEquals(backgrounds.first(), TerminalSchemes.terminalDeckLight.background)
        assertEquals(foregrounds.first(), TerminalSchemes.terminalDeckLight.foreground)
    }
}
