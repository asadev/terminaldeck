package dev.terminaldeck.android.ports

import dev.terminaldeck.android.protocol.DevServerReport
import dev.terminaldeck.android.protocol.DevServerStatus
import dev.terminaldeck.android.protocol.LocalPort
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The grouping, which is what turns a wall of ports into a screen.
 *
 * Every rule is pinned here rather than checked by looking at a phone, because the input that
 * produces the interesting cases — a WSL box with four `wslrelay` ports and a dev server on 5173 — is
 * not something anybody has to hand.
 */
class PortCatalogTest {

    private fun port(number: Int, process: String = "node", guessed: Boolean = false) =
        LocalPort(port = number, process = process, guessed = guessed)

    private fun dev(
        folder: String,
        status: DevServerStatus,
        port: Int? = null,
        session: String? = null,
    ) = DevServerReport(
        folder = folder,
        status = status,
        script = "dev",
        command = "pnpm run dev",
        sessionId = session,
        port = port,
        url = port?.let { "http://localhost:$it" },
    )

    private fun categoriesOf(sections: List<LocalhostSection>) = sections.map { it.category }

    @Test
    fun `a runtime that usually serves a page lands in web servers`() {
        val sections = PortCatalog.sections(listOf(port(5173, "node")), emptyList())
        assertEquals(listOf(PortCategory.Web), categoriesOf(sections))
    }

    @Test
    fun `a runtime is matched as a prefix, because two scanners spell them differently`() {
        assertTrue(PortCatalog.isWebRuntime("python3"))
        assertTrue(PortCatalog.isWebRuntime("Node"))
        assertTrue(PortCatalog.isWebRuntime("node22"))
        assertTrue(!PortCatalog.isWebRuntime("wslrelay"))
    }

    @Test
    fun `an unowned port is its own group, not part of the dull pile`() {
        val sections = PortCatalog.sections(listOf(port(2019, "unknown", guessed = true)), emptyList())
        // "we could not name this" and "this is named and dull" are different facts, and only one of
        // them might be worth a second look.
        assertEquals(listOf(PortCategory.Unnamed), categoriesOf(sections))
    }

    @Test
    fun `a named process that is nothing else is other services`() {
        val sections = PortCatalog.sections(listOf(port(6666, "AgentService")), emptyList())
        assertEquals(listOf(PortCategory.Other), categoriesOf(sections))
    }

    @Test
    fun `this product's own listener is not offered as somebody's dev server`() {
        // A desktop running headless is a `node` process, so the app's own port has to be recognised
        // before the runtime name is looked at — otherwise the phone offers itself its own socket.
        val sections = PortCatalog.sections(listOf(port(7777, "node")), emptyList(), appPorts = setOf(7777))
        assertEquals(listOf(PortCategory.App), categoriesOf(sections))

        assertTrue(PortCatalog.isOwnProcess("Terminal Deck"))
        assertTrue(PortCatalog.isOwnProcess("TerminalDeck"))
        assertTrue(PortCatalog.isOwnProcess("terminaldeck"))
        assertTrue(!PortCatalog.isOwnProcess("terminal"))
    }

    @Test
    fun `naming a port promotes it out of whatever pile it was in`() {
        val sections = PortCatalog.sections(
            ports = listOf(port(2019, "wslrelay"), port(5173, "node")),
            devServers = emptyList(),
            names = mapOf(2019 to "The relay"),
        )
        // One gesture with one meaning — *this one matters and here is why* — rather than a second
        // pin control that could get out of step with the name.
        assertEquals(listOf(PortCategory.Named, PortCategory.Web), categoriesOf(sections))
        assertEquals("The relay", sections.first().rows.single().name)
    }

    @Test
    fun `a ready dev server claims its port, so there is one row and not two`() {
        val sections = PortCatalog.sections(
            ports = listOf(port(5173, "node")),
            devServers = listOf(dev("/w/app", DevServerStatus.Ready, port = 5173, session = "s1")),
        )
        assertEquals(listOf(PortCategory.DevServer), categoriesOf(sections))
        val row = sections.single().rows.single()
        // The merged row carries both the project and the address.
        assertEquals("/w/app", row.dev?.folder)
        assertEquals(5173, row.entry?.port)
        assertEquals(5173, row.port)
    }

    @Test
    fun `a starting dev server has no port, so nothing is claimed and nothing is dropped`() {
        val sections = PortCatalog.sections(
            ports = listOf(port(5173, "node")),
            devServers = listOf(dev("/w/app", DevServerStatus.Starting, session = "s1")),
        )
        assertEquals(listOf(PortCategory.DevServer, PortCategory.Web), categoriesOf(sections))
        assertNull(sections.first().rows.single().port)
    }

    @Test
    fun `a failed dev server never carries the address of the server that died`() {
        // The report may not even mention a port; if it did, this must not join it to a live row.
        val sections = PortCatalog.sections(
            ports = listOf(port(5173, "node")),
            devServers = listOf(dev("/w/app", DevServerStatus.Failed, port = 5173)),
        )
        val devRow = sections.first { it.category == PortCategory.DevServer }.rows.single()
        assertNull(devRow.entry)
        // And the listening port is still its own row, because nothing claimed it.
        assertTrue(sections.any { it.category == PortCategory.Web })
    }

    @Test
    fun `no-dev-script is never a row`() {
        val sections = PortCatalog.sections(
            ports = emptyList(),
            devServers = listOf(dev("/w/app", DevServerStatus.NoDevScript)),
        )
        assertEquals(emptyList<LocalhostSection>(), sections)
    }

    @Test
    fun `the sections come out in the order they are drawn in`() {
        val sections = PortCatalog.sections(
            ports = listOf(
                port(2019, "unknown", guessed = true),
                port(6666, "AgentService"),
                port(7777, "node"),
                port(5173, "node"),
                port(3000, "node"),
            ),
            devServers = listOf(dev("/w/app", DevServerStatus.Idle)),
            appPorts = setOf(7777),
            names = mapOf(3000 to "The API"),
        )
        assertEquals(
            listOf(
                PortCategory.Named,
                PortCategory.DevServer,
                PortCategory.Web,
                PortCategory.App,
                PortCategory.Other,
                PortCategory.Unnamed,
            ),
            categoriesOf(sections),
        )
    }

    @Test
    fun `order within a section is the order the machine sent`() {
        val sections = PortCatalog.sections(
            ports = listOf(port(5173, "node"), port(3000, "node"), port(8080, "node")),
            devServers = emptyList(),
        )
        // The desktop ranks its ports most-likely-to-be-a-dev-server first, and re-sorting here would
        // throw away the only ordering anybody has an opinion about.
        assertEquals(listOf(5173, 3000, 8080), sections.single().rows.map { it.port })
    }

    @Test
    fun `the three noisy groups start folded and the three useful ones do not`() {
        assertEquals(false, PortCategory.Named.foldedByDefault)
        assertEquals(false, PortCategory.DevServer.foldedByDefault)
        assertEquals(false, PortCategory.Web.foldedByDefault)
        assertEquals(true, PortCategory.App.foldedByDefault)
        assertEquals(true, PortCategory.Other.foldedByDefault)
        assertEquals(true, PortCategory.Unnamed.foldedByDefault)
    }

    @Test
    fun `a row's id is stable across a port changing under a dev server`() {
        val first = PortCatalog.sections(emptyList(), listOf(dev("/w/app", DevServerStatus.Ready, port = 5173)))
        val second = PortCatalog.sections(emptyList(), listOf(dev("/w/app", DevServerStatus.Ready, port = 5174)))
        // Vite takes 5174 when 5173 is busy. Keying the row on the port would re-animate it.
        assertEquals(first.single().rows.single().id, second.single().rows.single().id)
    }

    @Test
    fun `the second action is the one the state deserves`() {
        fun action(status: DevServerStatus, session: String? = "s1") =
            PortCatalog.secondAction(
                LocalhostRow(null, dev("/w/app", status, session = session), null, PortCategory.DevServer)
            )

        assertEquals(PortRowAction.Start("/w/app"), action(DevServerStatus.Idle))
        assertEquals(PortRowAction.Retry("/w/app"), action(DevServerStatus.Failed))
        // A second start while one is coming up would be a second start.
        assertEquals(PortRowAction.OpenSession("s1"), action(DevServerStatus.Starting))
        // Where it is running, and where the interrupt stops it. There is no stop verb on the wire.
        assertEquals(PortRowAction.OpenSession("s1"), action(DevServerStatus.Ready))
        // The protocol says both states carry a session. Drawing a control that would have nowhere
        // to go is worse than drawing none, so the impossible case is handled rather than forced.
        assertEquals(PortRowAction.None, action(DevServerStatus.Starting, session = null))
        assertEquals(PortRowAction.None, action(DevServerStatus.Unknown))

        val plain = LocalhostRow(LocalPort(2019, "wslrelay"), null, null, PortCategory.Other)
        // Nothing on the wire can start or stop "whatever is on 2019".
        assertEquals(PortRowAction.CopyAddress(2019), PortCatalog.secondAction(plain))
    }

    @Test
    fun `the product's two spellings are the ones the brand module produces`() {
        // A rename that reached this client without reaching this file fails here rather than
        // quietly stopping the app's own port from being recognised.
        assertEquals("Terminal Deck", PortCatalog.BRAND_NAME)
        assertEquals("terminaldeck", PortCatalog.BRAND_ID)
    }
}
