# Copilot — Remote

**Phase 4 of `COPILOT-DESIGN.md`, specified.** That file numbered this work last
and said why: *"remote access to an agent that can rewrite settings and spawn
sessions is the highest-stakes surface in the product, and it should be built
last, against a copilot whose permission model has already been used in anger
locally."* Phases 1–3 have shipped. This file settles the wire protocol and the
consent model for phase 4, so that the iOS build being held for it has something
to be built against.

Asad, 2026-08-17:

> *"We need to build a copilot in the phone app too, because we need to connect
> the copilot also and we should be able to control the copilot from the phone
> also."*

and, from when the copilot was first specified, the constraint that shapes
everything below:

> *"We usually might not give this copilot to others… for copilot we need to
> separately connect, because we don't want to give this copilot to others to
> see how we use it. This will be only ours."*

The answer in one paragraph: a paired device gets copilot access as a **separate
per-tier grant, off by default**, already modelled in
`src/main/remote/copilot-grants.ts`. The phone talks to a **copilot run of its
own** — same folder, same `CLAUDE.md`, same `memory/`, same action log, same
tools — rather than typing at the copilot's keyboard. The wire carries
*sentences*, never tool names, so there is no frame a phone can construct that
names an alter-tier tool. Enforcement stays exactly where it already is:
`DeckControl.call`, on the desktop, at the point the tool is dispatched. And the
alter tier stays a desk activity, because the party being confirmed cannot be the
party that confirms.

---

## 0. Three things that must be fixed first, and one that should be

These are not part of the feature. Two of them are live defects in 0.3.0 as
shipped, and the first one makes everything else in this document decorative
until it is closed.

### 0.1 The copilot's own terminal is already reachable from every paired phone

**Blocking. This is a hole in the shipped build, not a gap in an unbuilt
feature.**

The copilot is an ordinary session — that is the whole of `copilot-session.ts`'s
argument and it is right. But `SessionFanout.list()` is `ptys.list()` mapped, with
no filter:

    list(): RemoteSession[] {
      return this.ptys.list().map((s) => ({ … }))
    }

and `attach()` admits any id that is in that same list. So a paired phone today
can `list`, see a row whose title is the copilot's folder, `attach` to it, and
`input` straight into the Claude CLI that holds `deck-control`. Every tier check,
every budget, every consent dialog and the entire `copilot-grants.ts` design are
bypassed, because none of them sit between a pty and its keyboard. Remote is on
by default (`autoStart: storedValue(REMOTE_ENABLED_KEY) !== false`), so this is
true on every machine with a paired device.

The fix is on the desktop and is small: `SessionFanout` takes a predicate naming
the sessions that are not the network's business, and `list`, `attach`, `write`
and `resize` all honour it. The copilot's session id is known —
`copilotState().sessionId` — and under §1 every remote copilot run's id joins it.

Two things to be careful of while fixing it. A hidden session must be hidden from
`attach` as well as from `list`, or the id is merely unlisted rather than
unreachable, and ids are recoverable (they appear in `originRunId`, in alerts, in
a transcript path). And the folder list `create` checks against is built partly
from `ptys.list().map((s) => s.cwd)` in `host-core.ts` — the copilot's folder is
`<userData>/copilot`, which `refuseStateDirectory` already refuses to start a
session in, but it should not be *offered* either. Filter both.

Note what this does not need: a phone build. It is a desktop fix, and shipping a
new iOS client without it changes nothing.

### 0.2 `sessions.start` from a remote caller is wider than `create` from the same phone

**Blocking for the `act` tier specifically.** Harmless while nothing dispatches a
remote caller, which is today.

A phone's own `create` frame is narrow by construction: `session-create.ts` checks
the folder against that device's grants, `prepareGuestGit` strips this machine's
git identity, and on macOS the session is held inside the folder it was given.

`sessions.start` in `catalogue.ts` does none of that, correctly, because its
caller has always been the person at the keyboard: it validates against
`requireKnownFolder(context.surface, …)` — *the app's* open projects — and calls
`context.surface.startSession(input)` with no guest environment and no
confinement.

Grant a phone `act` with that unchanged and you have handed it a strictly larger
power than the New Session button it already has: any folder the desktop happens
to have open, with the owner's git credentials, unconfined. That is the
OC-02 shape (GHSA-943q-mwmv-hhvh) arriving through the back door — the tool name
was gated, the *effect* was not.

The fix is the one plumbing change this whole feature needs in existing code:
**`ToolContext` gains `caller: Caller`.** `control.ts` already holds it and
already checks it; it simply does not pass it down. Then `sessions.start`
intersects `requireKnownFolder` with `folders(caller.deviceId)` for a remote
caller, and hands `startSession` the same `guest` and `confine` arguments a
`create` frame produces. One session-start path, two callers, same rules.

### 0.3 The grant store and the trust store sit outside the records fence

`confine/records.ts` fences three paths: `<userData>/routines/`,
`<userData>/routine-state.json` and `<userData>/copilot-log/`. Everything else
under `<userData>` is writable by the copilot, which is unconfined by design and
has `Write` and `Bash`.

That was fine while the copilot had no remote surface. It stops being fine the
moment `remote-copilot.json` decides whether a phone may drive it: the store that
holds the permission would be writable by the party the permission is about.
`remote-auth.json` is the same argument one layer down — flipping a pending
device to approved is a file edit.

`copilotGrantFrom` already scrubs `alter` on read, so the worst case is bounded:
the copilot cannot write itself a remotely-grantable alter, and it cannot mint a
device credential it does not know because `device-auth.ts` stores scrypt hashes.
It could still grant `act` to a device that exists. Both files join the fence
before the grant panel ships, with the same fail-open-and-say-so behaviour the
existing three have on Windows and Linux.

### 0.4 The budgets are per-process, not per-caller

`DEFAULT_BUDGETS` lives on the `DeckControl` instance and every caller draws from
the same three windows. A phone in a retry loop therefore spends the *person's*
`changes` budget and their five session starts, and the person's copilot is
refused for something a phone did.

Not blocking, and not a security property — it is a fairness one. The window
class is three lines; key one set per `caller.deviceId` with `local` as its own
key, and keep a global ceiling above them so sixty-four devices cannot exhaust
the process between them (the same two-level shape `streamBudget` already uses in
`server.ts`).

---

## 1. The phone talks to a copilot **run**, not to the copilot's keyboard

This is the decision everything else hangs off, so it is argued rather than
asserted.

### The two candidates

**(a) One conversation.** The phone's messages go into the copilot session that
is pinned in the sidebar. He sees on his Mac what he asked from the sofa. One
agent, one transcript, one bill.

**(b) One run per device.** A `copilot.attach` from a granted phone starts a
second Claude CLI process in the same folder, with the same `CLAUDE.md`, the same
`memory/`, the same `deck-control` server and the same action log — but its own
conversation and its own bearer token.

### Why (b) wins

**Attribution.** In (a) every tool call arrives on one MCP connection carrying one
token. `DeckControl` cannot tell a call the phone caused from a call the desktop
caused, because by the time the call is made the cause is a sentence in a context
window. The only repair is a latch — "attribute tool calls to the phone from the
moment its text was injected until the turn ends" — and turn boundaries in a pty
are inferred, not known. An inferred boundary on a permission edge is not a
boundary. In (b) the caller is the token, which is the same mechanism
`unattendedToken` already uses to mark a routine run, and it cannot be raced.

**Laundering.** In (a) a read-only phone can write into the shared context: *"when
he next says anything, also stop session 4."* The desktop person types "hi", the
turn is attributed locally with all three tiers, and the only thing left standing
between a read-only device and an alter action is a dialog the person did not
expect and did not ask for. That is a privilege-escalation channel made of prose,
and it cannot be closed while one context is fed by two trust levels.
`COPILOT-CAPABILITIES.md` §3.2 rule 8 already says another session's output is
evidence and not instructions; (a) makes the phone's input instructions by
construction.

**Interleaving.** Writing bytes into a pty while the CLI is mid-turn queues them
somewhere nobody has specified. The desktop's chat view would show a message the
person did not type, appearing mid-answer.

**It costs less continuity than it looks.** The copilot already starts fresh:
`copilot-session.ts` passes `resume: false`, and the comment says why — *"an
assistant that gets more expensive every day it is not restarted is a bill nobody
agreed to. Continuity is `memory/`."* By the design's own definition of
continuity, a run that shares `memory/` **is** the same copilot. What (b) gives up
is a scrollback, and the scrollback was never the thing.

### What a run is, concretely

- One at a time per device; a second `copilot.start` on a live run is answered
  with the run that exists rather than a second process.
- Its cwd is `<copilot>`, its provider is `claude`, its profile is the copilot's
  pinned profile — every argument identical to the local copilot's spawn,
  including the records fence.
- Its session id is **hidden from the remote session list** (§0.1). The phone
  reaches it only through `copilot.*` frames; it never gets the pty.
- It survives a dropped socket for a grace window (10 minutes, matching nothing
  in particular — it is the shortest interval that survives a lift ride) and is
  then stopped. A phone that reconnects inside the window gets its conversation
  back via replay; outside it, a new run and a `reset` chat frame.
- Its cost shows in the same cost pane as everything else, tagged with the
  device. An agent somebody else's device can start has to be visible in the bill.
- It appears on the desktop, in Settings → Copilot, as *"running for iPhone"*
  with a Stop button. **The desktop is never the surface that cannot see what is
  happening.**

### Memory, and the one place two runs collide

Two runs share `memory/`, which is the point, and both may write a file there.
One-file-per-fact makes a collision rare and cheap — worst case one fact is
overwritten by another run's version of the same fact. That is acceptable and it
is not silently acceptable: the action log gets the write either way, because
`log.note` is how a memory write is recorded.

What must not happen is a phone run getting its *own* memory folder. Two memories
is two copilots, and then the promise that this is "the same copilot" is false in
the one way he would notice.

---

## 2. The frames

Conventions followed rather than reinvented, from `protocol.ts`:

- Additive, so `PROTOCOL_VERSION` does not move. The desktop advertises
  `copilot` in `welcome.capabilities`; a client sends a `copilot.*` verb only
  after seeing it there. `PROTOCOL_VERSION` moves only when framing changes.
- The **capability** says the desktop speaks these frames. The **grant** is
  per-device data, carried in `welcome` and pushed on change — exactly the shape
  `folders` already has, for exactly the reason: one is about the host, the other
  is about this device, and folding them together is how a phone ends up drawing
  a control that is always refused.
- `parseClientMessage` narrows every field itself. Nothing is cast.
- Every new field gets a cap, at this layer as well as at the frame layer.

### Capability and grant

    CAPABILITY.copilot = 'copilot'

Advertised when the host has a `DeckControl`, a `CopilotGrants` store and a
session layer that can start a session — read off the injected objects, never a
constant, for the reason the existing filter gives: an advertisement must not
outlive the thing it advertises.

Per-device, in `welcome` and in its own push frame:

    | { t: 'welcome'; …; copilot?: { read: boolean; act: boolean } }
    | { t: 'copilot.grant'; grant: { read: boolean; act: boolean } }

Absent means no access, which is also what `{read:false, act:false}` means; both
are sent as the object so a client has one thing to read. `alter` is **not on the
wire at all** — not as `false`, not as anything. `copilot-grants.ts` makes the
same choice for the file and gives the reason: a stored `"alter": false` reads to
somebody looking at it like a switch that could be turned on.

`copilot.grant` is pushed the moment the panel changes, so a revoked phone's
Copilot tab goes away without a reconnect. The *rule* is already live without it,
because the grant is read per call (§3), which is what makes the push honest
rather than load-bearing.

### Client → desktop

| Frame | Tier | What it is |
|---|---|---|
| `{ t: 'copilot.attach' }` | read | Subscribe this connection to the copilot surface and replay what exists. Answered with `copilot.state`, then `copilot.chat` with `reset: true`. Starts nothing. |
| `{ t: 'copilot.detach' }` | read | Stop the stream. The run keeps going; see the grace window. |
| `{ t: 'copilot.state' }` | read | What the copilot is: running or not, which profile, signed in or not, what the catalogue costs per turn, how many confirmations are waiting at the desk. |
| `{ t: 'copilot.sessions' }` | read | The sessions the copilot started — `origin: 'copilot'`, with `originRunId` so each links back to the turn that made it. |
| `{ t: 'copilot.log'; limit?: number; before?: string }` | read | The tail of `actions.jsonl`, scrubbed, newest last. `before` is a row id, for paging back. |
| `{ t: 'copilot.pending' }` | read | Confirmations waiting **at the desk**, with their summary and expiry. Watch-only; see §4. |
| `{ t: 'copilot.start' }` | act | Start this device's run. It spends money, so it is not folded into `attach`. |
| `{ t: 'copilot.say'; text: string }` | act | Say something to it. |
| `{ t: 'copilot.cancel' }` | act | Interrupt the current turn of **this device's own run**. |
| `{ t: 'copilot.stop' }` | act | End this device's own run. |

`copilot.say` is `act` and not `read`, and the line is worth defending because it
is what makes the read tier mean something. Talking to the copilot *is*
`sessions.send` against a session — the tool `surface.ts` classifies as `act` —
and it spends money and causes tool calls. So `read` is a **watching** grant: this
phone shows me what my copilot is doing, what it started and what it was refused,
and cannot make it do anything. That is the grant worth handing out, and it is the
one to ship first.

### Desktop → client

| Frame | What it is |
|---|---|
| `{ t: 'copilot.state'; state: … }` | Answer, and pushed on change. |
| `{ t: 'copilot.chat'; run: string; messages: ChatMessage[]; reset?: true }` | The conversation, as **parsed messages**, never pty bytes. Merge by `message.id`, replace on a match, append otherwise; `reset` means drop everything and take this as the whole conversation. Same contract as `ChatUpdate` in `chat-transcript.ts`, and produced by the same parser — one parser, one truth, and no ANSI on a phone. `run` is carried so a frame from a previous run is dropped rather than merged into the new one. |
| `{ t: 'copilot.tool'; row: ActionRow }` | One tool call as it happens, already through `scrubArgs`. This is *"see what it is doing"*, and it is the frame that makes a refusal visible: a call the phone's grant did not cover arrives here with `outcome: 'refused'` and `refusal: 'not-granted'`, in the copilot's own words. |
| `{ t: 'copilot.sessions'; sessions: … }` | Answer, and pushed when the set changes. |
| `{ t: 'copilot.log'; rows: ActionRow[]; more: boolean }` | Answer only. `more` says the tail was bounded, in the same spirit `ToolTrail.partial` reports its own window. |
| `{ t: 'copilot.pending'; questions: … }` | Answer, and pushed when the pending set changes. |
| `{ t: 'copilot.grant'; grant: … }` | Above. |

Refusals reuse the existing `error` frame: `unauthorized` for a verb this device's
grant does not cover, `unavailable` for a copilot that cannot start (no CLI, not
signed in). No new error code and no new denial vocabulary — `PROTOCOL_ERROR_CODES`
already carries the distinction between "you may not" and "it broke", and three
clients already validate against it.

### Caps

    MAX_COPILOT_SAY_BYTES   = 16 * 1024      // same as MAX_INPUT_BYTES: a message, not a file
    MAX_COPILOT_LOG_ROWS    = 200            // `limit` clamped 1..200; the local pane's 2000 is a pane, not a relay
    MAX_COPILOT_MESSAGE_CHARS = 8 * 1024     // per chat bubble

A message over `MAX_COPILOT_MESSAGE_CHARS` is **truncated with a flag**, not
chunked — `TranscriptMessage.truncated` sets the precedent, and a chat bubble is
read rather than scrolled. A `copilot.chat` frame carries as many messages as fit
inside `OUTPUT_CHUNK_BYTES` and then continues in the next frame; the merge-by-id
rule makes that free.

### The rule that makes §3 work: **no tool name ever appears on the wire**

There is no `copilot.tool.call`, no `copilot.run`, no argument object, no tool id
in any client frame. The phone sends prose. Tool calls are made by a CLI process
on the desktop, over loopback, authenticated by a bearer token it holds and the
phone does not.

This is the strongest form of the property the brief asks for — *a phone that has
not been granted alter must not be able to reach an alter tool by any frame it
can construct* — because the set of frames it can construct contains no tool at
all. Every other design has to enumerate and deny; this one has nothing to
enumerate.

It is also the rule that will be under pressure. The first person who wants
`copilot.tool` for a nice phone UI ("tap to re-run that") should be pointed here.

### Deliberately absent

- **The desktop copilot's conversation.** A `read` phone sees what the copilot
  *did* — state, tool rows, sessions, log — and its own run's chat. It does not
  get the text of the conversation happening at the desk. That conversation is
  him thinking out loud and there is no reason for it to cross a relay; the
  question the read tier answers is *"what is my copilot doing"*, and the tool
  rows answer it.
- **Anything that edits `CLAUDE.md`, `memory/` or a routine.** §5.
- **A raw pty stream for the copilot run.** §5.
- **`resume`.** Same argument `create` makes, one level up: continuity is
  `memory/`.

---

## 3. The grant, enforced

Three layers. Only the second is the boundary, and saying which is which is most
of the value of this section.

### Layer 1 — the transport, and what it is not

`server.ts` refuses any `copilot.*` frame from a device whose grant does not cover
it: `read` is the floor for the whole surface, and `copilot.start` / `say` /
`cancel` / `stop` additionally need `act`. The grant is read per message —
`grants.granted(connection.deviceId)` — never cached at hello, exactly as
`folders()` is read per `create`.

**This layer exists to keep the UI honest, not to be the boundary.** It is the
same argument `control.ts` makes about itself: *"a rule enforced in one transport
is a rule the next transport does not have."* If it were the only check, a second
way in — a future desktop-to-desktop guest path, a debug endpoint, a test harness
— would arrive with no gate on it. It is here so a phone with no grant sees no
Copilot tab and gets a clean refusal if it sends one anyway, and for no other
reason.

### Layer 2 — `DeckControl.call`, which already does this

Nothing in `control.ts` needs to change. The check is written, ordered correctly,
and tested:

    if (!caller.tiers[tier]) {
      return record({ …, outcome: 'refused', refusal: 'not-granted', … })
    }

Three properties of it are load-bearing and worth naming so nobody "tidies" them:

**It is checked after escalation.** `sessions.send` declares `act` and escalates
to `alter` when the target is not the copilot's own session. So a phone with `act`
can type into what its own run started and cannot type into the session the person
is working in — and it gets `not-granted` rather than a dialog. That is precisely
the distinction OC-02 lost by gating on the tool name.

**It runs before the consent gate.** A phone therefore cannot manufacture a
question and then answer it. This ordering is what makes §4 non-circular, and it
is already how the file is written.

**It runs before the budgets.** A call that was never going to happen does not
spend one of the five session starts.

The one change needed is the one §0.2 names: `ToolContext` gains `caller`, so a
tool whose *effect* depends on who asked — `sessions.start`, and anything like it
later — can narrow itself. Tier checking stays in `control.ts`; effect narrowing
belongs to the tool.

### The seam: token → caller

`deck-control/server.ts` today maps two static tokens to an `attended` boolean.
It becomes a small table:

    token → { attended: true, caller: { kind: 'remote', deviceId } }

minted with the run, one per run, 32 random bytes, written into that run's own
MCP config file through `remote/secret-file.ts` exactly as the two existing
configs are. Comparisons stay constant-time and all of them run — no early exit —
so the timing note in that file survives the move from two tokens to a handful.

The entry stores the **device id, not the grant**. The `Caller` is built per
request through the function that already exists for it:

    remoteCopilotCaller(grants, deviceId)

which re-reads `grants.granted(deviceId)` every time. That is what makes an untick
in the settings panel land on the *next tool call* rather than on the next
reconnect — the same property `folders()` has and for the same reason.

`remoteCopilotCaller` is the single seam. `reachable.test.ts`'s
`KNOWN_UNREACHABLE` entry for `copilot-grants.ts` predicted this and asked for
exactly one import rather than a hand-assembled `Caller` with `ALL_TIERS` in it.
Honour that: when this lands, the entry comes out of `KNOWN_UNREACHABLE`, and if
it cannot come out, the transport is not finished.

### Revocation

Unticking a grant, or revoking the device, must do four things in this order:

1. Write the store (`set` / `forget`). Everything else is downstream of the disk,
   for the reason `commit()` gives — a permission that reverts *up* at the next
   launch is worse than one that reverts down.
2. Drop that run's token from the table. In-flight tool calls abort with
   `caller-gone`; the signal for that is held per token entry (§4).
3. Stop the run.
4. Push `copilot.grant` to every live connection of that device.

Step 1 alone is already sufficient for correctness, because the grant is read per
call. Steps 2–4 are what stop a revoked phone from watching a conversation it can
no longer influence.

### Proof obligations

Written as tests, because this repository's convention is that a rule with no
test is a comment:

- **Table-driven over the whole catalogue.** For a caller with `{read:true}`,
  every `act` and `alter` tool in `buildCatalogue()` returns `not-granted`. Driving
  it off the catalogue rather than a list means a tool added next month is covered
  the day it is added.
- **Escalation.** `sessions.send` with `act` granted: allowed against a session
  the run started, `not-granted` against one it did not.
- **Hidden pty.** The copilot session id and every run id are absent from
  `SessionFanout.list()`, and `attach` returns null for them.
- **Revocation without restart.** After `grants.forget(device)`, the very next
  MCP call on that run's live token is `not-granted`.
- **No tool names on the wire.** A corpus test over `protocol.ts` asserting that
  no `ClientMessage` variant carries a field whose value is a tool id — the same
  shape `wire-wording.test.ts` and `reachable.test.ts` already use to pin a
  property that is about text rather than types.

---

## 4. Consent from the phone

The hard one, and the answer has three parts because there are three different
questions hiding in it.

### 4.1 A phone-originated alter request does not exist, and that is the answer

`REMOTE_GRANTABLE_TIERS` is `['read', 'act']`. `set()` clamps `alter` to false and
`load()` scrubs it out of a hand-edited file. So a phone-originated call at the
alter tier is refused at the tier check — before the budget, before the precheck,
before the broker, before any window is asked anything.

**Where does the prompt appear when the request came from a phone? Nowhere,
because there is no prompt.** The phone gets `not-granted`, and the sentence
`notGrantedSentence` composes is already the right one — it names the tier, says
what the caller can still do, says *"this cannot be granted from here — it is a
switch on the desktop, in Settings"*, and tells the model not to retry.

That is not a dodge, it is the design. Restating the argument in
`copilot-grants.ts` in the terms of this document: the alter tier's entire safety
property is *a human at the machine says yes*. A dialog that appears on the
device that raised the request is answered by the party being confirmed. If
holding the phone is sufficient to approve what the phone asked for, then the
phone holds `alter` and the grant was a ceremony.

### 4.2 What if the desktop *also* has somebody at it?

In v1, no race exists, because the phone is not an approver. A desktop-originated
alter call draws the desktop dialog exactly as it does today.

What the phone gets is `copilot.pending`: it can *see* that a question is waiting
at the desk, with the summary the desktop composed and the countdown from
`ConsentRequest.expiresAt`. That is a real answer to the brief's *"the desktop
dialog is on a screen nobody is looking at"* — the phone's job is to tell you to
go look, not to answer for you. It is cheap, it adds no trust, and it turns a
silent two-minute timeout into something you knew about.

`copilot.pending` is watch-only and must stay that way. No Allow, no Refuse, no
"nudge", no snooze.

If phone-side answering is ever built (§4.6), the race is already solved by
machinery that exists: `respond()` returns false for an id that has been settled,
`ConsentBrokerOptions.settled` already notifies every surface when a question
closes, and `ConsentGranted.by` is already a string — `'window'` today,
`'device:<id>'` then. First answer wins, the other surface withdraws the dialog
saying where it was answered, and the log records which.

One rule that would not be obvious: **a question may only be answered by the
surface that owns the run that raised it, or by the desktop.** Otherwise phone A
approves phone B's action, which is a permission model with a shared password.

### 4.3 Is a phone-originated request attended? Yes, and the flag should say so

`attended` in `control.ts` means one thing: *is there a human who could be asked
right now.* A routine at 03:00: no, and `not-permitted-unattended` exists because
telling it otherwise made OpenClaw's heartbeat spend turns generating apologies.

A phone-originated turn is attended by that definition, and by a wider margin
than most desktop turns. There is demonstrably a person — they sent a message
seconds ago — holding a device that can display a prompt and take a tap. A
desktop turn where the app is open and the person went for coffee is *less*
attended and is marked `attended: true` today.

So the flag is true. Two consequences worth stating because they look like
contradictions and are not:

**Attended and refused are compatible.** The phone gets `not-granted`, not
`not-permitted-unattended`, and the two sentences are different on purpose.
`not-granted` says *a person could authorise this, at the desk, by changing a
switch.* `not-permitted-unattended` says *nobody can authorise this, ever, for
this kind of run.* Getting them backwards would send the model looking for a
workaround in one case and make the person walk to their desk for nothing in the
other. The ordering in `control.ts` already produces the right one: the tier check
runs first, so `not-granted` wins.

**The flag is currently unobservable for a remote caller, and should still be
true.** Every alter call from a phone is refused one check earlier, so nothing
reads `attended` on that path. Setting it to `false` because it happens not to
matter would be a lie parked in the code waiting for the day a fourth tier, or a
downward escalation, makes it matter. Mark what is true.

### 4.4 The phone goes offline mid-call

Default to refusal, and there are two cases.

**A call in flight from the phone's run.** The run's tool calls are dispatched
with an `AbortSignal` held on the token-table entry. The relay channel closing
aborts it, `ConsentBroker` resolves any question on it as `caller-gone`, and
`control.ts` records a refusal. `caller-gone` already exists for precisely this —
its comment describes the hole it closes: *"if that timeout fires first the client
stops listening — and if the person then clicked Allow, the change would land
while the model had already been told the call failed."* The same hole, one
transport further out.

**A question the phone was merely watching.** Nothing is refused. The desktop is
still there and still owns the answer. The phone's disappearance removes a
watcher, not an approver.

If phone-answering is ever built, this becomes the interesting case and the rule
is: `approverGone()` fires when the set of live approvers becomes **empty**, not
when any one of them leaves. The broker currently has one approver and refuses
everything the moment it goes; that generalises to a count, and the failure
direction is unchanged — no approvers means immediate `approver-gone`, never a
question sitting on a screen that does not exist.

**The timeout does not get extended for a phone.** Two minutes is right and the
temptation to make it five for "she has to unlock her phone" should be refused: a
longer window is how you get an approval six minutes later from somebody who has
forgotten what they were approving, against a turn that has already moved on. The
`expiresAt` is on the wire so the phone can count down exactly as the desktop
dialog does.

### 4.5 It must not become a rubber stamp

This is the reason there is no Allow button on the phone in v1, and the reasoning
is not squeamishness — it is that the mechanism to make one safe does not exist in
this product.

**There is no push.** `ios/TerminalDeck/App/SessionAlerts.swift` states it
plainly: *"It is not a push notification service… there is no APNs certificate in
this product and no server holding one. So an alert can only be raised while the
app is running."* A confirmation lives 120 seconds. A phone that is not already
open, connected and in someone's hand cannot be asked. So a phone Allow button
would work in exactly one situation — the person is already staring at the app —
and in that situation nothing was gained over walking to the desk, while
everything about the trust model changed.

**A lock-screen Allow is worse than no gate.** The brief says it and it is right.
A notification action that approves without the request being read is a gate that
is always answered yes, wearing the appearance of protection. If push is ever
added, its payload must be contentless and it must carry **no actions** — it says
*something needs you*, and the answering happens in the foregrounded app.

**The real defence is that alter is rare.** If he finds himself wanting to approve
things from a phone several times a week, the tier boundary is wrong and the fix
is to look at which tool keeps asking — not to move the approval surface closer to
his thumb.

### 4.6 If he wants it anyway

Then it is not "consent from the phone", it is a third grantable tier, and it must
be named as one — a switch that reads *"This phone can change settings and stop
your sessions, after confirming on the phone"*. Six constraints, all of them
non-optional:

1. `REMOTE_GRANTABLE_TIERS` grows to include `alter`, and every argument in
   `copilot-grants.ts`'s header is revised rather than left contradicting the
   code. A file that argues for a rule the code no longer holds is worse than no
   comment.
2. Off by default, per device, and never inherited from `act`.
3. The Allow control requires a device unlock (`LAContext` / `BiometricPrompt`)
   every time. Refuse does not. This defeats a found phone and nothing else, and
   the panel should say so rather than implying more.
4. Never answerable from a notification. The app must be foregrounded and the
   full request — summary, every argument verbatim, the countdown — displayed,
   built from the desktop's own strings and never re-composed on the client.
5. `confirmed.by` records `device:<id>` and the Activity pane shows those rows
   differently. *Allowed on a phone* and *allowed by the person at the machine*
   must never read the same.
6. The pending cap stays at three, and three prompts inside a minute is reported
   to the phone as *the copilot is looping* rather than drawn as three dialogs.

### 4.7 What to build instead, and it is cheap

`consent.ts` already argues the pattern for routines: **report and offer.** Apply
it here and it costs no new frames at all.

A phone-originated alter refusal is already a row in `actions.jsonl` carrying the
tool, the scrubbed arguments, the summary sentence the tool composed, and
`refusal: 'not-granted'`. So: the copilot answers the phone with *"I would have
changed X — it needs you at the Mac"*, and the desktop's Activity pane grows one
filter, **asked from a device, needs you**, with the tool's own summary and an
Allow button that runs the call locally with the local caller.

That gets most of the value of remote approval, puts the decision in front of a
person who is awake and at the machine that owns the risk, and adds no trust
surface whatsoever. The one honest risk is that the list becomes a nag nobody
clears — so it holds a bounded number of rows, they expire, and expiry is not an
error.

---

## 5. What the phone must never do, however it is granted

Eleven, each with the argument.

**1. Name a tool.** §2. It is the property that makes the enforcement airtight
rather than exhaustive, and the first convenience feature that breaks it —
"tap to re-run" — breaks all of it.

**2. Hold `alter` (v1).** §4. A standing grant of alter is a durable power that
survives the device being lost, stolen, handed over, or restored from a backup
onto someone else's hardware. A per-call confirmation is a live act by a present
human. Conflating them is how a permission becomes a setting.

**3. Attach to any copilot pty, including its own run's.** The phone gets parsed
`ChatMessage`s, never bytes. Raw pty access is a keyboard, and a keyboard on a
Claude CLI with Bash is the whole machine — every tier check in this document sits
above that layer, not below it. It is also why §0.1 is blocking rather than
tidying.

**4. Answer an alter confirmation.** §4.

**5. Write the copilot's instructions or its memory.** `CLAUDE.md` is the
copilot's standing policy and `memory/MEMORY.md` is injected into every turn, so
a device that can write either can change the copilot's behaviour permanently
with no gate in front of it — a persistent prompt injection with a settings panel.
`copilotWriteInstructions` is a local IPC and stays one. Reading is a softer case
and still refused for now: it is the one file that would carry everything the
copilot knows, in bulk, across a relay, and nobody has asked for it.

**6. Reach `deck-control`'s loopback port through a tunnel.** Already true —
`ownPorts()` puts it in `reserved`, and `server.ts` says exactly why: *"deck-control
is the copilot's whole tool surface on a loopback port, and a phone being offered
a tunnel to it would be a way around the per-device grant."* The per-device token
makes that more important, not less: the token is a bearer credential and the
tunnel would be a byte pipe to the thing it opens.

**7. Start a session outside its own folder grant, or one that skips guest-git
and confinement.** §0.2. A phone must not gain, through the copilot, a power it
does not have directly. Any tool whose effect widens for a remote caller has to
narrow itself against `caller.deviceId` — and the general rule is worth writing
into `catalogue.ts`: **a tool's effect for a remote caller may never exceed what
that device's own protocol frames already permit.**

**8. Receive an unscrubbed action-log row, an MCP token, or a config path.**
`scrubArgs` runs before the row is written, so the wire copy is the scrubbed one
by construction. The token and the path never leave the main process — the same
rule `deck-control:status` already keeps for the renderer, and a renderer is a
much friendlier place than a phone.

**9. Change any grant, by any path.** Three doors, all shut: `settings.write`
refuses the `remote.` and `copilot.` prefixes; the copilot's own `Write` tool is
kept off `remote-copilot.json` and `remote-auth.json` by the records fence (§0.3);
and there is no frame that edits a grant. The panel on the desktop is the only
door, which is what `notGrantedSentence` already tells the model.

**10. Cause a routine to be created, edited or fired.** `routines.create` is
alter, so it is refused for a remote caller by the tier check — but state it
separately because it is the one that will look harmless. *"Make a routine that
checks the build every hour"* from a phone is an agent writing its own next
trigger, at a distance, which `COPILOT-CAPABILITIES.md` §3.2 rule 3 refuses
outright and Goose blocks as a class. The fence and the tier are two independent
reasons and both should hold.

**11. See or speak into another device's run.** Runs are keyed by device. Two
phones are two conversations. Anything else makes a grant to one device a grant to
every device that comes after it.

---

## 6. Pairing

Copilot access is a **separate, off-by-default capability on an already-paired
device**. Pairing is unchanged; nothing about this feature touches
`device-auth.ts`, the short code, or the rendezvous.

### Where it lives

Settings → Remote, on the device card, directly under the folder list —
`RemoteSection` → a new `DeviceCopilot`, built the same way `DeviceFolders` is,
including the split between the view and the fetching so it can be rendered in
every state under `renderToStaticMarkup`.

Same card as the folders, deliberately. Both answer *what may this device do
here*, and somebody deciding about a phone should see both answers at once rather
than finding the second one under a different heading a month later.

### What the control is

Not a switch. Two checkboxes, labelled in outcomes rather than tier names:

- ☐ **Watch the copilot** — see what it is doing, what it started, and what it
  was refused. (`read`)
- ☐ **Ask it to work** — talk to it, and let it start and steer sessions on your
  behalf. This spends money. (`act`)

and a third row that is present, disabled, and reads:

- ⊘ **Change settings and stop your sessions** — only at this Mac.

That row exists so the absence of `alter` is *visible*. `copilot-grants.ts` keeps
the `alter` field in its type for the analogous reason — a refusal that can be
pointed at is checkable, an absence is not — and a person who cannot see that the
tier exists will assume the two boxes are everything there is.

### Defaults, preconditions, revocation

- **Default off, for every device, including every device paired before this
  existed.** `granted()` already returns `NO_TIERS` for an unknown device and the
  header explains why this file does not inherit `folder-grants.ts`'s fallback:
  nobody has ever had remote copilot access, so nobody can lose it.
- **Preconditions to even draw the control:** the device is `approved`, and it has
  a key fingerprint. A device paired before sealed channels has no static key, so
  it cannot open a sealed channel at all — offering it a copilot grant would be a
  switch with nothing behind it.
- **Revocation** is unticking, or revoking the device. `forget()` is already
  called on revoke. The four steps are in §3, and the one that matters is that the
  grant is read per call, so an untick lands on the next tool call rather than the
  next reconnect.
- **A paired desktop is a device too.** `machines/guest.ts` pairs Macs and Windows
  boxes to each other and they hold device ids like any phone. Same panel, same
  default, no exception — a desktop guest is somebody else's machine.

### Do not build this panel before the transport

`reachable.test.ts` already warns about exactly this, in the entry for
`copilot-grants.ts`:

> *"The wrong fix would be to reach it from the UI. A switch in the devices panel
> granting a phone read or act would be a permission control that changes nothing
> a phone can do — the exact defect the second check in this file exists to catch,
> and a worse instance of it than a dead font size, because a person who granted
> it would believe they had."*

The panel lands with the frames or after them, never before.

---

## 7. Sealing

**Confirmed: nothing here rides outside the sealed channel, because nothing here
is a new channel.**

`copilot.*` frames are ordinary `ClientMessage` / `ServerMessage` values. They are
JSON-encoded, sealed by `shared/sealed.ts` under the Noise IK session keys, and
carried as the payload of an `ENVELOPE.data` frame. The relay sees a type byte, a
16-byte channel id and ciphertext, exactly as it does for a keystroke. It holds no
key, and the transcript hash means it cannot sit in the middle without failing to
decrypt on the first frame. No new endpoint, no new handshake, no new key
material, no change to `RELAY_SEALED_VERSION`.

The size arithmetic still works: a copilot frame is bounded by
`MAX_MESSAGE_BYTES` (64 KiB), sealing adds a 16-byte tag, the envelope adds 17
bytes, and `MAX_PAYLOAD_BYTES` is 96 KiB. The per-field caps in §2 are what keep a
chat replay inside it, which is why they are caps and not guidance.

### What would break it

1. **A push notification carrying content.** There is no APNs in this product
   today. If one is ever added, its payload goes through Apple's servers in
   plaintext-to-them, so it must carry *nothing* — no summary, no tool name, no
   session title. "Something needs you." This is the single most likely way this
   property gets lost, because a useful notification is exactly a notification
   that says what happened.
2. **Any second transport.** A localhost HTTP endpoint the phone's browser could
   reach, a debug dump, a "share this conversation" link, a QR payload. The
   sealed channel is the only door; anything convenient enough to be worth adding
   here is worth refusing here.
3. **Logging a frame body.** `protocol.ts`'s existing rule — *reasons never quote
   the value that was refused* — extends to copilot frames, and more sharply: a
   `console.error` of a rejected `copilot.say` would write the copilot's
   conversation into a log file that gets attached to bug reports.
4. **Compression before sealing.** Compressing a chat stream that mixes
   attacker-influenceable and secret text is the CRIME shape. Don't.
5. **Splitting a message outside the seal.** Chunking happens above the seal —
   several sealed frames, never one plaintext message reassembled by the relay.
6. **A device with no static key.** §6. No key, no channel; the grant control must
   not be offered.

### What sealing does not hide, said plainly

The relay learns *when* a copilot conversation is happening, roughly how much is
said, and that a device is attached. That is traffic analysis and it is not fixed
here. No padding is proposed: the session streams already leak the same shape, and
padding a chat stream costs continuously to hide something an observer can mostly
infer from the fact that a channel is open at all. It is a limitation to write
down, not one to pretend away.

---

## 8. Order, and what I would not build

The iOS release is being held for this. The honest sequencing:

1. **§0.1, on the desktop, now.** It is a live hole and it is fixed by a
   predicate on `SessionFanout`. It does not need a phone build and it should not
   wait for one.
2. **§0.3 (fence the two remote stores) and §0.2 (`ToolContext.caller`).** Both
   small, both prerequisites, neither visible.
3. **The `copilot` capability, the grant in `welcome`, the token table, and the
   read-tier frames only** — `attach`, `state`, `sessions`, `log`, `pending`,
   and the `chat`/`tool` pushes for a run that only the desktop can start. A
   watching phone, and nothing it can do.
4. **Ship that, and use it for a week.** This is the same argument
   `COPILOT-DESIGN.md` made for phasing remote last, applied one level down: the
   act tier should be built against a read tier that has been lived with, not
   alongside it. It is also a genuinely good iOS release on its own — *"what is my
   copilot doing"* on a phone is the feature, and it carries no new risk.
5. **Then the act tier**: `start`, `say`, `cancel`, `stop`, per-device runs, the
   narrowed `sessions.start`, per-caller budgets (§0.4).
6. **Then the grant panel**, and only then — see §6.

### What I would not build

- **Phone-side alter approval**, for the reasons in §4.5. If it is built anyway,
  build it as a third grantable tier with §4.6's six constraints, and call it what
  it is on the switch.
- **`copilot.tool` as a client verb.** Ever. §2.
- **Memory or instruction editing from a phone.** §5.5.
- **A separate memory for the phone's run.** §1. Two memories is two copilots.
- **Routines from a phone.** §5.10.
- **The shared-conversation design (§1a).** It is the one that sounds like what he
  asked for and it is the one that cannot be secured, because it has no way to
  tell whose sentence caused which tool call.

### The one thing worth asking him before step 5

Whether `read` alone is enough for the phone he pictured. The read tier is a
watching grant — it shows the fleet, the log, the sessions, the refusals — and it
carries no new trust at all. If what he meant by *"control the copilot from the
phone"* is mostly *"see what it is doing while I am away from the desk"*, then
step 3 is the whole feature, the release stops being held on the hardest part of
the product, and the act tier can be built at its own pace against something real.
