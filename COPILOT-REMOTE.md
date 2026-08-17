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

The answer in one paragraph: a paired device gets copilot access through a
**separate connection** — its own six-digit code minted at the desktop, its own
credential, its own record in `src/main/remote/copilot-link.ts` — off by default,
and pairing a device for terminals grants none of it. The device talks to a
**copilot run of its own** — same folder, same `CLAUDE.md`, same `memory/`, same
action log, same tools — rather than typing at the copilot's keyboard. The wire
carries *sentences*, never tool names, so there is no frame a device can
construct that names a tool at all. Enforcement stays exactly where it already
is: `DeckControl.call`, on the desktop, at the point the tool is dispatched. And
a connected device may hold all three tiers, including `alter`, and answer its
own run's confirmations — because the second factor behind that tier is the
separate authorisation, not the geography of the desk.

---

## REVISED, 2026-08-17 — read this before §4

Asad, having read the argument in §4 that a phone must never answer a
confirmation:

> *"Phones will have full control over copilot, same as the actual machine app.
> But connecting copilot will be a separate connection than the sessions."*

**What this file said, and why it said it.** §4.1 and §4.5 argued at length that
the `alter` tier could not be granted to a device:

> *The alter tier's entire safety property is a human at the machine says yes. A
> dialog that appears on the device that raised the request is answered by the
> party being confirmed. If holding the phone is sufficient to approve what the
> phone asked for, then the phone holds `alter` and the grant was a ceremony.*

That argument is good and it is preserved verbatim, in this file and in
`copilot-link.ts`, because the next person to read it needs to find out why it
was superseded rather than wonder whether it was forgotten.

**Why it does not survive his answer.** The argument assumed the second factor
behind `alter` was *geography* — that being at the desk is what made a yes
meaningful. It is not, and it never was: somebody who walks away from an unlocked
Mac has taken their geography with them, and the desktop dialog would still be
answerable by whoever wandered past. What actually made it meaningful is that
**reaching the dialog required an authorisation the requesting party did not
already hold.**

So the factor moves rather than disappears. Copilot access is no longer a tick
box beside an already-paired device; it is a **separate act of authorisation**,
performed at this machine, producing a credential that has nothing to do with the
one that opens a session channel. A device paired to run ten terminals has no
copilot reach whatsoever — not a tab, not a frame, not a refusal whose shape it
could measure — until somebody mints a connect code for it and it is redeemed.
*Have deliberately authorised this specific device for the copilot* is a real
boundary, it is checkable, and it is the one thing the device cannot grant
itself.

**What changed, concretely:**

| Was | Is | Where |
|---|---|---|
| A per-device grant riding the session channel | A separate connection: own code, own credential, own record, own revoke | `remote/copilot-link.ts`, §6 |
| `REMOTE_GRANTABLE_TIERS = ['read','act']`, `set()` clamps `alter`, `load()` scrubs it | All three tiers grantable; the clamp and the scrub are gone | `remote/copilot-link.ts` |
| `copilot.pending` watch-only, no Allow, no Refuse | `copilot.ask` / `copilot.answer` / `copilot.settled`; first answer wins | §4, `protocol.ts` |
| Nothing distinguishes a grant from a connection in the panel | Connect / Disconnect, and the boxes only exist once connected | `renderer/remote/DeviceCopilot.tsx` |

**What did not change, and is pinned by tests that fail if it does:** the
copilot's pty stays off the session fanout (`copilot-off-the-network.test.ts`);
routines and the action log stay outside the copilot's writable reach
(`copilot-writable-boundary.test.ts`, `copilot-log-boundary.test.ts`,
`copilot-transcript-forgery.test.ts`); enforcement stays on the desktop at the
point the tool is invoked (`copilot-enforcement.test.ts`); and every device still
gets a run of its own, because the shared-conversation version cannot be secured.

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

> **Done, and the bound moved. 2026-08-17.** Both files are in the fence —
> `confine/records.ts`, `paths.remoteCopilot` and `paths.remoteAuth`. Two
> corrections to the paragraph above. The store is now
> `<userData>/remote/copilot-link.json` rather than `remote-copilot.json`, and
> the fence went on naming the old path for a while after the rename because
> nothing pinned the spelling — a Seatbelt rule over a path nothing writes
> refuses nothing, silently. `copilot-link.test.ts` now calls
> `recordsFenceAgrees` from the side that owns the path, which is what that
> function exists for. And `alter` is no longer scrubbed, so the bound is a
> different one: `CopilotLinks.load` drops any record with **no credential**, so
> the copilot cannot mint a connection — it would have to produce a secret whose
> scrypt hash it also wrote. What an edit could still do is raise the tiers of a
> connection that already exists, turning a device somebody connected read-only
> into one that answers confirmations. Which is why the fence is not optional.

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

    | { t: 'welcome'; …; copilot?: CopilotLinkWire }
    | { t: 'copilot.grant'; link: CopilotLinkWire }

    interface CopilotLinkWire {
      linked: boolean            // this desktop holds a copilot record for you
      open: boolean              // *this socket* has presented the credential
      grant: { read: boolean; act: boolean; alter: boolean }
    }

Three facts rather than one, because a client has three screens to draw and
folding them together makes one of them wrong: *ask the person for a code*,
*send the credential you already have*, and *you are in, here is what you may
do*. **`open` is false on every `welcome`, always** — a session channel does not
carry the copilot by existing, which is the whole difference between this design
and the per-device grant it replaced.

`alter` **is** on the wire, and used to be deliberately absent — see the revision
note at the top. Its absence was three independent refusals guarding a tier whose
safety property was *a human at the machine says yes*; that property is now
guarded by the connection instead.

`copilot.grant` is pushed the moment the panel changes, so a disconnected
device's Copilot tab goes away without a reconnect. The *rule* is already live
without it, because the store is read per frame and per call (§3), which is what
makes the push honest rather than load-bearing.

### Client → desktop

Three frames carry **no tier** and cannot: they *are* the authorisation, and a
device with no copilot connection has no tiers, so requiring one to send the
frame that establishes the connection would mean no device could ever connect.
`COPILOT_UNTIERED_FRAMES` names them so the set is checkable, and
`copilot-frames.test.ts` asserts the two lists together cover every `copilot.*`
client verb — a verb added to neither fails the suite.

| Frame | Tier | What it is |
|---|---|---|
| `{ t: 'copilot.connect'; code }` | — | Redeem a connect code minted at the desktop. Answered once with `copilot.linked` carrying the credential; it is never sent again, because the desktop keeps a scrypt hash. Opens this socket as well: it has just proved it holds a code minted seconds ago, which is a stronger claim than the credential it is about to be given. |
| `{ t: 'copilot.hello'; credential }` | — | Open the copilot connection on this socket. Required after every reconnect. |
| `{ t: 'copilot.bye' }` | — | Close it on this socket. The credential and the record survive — this is the connection ending, not the authorisation. |
| `{ t: 'copilot.answer'; id; approved }` | alter | Answer a confirmation. §4. |
| `{ t: 'copilot.attach' }` | read | Subscribe this connection to the copilot surface and replay what exists. Answered with `copilot.state`, then `copilot.chat` with `reset: true`. Starts nothing. |
| `{ t: 'copilot.detach' }` | read | Stop the stream. The run keeps going; see the grace window. |
| `{ t: 'copilot.state' }` | read | What the copilot is: running or not, which profile, signed in or not, what the catalogue costs per turn, how many confirmations are waiting at the desk. |
| `{ t: 'copilot.sessions' }` | read | The sessions the copilot started — `origin: 'copilot'`, with `originRunId` so each links back to the turn that made it. |
| `{ t: 'copilot.log'; limit?: number; before?: string }` | read | The tail of `actions.jsonl`, scrubbed, newest last. `before` is a row id, for paging back. |
| `{ t: 'copilot.pending' }` | read | Every waiting confirmation, with its summary, expiry and `mine` — whether **this** connection may answer it. No arguments; see §4. |
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
| `{ t: 'copilot.grant'; link: … }` | Above. |
| `{ t: 'copilot.linked'; credential; link }` | Answer to `copilot.connect`, sent exactly once. The client stores the credential where it stores its pairing credential and with the same care; the two are worth the same. |
| `{ t: 'copilot.ask'; question }` | A confirmation **this** connection may answer, with the tool, the tier, the desktop's own summary, the origin, the countdown and **every argument verbatim**. Sent only to the surface that owns the run that raised it. |
| `{ t: 'copilot.settled'; settled }` | A question closed, and `by` — where it was answered. Sent to every connection that was told about it, including the one that answered. |

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
in any client frame. The device sends prose. Tool calls are made by a CLI process
on the desktop, over loopback, authenticated by a bearer token it holds and the
device does not.

The property this used to buy was *a phone that has not been granted alter cannot
reach an alter tool by any frame it can construct*, and it bought it by there
being no tool to name. `alter` is grantable now, and the property is unchanged
and still worth exactly as much: a device holding every tier still **cannot name
a call**. It can say a sentence, and it can decide about a call the desktop
composed — `copilot.answer` carries a question id and a boolean, and the tool,
the arguments and the effect were all decided on this machine before anybody was
asked anything. Every other design has to enumerate and deny; this one has
nothing to enumerate.

It is also the rule that will be under pressure. The first person who wants
`copilot.tool` for a nice phone UI ("tap to re-run that") should be pointed here.

### Deliberately absent

- **A tool name, in any direction a client can send.** Above.
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

### Revocation — and the two things that are revoked separately

**Revoking the copilot and revoking the pairing are two acts, and neither implies
the other.** Disconnecting the copilot — `CopilotLinks.disconnect`, the button in
Settings — drops the record and the credential with it, and touches nothing in
`remote-auth.json`: the device keeps every terminal it was paired for. That is
the property `server.test.ts` asserts on both sides, and it is the whole point of
the two authorisations being separate acts.

The other direction is not symmetric and should not be. Revoking the *device*
also drops its copilot record, because revocation in `device-auth.ts` is
permanent and a returning phone pairs again with a **new** device id — so the
record could never be opened by anything, and keeping it would leave a credential
in a file with nobody's name against it. That is garbage collection, not a
cascade.

Either one, and unticking a tier, must do five things in this order:

1. Write the store (`set` / `disconnect` / `forget`). Everything else is
   downstream of the disk, for the reason `commit()` gives — a permission that
   reverts *up* at the next launch is worse than one that reverts down.
2. Withdraw every confirmation that device raised, as `caller-gone`. A device
   whose access just changed must not be left holding a dialog it may no longer
   answer.
3. Drop that run's token from the table. In-flight tool calls abort with
   `caller-gone`; the signal for that is held per token entry (§4).
4. Stop the run.
5. Close the copilot connection on every live socket of that device, and push
   `copilot.grant` to each — with `linked: false` when the record has gone, so
   the refusal a device gets next says *this device is not connected* rather than
   *you do not have enough access*. Two different sentences with two different
   remedies, and the second would send somebody looking for a checkbox that is no
   longer the obstacle.

Step 1 alone is already sufficient for correctness, because the store is read per
frame and per call. Steps 2–5 are what stop a disconnected device from watching a
conversation it can no longer influence, or answering a question it can no longer
be trusted with.

### Proof obligations

Written as tests, because this repository's convention is that a rule with no
test is a comment:

- **A paired device with no copilot connection reaches nothing.** Every tool,
  *including the read ones*, is `not-granted` for a device that has never
  redeemed a code — and every `copilot.*` frame, including the read-tier ones, is
  refused over a real socket. `copilot-enforcement.test.ts` and
  `server.test.ts`. This is the headline obligation of the revision.
- **The panel is not a second door.** `CopilotLinks.set` refuses to create a
  record, so no settings write can give copilot access to an unconnected device.
  `copilot-link.test.ts`, `copilot-runs.test.ts`.
- **Table-driven over the whole catalogue.** For a caller with `{read:true}`,
  every `act` and `alter` tool in `buildCatalogue()` returns `not-granted`. Driving
  it off the catalogue rather than a list means a tool added next month is covered
  the day it is added. And the inverse: a connection holding `alter` reaches an
  alter tool *through the gate*, so the file distinguishes "the boundary holds"
  from "the feature is broken".
- **Escalation.** `sessions.send` with `act` granted: allowed against a session
  the run started, `not-granted` against one it did not.
- **Hidden pty.** The copilot session id and every run id are absent from
  `SessionFanout.list()`, and `attach` returns null for them.
- **Revocation without restart.** After `links.disconnect(device)`, the very next
  MCP call on that run's live token is `not-granted`, and the very next frame on
  its live socket is refused.
- **A frame a device should not be able to send.** A connected device holding
  `alter` answering *another* device's question is refused, and told the same
  thing a settled question would tell it. `copilot-answer.test.ts`,
  `server.test.ts`.
- **No tool names on the wire.** A corpus test over `protocol.ts` asserting that
  no `ClientMessage` variant carries a field whose value is a tool id — the same
  shape `wire-wording.test.ts` and `reachable.test.ts` already use to pin a
  property that is about text rather than types.

---

## 4. Consent from a connected device

**Rewritten 2026-08-17.** What this section used to say is at the end of it,
under §4.8, unedited — the argument was good, and a file that quietly deletes the
reasoning it superseded leaves the next person to rediscover it from scratch.

The hard one, and the answer has four parts because there are four different
questions hiding in it: who may be asked, who may answer *which* question, what
they have to be shown in order to answer honestly, and what happens when nobody
answers at all.

### 4.1 A device-originated alter request now exists, and the dialog goes to it

`REMOTE_GRANTABLE_TIERS` is `['read', 'act', 'alter']`. The clamp in `set()` and
the scrub in `load()` are gone.

**Where does the prompt appear when the request came from a device? On that
device, and on the desktop, at the same time.** `DeckControl.call` reaches the
broker with `origin: 'device:<id>'`; `deck-control/index.ts` fans the question
out to both surfaces; first answer wins.

What makes this honest rather than a ceremony is not that the device is trusted.
It is that **connecting the copilot is a separate act of authorisation from
pairing for sessions**. The old argument — *a dialog answered on the device that
raised the request is answered by the party being confirmed* — assumed the second
factor was being at the desk. It was not: it was holding an authorisation you did
not already have. That authorisation is now the copilot connection, and a device
paired to run terminals holds none of it.

The tier is still a tier. A person can connect a device read-only, or connect it
to work but not to change things. Three checkboxes, and the third one's label
says exactly what ticking it moves: *the confirmation appears on that device, and
whoever is holding it answers.*

### 4.2 The race, and the rule that is not obvious

Both surfaces are asked, so both can answer, and the machinery for that already
existed:

- `respond()` returns false for an id that has been settled, so the race needs no
  lock — it needs both surfaces to have been asked.
- `ConsentBrokerOptions.settled` notifies every surface when a question closes.
- `ConsentGranted.by` is a string: `'window'` for the desktop, `device:<id>` for
  a connection.

First answer wins. The other surface **withdraws its dialog saying where it was
answered** — `copilot.settled` carries `by`, and `settledSentence` on the desktop
says *Allowed on a connected device*. A dialog that vanishes on its own teaches a
person that the app does things behind their back. And the log records which:
`confirmed.by` is `device:<id>`, and `detailFor` writes *— allowed on a connected
device* rather than *— allowed by the person*. Those must never read the same.

**The rule that is not obvious, and is enforced:** a question may only be
answered by the surface that owns the run that raised it, or by the desktop.
Otherwise device A approves device B's action, which is a permission model with a
shared password. It lives in `ConsentBroker.respond`, with the question, not in
the transport — *a rule enforced in one transport is a rule the next transport
does not have*. A device that tries gets `accepted: false`, which is the same
answer a settled question gets, so probing for another device's question ids
learns nothing.

The desktop is exempt from the ownership rule because the desktop is the machine:
somebody standing at it can already do by hand whatever they would be approving.

### 4.3 What a device must be shown, or the gate is worse than nothing

This is where it goes wrong in practice. **A consent prompt without enough
context becomes a reflex Yes, and a gate that is always answered yes is worse
than no gate, because it looks like protection.**

So there are two shapes on the wire and the difference between them is the whole
of this subsection:

- `CopilotPendingRow` — *something needs attention*. Goes to every watching
  connection. The tool, the desktop's own one-line summary, the countdown, and
  `mine`. **No arguments**: a device that cannot answer has no decision to make
  with somebody's settings patch or the text about to be typed into their
  terminal.
- `CopilotConsentQuestion` — *decide*. Goes only to the surface that raised it.
  What is being asked, by whom (`origin`), **with what arguments** — every one of
  them, verbatim, in the tool's own order — and what happens if you say nothing.

Nothing is re-composed on the client. `summary` is written by the tool that is
about to run, by the code that knows what it will do; a client that wrote its own
sentence would be describing an action it did not implement, and the first time
the two drifted somebody would approve one thing having read another.

**Refusing must be at least as easy as accepting.** Not Allow under the thumb and
Refuse in a corner. This is a constraint on every client and it is the one most
likely to be lost to a layout that looks tidy: the destructive-looking button is
the safe one here, and a design that makes the safe answer the harder gesture has
inverted the gate. The desktop's own dialog obeys it and the iOS client must.

And the expiry is on the wire so the device counts down exactly as the dialog
does. **Two minutes, not extended for a phone.** The temptation to make it five
for *she has to unlock her phone* is refused: a longer window is how you get an
approval six minutes later from somebody who has forgotten what they were
approving, against a turn that has already moved on.

### 4.4 Is a device-originated request attended? Yes, and the flag says so

`attended` in `control.ts` means one thing: *is there a human who could be asked
right now.* A routine at 03:00: no, and `not-permitted-unattended` exists because
telling it otherwise made OpenClaw's heartbeat spend turns generating apologies.

A device-originated turn is attended by that definition and by a wider margin
than most desktop turns: there is demonstrably a person, they sent a message
seconds ago, and they are holding a device that can display a prompt and take a
tap. A desktop turn where the app is open and the person went for coffee is
*less* attended and is marked `attended: true` today.

The flag was already true. What changed is that it is now **observable** — before
this revision every alter call from a device was refused one check earlier, so
nothing read it. Marking it correctly then, when nothing read it, is why nothing
had to be repaired now.

### 4.5 Nobody answers: every way that happens, and it is always a refusal

- **Timeout.** Two minutes, then `timeout`. Unchanged.
- **The device's copilot connection drops mid-prompt.** Refused at once, with
  `caller-gone`. Not left for the desktop to answer, even though the desktop may
  answer anything: the run that asked is about to be reaped, the person who asked
  is gone, and an approval landing afterwards is a change nobody is waiting for.
  `server.ts` calls `CopilotRemote.closed` when the **last** open copilot
  connection of that device goes — a phone with the app open in two places has
  not stopped watching because one of them closed.
- **A call in flight from the device's run.** The run's tool calls carry an
  `AbortSignal` held on the token-table entry; dropping the grant aborts it and
  the broker resolves `caller-gone`.
- **Nobody could be asked at all.** `ask` returns false when no approver saw it —
  no window attached, and no connection holding `alter` — and the broker answers
  `no-approver` immediately rather than holding a tool call open for two minutes
  on a dialog that was never drawn.
- **The window goes.** `approverGone()`, unchanged: everything outstanding is
  refused. `callerGone(surface)` is the narrower device version and deliberately
  throws if handed `'window'`, because a silent alias is how somebody ends up
  refusing every device's question because a renderer reloaded.
- **A question the device was merely watching.** Nothing is refused. It was never
  an approver for that one.

### 4.6 If push is ever added

There is no APNs in this product — `ios/TerminalDeck/App/SessionAlerts.swift`
says so plainly — so an alert can only be raised while the app is running. That
is a real limitation on this feature: a confirmation lives 120 seconds, and a
device that is not already open and in someone's hand cannot be asked.

If push is ever added, two constraints, both non-negotiable:

1. **The payload carries nothing.** It goes through Apple's servers in
   plaintext-to-them, so no summary, no tool name, no session title. *Something
   needs you.* This is the single most likely way the sealing property in §7 gets
   lost, because a useful notification is exactly a notification that says what
   happened.
2. **It carries no actions.** A lock-screen Allow that approves without the
   request being read is a gate that is always answered yes wearing the
   appearance of protection. The app is foregrounded, the full request is
   displayed — summary, every argument verbatim, the countdown — and the answer
   happens there.

A device unlock (`LAContext` / `BiometricPrompt`) in front of Allow is worth
having and defeats a found phone and nothing else; the client should say that
rather than implying more. Refuse must not require it.

### 4.7 The real defence is still that alter is rare

If he finds himself approving things from a phone several times a week, the tier
boundary is wrong and the fix is to look at which tool keeps asking — not to make
the approval gesture smaller. The pending cap stays at three, and three prompts
inside a minute should be reported to the device as *the copilot is looping*
rather than drawn as three dialogs.

And `consent.ts`'s **report and offer** pattern is still worth building beside
this rather than instead of it: a device-originated refusal is already a row in
`actions.jsonl` with the tool, the scrubbed arguments and the summary, so the
Activity pane can grow an *asked from a device, needs you* filter with an Allow
button that runs the call locally. That costs no new frames and puts some
decisions in front of somebody at the machine that owns the risk.

### 4.8 What this section said before, unedited

Kept because the argument is good, because the code it describes is what the
tests were written against, and because somebody will one day propose exactly it
again. The two paragraphs that matter:

> **4.1 A phone-originated alter request does not exist, and that is the answer.**
> `REMOTE_GRANTABLE_TIERS` is `['read', 'act']`. `set()` clamps `alter` to false
> and `load()` scrubs it out of a hand-edited file. So a phone-originated call at
> the alter tier is refused at the tier check — before the budget, before the
> precheck, before the broker, before any window is asked anything.
>
> Where does the prompt appear when the request came from a phone? Nowhere,
> because there is no prompt. […] That is not a dodge, it is the design. The
> alter tier's entire safety property is *a human at the machine says yes*. A
> dialog that appears on the device that raised the request is answered by the
> party being confirmed. If holding the phone is sufficient to approve what the
> phone asked for, then the phone holds `alter` and the grant was a ceremony.

> **4.5 It must not become a rubber stamp.** […] There is no push. A confirmation
> lives 120 seconds. A phone that is not already open, connected and in someone's
> hand cannot be asked. So a phone Allow button would work in exactly one
> situation — the person is already staring at the app — and in that situation
> nothing was gained over walking to the desk, while everything about the trust
> model changed.

The first is superseded by the separate connection; the second is *not*
superseded and is why §4.6 exists. The push limitation is real, and it means this
feature is worth exactly what it is worth when somebody is already holding the
device — which, for a person who reaches for their phone to check on a build, is
most of the time it matters.

---

## 5. What a connected device must never do, however it is granted

Eleven, each with the argument. Two of them were revised on 2026-08-17 and are
marked; the other nine are unchanged and are pinned by tests.

**1. Name a tool.** §2. It is the property that makes the enforcement airtight
rather than exhaustive, and the first convenience feature that breaks it —
"tap to re-run" — breaks all of it.

**2. ~~Hold `alter` (v1).~~ REVISED — hold `alter` without a separate
connection.** §4. The original rule read: *a standing grant of alter is a durable
power that survives the device being lost, stolen, handed over, or restored from
a backup onto someone else's hardware; a per-call confirmation is a live act by a
present human; conflating them is how a permission becomes a setting.*

That is still true of the *grant*, and the answer to it is that a device holding
`alter` does not skip the confirmation — it **receives** it. Nothing is
pre-authorised: every alter call still draws a question, still expires into a
refusal, still writes a row naming who answered. What the tier decides is which
screen the question appears on. And the durable half of the objection — lost,
stolen, restored from a backup — is answered by the connection being separately
revocable, immediately, from the machine, without unpairing the device.

**3. Attach to any copilot pty, including its own run's.** The phone gets parsed
`ChatMessage`s, never bytes. Raw pty access is a keyboard, and a keyboard on a
Claude CLI with Bash is the whole machine — every tier check in this document sits
above that layer, not below it. It is also why §0.1 is blocking rather than
tidying.

**4. ~~Answer an alter confirmation.~~ REVISED — answer *another surface's*
confirmation.** §4.2. A connected device holding `alter` answers its own run's
questions and nothing else. The desktop answers anything, because somebody
standing at the machine can already do by hand whatever they would be approving.
Device A approving device B's action is a permission model with a shared
password, and it is refused inside the broker rather than in the transport.

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

**9. Change any grant or make itself a connection, by any path.** Four doors, all
shut: `settings.write` refuses the `remote.` and `copilot.` prefixes; the
copilot's own `Write` tool is kept off `copilot-link.json` and `remote-auth.json`
by the records fence (§0.3); `CopilotLinks.set` refuses to *create* a record, so
the settings channel cannot connect a device; and `load()` drops any record with
no credential, so a hand-edited file cannot invent a connection either. Minting a
code is the only door and it is on the desktop, which is what
`notGrantedSentence` already tells the model.

**10. Cause a routine to be created, edited or fired.** `routines.create` is
alter, so it is refused for a remote caller by the tier check — but state it
separately because it is the one that will look harmless. *"Make a routine that
checks the build every hour"* from a phone is an agent writing its own next
trigger, at a distance, which `COPILOT-CAPABILITIES.md` §3.2 rule 3 refuses
outright and Goose blocks as a class. The fence and the tier are two independent
reasons and both should hold.

**11. See or speak into another device's run, or read another device's pending
question in full.** Runs are keyed by device. Two devices are two conversations.
A question raised by one reaches the other as a watch row — the tool, the
summary, the countdown, `mine: false` — and never as a `copilot.ask` with the
arguments in it. Anything else makes a grant to one device a grant to every
device that comes after it.

**12. Reach the copilot at all without a connection.** New, and it is the one
that subsumes half the list. A device that has been paired, approved and given
folders gets `unauthorized` for every `copilot.*` frame — including the read-tier
ones — until it has redeemed a connect code minted at this machine. There is no
frame it can send that measures anything about the copilot: not whether one is
running, not how many confirmations are waiting, not whether a grant it does not
have would have been enough.

---

## 6. Connecting, and the panel

**Revised 2026-08-17.** Copilot access used to be *a separate, off-by-default
capability on an already-paired device* — a checkbox. It is a **separate
connection**: its own six-digit code, its own credential, its own record, its own
revoke. Pairing is still unchanged; nothing here touches `device-auth.ts`, the
short code it mints, or the rendezvous. What is new sits beside them and borrows
their shape.

### The ceremony

1. Somebody at this machine opens Settings → Remote, finds the device, and
   presses **Connect the copilot…**. That mints a six-digit code — sixty seconds,
   single use, five wrong guesses and the code itself is dead — and decides there
   and then what it grants. All three tiers by default, which is what *"full
   control over copilot, same as the actual machine app"* means; the checkboxes
   that appear afterwards are how it is narrowed.
2. The code is read out and typed into the device, which sends `copilot.connect`
   on its **already-authenticated sealed channel** — so the device id is a fact
   rather than a claim, and the code is the second thing being proved.
3. The desktop answers `copilot.linked` once, with a 32-byte credential stored
   here as a scrypt hash. There is no path that shows it again: a device that
   loses it asks for a new code, which is right, because minting one is a
   deliberate act at the machine and re-issuing on request would not be.
4. Every socket that device opens from then on sends `copilot.hello` with that
   credential before any `copilot.*` verb is served. **On every reconnect.** A
   session channel does not carry the copilot by existing.

The tiers travel with the *code* rather than being ticked afterwards, and that is
the whole ceremony: the person minting it is standing here, looking at a screen
that says what they are about to hand over. A code that granted nothing and left
the tiers to a later click would make connecting and authorising two separate
moments, and the second one is the one people skip.

### Why the credential carries no device id

`device-auth.ts` mints `"<id>.<secret>"` because a session credential arrives on
an anonymous socket and has to say who it is. This one arrives on a socket that
has already proved which device it is, so an id would be a field nobody reads.
Leaving it out buys a property worth having: a copilot credential is useless on
any socket that is not that device's, so a leaked one is not a bearer token for
the copilot — it is half of a pair, and the other half is the device's session
credential and its static key.

### Where the panel lives

Settings → Remote, on the device card, directly under the folder list —
`RemoteSection` → `DeviceCopilot`, built the same way `DeviceFolders` is,
including the split between the view and the fetching so it can be rendered in
every state under `renderToStaticMarkup`.

Same card as the folders, deliberately. Both answer *what may this device do
here*, and somebody deciding about a phone should see both answers at once rather
than finding the second one under a different heading a month later.

### What the controls are

For a device with **no connection**: a Connect button, a sentence saying what
connecting will hand over, and **nothing tickable**. That is the assertion that
replaced the permanently-disabled third row this section used to specify, and it
defends the same property — a control must never suggest a permission the store
would not grant. `CopilotLinks.set` refuses to create a record, so a checkbox
here would be a switch that changes nothing.

For a **connected** device: three checkboxes, labelled in outcomes rather than
tier names, and a quiet Disconnect.

- ☐ **Watch the copilot** — see what it is doing, what it started, and what it
  was refused. It cannot make it do anything. (`read`)
- ☐ **Ask it to work** — talk to it, and let it start and steer sessions on your
  behalf. **This spends money.** (`act`)
- ☐ **Change settings and stop your sessions** — every change is still confirmed
  one at a time, but the confirmation appears *on that device* and whoever is
  holding it answers. Leave it off to keep those confirmations at this Mac.
  (`alter`)

The third label is the important one and it took three drafts. It does not say
"grants alter" and it does not say "full control": what ticking it changes is
which screen the question is drawn on and which thumb answers it, and a person
who has not been told that has not been told what they are agreeing to.

### Defaults, preconditions, revocation

- **No connection, for every device, including every device paired before this
  existed.** `granted()` returns `NO_TIERS` for a device with no record and the
  header explains why this file does not inherit `folder-grants.ts`'s fallback:
  nobody has ever had remote copilot access, so nobody can lose it.
- **Preconditions to draw the control:** the device is `approved`, and it has a
  key fingerprint. A device paired before sealed channels has no static key, so
  it cannot open a sealed channel at all — offering it a Connect button would be
  a control with nothing behind it.
- **Disconnecting** drops the record and the credential with it, immediately, and
  leaves the pairing alone. Unticking every box is *not* the same thing: an
  all-false record still holds a working credential, so the device can still open
  a connection and be refused everything. Both states are real and the panel shows
  them differently, because only one of them has something to revoke.
- **A paired desktop is a device too.** `machines/guest.ts` pairs Macs and Windows
  boxes to each other and they hold device ids like any phone. Same panel, same
  default, no exception — a desktop guest is somebody else's machine.

### Do not build this panel before the transport

`reachable.test.ts` warned about exactly this, and the warning is now a matter of
record rather than a prediction:

> *"The wrong fix would be to reach it from the UI. A switch in the devices panel
> granting a phone read or act would be a permission control that changes nothing
> a phone can do — the exact defect the second check in this file exists to catch,
> and a worse instance of it than a dead font size, because a person who granted
> it would believe they had."*

The panel lands with the frames or after them, never before. `CopilotLinks.set`
refusing to create a record is the same warning enforced in the store rather than
remembered.

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

**Revised 2026-08-17.** Steps 1–6 have all landed on the desktop, and the
sequencing question the section closed with was answered by him rather than by
shipping: `read` alone is not what he meant.

Where it stands:

1. ✅ **§0.1** — the copilot's pty is off the session fanout, pinned by
   `copilot-off-the-network.test.ts` against the real core and four cases in
   `server.test.ts`.
2. ✅ **§0.3 and §0.2** — both remote stores are in the records fence and
   `ToolContext` carries the caller.
3. ✅ **The capability, the link in `welcome`, the token table, the read frames.**
4. ✅ **The act tier** — `start`, `say`, `cancel`, `stop`, per-device runs.
5. ✅ **The separate connection** — `copilot.connect` / `hello` / `bye`,
   `copilot-link.ts`, and every `copilot.*` frame gated on it.
6. ✅ **Consent from a device** — `copilot.ask` / `answer` / `settled`, the
   ownership rule in the broker, the log row that says where it was answered.
7. ✅ **The panel** — Connect, three tiers, Disconnect.

**Left, and it is the iOS client.** Everything above is desktop-side and is
exercised over a real socket by `server.test.ts`; none of it is reachable from a
phone until the client speaks the four new frames. See the report at the end of
this section.

Still owed on the desktop: per-caller budgets (§0.4), which are a fairness
property rather than a security one and are three lines.

### What I would not build

- **`copilot.tool` as a client verb.** Ever. §2. It is the one convenience that
  trades the whole enforcement property for a gesture.
- **A push notification carrying content, or one carrying actions.** §4.6.
- **A raw pty for the copilot connection.** §5.3. *Full control over copilot*
  means its chat, its tools and its confirmations — things that go through the
  gate, the budgets and the action log. A pty goes through none of them: it is
  *underneath* the permission model, not the top of it, so handing one over would
  not be granting the highest tier, it would be leaving the building. **Whether
  the copilot connection should also offer its own terminal is a separate
  question and it is not answered here** — it is reported, not decided.
- **Memory or instruction editing from a device.** §5.5.
- **A separate memory for a device's run.** §1. Two memories is two copilots.
- **Routines from a device.** §5.10.
- **The shared-conversation design (§1a).** It is the one that sounds like what he
  asked for and it is the one that cannot be secured, because turn boundaries in
  a pty are inferred rather than known, so it has no way to tell whose sentence
  caused which tool call.

### What the iOS client needs now

The desktop is finished; the phone is not. In the order a client should build
them:

1. **Store a second credential.** Keychain, beside the pairing one, with the same
   protection class. `copilot.linked` delivers it exactly once and there is no
   way to ask for it again — a client that loses it must show the Connect screen
   rather than silently failing every copilot frame.
2. **A Connect screen.** Six digits, numeric keypad, sent as `copilot.connect`.
   Drawn when `welcome.copilot.linked` is false. The error sentences come from
   the desktop and are already written for a person; do not re-compose them.
   **Normalise before sending** — `shared/short-code.ts`'s `normaliseCode`, the
   same function the pairing screen already uses. The desktop hashes the string
   it is given and does not strip separators, exactly as `device-auth.ts` does
   not, so a code sent as `481 902` is simply wrong. That split is deliberate:
   one place decides what a code looks like, and it is the client, because the
   client is where somebody typed it.
3. **`copilot.hello` on every connect and reconnect**, before any other
   `copilot.*` frame, and a Copilot tab that stays dark until `copilot.grant`
   arrives with `open: true`. `welcome.copilot.open` is *always* false — a client
   that treats it as "already in" will send frames that are refused.
4. **Draw controls off `grant`, not off the capability.** `read` → the state, the
   sessions, the log, the pending list. `act` → Start, the message box, Cancel,
   Stop. `alter` → the Allow/Refuse pair on `copilot.ask`.
5. **The consent sheet, and it is the part worth the most care.** On
   `copilot.ask`: the tool, the desktop's summary, **every argument verbatim**,
   the origin, and a live countdown that says the question expires into a
   *refusal*. On `copilot.settled` for the same id: withdraw it, saying where it
   was answered (`by`).
   - **Refusing must be at least as easy as accepting.** Not Allow under the
     thumb and Refuse in a corner. The safe answer must not be the harder
     gesture.
   - Optionally a device unlock in front of Allow, never in front of Refuse, and
     the sheet should say it defeats a found phone and nothing more.
   - Never answer from a notification, and there is no notification to answer
     from: there is no APNs in this product.
6. **`copilot.pending` with `mine`.** Rows with `mine: false` are a *go and look*
   notice and must draw no Allow button — one is always refused, and a control
   that is always refused is the defect this repository has paid for twice.
7. **`copilot.bye`** when a person leaves the Copilot tab on a shared device.
8. **`ios/Harness/host-standin.ts` gained `--copilot alter`.** It accepts any
   `copilot.hello` — it is a client harness, not a security model — but it
   reproduces the shape: `open` is false on every welcome, so a client that skips
   the hello sees nothing. It does not yet serve `copilot.connect`,
   `copilot.ask`, `copilot.answer` or `copilot.settled`; whoever builds the
   client should add those to the stand-in in the same pass, because a client
   that has only ever been driven against a permissive host is the failure that
   file exists to catch.
