package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The catalogue is a **copy** of `src/shared/model-catalog.ts` and `catalog.ts`, so what these check
 * is that the copy still says what the original says: the ids are what get typed at a real binary,
 * and a drifted id is a control that silently sets nothing.
 */
class ControlCatalogTest {

    @Test
    fun `the model ids are the aliases the CLI accepts`() {
        assertEquals(
            listOf("opus[1m]", "opus", "fable", "sonnet", "haiku", "opusplan"),
            ControlCatalog.models.map { it.id },
        )
        // The recommended row, and only it, carries the account tag.
        assertEquals(1, ControlCatalog.models.count { it.hint != null })
        assertEquals("opus[1m]", ControlCatalog.models.first { it.hint != null }.id)
    }

    @Test
    fun `earlier models are captioned once, at the top of their run`() {
        val rows = ControlCatalog.rows(ControlName.Model)
        val captioned = rows.filter { it.group != null }
        assertEquals(1, captioned.size)
        assertEquals("Earlier models", captioned.single().group)
        assertEquals("claude-opus-4-8", captioned.single().id)
    }

    @Test
    fun `permission lists the five modes shift-tab visits, and not dontAsk`() {
        assertEquals(
            listOf("plan", "manual", "acceptEdits", "auto", "bypass"),
            ControlCatalog.permission.map { it.id },
        )
        assertFalse(ControlCatalog.permission.any { it.id == "dontAsk" })
    }

    @Test
    fun `effort puts extra high first because that is what this app sets`() {
        assertEquals("xhigh", ControlCatalog.effort.first().id)
        assertEquals(
            listOf("xhigh", "ultracode", "max", "high", "medium", "low", "auto"),
            ControlCatalog.effort.map { it.id },
        )
    }

    @Test
    fun `a chip prints the value alone, and the unread word when nothing was read`() {
        assertEquals("Unknown", ControlCatalog.displayValue(ControlReadingWire.EMPTY, ControlName.Model))
        // Permission is the one the CLI prints only when it changes, so its unread word differs.
        assertEquals(
            "Not reported",
            ControlCatalog.displayValue(ControlReadingWire.EMPTY, ControlName.Permission),
        )
        assertEquals(
            "High",
            ControlCatalog.displayValue(ControlReadingWire("high", "High"), ControlName.Effort),
        )
    }

    @Test
    fun `a model label is shortened the way the desktop's chip shortens it`() {
        assertEquals("Opus 5", ControlCatalog.shortModelLabel("Opus 5 (recommended)"))
        assertEquals("Opus 5 1M", ControlCatalog.shortModelLabel("Opus 5 (1M context)"))
        assertEquals("Opus Plan", ControlCatalog.shortModelLabel("Opus in plan mode, else Sonnet"))
    }

    @Test
    fun `a row ticks on the exact id, and on a decorated label naming the same model`() {
        val opus = ControlCatalog.models.first { it.id == "opus" }
        assertTrue(ControlCatalog.isCurrent(ControlReadingWire(value = "opus"), opus))
        assertTrue(
            ControlCatalog.isCurrent(
                ControlReadingWire(value = "something-else", label = "Opus 5 (recommended)"),
                opus,
            )
        )
        // 1M is part of the identity, not decoration: the long-context row is a different row.
        val long = ControlCatalog.models.first { it.id == "opus[1m]" }
        assertFalse(ControlCatalog.isCurrent(ControlReadingWire(value = "x", label = "Opus 5"), long))
        assertTrue(
            ControlCatalog.isCurrent(
                ControlReadingWire(value = "x", label = "Opus 5 with 1M context"),
                long,
            )
        )
    }

    @Test
    fun `nothing ticks when nothing has been read`() {
        for (option in ControlCatalog.rows(ControlName.Model)) {
            assertFalse(ControlCatalog.isCurrent(ControlReadingWire.EMPTY, option))
        }
    }
}
