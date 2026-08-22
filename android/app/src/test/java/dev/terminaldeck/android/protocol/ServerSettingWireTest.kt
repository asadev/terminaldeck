package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/** The merge that keeps the two rows in a fixed order across a push, mirrored from server-settings.ts. */
class ServerSettingWireTest {

    @Test
    fun `merge replaces by key and keeps the declaration order`() {
        val provider = ServerSettingWire("agents.defaultProvider", "claude", listOf("claude", "codex"))
        val restore = ServerSettingWire("general.restoreSessions", "false")
        // A push arriving out of order, restore first.
        val merged = ServerSettingWire.merge(null, listOf(restore, provider))
        assertEquals(listOf(ServerSettingKey.DefaultProvider, ServerSettingKey.RestoreSessions), merged.map { it.known })
    }

    @Test
    fun `a later row for a key wins without reordering the section`() {
        val first = ServerSettingWire.merge(
            null,
            listOf(
                ServerSettingWire("agents.defaultProvider", "claude"),
                ServerSettingWire("general.restoreSessions", "false"),
            ),
        )
        // One row changes; the other is untouched and the order holds.
        val next = ServerSettingWire.merge(first, listOf(ServerSettingWire("general.restoreSessions", "true")))
        assertEquals(listOf(ServerSettingKey.DefaultProvider, ServerSettingKey.RestoreSessions), next.map { it.known })
        assertEquals("claude", next[0].value)
        assertEquals("true", next[1].value)
    }

    @Test
    fun `the label map names the builtins and shows an unknown id as itself`() {
        assertEquals("Claude Code", ServerSettingsLabels.provider("claude"))
        assertEquals("Codex CLI", ServerSettingsLabels.provider("codex"))
        assertEquals("custom:my-agent", ServerSettingsLabels.provider("custom:my-agent"))
    }
}
