# The Copilot

> **Scope, sharpened 2026-08-17 — read this before anything below.**
>
> Asad: *"This one will not be like a general personal assistant. This one will
> be more of a personal assistant **of a developer**, to help him get the
> developments done. Not to do the marketing for him, not to do the emails for
> him, not those kinds of things — most probably for developers, to get things
> done for development."*
>
> So: no inbox, no calendar, no social, no CRM. Every capability must serve
> someone trying to ship code. The mechanism described below — a real session
> with an MCP server, its own memory and an action log — is unchanged and
> correct; what changes is **what it is good at**.
>
> The advantage to build on is the one this app uniquely has: it runs *many*
> agents at once and owns their ptys, transcripts, git state and lifecycle. A
> CLI agent knows only its own session. Triaging a fleet, summarising an
> overnight run, catching a session that is stuck or looping, reviewing a diff
> before it lands, and turning a vague ask into a properly-scoped prompt for a
> sub-session are the capabilities worth building first.
>
> `COPILOT-CAPABILITIES.md` supersedes this file where the two disagree. Note
> that the copilot's own `CLAUDE.md`, written by the runtime pass before this
> constraint was set, will need revising to match.

Asad, 2026-08-17. The whole feature is in one sentence of his:

> *"exactly like you are a commander, exactly like you are working now for me —
> but now you are working in folders and files, I don't know which files where
> and all that stuff. Here I can actually see it."*

So this is not "add a chatbot to the sidebar". He already has a commander; what
he does not have is a **window into one**. Every design decision below is
settled by asking which option makes the machinery visible.

---

## What it is, mechanically

**The copilot is a real session, pinned above the session list, running the
Claude CLI with a Terminal Deck MCP server attached and a working directory of
its own.**

Not an in-process SDK agent, not a bespoke chat backend. A session. The reason
is his requirement, not elegance:

| He asked for | A session gives it for free |
|---|---|
| *"see all of his files"* | Its cwd is a real folder. Open it in Files. |
| *"whatever files it reads in the beginning… properly organized"* | Its startup reads **are** `CLAUDE.md` + `memory/`. The settings pane lists the actual files. |
| *"see how it started the session, how it worked for us"* | It has a normal transcript. The transcript viewer already exists. |
| *"proper memory… its own, not the other sessions'"* | A `memory/` folder that only it writes to. **A rule, not a wall** — see below. |
| *"we can connect any Claude"* | The profile system already built. |

Anything bespoke would have to re-implement all five, and would be a black box —
the exact thing he is asking to escape.

### Layout

```
<userData>/copilot/          the copilot may write in here
  CLAUDE.md              instructions — what it is, what it may do
  memory/                its own memory, one file per fact (the pattern he already uses)

<userData>/routines/      one file per routine, human-readable
<userData>/copilot-log/   actions.jsonl — every action it took, append-only
```

All four are shown in **Settings → Copilot**, as files, editable. That pane is
the answer to *"so we can see and learn how our copilot is working."*

**Two of them moved out of that folder, and the split is the point.** As first
written, all four sat under `<userData>/copilot/` — which was then the one
directory the copilot could write to. That made a routine file something it
could author without the confirmation a person is owed, and made the action log
something the audited party could append to, edit or delete. Neither is a thing
an instruction can prevent. Routines are now reachable only through
`routines/ipc.ts` or a confirmed tool call; the log is written by the app alone,
and the copilot adds a line to it with the `log.note` tool. `copilot-home.ts`
carries the argument, and `copilot-writable-boundary.test.ts` and
`copilot-log-boundary.test.ts` prove both refusals against a real `sandbox-exec`.

Those two refusals survived the confinement being removed, and are now the whole
of what is fenced — see the correction below.

---

## What it can actually do

Two tool surfaces, and the split matters.

**Native Claude Code tools** (Read/Write/Bash/Edit) — it gets these because it
is a CLI session. This is also the first real security question: Bash is the
whole machine.

> **Corrected 2026-08-17 — this paragraph said the copilot must run under the
> folder confinement built for paired-device sessions, and it did, and that was
> wrong.** Asad, having used it: *"Why does the copilot have a sandbox instead of
> being like normal, like the other ones? … The copilot still has less things, it
> is less controllable, it is not the best copilot in the market."*
>
> He is right, and the accounting is one-sided. **What the jail cost:** the
> copilot started *signed out* on every machine, every time — its login would
> live in the macOS keychain and the keychain is closed to a `(deny default)`
> process; it could not write a line of anything; and on Windows and on most
> Linux boxes it **refused to start at all**, because `confinementKind` answers
> `'none'` there. The agent meant to supervise the others was less capable than
> any of them. **What the jail bought:** protection against the copilot
> *reading* things. Not against exfiltration — the network is open to every
> confined session by design, because closing it would break `git push` and
> `npm install`.
>
> The real control on a copilot is the **consent gate plus the action log**.
> Those govern what it *does*, which is the actual risk, and a gate is legible:
> a person sees the prompt and decides. A jail is invisible and its failures look
> like the product being broken.
>
> So the copilot now runs under **the same policy as any other session started
> at this keyboard** — unconfined, as one of the accounts in the profile system,
> reading and writing what the person does, on every platform. What survives is a
> **records fence**: an `(allow default)` Seatbelt profile with three denies in
> it, around `<userData>/routines/`, `<userData>/routine-state.json` and
> `<userData>/copilot-log/`. Not a jail — the process inside it has the
> keychain, the home directory and every repository — a fence around the two
> things that are about accountability rather than capability: the triggers it
> must not author, and the record of what it did. `confine/records.ts` carries
> the argument and the measurements; it fails open, visibly, on platforms that
> cannot hold it.
>
> Two things that were lost and are said out loud rather than quietly: the
> credential carve-out (`.env`, `~/.ssh`, `.npmrc` refused inside readable
> folders) is gone, because it was a *stricter* rule than any other session on
> the machine obeys and belongs back as a product-wide option; and **memory
> isolation is now a rule rather than a wall** — see §4 below.

**A `deck-control` MCP server** — the part that does not exist yet. It exposes
the app's own IPC surface, which is already large:

- `sessions.list` · `sessions.get` · `sessions.transcript` · `sessions.start` ·
  `sessions.send` · `sessions.stop`
- `projects.list` · `git.status`
- `settings.read` · `settings.write`
- `alerts.list`
- `routines.list` · `routines.create` · `routines.delete`

That is nearly the whole request — *"it can tell you about the other sessions
running, you can ask him about any other session"* is `sessions.list` +
`sessions.transcript`. *"It can do settings"* is `settings.write`. *"It can
start sessions"* is `sessions.start`.

Memory needs no tools. It is files, and it already has Read/Write.

**Its memory being its own is a rule, and the file used to imply otherwise.**
While the copilot was jailed, `copilot-session.ts` claimed the guarantee was
structural: other sessions' transcripts sat outside the boundary and could not be
read at all. That was already only half true — `sessions.transcript` hands them
over through the front door, by design, because reading the fleet's transcripts
is one of the capabilities the copilot exists for — and the rule that actually
matters was never about reading. It is `COPILOT-CAPABILITIES.md` §4.1: *it may
read another session's transcript to answer a question; it may not copy that into
`memory/`*. No filesystem rule ever enforced that, because both halves happen
inside the copilot's own folder. It is stated as a rule in the copilot's
`CLAUDE.md`, in those words, and Settings → Copilot says it is a rule. The
mechanism that would make it a wall is a check on the memory-write path
(§4.5 of the capabilities document); it does not exist yet and nothing pretends
it does.

### Permission tiers

It can spend money, change settings and delete work, so:

| Tier | Examples | Behaviour |
|---|---|---|
| Read | list sessions, read a transcript, read settings | always allowed |
| Act | start a session, send to a session | allowed, logged, undoable by stopping |
| Alter | write settings, delete a session, create a routine | **confirmed in the UI**, logged |

Every call lands in `<userData>/copilot-log/actions.jsonl` and gets a row in
Settings → Copilot → Activity. An agent that can silently rewrite your settings
is not a assistant, it is a fault — and, by the same argument, neither is one
that can silently rewrite the record of what it did, which is why that file is
outside the folder it may write to.

---

## Copilot sessions

Sessions it starts are tagged `origin: 'copilot'` and grouped under **Copilot
sessions** in the sidebar, separate from your own. Each one links back to the
copilot turn that spawned it, and that turn links forward to the session — so
"why does this exist" is one click in either direction.

This needs a new field on session metadata, and the sidebar grouping the
tab-strip work is already touching. It should land after that settles, not
alongside it.

---

## Routines

His words: *"people can automate things and run some tasks automatically, some
routine tasks."*

A routine is **trigger → prompt → where it runs**. One file each, in
`routines/`, readable and editable by hand.

On triggers, his own standing preference decides the design — recorded from an
earlier session:

> *"events, not polling — webhooks/APIs/push over crons and timers, they make
> the system heavier."*

So the trigger list is event-first, and schedule is one entry in it rather than
the foundation:

- a session finishes, or goes idle N minutes
- a session fails, or an alert fires
- git state changes in a project (already watched — `watchGit` exists)
- a file or folder changes
- a schedule
- manual / asked for by name

Everything except schedule is already emitted somewhere in this app. The
routine engine subscribes; it does not poll.

Routines run **through the copilot**, not beside it — a routine is a saved
instruction to the same agent, so there is one system to understand and one
action log to read.

---

## Where you talk to it

Pinned at the top of the sidebar, above the session list, as he described. It
opens a full chat view rather than a floating box — a floating box would fight
the tab strip that is being rebuilt right now, and it needs room to show what it
did, not just what it said.

macOS first. He explicitly deferred other channels: *"let's not think about the
other channels."*

> **Corrected 2026-08-17 — "a full chat view" turned out to mean a *window*, not
> a page.** Asad, having used it:
>
> > *"Give the copilot a full window like the other windows. It is not that much
> > of a big window, it is like a small box inside the copilot page. Let it have
> > a proper window like others — proper dropdowns on the top, like changing the
> > counts, efforts, models, all those things should be there, exactly like the
> > other sessions. It should have all of those things, nothing should be less
> > than that. And it can stay as a window pill with the other windows."*
>
> The page was a `PanelId` — one of the places the window can travel to — and
> being one is what gave it a bespoke bar carrying a state line, a second
> spelling of Terminal/Chat and a Stop, above a terminal squeezed into the middle
> third of the window. Every one of those had a first-class equivalent one row up
> that the copilot was not being given, for one reason: it is filtered out of the
> session list, and that list is what feeds the tab strip, the heading, the
> account chip and the model / effort / fast-mode / connectors / usage cluster.
>
> So it is a **window** now. There are two lists in `App.tsx` — the fleet, which
> the dashboard, the swarm, the alert scanner and the rail's project runs read,
> and the fleet *plus the copilot*, which everything that draws a session as a
> window reads. The copilot's tab carries `isCopilot`, and the handful of things
> that are genuinely different hang off that flag and nothing else: it is called
> Copilot rather than Session N, it wears its compass in the strip, it is not
> listed in the rail (the pinned row is its home), its folder is not a project
> `⌘T` would open into, and `⌘W` puts it away instead of ending it. `PanelId` no
> longer has a `copilot` member — a member with no page is a dead route by
> construction — and its name and glyph live in `renderer/copilot/identity.ts`.
>
> What survives of the page is drawn only when it has something to say, in a
> bounded strip above the pane: the sign-in explanation on a first run, a refused
> start in the CLI's own words, the turn a "why does this exist" link asked
> about, the tours, and the sessions it started. With the copilot running and
> signed in, that strip has no children and the terminal fills the window.
>
> Its main-process side needed one line: `session:created` was never fired for
> the copilot, because the channel exists for sessions a window did not ask for
> and nobody had counted this as one. The renderer therefore knew its *id* and
> nothing else — no title, no status, no account — which is enough for a page
> that mounts a terminal and not enough for a window.

---

## Remote, and why it is last

*"We might not give this copilot to others… for copilot we need to separately
connect, because we don't want to give this copilot to others."*

Correct instinct, and the existing model already supports it: pairing grants a
device access to specific folders. Copilot access becomes a **separate
capability grant**, off by default, granted per device. A paired phone gets
terminal access and no copilot unless you say so.

> **Corrected 2026-08-17 — "separately connect" turned out to mean it
> literally.** This paragraph read the phrase as a *grant*: a checkbox beside an
> already-paired device. Asad, on the finished spec: *"Phones will have full
> control over copilot, same as the actual machine app. But connecting copilot
> will be a separate connection than the sessions."*
>
> So it is a connection, not a capability bit. Its own six-digit code minted at
> the desktop, its own credential, its own record, its own revoke — and a device
> paired to run terminals has **no** copilot reach until it has been through
> that ceremony. `COPILOT-REMOTE.md` §6 is the design and
> `src/main/remote/copilot-link.ts` is the store.
>
> The consequence worth naming here, because it contradicts the tier table
> above: a connected device **can** hold the alter tier and answer its own
> confirmations. Not because the tier got safer, but because the second factor
> behind it moved from *be at the desk* to *have been deliberately authorised for
> the copilot* — which is a boundary rather than a geography. Every alter call
> still draws a question, still expires into a refusal, and still writes a row
> naming the surface that answered it: *allowed on a connected device* is a
> different row from *allowed by the person*. `COPILOT-REMOTE.md` §4 carries the
> full argument and the one it superseded.

Deliberately phase 4. Remote access to an agent that can rewrite settings and
spawn sessions is the highest-stakes surface in the product, and it should be
built last, against a copilot whose permission model has already been used in
anger locally.

---

## Order

1. **Copilot as a session** — the folder, `CLAUDE.md`, memory, pinned entry, chat
   view, transcript. Talks, remembers, reads its own files. No powers yet.
2. **`deck-control` MCP server + permission tiers + action log.** Now it can see
   and do. This is the bulk of the work.
3. **Copilot sessions group + routines.** Needs 1 and 2; the grouping also needs
   the tab-strip work to have settled.
4. **Remote capability grant.**

---

## Open, and worth his answer before phase 2

- **Cost.** An always-available agent with a wide tool surface bills on every
  question, and reading a transcript to answer "how is that session doing" is a
  large prompt. It should show its own spend using the cost work landing now —
  but it is worth knowing whether he wants a ceiling on it.
- **Which account.** Any Claude profile, per the profile system. Whether the
  copilot should be *pinned* to one profile rather than following the app's
  current account is not obvious; pinned is the safer default.
