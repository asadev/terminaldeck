package dev.terminaldeck.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The sticky modifier, which is the part of a touch key row that goes wrong.
 *
 * Mirrors `pwa/src/keybar.test.ts` so the two clients cannot drift on what Ctrl means.
 */
class KeyBarTest {

    private val esc = "\u001b"

    @Test
    fun `ctrl arms and disarms without sending anything`() {
        val armed = KeyBar.press(KeyBarKey.Ctrl, ctrl = false)
        assertEquals("", armed.data)
        assertTrue(armed.ctrl)

        val disarmed = KeyBar.press(KeyBarKey.Ctrl, ctrl = true)
        assertEquals("", disarmed.data)
        assertFalse(disarmed.ctrl)
    }

    @Test
    fun `an armed ctrl folds into the next key and is spent`() {
        val press = KeyBar.press(KeyBarKey.Tilde, ctrl = true)
        // Ctrl+~ has no control byte; the character goes as itself.
        assertEquals("~", press.data)
        assertFalse("ctrl outlived the key it applied to", press.ctrl)
    }

    /**
     * The failure this rule exists to prevent: a modifier that survives a key it could not apply
     * to fires on the key *after* that one, turning an ordinary letter into a chord.
     */
    @Test
    fun `ctrl is spent even by a key it cannot combine with`() {
        assertFalse(KeyBar.press(KeyBarKey.Pipe, ctrl = true).ctrl)
        assertFalse(KeyBar.press(KeyBarKey.Esc, ctrl = true).ctrl)
        assertFalse(KeyBar.press(KeyBarKey.Tab, ctrl = true).ctrl)
    }

    @Test
    fun `arrows send the xterm sequences, and the modified ones under ctrl`() {
        assertEquals("$esc[A", KeyBar.press(KeyBarKey.Up, ctrl = false).data)
        assertEquals("$esc[B", KeyBar.press(KeyBarKey.Down, ctrl = false).data)
        assertEquals("$esc[C", KeyBar.press(KeyBarKey.Right, ctrl = false).data)
        assertEquals("$esc[D", KeyBar.press(KeyBarKey.Left, ctrl = false).data)
        assertEquals("$esc[1;5A", KeyBar.press(KeyBarKey.Up, ctrl = true).data)
        assertEquals("$esc[1;5D", KeyBar.press(KeyBarKey.Left, ctrl = true).data)
    }

    @Test
    fun `esc and tab send one byte each`() {
        assertEquals(esc, KeyBar.press(KeyBarKey.Esc, ctrl = false).data)
        assertEquals("\t", KeyBar.press(KeyBarKey.Tab, ctrl = false).data)
        assertEquals("$esc[Z", KeyBar.press(KeyBarKey.Tab, ctrl = true).data)
    }

    @Test
    fun `the control byte is the mask, not a lookup table`() {
        assertEquals("\u0003", KeyBar.controlByteFor('c'))
        assertEquals("\u0003", KeyBar.controlByteFor('C'))
        assertEquals("\u0000", KeyBar.controlByteFor(' '))
        assertEquals("\u007f", KeyBar.controlByteFor('?'))
        assertEquals("\u001c", KeyBar.controlByteFor('\\'))
        // Terminals disagree about these two, so this client refuses to guess.
        assertNull(KeyBar.controlByteFor('/'))
        assertNull(KeyBar.controlByteFor('|'))
        assertNull(KeyBar.controlByteFor('é'))
    }

    @Test
    fun `every key in the row produces something or changes the modifier`() {
        for (key in KEY_BAR) {
            val press = KeyBar.press(key, ctrl = false)
            assertTrue(key.title, press.data.isNotEmpty() || key == KeyBarKey.Ctrl)
        }
    }
}
