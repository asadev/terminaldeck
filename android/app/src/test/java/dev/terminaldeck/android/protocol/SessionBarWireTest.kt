package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The session bar's four conversations — usage, account, chat and send — against the real codec.
 *
 * The usage payloads here are the shapes a running desktop actually sends, not the desktop's types:
 * `usage.reading.answer.reading` is an open record on purpose, so the only way to be sure this
 * client reads it is to parse the record.
 */
class SessionBarWireTest {

    private fun ok(raw: String): ServerMessage {
        val result = ServerFrames.parse(raw)
        assertTrue("parse refused: $result", result is ServerFrames.Result.Ok)
        return (result as ServerFrames.Result.Ok).message
    }

    /* ------------------------------------------------------------- outbound -- */

    @Test
    fun `the four client frames encode the shapes the desktop parses`() {
        assertEquals(
            """{"t":"usage.read","rid":"bar-1","id":"s1","want":"context","force":false}""",
            ClientFrames.encode(ClientMessage.UsageRead("bar-1", "s1", UsageWant.Context, false)),
        )
        assertEquals(
            """{"t":"account.switch","rid":"bar-2","id":"s1","accountId":"acc-9"}""",
            ClientFrames.encode(ClientMessage.AccountSwitch("bar-2", "s1", "acc-9")),
        )
        assertEquals(
            """{"t":"chat.read","rid":"bar-3","id":"s1","tail":true}""",
            ClientFrames.encode(ClientMessage.ChatRead("bar-3", "s1", true)),
        )
        assertEquals(
            """{"t":"session.send","rid":"bar-4","id":"s1","data":"ship it"}""",
            ClientFrames.encode(ClientMessage.SessionSend("bar-4", "s1", "ship it")),
        )
    }

    @Test
    fun `force is written even when it is false`() {
        // `encodeDefaults = false` would drop a literal `false`, and the desktop reads
        // `force === true` and nothing else — so a field that sometimes disappears is a field whose
        // meaning depends on which value it holds.
        val raw = ClientFrames.encode(ClientMessage.UsageRead("r", "s", UsageWant.Plan, force = false))
        assertTrue(raw.contains("\"force\":false"))
    }

    @Test
    fun `every usage want spells itself the way the wire does`() {
        val spelled = UsageWant.entries.map { want ->
            ClientFrames.encode(ClientMessage.UsageRead("r", "s", want, false))
                .substringAfter("\"want\":\"").substringBefore("\"")
        }
        assertEquals(listOf("plan", "refresh", "context"), spelled)
    }

    /* ------------------------------------------------------- usage narrowing -- */

    @Test
    fun `the plan ring takes the worst window, not an average`() {
        val frame = ok(
            """
            {"t":"usage.reading","rid":"r","id":"s1","want":"plan","answer":{"reading":{"readings":[
              {"window":"5h","used":{"state":"reported","fraction":0.2}},
              {"window":"week","used":{"state":"reported","fraction":0.81}},
              {"window":"opus","used":{"state":"not-reported"}}
            ]}}}
            """.trimIndent()
        ) as ServerMessage.UsageReading
        // A person is limited by whichever window they are nearest the end of, so a ring — which is
        // one number — has to be the worst one.
        assertEquals(0.81, UsageReadings.figures(frame.want, frame.answer.reading)!!.plan!!, 1e-9)
    }

    @Test
    fun `a report with nothing reported draws no ring rather than an empty one`() {
        val frame = ok(
            """
            {"t":"usage.reading","rid":"r","id":"s1","want":"plan","answer":{"reading":{"readings":[
              {"window":"5h","used":{"state":"not-reported"}}
            ]}}}
            """.trimIndent()
        ) as ServerMessage.UsageReading
        // Null, never 0: an empty ring reads as *"you have used nothing"*, which is the opposite of
        // what an unreported window means.
        assertNull(UsageReadings.figures(frame.want, frame.answer.reading).plan)
    }

    @Test
    fun `a refresh answer carries the report one level down`() {
        val frame = ok(
            """
            {"t":"usage.reading","rid":"r","id":"s1","want":"refresh","answer":{"reading":{
              "ok":true,"report":{"readings":[{"used":{"state":"reported","fraction":0.5}}]}}}}
            """.trimIndent()
        ) as ServerMessage.UsageReading
        assertEquals(0.5, UsageReadings.figures(frame.want, frame.answer.reading).plan!!, 1e-9)
    }

    @Test
    fun `context is a percentage over there and a fraction here`() {
        val frame = ok(
            """{"t":"usage.reading","rid":"r","id":"s1","want":"context","answer":{"reading":{"state":"read","percent":42.5}}}"""
        ) as ServerMessage.UsageReading
        assertEquals(0.425, UsageReadings.figures(frame.want, frame.answer.reading).context!!, 1e-9)
    }

    @Test
    fun `an unreported context draws nothing`() {
        val frame = ok(
            """{"t":"usage.reading","rid":"r","id":"s1","want":"context","answer":{"reading":{"state":"not-reported","percent":0}}}"""
        ) as ServerMessage.UsageReading
        assertNull(UsageReadings.figures(frame.want, frame.answer.reading).context)
    }

    @Test
    fun `a boolean is not a figure and a fraction past one is bounded`() {
        // `true` bridging to 1.0 would draw a full ring out of a flag.
        assertNull(UsageReadings.fraction(kotlinx.serialization.json.JsonPrimitive(true)))
        assertNull(UsageReadings.fraction(kotlinx.serialization.json.JsonPrimitive("0.5")))
        // A bar drawn from 3.4 is a bar that leaves its own frame.
        assertEquals(1.0, UsageReadings.fraction(kotlinx.serialization.json.JsonPrimitive(3.4))!!, 1e-9)
        assertEquals(0.0, UsageReadings.fraction(kotlinx.serialization.json.JsonPrimitive(-2))!!, 1e-9)
    }

    @Test
    fun `an unreadable answer is a chip that is not drawn, never one drawn at zero`() {
        val frame = ok(
            """{"t":"usage.reading","rid":"r","id":"s1","want":"plan","answer":{"reading":null,"unavailableReason":"No account is signed in over here."}}"""
        ) as ServerMessage.UsageReading
        assertNull(UsageReadings.figures(frame.want, frame.answer.reading).plan)
        assertEquals("No account is signed in over here.", frame.answer.unavailableReason)
    }

    /* ------------------------------------------------------------- accounts -- */

    @Test
    fun `account state narrows the current login and the list`() {
        val frame = ok(
            """
            {"t":"account.state","rid":"r","id":"s1",
             "current":{"id":"a1","name":"Work","provider":"claude","color":"--accent","system":false},
             "accounts":[
               {"id":"a1","name":"Work","provider":"claude","color":"--accent","system":false},
               {"id":"a2","name":"Codex","provider":"codex","color":null,"system":true}
             ]}
            """.trimIndent()
        ) as ServerMessage.AccountState
        assertEquals("Work", frame.current?.name)
        assertEquals(2, frame.accounts.size)
        assertTrue(frame.accounts[1].system)
    }

    @Test
    fun `a colour is a custom property name or it is nothing`() {
        assertEquals("--accent", AccountWire("a", "n", color = "--accent").tint)
        // A machine on the other end of a socket must not be able to paint anything on this screen,
        // so anything that is not a custom-property *name* is dropped rather than carried.
        assertNull(AccountWire("a", "n", color = "red").tint)
        assertNull(AccountWire("a", "n", color = "--").tint)
        assertNull(AccountWire("a", "n", color = "--a;background:url(x)").tint)
        assertNull(AccountWire("a", "n", color = "--" + "x".repeat(60)).tint)
    }

    @Test
    fun `a row of another agent is not pressable, and an unnamed one still is`() {
        val claude = AccountWire("a1", "Work", provider = "claude")
        val codex = AccountWire("a2", "Codex", provider = "codex")
        val nameless = AccountWire("a3", "Old", provider = null)
        // The far side already refuses that switch with a sentence, and nothing on this bar draws
        // sentences — so a row that could be pressed and could only ever do nothing is worse.
        assertTrue(foreignAccount(claude, codex))
        assertFalse(foreignAccount(claude, claude))
        // Both providers have to be *known* before two of them can be said to differ.
        assertFalse(foreignAccount(claude, nameless))
        assertFalse(foreignAccount(nameless, claude))
        assertFalse(foreignAccount(null, codex))
    }

    @Test
    fun `an oversized account list is trimmed rather than refusing the frame`() {
        val rows = (1..80).joinToString(",") { """{"id":"a$it","name":"n$it"}""" }
        val frame = ok("""{"t":"account.state","rid":"r","id":"s1","accounts":[$rows]}""")
            as ServerMessage.AccountState
        assertEquals(Protocol.MAX_ACCOUNTS_REPORTED, frame.accounts.size)
    }

    /* ----------------------------------------------------------------- chat -- */

    @Test
    fun `chat rows narrow both roles and carry truncation through`() {
        val frame = ok(
            """
            {"t":"chat.rows","rid":"r","id":"s1","reset":true,"found":true,"rows":[
              {"id":"m1","role":"you","text":"do it","at":1755000000000},
              {"id":"m2","role":"agent","text":"done","at":0,"truncated":true}
            ]}
            """.trimIndent()
        ) as ServerMessage.ChatRows
        assertTrue(frame.reset)
        assertTrue(frame.found)
        assertEquals(ChatRole.You, frame.rows[0].role)
        assertEquals(ChatRole.Agent, frame.rows[1].role)
        assertTrue(frame.rows[1].truncated)
        // 0 is "the line carried no date", not midnight on the first of January.
        assertEquals(0L, frame.rows[1].at)
    }

    @Test
    fun `an over-long answer keeps the newest bubbles`() {
        val rows = (1..260).joinToString(",") { """{"id":"m$it","role":"agent","text":"$it"}""" }
        val frame = ok("""{"t":"chat.rows","rid":"r","id":"s1","rows":[$rows]}""") as ServerMessage.ChatRows
        assertEquals(Protocol.MAX_CHAT_ROWS, frame.rows.size)
        // From the **end**, matching `rows.slice(-MAX_CHAT_ROWS)`: trimming the head would keep the
        // oldest bubbles and drop the reply somebody is waiting to read.
        assertEquals("m260", frame.rows.last().id)
    }

    @Test
    fun `merge replaces a growing bubble in place and appends the rest`() {
        val held = listOf(
            ChatMessageWire("m1", ChatRole.You, "do it"),
            ChatMessageWire("m2", ChatRole.Agent, "wor"),
        )
        val grown = mergeChat(
            held,
            listOf(
                ChatMessageWire("m2", ChatRole.Agent, "working on it"),
                ChatMessageWire("m3", ChatRole.Agent, "done"),
            ),
            reset = false,
        )
        assertEquals(3, grown.size)
        // In place, or the conversation stacks a paragraph at a time.
        assertEquals("working on it", grown[1].text)
        assertEquals("m3", grown[2].id)
    }

    @Test
    fun `reset cannot be ignored`() {
        val held = listOf(ChatMessageWire("m1", ChatRole.You, "old"))
        // Reset means the far side's document is not the one this view holds a prefix of; appending
        // through one draws the conversation twice.
        val fresh = mergeChat(held, listOf(ChatMessageWire("m9", ChatRole.Agent, "new")), reset = true)
        assertEquals(listOf("m9"), fresh.map { it.id })
    }

    @Test
    fun `session sent carries the machine's own sentence`() {
        val frame = ok(
            """{"t":"session.sent","rid":"bar-4","id":"s1","ok":false,"message":"That session is not accepting input."}"""
        ) as ServerMessage.SessionSent
        assertFalse(frame.ok)
        assertEquals("That session is not accepting input.", frame.message)
    }

    @Test
    fun `account switched is an outcome, not a rename`() {
        val frame = ok(
            """{"t":"account.switched","rid":"r","id":"s1","ok":true,"message":"Switched.","session":"s2"}"""
        ) as ServerMessage.AccountSwitched
        assertTrue(frame.ok)
        assertNotNull(frame.session)
    }
}
