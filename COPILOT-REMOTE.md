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

The answer in one paragraph: **pairing a device as "My device" is the copilot
authorisation.** One of his own devices reaches the copilot from the moment it is
approved at this keyboard, holding every tier; a guest never reaches it and is
never told there is anything to reach. There is no second code, no second
credential, no second store and no second screen. The device talks to a **copilot
run of its own** — same folder, same `CLAUDE.md`, same `memory/`, same action
log, same tools — rather than typing at the copilot's keyboard. The wire carries
*sentences*, never tool names, so there is no frame a device can construct that
names a tool at all. Enforcement stays exactly where it already is:
`DeckControl.call`, on the desktop, at the point the tool is dispatched. And one
of his own devices holds all three tiers, including `alter`, and answers its own
run's confirmations — because the second factor behind that tier was never
geography and was never a code: it was holding an authorisation the requesting
party could not give itself, and a device kind is exactly that.

---

## REVISED AGAIN, 2026-08-19 — the second connection is deleted

Asad, having used the thing this file specified:

> *"instead of giving mobile app separate connection for copilot just make it
> like if we are connecting as my device copilot automatically comes, if we
> connect as guest then copilot don't come — that's all we need to do instead of
> two different connections"*

**What this file said, and why it said it.** The block below, written two days
earlier, moved the second factor behind the `alter` tier off *being at the desk*
and onto *having been deliberately authorised for the copilot*, and then built
that authorisation as a **separate connection**: its own six-digit code minted at
the desktop, its own 32-byte credential, its own record, its own revoke, its own
panel. §6 specified the ceremony and §5 rule 12 made it the rule that subsumed
half the list. All of it is preserved — the diagnosis is the best paragraph in
this document and it is *not* what was wrong.

**Why it does not survive.** The diagnosis was right and the remedy proved the
same fact twice. Re-read what the factor actually is:

> *What actually made it meaningful is that reaching the dialog required an
> authorisation the requesting party did not already hold.*

A separate connection is **one** way to be such an authorisation. It is not the
only one, and within a day of §6 shipping there was another on this machine doing
exactly that work: `device-kind.ts` landed on 08-18, one commit after this file
and `copilot-link.ts` landed together on 08-17. Two mechanisms for one property,
built a day apart, is how a design ends up asking somebody the same question
twice. Hold the kind against the four properties §6 was manufacturing:

| §6 wanted | The kind already has it |
|---|---|
| Minted at this machine, by a person looking at a screen that says what they are handing over | The approval screen, whose two sentences are his own and say precisely that |
| Proved at the other end | The six digits typed into the phone are the pairing code; the kind is chosen against that pairing, at this keyboard, while it is happening |
| Not something the device can give itself | `claim()` is called by the approval flow on the desktop; no frame reaches it |
| Not something anyone can flip afterwards without doing it all again | `claim()` writes once, a second call with a different kind is refused, and *there is deliberately no method that overwrites one* — changing what a device is means revoking and pairing again |

So the copilot code was a second proof of a fact already proved, and it was not
free. It cost a screen, a credential, a file, a store, a revoke path, four wire
frames, and — the part he actually hit — a whole class of states in which a
device is **paired as his own and yet refused by the copilot**, sitting in front
of a *Connect the copilot* prompt for a machine it is already trusted on. This
repository has spent weeks deleting exactly that shape everywhere else. It is
the same defect as a control that is always refused, one level up: not a dead
button, a dead ceremony.

**What it costs, and this is not a free simplification.** The approval screen is
now the *only* place the decision is made. One press there and a device reaches
an agent that holds this machine's shell, at the alter tier, answering its own
confirmations. There is no second gate behind it, no narrower setting, and no
undo in place — the only correction is `forget()` plus pairing again, which is
what that method's own comment says it is for. Three things are what make that
acceptable rather than merely simpler, and all three have to keep holding:

1. **The screen already carries the weight, and its wording is now load-bearing
   rather than descriptive.** *"My device — Full access. It's you at another
   keyboard."* and *"Guest — You choose what they can reach. The copilot is
   never shared."* Those are his sentences, they are quoted verbatim in
   `device-kind.ts`, and the second one is what stops the copilot's absence from
   a guest flow reading as a missing feature. Neither may be softened into
   product copy.
2. **It fails closed.** `kindOf` answers `guest` for a device it has never heard
   of, a record it cannot parse and a file it cannot read. There is no branch
   that produces `mine` from bad input.
3. **Nothing is pre-authorised.** Holding `alter` is not permission to change
   something; it decides *which screen the question is drawn on*. Every alter
   call still draws a confirmation, still expires into a refusal, and still
   writes a row naming the surface that answered it.

**What changed, concretely:**

| Was | Is | Where |
|---|---|---|
| A separate connection: own code, own credential, own record, own revoke | The device's kind. `mine` reaches the copilot, `guest` does not | `remote/device-kind.ts`, §6 |
| `copilot.connect` redeems a six-digit copilot code | **Deleted.** No client may send it; there is no code and nothing to redeem | §2, `protocol.ts` |
| `copilot.hello` presents a stored credential | `{ t: 'copilot.hello' }`, carrying nothing — it is a subscription, not a proof | §2 |
| `welcome.copilot` present for every device, `linked` saying whether it had connected | Present **only** for a `mine` device; a guest gets no key at all | §2 |
| Per-device tier checkboxes on a connected device | No switch. *My device* means full access | §6 |
| Two revocations, neither implying the other | One. Revoking the device is the only revocation | §3 |
| The link store is the file that decides copilot access, and it is fenced | The **kinds** file decides it, and it is not fenced yet | §0.5 |

**What did not change, and is pinned by tests that fail if it does:** the
copilot's pty stays off the session fanout (`copilot-off-the-network.test.ts`);
routines and the action log stay outside the copilot's writable reach
(`copilot-writable-boundary.test.ts`, `copilot-log-boundary.test.ts`,
`copilot-transcript-forgery.test.ts`); enforcement stays on the desktop at the
point the tool is invoked (`copilot-enforcement.test.ts`); every device still
gets a run of its own; and no tool name ever appears on the wire.

---

## REVISED, 2026-08-17 — superseded in part by the block above; read this before §4

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

## 0. Four things that must be fixed first, and one that should be

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
>
> **And then the store it names went away. 2026-08-19.** With the separate
> connection deleted there is no `copilot-link.json`, and the file that decides
> copilot access is a *different* file, which is not in the fence. That is §0.5,
> and it is this same lesson arriving a second time.

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

### 0.5 The file that decides copilot access is no longer the file that is fenced

**DONE, 2026-08-19, in the same change that created the hole.** Both moves below
landed: `records.ts` now fences `<userData>/remote/remote-device-kinds.json` in
place of the deleted `copilot-link.json`, and `recordsFenceAgrees` is asserted
from `device-kind.test.ts` — the side that owns the spelling — with
`recordsFenceList` checked alongside it. `copilot-writable-boundary.test.ts` and
`copilot-layer.test.ts` pass unchanged against the new path, which is the point
of routing every reader through `fencedPaths()` rather than a literal.

The section is kept in full rather than trimmed to a line, because **it was
written independently of the fix and reached the same two moves**, and because
the argument below is the durable part: the reasoning is what tells the next
person why a fence follows a permission when a store is deleted, rather than
staying where the store used to be.

It was found last, and not because it is the softest.

§0.3 put the link store inside the records fence for one reason, stated there:
*the store that holds the permission would be writable by the party the
permission is about.* That reason has not weakened by a word. What changed is
**which file holds the permission.**

With `copilot.connect` gone there is no link store. The file that decides whether
a device reaches the copilot is `<userData>/remote/remote-device-kinds.json`, and
today it is **not fenced**: `fencedPaths()` returns `routines`, `routineState`,
`log`, `remoteCopilot` and `remoteAuth`, and the kinds file is not among them —
because when that list was written a kind decided *folders* and the copilot was
decided somewhere else entirely.

Two moves, and they are really one move:

**1. `paths.remoteDeviceKinds` joins the fence**, with `recordsFenceAgrees`
called from the side that owns the path — `device-kind.test.ts` — which is the
pattern `copilot-link.test.ts` established and the reason that function exists: a
fence over a path spelled in two places is a fence over whichever spelling nobody
changed. The assertion has to move with the store, or it is deleted along with
it and the lesson goes too.

Note how much heavier this is than the version it replaces. Under the old model
the worst a hand-edit could do was bounded, and §0.3 says by what: `load()`
dropped any record with no credential, so the copilot could not *mint* a
connection, only raise the tiers of one somebody had already made. **There is no
credential any more, so there is nothing left for it to fail to forge.** One line
appended to a JSON file by an agent that has `Write` promotes a guest to *my
device*: no tool call, no confirmation, no log row, and no code typed by anybody.
The fence is not defence in depth here. It is the only thing standing between an
unconfined agent and its own promotion.

**2. `paths.remoteCopilot` comes out, when the store goes.** This file already
records what happens if it does not — *"the fence went on naming the old path for
a while after the rename because nothing pinned the spelling — a Seatbelt rule
over a path nothing writes refuses nothing, silently."* A deny left standing over
a deleted store is that same defect wearing the appearance of a protection, and
it is worse than the first instance, because it would sit in `fencedPaths()`
being counted by everything that shows a person what is protected.

And one thing that is genuinely better, worth saying because it is the half that
needs no work: **the two failure directions agree.** The fence stops the file
being *rewritten*; `device-kind.ts` fails closed, so a file the copilot
*destroyed* demotes every device to guest rather than promoting one. Neither
substitutes for the other and both are needed — something that cannot write can
still delete, and a fail-closed read is what makes deletion a refusal instead of
a grant.

---

## 1. The phone talks to a copilot **run**, not to the copilot's keyboard

This is the decision everything else hangs off, so it is argued rather than
asserted.

### The two candidates

**(a) One conversation.** The phone's messages go into the copilot session that
is pinned in the sidebar. He sees on his Mac what he asked from the sofa. One
agent, one transcript, one bill.

**(b) One run per device.** A `copilot.attach` from one of his devices starts a
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

Advertised when the host has a `DeckControl` and a session layer that can start a
session — read off the injected objects, never a constant, for the reason the
existing filter gives: an advertisement must not outlive the thing it advertises.

Per-device, in `welcome` and as the answer to `copilot.hello` / `copilot.bye`:

    | { t: 'welcome'; …; copilot?: CopilotLinkWire }
    | { t: 'copilot.grant'; link: CopilotLinkWire }

    interface CopilotLinkWire {
      linked: boolean            // always true when the key is present; see below
      open: boolean              // *this socket* has asked for the copilot surface
      grant: { read: boolean; act: boolean; alter: boolean }
    }

**The key's presence is the authorisation, and it is the only thing a client may
branch on.** `welcome.copilot` is there if and only if this host has a copilot
*and* this device's kind is `mine`. A guest gets **no key at all** — absent, not
`linked: false` — and that distinction is deliberate rather than economical.
`device-kind.ts` gives the reason and it is his: *"a guest is never offered the
copilot — not offered and defaulted off, **absent** — because an unchecked box
still advertises a feature and invites the ask, and the answer to the ask is
always no."* A field saying `linked: false` is that unchecked box on the wire. A
guest client draws no Copilot tab because it was never told there is one, and
there is no refusal for it to measure the shape of.

**`linked` survives as a field that can no longer be false.** Keeping the shape
costs one boolean and moves nothing; changing it moves three client validators
and buys nothing. But say plainly what it now is, because a field that is always
true looks like a check while testing a constant: **a client that branches on
`linked` is testing nothing and will look correct while doing so.** Branch on the
key. `linked` is there so the shape did not have to change on the day the
ceremony was deleted, and the day it is removed is a protocol-version day, not a
Tuesday.

**`open` survives and now means something different from what it used to.** It
used to say *this socket has presented the credential*, which was authorisation.
There is no credential. It now says *this socket is on the copilot surface* —
presence, not proof — and that is still a real thing to track, for three reasons
that all outlive the credential: a device can have several sockets (the app open
in two places, §4.5, where the run survives until the **last** one goes);
`copilot.bye` has to mean something for a person putting the copilot away on a
screen other people can see; and the desktop has to know which sockets a
`copilot.ask` is for. **`open` is still false on every `welcome`, always** — a
socket is joined, not a device.

Do not fold `copilot.hello` into `copilot.attach`, which is the tidy-up somebody
will propose the moment the credential is gone. They are two different questions
and they are answered at different times: `hello` is **presence** — this socket
is on the surface, and copilot verbs are served on it — and `attach` is
**streaming**, the one that opens the firehose and replays a conversation. A
client can be present and not streaming, which is what a Copilot tab looks like
in the background, and merging them would mean either paying for a replay to send
a `copilot.state`, or making `bye` mean two things at once.

`grant` for a `mine` device is `{ read: true, act: true, alter: true }`, and
there is nothing that makes it anything else: the per-device tier switch is gone
with the panel. The three booleans stay on the wire anyway, and the reason is
about the shape of the clients rather than about today's values — a client that
draws its controls from *what the host granted* is a client that stays correct in
front of a host that refuses something, and a client that draws them from *I am
his device so I have everything* has hard-coded an inference at the point where
the host is the authority. The tiers themselves did not stop existing; they
stopped being variable. `DeckControl.call` still checks one per call, which is
where a tier is a tier (§3).

`alter` **is** on the wire, and used to be deliberately absent — see the revision
notes at the top. Its absence was three independent refusals guarding a tier
whose safety property was *a human at the machine says yes*; that property is now
guarded by the pairing.

`copilot.grant` is no longer *pushed*. It used to arrive whenever the panel
changed, so a disconnected device's Copilot tab could go away without a
reconnect; there is no panel and nothing that can change. Its remaining job is to
be the answer to `copilot.hello` and to `copilot.bye`, carrying `open` true or
false, so a client has one frame to react to and one shape to read whatever it
just did. A device's copilot standing is decided at pairing and can only end by
the pairing ending — which needs no frame, because it takes the socket with it.

### Client → desktop

Two frames carry **no tier**, and the reason has changed even though the list has
only shortened. It used to be that they *were* the authorisation, so requiring a
tier to send the frame that establishes the connection would have meant no device
could ever connect. Nothing is established now: they carry no tier because they
**ask for nothing** — one says *start sending me the copilot surface*, the other
says *stop* — and neither reaches a tool, spends a penny or changes anything on
this machine. `COPILOT_UNTIERED_FRAMES` still names them so the set is checkable,
and `copilot-frames.test.ts` still asserts the two lists together cover every
`copilot.*` client verb, so a verb added to neither fails the suite.
**`copilot.connect` must not reappear in either list**, because it must not
reappear at all.

| Frame | Tier | What it is |
|---|---|---|
| `{ t: 'copilot.hello' }` | — | Put this socket on the copilot surface, so copilot verbs are served on it. It carries nothing, because there is nothing left to present: the socket has already proved which device it is, and the desktop already knows that device's kind. Required after every reconnect — a socket is joined, not a device. Answered with `copilot.grant`. Presence, not streaming; `copilot.attach` is the one that sends anything. |
| `{ t: 'copilot.bye' }` | — | Leave it, on this socket. Nothing is revoked and nothing is forgotten: this is a person putting the copilot away on a screen somebody else can see, not an authorisation ending. |
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

`copilot.say` is `act` and not `read`, and the line is still worth defending even
though nothing on the wire currently holds one without the other. Talking to the
copilot *is* `sessions.send` against a session — the tool `surface.ts` classifies
as `act` — and it spends money and causes tool calls, so it does not belong on
the same side of a line as watching.

The line used to be the product: a device could be connected read-only, and
*watching* was the grant worth handing out first. That shape is gone with the
per-device tiers (§6.3 counts it as a cost). What the classification still buys
is that the tier a frame declares matches what the frame actually does, which is
the thing `DeckControl.call` checks per call and the thing that has to stay true
for any of §3 to mean anything. A verb misfiled as `read` is a hole the day
anything narrows again, and it is a lie about spending money today.

### Desktop → client

| Frame | What it is |
|---|---|
| `{ t: 'copilot.state'; state: … }` | Answer, and pushed on change. |
| `{ t: 'copilot.chat'; run: string; messages: ChatMessage[]; reset?: true }` | The conversation, as **parsed messages**, never pty bytes. Merge by `message.id`, replace on a match, append otherwise; `reset` means drop everything and take this as the whole conversation. Same contract as `ChatUpdate` in `chat-transcript.ts`, and produced by the same parser — one parser, one truth, and no ANSI on a phone. `run` is carried so a frame from a previous run is dropped rather than merged into the new one. |
| `{ t: 'copilot.tool'; row: ActionRow }` | One tool call as it happens, already through `scrubArgs`. This is *"see what it is doing"*, and it is the frame that makes a refusal visible: a call the phone's grant did not cover arrives here with `outcome: 'refused'` and `refusal: 'not-granted'`, in the copilot's own words. |
| `{ t: 'copilot.sessions'; sessions: … }` | Answer, and pushed when the set changes. |
| `{ t: 'copilot.log'; rows: ActionRow[]; more: boolean }` | Answer only. `more` says the tail was bounded, in the same spirit `ToolTrail.partial` reports its own window. |
| `{ t: 'copilot.pending'; questions: … }` | Answer, and pushed when the pending set changes. |
| `{ t: 'copilot.grant'; link: … }` | Above. The answer to `copilot.hello` and to `copilot.bye`, and nothing pushes it any more. |
| `{ t: 'copilot.ask'; question }` | A confirmation **this** connection may answer, with the tool, the tier, the desktop's own summary, the origin, the countdown and **every argument verbatim**. Sent only to the surface that owns the run that raised it. |
| `{ t: 'copilot.settled'; settled }` | A question closed, and `by` — where it was answered. Sent to every connection that was told about it, including the one that answered. |

Refusals reuse the existing `error` frame: `unauthorized` for any `copilot.*`
verb from a guest, `unavailable` for a copilot that cannot start (no CLI, not
signed in). No new error code and no new denial vocabulary — `PROTOCOL_ERROR_CODES`
already carries the distinction between "you may not" and "it broke", and three
clients already validate against it.

There used to be a third sentence here, and it is worth recording that it went:
the old design distinguished *this device is not connected* from *you do not have
enough access*, because they had two different remedies and sending somebody
after the wrong one wastes their evening. A guest has neither remedy — there is
no checkbox to find and no code to ask for, and the only thing that would change
the answer is being paired again as one of his devices. So the two sentences
collapse into one honest one, and that collapse is a feature of the simpler model
rather than a loss.

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
being no tool to name. Every device that reaches the copilot now holds `alter`,
and the property is unchanged and worth **more** rather than less, because it is
what the model rests on once the tiers stop varying: a device holding every tier
still **cannot name a call**. It can say a sentence, and it can decide about a call the desktop
composed — `copilot.answer` carries a question id and a boolean, and the tool,
the arguments and the effect were all decided on this machine before anybody was
asked anything. Every other design has to enumerate and deny; this one has
nothing to enumerate.

It is also the rule that will be under pressure. The first person who wants
`copilot.tool` for a nice phone UI ("tap to re-run that") should be pointed here.

### Deliberately absent

- **A tool name, in any direction a client can send.** Above.
- **The desktop copilot's conversation.** A device sees what the copilot *did* —
  state, tool rows, sessions, log — and its own run's chat. It does not get the
  text of the conversation happening at the desk, and this is the one exclusion
  the 08-19 simplification did **not** relax: *"it's you at another keyboard"* is
  an argument about permission, not about a second person's screen showing a
  conversation somebody is still having. That conversation is him thinking out
  loud and there is no reason for it to cross a relay; the question the read
  frames answer is *"what is my copilot doing"*, and the tool rows answer it.
- **Anything that edits `CLAUDE.md`, `memory/` or a routine.** §5.
- **A raw pty stream for the copilot run.** §5.
- **`resume`.** Same argument `create` makes, one level up: continuity is
  `memory/`.

---

## 3. The grant, enforced

Three layers. Only the second is the boundary, and saying which is which is most
of the value of this section.

### Layer 1 — the transport, and what it is not

`server.ts` refuses every `copilot.*` frame from a guest, including the untiered
ones, and serves the whole surface to one of his devices: `read` is the floor,
and `copilot.start` / `say` / `cancel` / `stop` additionally need `act`, both of
which a `mine` device holds. **The kind is read per message** — never cached at
hello, never latched at the socket — exactly as `folders()` is read per `create`,
and for the same reason: the thing a person changed at this keyboard has to land
on the *next* frame rather than the next reconnect. That property used to belong
to the link store and it moves to `DeviceKinds` unchanged.

**This layer exists to keep the UI honest, not to be the boundary.** It is the
same argument `control.ts` makes about itself: *"a rule enforced in one transport
is a rule the next transport does not have."* If it were the only check, a second
way in — a future desktop-to-desktop guest path, a debug endpoint, a test harness
— would arrive with no gate on it. It is here so a guest sees no Copilot tab and
gets a clean refusal if it sends one anyway, and for no other reason.

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

The entry stores the **device id, not the tiers**, and that has survived the
simplification even though the tiers are now a constant. The `Caller` is built
per request through the one function that exists for it, `remoteCopilotCaller`,
which re-reads the device's kind every time. Storing `ALL_TIERS` in the table at
mint time would be the same object with the check deleted — and it would be a
cache of a permission, which is the thing this whole file keeps refusing to hold.
Revoking a device has to land on the *next tool call*, not on the next reconnect,
and it only does that if something re-reads.

`remoteCopilotCaller` is the single seam. `reachable.test.ts`'s
`KNOWN_UNREACHABLE` entry predicted this and asked for exactly one import rather
than a hand-assembled `Caller` with `ALL_TIERS` in it. Honour that, and honour it
harder now that a hand-assembled one would happen to be *correct today*: a
literal that is right by coincidence is the one nobody revisits.

### Revocation — and there is only one thing left to revoke

**Revoking the device is the only revocation, and that is a real cost, said
here where somebody will come looking for it.** There used to be two acts and
neither implied the other: a person could take the copilot away from a phone and
leave it every terminal it was paired for. That is gone. A device is one of his
or it is a guest, the kind was written once, and `device-kind.ts` deliberately
has no method that overwrites one — so the only way to stop one of his own
devices reaching the copilot is `forget()` plus revoking the pairing.

Is that acceptable? Yes, and for a reason rather than a shrug. The device it
would ever be exercised against is *his own*, because that is the only kind that
has the copilot at all. The scenario is a phone that is lost, sold or handed on
— and on that day the correct action is revoke, not narrow: leaving it terminals
while taking away the copilot is leaving somebody a shell on this machine. The
state the simplification removes is the one he actually hit and read as a bug:
paired as his own, and refused by the copilot.

What must **not** be built back as a convenience is a control that changes a
device's kind in place. §6, and `device-kind.ts` says why in one line: *an
escalation that needs no second act is not an escalation, it is a default with a
delay on it.*

Revoking a device must do five things in this order:

1. Write the stores — `DeviceAuth`'s revoke and `DeviceKinds.forget`. Everything
   else is downstream of the disk, for the reason `commit()` gives: a permission
   that reverts *up* at the next launch is worse than one that reverts down.
   `forget()` is garbage collection rather than a cascade — revocation is
   permanent and a returning phone pairs again with a **new** device id, so the
   row could never be reached by anything and the file would only ever grow.
2. Withdraw every confirmation that device raised, as `caller-gone`. A device
   whose access just ended must not be left holding a dialog it may no longer
   answer.
3. Drop that run's token from the table. In-flight tool calls abort with
   `caller-gone`; the signal for that is held per token entry (§4).
4. Stop the run.
5. Close the copilot surface on every live socket of that device. This step used
   to also push `copilot.grant` with `linked: false`, so a device could be told
   the copilot had gone while its session channel stayed up. **There is no such
   state now** — the pairing and the copilot end together and the socket ends
   with them, which is why the frame is no longer pushed (§2).

Step 1 alone is already sufficient for correctness, because the kind is read per
frame and per call. Steps 2–5 are what stop a revoked device from watching a
conversation it can no longer influence, or answering a question it can no longer
be trusted with, in the seconds before its socket notices.

### Proof obligations

Written as tests, because this repository's convention is that a rule with no
test is a comment:

- **A guest reaches nothing, and is told nothing.** Every tool, *including the
  read ones*, is `not-granted` for a guest; every `copilot.*` frame, **including
  the untiered ones**, is refused over a real socket; and its `welcome` carries
  no `copilot` key at all. That last clause is the one to write carefully,
  because it is the assertion that pins *absent, not false* — a test that only
  checks `linked === false` would pass against the shape this revision exists to
  delete. `copilot-enforcement.test.ts` and `server.test.ts`. This is the
  headline obligation.
- **There is no second door, because there is no second store.** Nothing outside
  the approval flow can make a device `mine`: `claim()` writes once and refuses a
  different kind, there is no overwrite method, `settings.write` refuses the
  `remote.` prefix, and the kinds file is inside the records fence (§0.5).
  `device-kind.test.ts`, and a fence test called from the side that owns the
  path.
- **`copilot.connect` is not a verb.** A corpus test over `protocol.ts`: no
  `ClientMessage` variant is named `copilot.connect`, and no `copilot.*` client
  frame carries a field named `code` or `credential`. Same shape as
  `wire-wording.test.ts`. A deleted verb a client can still send is not deleted,
  and this is the assertion that keeps it deleted through the next person who
  finds the old spec and thinks it was an oversight.
- **Table-driven over the whole catalogue.** For a guest caller, every tool in
  `buildCatalogue()` returns `not-granted`. Driving it off the catalogue rather
  than a list means a tool added next month is covered the day it is added. And
  the inverse: one of his devices reaches an alter tool *through the gate*, so
  the file distinguishes "the boundary holds" from "the feature is broken".
- **Escalation.** `sessions.send` from a device: allowed against a session its
  own run started, escalated to `alter` and therefore confirmed against one it
  did not — and refused outright for a guest, one check earlier.
- **Hidden pty.** The copilot session id and every run id are absent from
  `SessionFanout.list()`, and `attach` returns null for them.
- **Revocation without restart.** After revoking the device, the very next MCP
  call on that run's live token is `not-granted` — proved on the *token*, not by
  waiting for the socket to close, because the socket closing is the thing that
  would hide a missing re-read.
- **A frame a device should not be able to send.** One of his devices answering
  *another* device's question is refused, and told the same thing a settled
  question would tell it. `copilot-answer.test.ts`, `server.test.ts`.
- **No tool names on the wire.** A corpus test over `protocol.ts` asserting that
  no `ClientMessage` variant carries a field whose value is a tool id — the same
  shape `wire-wording.test.ts` and `reachable.test.ts` already use to pin a
  property that is about text rather than types.

---

## 4. Consent from one of his devices

**Rewritten 2026-08-17, amended 2026-08-19.** What this section used to say is at
the end of it, under §4.8, unedited — the argument was good, and a file that
quietly deletes the reasoning it superseded leaves the next person to rediscover
it from scratch. The 2026-08-19 amendment changes *what the authorisation is* and
nothing else: every mechanism below — who is asked, who may answer which
question, what they must be shown, what happens when nobody answers — is
unchanged, because none of it ever depended on the shape of the ceremony.

The hard one, and the answer has four parts because there are four different
questions hiding in it: who may be asked, who may answer *which* question, what
they have to be shown in order to answer honestly, and what happens when nobody
answers at all.

### 4.1 A device-originated alter request now exists, and the dialog goes to it

There is no clamp and no scrub. One of his own devices holds all three tiers; a
guest holds none, and is refused one check earlier than any of this.

**Where does the prompt appear when the request came from a device? On that
device, and on the desktop, at the same time.** `DeckControl.call` reaches the
broker with `origin: 'device:<id>'`; `deck-control/index.ts` fans the question
out to both surfaces; first answer wins.

What makes this honest rather than a ceremony is not that the device is trusted
in general. It is that **being one of his devices is an act of authorisation
performed at this keyboard**, and a device cannot perform it for itself. The old
argument — *a dialog answered on the device that raised the request is answered
by the party being confirmed* — assumed the second factor was being at the desk.
It was not: it was holding an authorisation you did not already have.

**Amended 2026-08-19.** Between 08-17 and 08-19 that authorisation was a separate
copilot connection. It is now the device kind, and the argument is *stronger*
rather than weaker, which is worth showing rather than asserting. Both are minted
at this machine and neither can be self-granted. But a copilot connection was
revocable in place and could be narrowed with checkboxes, which meant the
authorisation was a **setting**; a kind is written once, has no overwrite method,
and can only be changed by revoking and pairing again. Set against rule 2's own
words — *conflating a durable power with a live act is how a permission becomes a
setting* — the thing that replaced the connection is the one that is not a
setting.

The tier is still a tier and `DeckControl.call` still checks one per call. What
is gone is the *variable* — there is no longer a way to have a device of his own
that may watch but not work, or work but not change. He asked for that
explicitly: *"if we are connecting as my device copilot automatically comes."*
The narrower shapes belonged to a world where a phone might be half-trusted, and
this model has no half — the half is called a guest and it has no copilot at
all.

### 4.2 The race, and the rule that is not obvious

Both surfaces are asked, so both can answer, and the machinery for that already
existed:

- `respond()` returns false for an id that has been settled, so the race needs no
  lock — it needs both surfaces to have been asked.
- `ConsentBrokerOptions.settled` notifies every surface when a question closes.
- `ConsentGranted.by` is a string: `'window'` for the desktop, `device:<id>` for
  a device.

First answer wins. The other surface **withdraws its dialog saying where it was
answered** — `copilot.settled` carries `by`, and `settledSentence` on the desktop
names the other surface. A dialog that vanishes on its own teaches a person that
the app does things behind their back. And the log records which: `confirmed.by`
is `device:<id>`, and `detailFor` writes a device sentence rather than *— allowed
by the person*. Those must never read the same.

> **The words are owed a change, 2026-08-19.** Both strings currently say
> *"allowed on a connected device"*, and "connected" was the name of a ceremony
> that no longer exists — a person reading it in the log will go looking for a
> connection they can inspect or revoke and find nothing. The replacement should
> say whose device it was and nothing about connecting: **"allowed on another of
> your devices"**. It stays different from *allowed by the person* in the one
> way that matters, which is *which screen was it answered on*, and it stays true
> of the only device that can ever answer. This is a source change in
> `settledSentence` and `detailFor`, and it is listed as owed rather than done.

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
- **The device leaves the copilot surface mid-prompt** — `copilot.bye`, or its
  last socket dropping. Refused at once, with `caller-gone`. Not left for the
  desktop to answer, even though the desktop may answer anything: the run that
  asked is about to be reaped, the person who asked is gone, and an approval
  landing afterwards is a change nobody is waiting for. `server.ts` calls
  `CopilotRemote.closed` when the **last** open socket of that device goes — a
  phone with the app open in two places has not stopped watching because one of
  them closed, and that is the whole reason `open` is still tracked per socket
  now that it proves nothing (§2).
- **A call in flight from the device's run.** The run's tool calls carry an
  `AbortSignal` held on the token-table entry; revoking the device aborts it and
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

The first is superseded — by the separate connection on 08-17, and by the device
kind on 08-19, which is the same supersession twice: what refutes it is that
*being able to reach the copilot at all* is an authorisation minted at this
machine, and the phone did not hold it before somebody at this keyboard said so.
The second is *not* superseded by anything and is why §4.6 exists. The push
limitation is real, and it means this feature is worth exactly what it is worth
when somebody is already holding the device — which, for a person who reaches for
their phone to check on a build, is most of the time it matters.

---

## 5. What one of his devices must never do

Twelve, each with the argument. Three carry a revision note; the other nine are
unchanged and are pinned by tests. The list is written against a device of his
own, because a guest never gets far enough for any of it to be the operative
refusal — rule 12 is what stops a guest, and it stops it before the first frame.

**1. Name a tool.** §2. It is the property that makes the enforcement airtight
rather than exhaustive, and the first convenience feature that breaks it —
"tap to re-run" — breaks all of it.

**2. ~~Hold `alter` (v1).~~ ~~REVISED — hold `alter` without a separate
connection.~~ REVISED AGAIN — hold `alter` as a guest.** §4. The original rule
read: *a standing grant of alter is a durable power that survives the device
being lost, stolen, handed over, or restored from a backup onto someone else's
hardware; a per-call confirmation is a live act by a present human; conflating
them is how a permission becomes a setting.*

That is still true, and the answer to it is unchanged: a device holding `alter`
does not skip the confirmation — it **receives** it. Nothing is pre-authorised.
Every alter call still draws a question, still expires into a refusal, still
writes a row naming who answered. What the tier decides is which screen the
question appears on.

The durable half of the objection — lost, stolen, restored onto somebody else's
hardware — used to be answered by the connection being separately revocable. It
is now answered by the **device** being revocable, which is a blunter instrument
and worth naming as such: the remedy for a lost phone is revoke the phone, not
narrow it. §3 argues that this is the right remedy rather than merely the only
one left, and the argument is short — a phone you no longer control should not
keep a shell on this machine either.

**3. Attach to any copilot pty, including its own run's.** The phone gets parsed
`ChatMessage`s, never bytes. Raw pty access is a keyboard, and a keyboard on a
Claude CLI with Bash is the whole machine — every tier check in this document sits
above that layer, not below it. It is also why §0.1 is blocking rather than
tidying.

**4. ~~Answer an alter confirmation.~~ REVISED — answer *another surface's*
confirmation.** §4.2. One of his devices answers its own run's questions and
nothing else. The desktop answers anything, because somebody
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

**9. Change any grant, or make a device one of his, by any path.** Four doors,
all shut: `settings.write` refuses the `remote.` and `copilot.` prefixes; the
copilot's own `Write` tool is kept off `remote-device-kinds.json` and
`remote-auth.json` by the records fence (§0.5 — the kinds file is the one that
still has to be added, and it is blocking); `DeviceKinds.claim` writes once and
refuses a different kind, with no method anywhere that overwrites one; and
`kindOf` fails closed, so a file the copilot managed to corrupt demotes every
device rather than promoting one. **The approval screen at this keyboard is the
only door**, which is what `notGrantedSentence` already tells the model.

This rule got *sharper* on 2026-08-19 rather than softer, and the reason is worth
holding on to: under the separate connection an edited store could only widen a
connection somebody had already made, because a record with no credential was
dropped on load. There is no credential now, so an edit is not a step towards the
authorisation — it **is** the authorisation. Which is exactly why §0.5 is
blocking.

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

**12. ~~Reach the copilot at all without a connection.~~ REVISED — reach the
copilot at all as a guest.** It is the rule that subsumes half the list. A guest
that has been paired, approved and given folders gets `unauthorized` for every
`copilot.*` frame, **including the untiered ones**, and its `welcome` carries no
`copilot` key at all. There is no frame it can send that measures anything about
the copilot: not whether one is running, not how many confirmations are waiting,
not whether some grant it does not have would have been enough. And it is not
told the copilot exists, which is the half that is easy to drop while keeping the
refusals — *"the copilot is never shared"* is a promise about the guest's screen
as much as about the guest's reach.

---

## 6. Where the decision is made

**Revised again 2026-08-19.** This section has now been rewritten twice, in
opposite directions, and both rewrites are kept: the version from 08-17 is at
§6.6, unedited, because the next person to want a copilot code needs to find out
that it was built and deleted rather than that nobody thought of it.

Copilot access was, in order: *a checkbox beside an already-paired device*, then
*a separate connection with its own six-digit code, credential, record and
revoke*, and now **nothing of its own at all**. It is a consequence of the one
choice a person already makes about a device, on the screen where they already
make it.

### 6.1 The ceremony, and there is only one

1. Somebody at this machine shows a pairing code, the same six digits
   `device-auth.ts` has always minted. Nothing here changes pairing.
2. The device types it and appears as pending.
3. The approval screen asks the one question, and this is the whole of it:

   > **My device** — Full access. It's you at another keyboard.
   >
   > **Guest** — You choose what they can reach. The copilot is never shared.

4. **My device** → `DeviceKinds.claim(id, 'mine')`, and from the next frame that
   device's `welcome` carries the `copilot` key. **Guest** → `claim(id, 'guest')`
   and it never does.

That is it. No second code, no second credential, no second screen, and no state
in between. A device is approved and the copilot is there, or it is approved as a
guest and there is nothing to be there.

### 6.2 Why the approval screen is enough, when a whole ceremony was not

The 08-17 argument identified the property correctly and then built a second
mechanism to hold it. Hold the property up against the screen instead:

**It is minted here.** The choice is made by a person at this keyboard, on this
machine, looking at a screen that says what each answer hands over. That is
exactly what §6.6 wanted from *"the person minting it is standing here, looking
at a screen that says what they are about to hand over"* — the sentence is
already true of the approval screen, and it was true before any of this was
built.

**It is proved at the other end.** The six digits typed into the phone are the
pairing code, and the kind is chosen against that pairing while it is happening.
Two parties, two acts, one ceremony.

**The device cannot give it to itself.** `claim()` is reached from the approval
flow in the main process. No frame reaches it, no settings write reaches it, and
the file it writes is fenced (§0.5).

**It cannot be changed afterwards without doing it all again.** This is the one
the second code did *worse*, not better, and it is the argument that decides the
section. A copilot connection was revocable in place and narrowable with
checkboxes — an authorisation that is also a setting. `claim()` writes once, a
second call with a different kind is refused, and the module says why: *"a toggle
would make the distinction one tap deep… an escalation that needs no second act
is not an escalation, it is a default with a delay on it."* The remedy for a
wrong choice is `forget()` and pairing again, which is the same two acts that
decided it the first time.

So the second code proved a fact that was already proved, by a mechanism with a
weaker durability property than the one it was layered on top of. What it cost is
easy to enumerate because it is all deleted: a screen, a credential, a store, a
revoke path, four wire frames, a settings panel, and one product state — *paired
as his own device, and told by the copilot to connect* — which is the shape this
repository has spent weeks removing everywhere else.

### 6.3 What this costs, stated where somebody will look for it

Not free, and the honest accounting is three lines:

- **One press is the whole decision.** *My device* reaches an agent that holds
  this machine's shell, at the alter tier, answering its own confirmations. There
  is no second gate behind it. The screen is the permission dialog now, and its
  wording is load-bearing rather than descriptive — softening either sentence
  into product copy is a change to the permission model.
- **There is no half-trust for a device of his own.** Watch-only is gone; so is
  work-but-do-not-change. If somebody wants a phone that may only watch, the
  answer today is *guest*, which means no copilot at all. That is a real
  reduction and it is what he asked for.
- **The only correction is revoke and pair again.** Deliberate — see the toggle
  argument above — but it means a mis-tap on the approval screen is fixed at this
  keyboard rather than in place, and the screen should be laid out knowing that.

### 6.4 What is in the settings panel now

Under the device card, where the folders are — `RemoteSection` — and it is **not
a control**. A device of his own gets a line of text:

> **Your copilot** — this device can use it, because it is one of yours.

and a guest gets nothing at all: no row, no greyed switch, no explanatory
sentence about a feature it does not have. That absence is the same rule
`device-kind.ts` states and rule 12 enforces, applied to the desktop's own
screen: an unchecked box still advertises the feature, and a person looking at
somebody else's phone in this list should not be given something to wonder about.

Three things this panel must never grow, and each one has already been argued
somewhere above:

- **A tier checkbox.** There are no per-device tiers. A control that always sets
  the same value is the defect this repository has paid for twice.
- **A copilot Disconnect.** There is nothing to disconnect; the button would have
  to either lie or revoke the pairing under a name that does not say so.
- **A kind toggle.** §6.2. Re-pairing is the mechanism, and the screen says so
  plainly rather than hiding a control it would refuse.

There is exactly one call site of `DeviceKinds.claim` today — the approval flow
in `server.ts` — and that is what makes "the approval screen is the only door"
a fact rather than an intention. Anything that adds a second call site is adding
a second door, and there is one such thing already half-promised: see §6.5.

### 6.5 What did not change

- **A paired desktop is a device too.** `machines/guest.ts` pairs Macs and
  Windows boxes to each other and they hold device ids like any phone. Same
  question on approval, same two answers. A desktop somebody else owns is a
  guest, and the word does the work.
- **Preconditions.** The device is `approved` and has a key fingerprint. A device
  paired before sealed channels has no static key and cannot open a sealed
  channel at all — this is now automatic rather than a precondition on drawing a
  control, because there is no control to draw.
- **Devices paired before kinds existed are guests.** `kindOf` fails closed, and
  `device-kind.ts` already accounts for the regression: those devices can start
  nothing until somebody chooses for them, the desktop names them, and the
  refusal says which machine to go and fix it on. That cost was accepted when
  kinds shipped, and this revision adds the copilot to the list of things such a
  device does not have until somebody chooses.

  **But the mitigation it names — *"the desktop names those devices and offers
  the choice in one press"* — is not built.** `claim` has one call site and it is
  the approval flow; there is nothing in `RemoteSection.tsx` that chooses a kind
  for an already-paired device. Today the remedy is re-pairing, which works and
  is honest. If the one-press chooser is built, it is now **a control that hands
  over the copilot**, and three constraints come with it that did not apply when
  it was only about folders: it may appear only for a device with **no** record,
  never beside one that has a kind, because `claim` refuses a change and a
  control that is refused is the defect this file keeps naming; it must carry the
  approval screen's two sentences verbatim rather than a shorter label, because
  it is now making the same decision; and it must not be reachable for a device
  whose record says `guest`, or it is the toggle under another name.

### 6.6 What this section said on 2026-08-17, unedited

Kept for the same reason §4.8 is kept: the argument is good, the code it
describes is what several tests were written against, and somebody will one day
propose exactly it again. The parts that matter:

> **Revised 2026-08-17.** Copilot access used to be *a separate, off-by-default
> capability on an already-paired device* — a checkbox. It is a **separate
> connection**: its own six-digit code, its own credential, its own record, its
> own revoke.
>
> 1. Somebody at this machine opens Settings → Remote, finds the device, and
>    presses **Connect the copilot…**. That mints a six-digit code — sixty
>    seconds, single use, five wrong guesses and the code itself is dead — and
>    decides there and then what it grants.
> 2. The code is read out and typed into the device, which sends
>    `copilot.connect` on its **already-authenticated sealed channel** — so the
>    device id is a fact rather than a claim, and the code is the second thing
>    being proved.
> 3. The desktop answers `copilot.linked` once, with a 32-byte credential stored
>    here as a scrypt hash. There is no path that shows it again.
> 4. Every socket that device opens from then on sends `copilot.hello` with that
>    credential before any `copilot.*` verb is served. **On every reconnect.** A
>    session channel does not carry the copilot by existing.
>
> The tiers travel with the *code* rather than being ticked afterwards, and that
> is the whole ceremony: the person minting it is standing here, looking at a
> screen that says what they are about to hand over.
>
> **Why the credential carries no device id.** `device-auth.ts` mints
> `"<id>.<secret>"` because a session credential arrives on an anonymous socket
> and has to say who it is. This one arrives on a socket that has already proved
> which device it is, so an id would be a field nobody reads.
>
> ☐ **Watch the copilot** — see what it is doing, what it started, and what it
> was refused. (`read`) · ☐ **Ask it to work** — talk to it, and let it start and
> steer sessions on your behalf. **This spends money.** (`act`) · ☐ **Change
> settings and stop your sessions** — every change is still confirmed one at a
> time, but the confirmation appears *on that device*. (`alter`)

Three things in it are still true and were carried forward rather than dropped,
which is worth saying so nobody restores the whole section to recover them: the
copilot's own reasoning must never be handed to a device that has not been
authorised for it; the third checkbox's label was right that *what changes is
which screen the question is drawn on*, and that sentence now belongs to the
approval screen; and **do not build the panel before the transport** —
`reachable.test.ts` warned that *"a switch in the devices panel granting a phone
read or act would be a permission control that changes nothing a phone can do"*.
This revision honours that warning by having no switch at all.

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
6. **A device with no static key.** §6.5. No key, no channel, and therefore no
   copilot — which needs no control to withhold now, because there is no control.
   A device that cannot open a sealed channel never reaches a `welcome` to be
   given a `copilot` key in.

### What sealing does not hide, said plainly

The relay learns *when* a copilot conversation is happening, roughly how much is
said, and that a device is attached. That is traffic analysis and it is not fixed
here. No padding is proposed: the session streams already leak the same shape, and
padding a chat stream costs continuously to hide something an observer can mostly
infer from the fact that a channel is open at all. It is a limitation to write
down, not one to pretend away.

---

## 8. Order, and what I would not build

**Revised again 2026-08-19.** The sequencing question this section closed with
was answered by him rather than by shipping — twice. First `read` alone was not
what he meant; then the separate connection was not either.

Where it stands:

1. ✅ **§0.1** — the copilot's pty is off the session fanout, pinned by
   `copilot-off-the-network.test.ts` against the real core and four cases in
   `server.test.ts`.
2. ✅ **§0.2 and §0.3** — `ToolContext` carries the caller, and the remote stores
   that existed at the time are in the records fence.
3. ✅ **The capability, the copilot key in `welcome`, the token table, the read
   frames.**
4. ✅ **The act tier** — `start`, `say`, `cancel`, `stop`, per-device runs.
5. ✅ **Consent from a device** — `copilot.ask` / `answer` / `settled`, the
   ownership rule in the broker, the log row that says where it was answered.
6. ⛔️ **The separate connection** — `copilot.connect`, `copilot-link.ts`, the
   credential, the panel. Built 08-17, **deleted 08-19**. Listed rather than
   erased so nobody spends an afternoon working out whether it was ever there.
7. 🔄 **The kind decides it** — `welcome.copilot` present only for a `mine`
   device, `copilot.hello` carrying nothing, every `copilot.*` frame refused for
   a guest.

**Owed on the desktop, and the first one is blocking:**

- **§0.5 — `remote-device-kinds.json` joins the records fence, and
  `paths.remoteCopilot` leaves it.** The file that decides copilot access is
  writable by the copilot until this lands, and an edit to it is now the whole
  authorisation rather than a step towards one.
- **The two settled sentences.** §4.2 — *"allowed on a connected device"* names
  a ceremony that no longer exists, and somebody reading it in the log will go
  looking for a connection to inspect.
- **A test that a guest's `welcome` carries no `copilot` key.** §3. Not that it
  carries `linked: false` — that is the shape being deleted, and a test written
  against it would pass while the property was broken.
- **Per-caller budgets (§0.4)**, a fairness property rather than a security one,
  still three lines.

And one thing that is *not* owed and should stay unbuilt unless he asks: the
one-press kind chooser for devices paired before kinds existed (§6.5). It was a
mitigation for a folder regression; it is now a second door onto the copilot, and
re-pairing already works.

### What I would not build

- **`copilot.tool` as a client verb.** Ever. §2. It is the one convenience that
  trades the whole enforcement property for a gesture.
- **A push notification carrying content, or one carrying actions.** §4.6.
- **A raw pty for the copilot surface.** §5.3. *Full control over copilot* means
  its chat, its tools and its confirmations — things that go through the gate,
  the budgets and the action log. A pty goes through none of them: it is
  *underneath* the permission model, not the top of it, so handing one over would
  not be granting the highest tier, it would be leaving the building. **Whether
  a device should also get the copilot's own terminal is a separate question and
  it is not answered here** — it is reported, not decided. Note that the 08-19
  simplification makes it a *sharper* question rather than a softer one: "it's
  you at another keyboard" is an argument somebody will now reach for, and it is
  an argument about trust, whereas this refusal is about which layer the
  permission model sits on.
- **Memory or instruction editing from a device.** §5.5.
- **A separate memory for a device's run.** §1. Two memories is two copilots.
- **Routines from a device.** §5.10.
- **A copilot code, in any form.** §6. Built, shipped in spec, and deleted.
  Anyone proposing it back should read §6.6 first and then say which of the four
  properties in §6.2 the device kind does not already hold.
- **A control that changes a device's kind in place.** §6.2. Re-pairing is the
  mechanism, and a toggle would make the whole of this section one tap deep.
- **The shared-conversation design (§1a).** It is the one that sounds like what he
  asked for and it is the one that cannot be secured, because turn boundaries in
  a pty are inferred rather than known, so it has no way to tell whose sentence
  caused which tool call.

### What the iOS client needs now

**Rewritten 2026-08-19, and the list got shorter by two whole screens.** The
first two items below used to be *store a second credential* and *build a Connect
screen*; both are deleted. A client that already built them should delete them
too — a Connect screen drawn for a device that is one of his is a dead end with a
keypad on it, and a stored copilot credential is a secret with nothing to open.

In the order a client should build them:

1. **Nothing to store, and nothing to ask for.** There is no copilot credential.
   If an earlier build wrote one to the Keychain, delete it on upgrade rather
   than leaving it: a secret nobody reads is a secret nobody rotates.
2. **Branch on the presence of `welcome.copilot`.** Key there → this is one of
   his devices and the copilot is available; key absent → **draw no Copilot tab
   and say nothing about it**. Not a disabled tab, not an explanatory sheet, not
   a "not available on this device" row. §5 rule 12, and it is the client's half
   of *the copilot is never shared*. Do not branch on `link.linked`, which is now
   always true when the key is there.
3. **`copilot.hello` on every connect and reconnect**, before any other
   `copilot.*` frame, and a Copilot tab that stays dark until `copilot.grant`
   arrives with `open: true`. It carries nothing now — no credential, no code.
   `welcome.copilot.open` is *always* false, so a client that treats it as
   "already in" will send frames that are refused. A socket is joined, not a
   device.
4. **Draw controls off `grant`, not off the capability and not off an
   inference.** `read` → the state, the sessions, the log, the pending list.
   `act` → Start, the message box, Cancel, Stop. `alter` → the Allow/Refuse pair
   on `copilot.ask`. All three are true today for every device that has the key,
   and drawing from the grant anyway is what keeps the client correct in front of
   a host that refuses something — hard-coding *I am his device so I have
   everything* moves the authority to the wrong end of the wire.
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
8. **`ios/Harness/host-standin.ts`.** Its `--copilot` flag reproduced the shape
   of the connection: `open` false on every welcome, so a client that skipped the
   hello saw nothing. Keep that, drop `copilot.connect`, and add the case the
   client now has to handle correctly — **a welcome with no `copilot` key at
   all** — because that is the guest path and it is the one a permissive harness
   will never exercise. It should also still grow `copilot.ask`, `copilot.answer`
   and `copilot.settled`; a client that has only ever been driven against a host
   that says yes is the failure that file exists to catch.
