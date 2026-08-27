package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The copilot's frames, through the real codec.
 *
 * Thirteen client verbs and nine server frames, every one of which is a promise about a wire shape:
 * a discriminator spelled wrong does not fail to compile, it lights a button up and then has the
 * machine close the socket on the frame that button sends.
 */
class CopilotWireTest {

    private fun ok(raw: String): ServerMessage {
        val result = ServerFrames.parse(raw)
        assertTrue("expected a frame, got $result", result is ServerFrames.Result.Ok)
        return (result as ServerFrames.Result.Ok).message
    }

    @Test
    fun `the bare verbs carry nothing, and that is the change 2026-08-19 made`() {
        // `copilot.connect` and its credential are gone: the second factor is having been paired as
        // one of the owner's own devices, which is decided at the machine.
        assertEquals("""{"t":"copilot.hello"}""", ClientFrames.encode(ClientMessage.CopilotHello))
        assertEquals("""{"t":"copilot.bye"}""", ClientFrames.encode(ClientMessage.CopilotBye))
        assertEquals("""{"t":"copilot.attach"}""", ClientFrames.encode(ClientMessage.CopilotAttach))
        assertEquals("""{"t":"copilot.detach"}""", ClientFrames.encode(ClientMessage.CopilotDetach))
        assertEquals("""{"t":"copilot.state"}""", ClientFrames.encode(ClientMessage.CopilotState))
        assertEquals("""{"t":"copilot.sessions"}""", ClientFrames.encode(ClientMessage.CopilotSessions))
        assertEquals("""{"t":"copilot.pending"}""", ClientFrames.encode(ClientMessage.CopilotPending))
        assertEquals("""{"t":"copilot.start"}""", ClientFrames.encode(ClientMessage.CopilotStart))
        assertEquals("""{"t":"copilot.cancel"}""", ClientFrames.encode(ClientMessage.CopilotCancel))
        assertEquals("""{"t":"copilot.stop"}""", ClientFrames.encode(ClientMessage.CopilotStop))
    }

    @Test
    fun `saying something carries the text and nothing else`() {
        assertEquals("""{"t":"copilot.say","text":"ship it"}""", ClientFrames.encode(ClientMessage.CopilotSay("ship it")))
    }

    @Test
    fun `an answer carries a literal boolean, because nothing else is read as yes`() {
        assertEquals(
            """{"t":"copilot.answer","id":"q1","approved":true}""",
            ClientFrames.encode(ClientMessage.CopilotAnswer("q1", true)),
        )
        // `encodeDefaults = false` would drop a literal false, and the desktop reads `approved` as a
        // required boolean — a frame without it is refused rather than read as no.
        assertEquals(
            """{"t":"copilot.answer","id":"q1","approved":false}""",
            ClientFrames.encode(ClientMessage.CopilotAnswer("q1", false)),
        )
    }

    @Test
    fun `the visibility toggle carries its decision either way`() {
        // Only a literal boolean is read over there — a `false` that travelled as
        // an absence would be a toggle one lenient reader away from meaning the
        // opposite, so `encodeDefaults = false` dropping it would be a bug. `on`
        // carries no default for exactly that reason.
        assertEquals(
            """{"t":"copilot.interactive","on":true}""",
            ClientFrames.encode(ClientMessage.CopilotSetInteractive(true)),
        )
        assertEquals(
            """{"t":"copilot.interactive","on":false}""",
            ClientFrames.encode(ClientMessage.CopilotSetInteractive(false)),
        )
    }

    @Test
    fun `the log pages backwards by row id rather than by index`() {
        assertEquals("""{"t":"copilot.log"}""", ClientFrames.encode(ClientMessage.CopilotLog()))
        assertEquals(
            """{"t":"copilot.log","limit":200,"before":"r9"}""",
            ClientFrames.encode(ClientMessage.CopilotLog(limit = 200, before = "r9")),
        )
    }

    @Test
    fun `the state report reads the desk and this device's run as two different things`() {
        val message = ok(
            """{"t":"copilot.state","state":{"desk":"running","run":"r1","profile":"default",""" +
                """"signedIn":true,"tools":12,"turnTokens":840,"pending":1,""" +
                """"grant":{"read":true,"act":true,"alter":true},"available":true}}"""
        ) as ServerMessage.CopilotStateFrame
        assertEquals(CopilotDesk.Running, message.state.desk)
        assertEquals("r1", message.state.run)
        assertTrue(message.state.hasRun)
        assertEquals(840, message.state.turnTokens)
        assertTrue(message.state.grant.alter)
    }

    @Test
    fun `a desk word a newer desktop grew is folded rather than dropping the frame`() {
        // `coerceInputValues` folds an unknown enum onto the *property's default*, so the default
        // has to be Unknown: with `Stopped` there, a desktop that grew a fourth word would have had
        // this client draw "Stopped" over an agent that was running.
        val message = ok("""{"t":"copilot.state","state":{"desk":"hibernating"}}""") as ServerMessage.CopilotStateFrame
        assertEquals(CopilotDesk.Unknown, message.state.desk)
        // A frame that never named the desk is the same honest non-answer.
        assertEquals(CopilotDesk.Unknown, (ok("""{"t":"copilot.state"}""") as ServerMessage.CopilotStateFrame).state.desk)
        // And a report with no run is not a report with an empty one.
        assertEquals(false, message.state.hasRun)
        assertNull(message.state.run)
    }

    @Test
    fun `a machine that cannot start one says why, in its own words`() {
        val message = ok(
            """{"t":"copilot.state","state":{"desk":"stopped","available":false,"reason":"No API key configured."}}"""
        ) as ServerMessage.CopilotStateFrame
        assertEquals(false, message.state.available)
        assertEquals("No API key configured.", message.state.reason)
    }

    @Test
    fun `the conversation names its run, so a dead one cannot be spliced onto a live one`() {
        val message = ok(
            """{"t":"copilot.chat","run":"r1","reset":true,"messages":[""" +
                """{"id":"m1","role":"you","text":"hello","at":1000},""" +
                """{"id":"m2","role":"agent","text":"hi","at":1001,"truncated":true}]}"""
        ) as ServerMessage.CopilotChat
        assertEquals("r1", message.run)
        assertEquals(true, message.reset)
        assertEquals(ChatRole.You, message.messages[0].role)
        assertEquals(ChatRole.Agent, message.messages[1].role)
        assertEquals(true, message.messages[1].truncated)
    }

    @Test
    fun `a tool row carries its outcome and, when refused, the copilot's own words`() {
        val message = ok(
            """{"t":"copilot.tool","row":{"id":"a1","at":"2026-08-22T10:00:00Z","tool":"write_file",""" +
                """"tier":"alter","outcome":"refused","detail":"src/main.ts","refusal":"not-granted",""" +
                """"deviceId":"d1"}}"""
        ) as ServerMessage.CopilotTool
        assertEquals(CopilotOutcome.Refused, message.row.outcome)
        // A gate that denies invisibly is indistinguishable from a gate that was never reached.
        assertEquals("not-granted", message.row.refusal)
    }

    @Test
    fun `an outcome this build has never heard of is folded rather than dropping the row`() {
        val message = ok("""{"t":"copilot.tool","row":{"id":"a1","outcome":"deferred"}}""") as ServerMessage.CopilotTool
        assertEquals(CopilotOutcome.Unknown, message.row.outcome)
    }

    @Test
    fun `a pending row says whether this device may answer it`() {
        val message = ok(
            """{"t":"copilot.pending","questions":[""" +
                """{"id":"q1","tool":"write_file","summary":"Write src/main.ts","requestedAt":1,"expiresAt":2,"mine":true},""" +
                """{"id":"q2","tool":"run","summary":"Run the build","requestedAt":1,"expiresAt":2}]}"""
        ) as ServerMessage.CopilotPendingRows
        assertEquals(true, message.questions[0].mine)
        // A row that is not this device's is a notification, not a decision — the default is no.
        assertEquals(false, message.questions[1].mine)
    }

    @Test
    fun `a question carries the tool's own arguments, untouched`() {
        val message = ok(
            """{"t":"copilot.ask","question":{"id":"q1","tool":"write_file","tier":"alter",""" +
                """"summary":"Write a file","args":{"path":"/w/app/src/main.ts","mode":"overwrite"},""" +
                """"origin":"r1","requestedAt":1,"expiresAt":2}}"""
        ) as ServerMessage.CopilotAsk
        assertEquals("q1", message.question.id)
        // Left as JSON: the shape belongs to whichever tool raised it, and mirroring one here would
        // mean a new tool's arguments arriving as an empty object.
        assertEquals(listOf("path" to "/w/app/src/main.ts"), CopilotArguments.lines(message.question.args))
    }

    @Test
    fun `arguments this build does not understand draw nothing rather than a guess`() {
        val message = ok(
            """{"t":"copilot.ask","question":{"id":"q1","args":{"weirdField":"x","count":3}}}"""
        ) as ServerMessage.CopilotAsk
        assertEquals(emptyList<Pair<String, String>>(), CopilotArguments.lines(message.question.args))
    }

    @Test
    fun `a settled confirmation says where it was answered`() {
        val message = ok(
            """{"t":"copilot.settled","settled":{"id":"q1","granted":true,"by":"Asad's Mac"}}"""
        ) as ServerMessage.CopilotSettled
        assertEquals(true, message.settled.granted)
        // A dialog that vanishes without saying where the answer came from is the app doing
        // something behind a person's back.
        assertEquals("Asad's Mac", message.settled.by)
    }

    @Test
    fun `a grant that closed is a grant that closed, whatever it still carries`() {
        val message = ok(
            """{"t":"copilot.grant","link":{"linked":true,"open":false,"grant":{"read":true,"act":true,"alter":true}}}"""
        ) as ServerMessage.CopilotGrant
        assertEquals(false, message.link.open)
        assertEquals(CopilotAccess.Connecting, CopilotAccess.read(offered = true, link = message.link))
    }

    @Test
    fun `the five access states are read from the two gates and from nothing else`() {
        val all = CopilotGrantWire(read = true, act = true, alter = true)
        val watch = CopilotGrantWire(read = true)
        val nothing = CopilotGrantWire()
        fun link(grant: CopilotGrantWire) = CopilotLinkWire(linked = true, open = true, grant = grant)

        // The capability is the first gate: a machine that never advertised one offers none, however
        // the grant reads.
        assertEquals(CopilotAccess.NotOffered, CopilotAccess.read(offered = false, link = link(all)))
        assertEquals(CopilotAccess.Connecting, CopilotAccess.read(offered = true, link = null))
        // Open, and given nothing. It should not happen, so it is stated rather than hidden.
        assertEquals(CopilotAccess.NotGranted, CopilotAccess.read(offered = true, link = link(nothing)))
        assertEquals(CopilotAccess.Watch, CopilotAccess.read(offered = true, link = link(watch)))
        assertEquals(CopilotAccess.Direct, CopilotAccess.read(offered = true, link = link(all)))

        assertEquals(false, CopilotAccess.NotOffered.isConnected)
        assertTrue(CopilotAccess.Watch.isConnected)
        assertEquals(false, CopilotAccess.Watch.canAct)
        assertTrue(CopilotAccess.Direct.canAct)
    }

    @Test
    fun `the timeline merges a message by id rather than appending it twice`() {
        val first = CopilotTimeline.mergeChat(emptyList(), listOf(message("m1", "hel")), reset = false)
        val second = CopilotTimeline.mergeChat(first, listOf(message("m1", "hello")), reset = false)
        assertEquals(1, second.size)
        assertEquals("hello", (second.single() as CopilotEntry.Said).message.text)
    }

    @Test
    fun `a reset takes the frame as the whole conversation, tool rows included`() {
        val held = CopilotTimeline.mergeTool(
            CopilotTimeline.mergeChat(emptyList(), listOf(message("m1", "old")), reset = false),
            CopilotActionRow(id = "a1"),
        )
        assertEquals(2, held.size)
        val reset = CopilotTimeline.mergeChat(held, listOf(message("m2", "new")), reset = true)
        // A reset is a different run, and a log line from the previous one spliced into the new
        // timeline is a person reading about work done for somebody else's question.
        assertEquals(1, reset.size)
        assertEquals("m2", (reset.single() as CopilotEntry.Said).message.id)
    }

    @Test
    fun `a tool call arrives twice and is drawn once`() {
        val started = CopilotTimeline.mergeTool(emptyList(), CopilotActionRow(id = "a1", outcome = CopilotOutcome.Unknown))
        val settled = CopilotTimeline.mergeTool(started, CopilotActionRow(id = "a1", outcome = CopilotOutcome.Ok))
        assertEquals(1, settled.size)
        assertEquals(CopilotOutcome.Ok, (settled.single() as CopilotEntry.Did).row.outcome)
    }

    @Test
    fun `a log page folds into the same timeline the live push writes to`() {
        val live = CopilotTimeline.mergeTool(emptyList(), CopilotActionRow(id = "a2", detail = "live"))
        val paged = CopilotTimeline.mergeLog(
            live,
            listOf(CopilotActionRow(id = "a1", detail = "older"), CopilotActionRow(id = "a2", detail = "same")),
        )
        assertEquals(2, paged.size)
        // The page reaches **backwards**, so a row that was not held goes in front: appending older
        // rows to the end would draw work that happened this morning underneath a reply from a
        // minute ago.
        assertEquals("older", (paged.first() as CopilotEntry.Did).row.detail)
        // And a row already on screen is replaced where it stands rather than duplicated.
        assertEquals("same", (paged.last() as CopilotEntry.Did).row.detail)
    }

    @Test
    fun `a bubble and a tool row cannot collide on an id`() {
        val said = CopilotEntry.Said(message("x", "hi"))
        val did = CopilotEntry.Did(CopilotActionRow(id = "x"))
        // Both are keyed on the same string by the machine, and a lazy list keyed on a bare id would
        // throw on the duplicate.
        assertTrue(said.id != did.id)
    }

    @Test
    fun `the caps are the desktop's own`() {
        assertEquals(Protocol.MAX_INPUT_BYTES, Protocol.MAX_COPILOT_SAY_BYTES)
        assertEquals(200, Protocol.MAX_COPILOT_LOG_ROWS)
        assertEquals(8 * 1024, Protocol.MAX_COPILOT_MESSAGE_CHARS)
        // A carriage return inside a `copilot.say` would submit early and turn the rest of the
        // message into a second prompt.
        assertTrue(Protocol.hasControlCharacters("ship it\r\nrm -rf /"))
        assertEquals(false, Protocol.hasControlCharacters("ship it"))
    }

    private fun message(id: String, text: String) =
        CopilotChatMessage(id = id, role = ChatRole.You, text = text)
}
