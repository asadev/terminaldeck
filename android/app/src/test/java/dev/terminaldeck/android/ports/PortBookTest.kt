package dev.terminaldeck.android.ports

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The phone's own names for a machine's ports, over a store in memory. */
class PortBookTest {

    private class Memory : PortBook.Store {
        var value: String? = null
        override fun read(): String? = value
        override fun write(value: String) {
            this.value = value
        }
    }

    @Test
    fun `a name is kept against the machine and the port`() {
        val book = PortBook(Memory())
        book.setName("The API", "mac", 3000)
        assertEquals("The API", book.name("mac", 3000))
        // A phone paired with a Mac and a PC is holding two unrelated port 3000s.
        assertNull(book.name("pc", 3000))
        assertEquals(mapOf(3000 to "The API"), book.names("mac"))
    }

    @Test
    fun `clearing the field removes the name rather than storing an empty one`() {
        val book = PortBook(Memory())
        book.setName("The API", "mac", 3000)
        book.setName("   ", "mac", 3000)
        // An empty string would leave a row promoted to "Named by you" with nothing written on it.
        assertNull(book.name("mac", 3000))
        assertEquals(emptyMap<Int, String>(), book.names("mac"))
    }

    @Test
    fun `a pasted paragraph is folded to something that fits a row`() {
        assertEquals("one two", PortBook.clean("  one two  "))
        // A name with a line break in it is a paste accident, not an intention, so the halves are not
        // joined with a space — the control characters go.
        assertEquals("onetwo", PortBook.clean("one\ntwo"))
        assertNull(PortBook.clean(null))
        assertNull(PortBook.clean(" "))
    }

    @Test
    fun `a name is cut to a length a row can hold, and not left ending in a space`() {
        val long = "a".repeat(PortBook.MAX_NAME_LENGTH) + " and more"
        val cleaned = PortBook.clean(long)!!
        assertEquals(PortBook.MAX_NAME_LENGTH, cleaned.length)
        assertFalse(cleaned.endsWith(" "))

        val runsOutMidWord = "b".repeat(PortBook.MAX_NAME_LENGTH - 1) + "   tail"
        assertFalse(PortBook.clean(runsOutMidWord)!!.endsWith(" "))
    }

    @Test
    fun `a group's fold is the category's default until somebody disagrees`() {
        val book = PortBook(Memory())
        assertTrue(book.isFolded("mac", PortCategory.Other))
        assertFalse(book.isFolded("mac", PortCategory.Web))

        book.setFolded(false, "mac", PortCategory.Other)
        assertFalse(book.isFolded("mac", PortCategory.Other))
        // Per machine: a WSL box where `wslrelay` is the whole point is a real machine, and the
        // default that is right for a Mac is wrong for it.
        assertTrue(book.isFolded("pc", PortCategory.Other))
    }

    @Test
    fun `names and folds survive a relaunch`() {
        val store = Memory()
        PortBook(store).apply {
            setName("The API", "mac", 3000)
            setFolded(false, "mac", PortCategory.Unnamed)
        }
        val reopened = PortBook(store)
        assertEquals("The API", reopened.name("mac", 3000))
        assertFalse(reopened.isFolded("mac", PortCategory.Unnamed))
    }

    @Test
    fun `a record another build wrote is cleaned on the way back out`() {
        val store = Memory()
        val long = "z".repeat(200)
        store.value = """{"names":{"mac":{"3000":"$long"}},"folds":{"mac":{"NotACategory":true}}}"""
        val book = PortBook(store)
        assertEquals(PortBook.MAX_NAME_LENGTH, book.name("mac", 3000)!!.length)
        // A category this build has never heard of is dropped rather than kept as a key that decides
        // nothing.
        assertTrue(book.isFolded("mac", PortCategory.Other))
    }

    @Test
    fun `a half-written record is a book with no names, not a crash`() {
        val store = Memory()
        store.value = """{"names":{"mac":{"3000":"""
        assertNull(PortBook(store).name("mac", 3000))
    }

    @Test
    fun `a machine with no id is refused rather than stored under an empty key`() {
        val book = PortBook(Memory())
        book.setName("nowhere", "", 3000)
        assertNull(book.name("", 3000))
    }
}
