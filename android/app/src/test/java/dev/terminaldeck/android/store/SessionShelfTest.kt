package dev.terminaldeck.android.store

import dev.terminaldeck.android.protocol.RemoteSessionView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The shelf, driven over a store in memory rather than a device's disk. */
class SessionShelfTest {

    private class Memory : SessionShelf.Store {
        var value: String? = null
        var writes = 0
        override fun read(): String? = value
        override fun write(value: String) {
            this.value = value
            writes += 1
        }
    }

    private fun session(id: String) = RemoteSessionView(
        id = id, title = id, cwd = "/w/$id", provider = "claude", status = "working", exitCode = null,
    )

    private val all = listOf(session("a"), session("b"), session("c"))

    @Test
    fun `a fresh shelf hides nothing and reorders nothing`() {
        val shelf = SessionShelf(Memory())
        val split = shelf.split(all, "mac")
        assertEquals(all, split.listed)
        assertEquals(emptyList<RemoteSessionView>(), split.archived)
    }

    @Test
    fun `an archived row leaves the list and can be found on the shelf`() {
        val shelf = SessionShelf(Memory())
        shelf.setArchived(true, "mac", "b")

        val split = shelf.split(all, "mac")
        assertEquals(listOf("a", "c"), split.listed.map { it.id })
        assertEquals(listOf("b"), split.archived.map { it.id })
        assertTrue(shelf.isArchived("mac", "b"))
    }

    @Test
    fun `unarchiving puts the row back where it belongs rather than at the top`() {
        val shelf = SessionShelf(Memory())
        shelf.setArchived(true, "mac", "a")
        shelf.setArchived(false, "mac", "a")
        assertEquals(listOf("a", "b", "c"), shelf.split(all, "mac").listed.map { it.id })
        assertFalse(shelf.isArchived("mac", "a"))
    }

    @Test
    fun `pinned rows keep the order they were pinned in, not the machine's`() {
        val shelf = SessionShelf(Memory())
        shelf.setPinned(true, "mac", "c")
        shelf.setPinned(true, "mac", "a")
        // A person who pins two sessions is stating which one they want first; re-sorting by the
        // machine's list order would throw that away.
        assertEquals(listOf("a", "c", "b"), shelf.split(all, "mac").listed.map { it.id })
    }

    @Test
    fun `archiving unpins, because a row cannot be both at the top and absent`() {
        val shelf = SessionShelf(Memory())
        shelf.setPinned(true, "mac", "a")
        shelf.setArchived(true, "mac", "a")
        assertFalse(shelf.isPinned("mac", "a"))
        // A stale pin left behind would make an unarchive jump the row to the top for reasons nobody
        // could see.
        shelf.setArchived(false, "mac", "a")
        assertEquals(listOf("a", "b", "c"), shelf.split(all, "mac").listed.map { it.id })
    }

    @Test
    fun `pinning unarchives, the mirror of the rule above`() {
        val shelf = SessionShelf(Memory())
        shelf.setArchived(true, "mac", "b")
        shelf.setPinned(true, "mac", "b")
        assertFalse(shelf.isArchived("mac", "b"))
        assertEquals(listOf("b", "a", "c"), shelf.split(all, "mac").listed.map { it.id })
    }

    @Test
    fun `one gesture is one write, however many verbs it calls`() {
        val store = Memory()
        val shelf = SessionShelf(store)
        shelf.setPinned(true, "mac", "a")
        val before = store.writes
        shelf.setArchived(true, "mac", "a")
        assertEquals("archive-which-unpins commits once", before + 1, store.writes)
    }

    @Test
    fun `the count is measured against the live list, not against the store`() {
        val shelf = SessionShelf(Memory())
        shelf.setArchived(true, "mac", "b")
        // A machine that has been rebooted has archived ids for sessions that no longer exist, and a
        // count of those is a menu item that opens onto nothing.
        shelf.setArchived(true, "mac", "gone-in-a-restart")
        assertEquals(1, shelf.archivedCount(all, "mac"))
        assertEquals(2, shelf.archived("mac").size)
    }

    @Test
    fun `two machines keep their own shelves`() {
        val shelf = SessionShelf(Memory())
        shelf.setArchived(true, "mac", "a")
        assertTrue(shelf.isArchived("mac", "a"))
        assertFalse(shelf.isArchived("pc", "a"))
        assertEquals(listOf("a", "b", "c"), shelf.split(all, "pc").listed.map { it.id })
    }

    @Test
    fun `it survives a relaunch`() {
        val store = Memory()
        SessionShelf(store).apply {
            setArchived(true, "mac", "b")
            setPinned(true, "mac", "c")
        }
        val reopened = SessionShelf(store)
        assertTrue(reopened.isArchived("mac", "b"))
        assertTrue(reopened.isPinned("mac", "c"))
        assertEquals(listOf("c", "a"), reopened.split(all, "mac").listed.map { it.id })
    }

    @Test
    fun `a record another build wrote does not get around the bound`() {
        val store = Memory()
        val ids = (1..SessionShelf.MAX_PER_HOST + 20).map { "s$it" }
        store.value = """{"archived":{"mac":${ids.joinToString(",", "[", "]") { "\"$it\"" }}},"pinned":{}}"""
        val shelf = SessionShelf(store)
        assertEquals(SessionShelf.MAX_PER_HOST, shelf.archived("mac").size)
        // Trimmed from the front: the drop is of the thing archived longest ago.
        assertTrue(shelf.isArchived("mac", "s${SessionShelf.MAX_PER_HOST + 20}"))
        assertFalse(shelf.isArchived("mac", "s1"))
    }

    @Test
    fun `a half-written record is a shelf that hides nothing, not a crash`() {
        val store = Memory()
        store.value = """{"archived":{"mac":["a"],"""
        val shelf = SessionShelf(store)
        assertEquals(all, shelf.split(all, "mac").listed)
    }

    @Test
    fun `a machine that is forgotten takes its shelf with it`() {
        val shelf = SessionShelf(Memory())
        shelf.setArchived(true, "mac", "a")
        shelf.forget("mac")
        assertFalse(shelf.isArchived("mac", "a"))
    }

    @Test
    fun `a host or session with no name is refused rather than stored under an empty key`() {
        val store = Memory()
        val shelf = SessionShelf(store)
        shelf.setArchived(true, "", "a")
        shelf.setArchived(true, "mac", "")
        assertEquals(0, store.writes)
    }
}
