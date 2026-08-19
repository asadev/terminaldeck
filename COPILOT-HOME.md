# The copilot's home

Asad, 2026-08-18. Three sentences of his set the architecture, and every
decision below is settled by one of them rather than by taste.

> *"Some people will use all of it on a server. So they can anytime turn off
> their PC or laptop if they want to. And it should keep still working if the
> battery is died. They might set up some routine job, some automated things on
> this AI tool… which should work seamlessly and that's not reliable on the local
> device."*

> *"It should not be like if they choose server so like audit log cannot be there
> or something, or any single thing cannot be in one place and it needs two-place
> two-sided coverage at the same time. When we are using servers it means we need
> to give every single thing to the server independently too, so they can
> actually use it only."*

> *"Even on my WSL I will not use it, because I can install in my PC and reach it
> directly to WSL. So this will be only needed for the servers."*

This document supersedes `HEADLESS.md`, which described a different product for a
case that does not exist (§9). It sits beside `COPILOT-DESIGN.md`, which decides
*what the copilot is*, and `SERVERS-DESIGN.md`, which decides *what a server page
looks like*. Where this file and `HEADLESS.md` disagree, this one is right.

---

## 0 · The invariant

**No feature may require both sides at once.**

Wherever the copilot lives, it lives there *completely* — its folder, its memory,
its instructions, its tools, its record of what it did, and its routines. Every
other machine is a way in, and a way in may be switched off, run out of battery,
or never be opened again. If any single capability would need the laptop **and**
the server running together, that capability is designed wrong and does not ship
in that shape.

The test to apply to any proposal, in one question:

> **Unplug the other side. Does this still work?**

If the answer is "it works, but you cannot see it" — fine, that is a way in being
absent. If the answer is "it stops", the design is wrong. If the answer is "it
runs, but the log stops" or "it runs, but it cannot ask permission" — that is the
same wrongness wearing a smaller hat, and §5 and §7 are where it usually hides.

There is one permitted shape of exception and it is not a loophole, it is the
opposite of one: a capability a particular kind of home genuinely cannot hold is
**absent** there — not degraded, not proxied, not "available when your laptop is
on". It is missing from the tool catalogue, the person is told which ones at
install time, and nothing on any screen implies otherwise. §2.5 names the one
capability that is in this position today and §10 is the guard that stops a
second one arriving quietly.

### Two corrections, already conceded, not to be re-derived

**1. A thin server component is wrong.** An earlier proposal put "the copilot's
body on the server and its face in the app". That is precisely the two-sided
coverage he ruled out: the face is where the confirmations are, so an unattended
routine would depend on the face; the body is where the log is, so the app would
be reading a file over a wire. The server side is **complete**. It runs a real
copilot session, holds a real action log, fires real routines, answers real
confirmations from real connected devices, and does all of it with every desktop
in the world switched off.

**2. The headless host is not for machines-with-no-screen.** That case does not
exist for him — he installs the desktop app on the PC and reaches WSL from it.
Its only real purpose is **servers**, and it is reshaped into a server component
rather than defended as a peer-machine product. §9 says what is deleted.

---

## 1 · The vocabulary

Pick the words once. Every agent building against this document uses these and no
synonyms. The bar is `src/renderer/machines/servers/plain-words.test.ts`, which
reads the copy out of the source and fails the build on fifteen patterns — and
whose own argument applies here unchanged: *"copy rots one sentence at a time,
and the sentence that reintroduces `systemd` will be added by somebody debugging
a real problem, for whom the word is the clearest one available."*

### 1.1 The two nouns, and there are only two

| Word | What it means to the person | How they can tell |
|---|---|---|
| **Home** | Where the copilot actually is. A computer, and a folder on it. Exactly one at a time. | Turn everything else off and it keeps working. |
| **A way in** | Anything you talk to it from — this app on any computer, a phone, a browser. | Close it and nothing stops. |

"A way in" is not invented for this document. `src/main/idle.ts` already uses it,
in exactly this sense, about the tailnet listener: *"it is a second way in, and a
way in that closed itself while idle would be a host that cannot be woken."* The
phrase is plain, it is not a term of art, and it says the important thing — that
these are entrances, not halves.

**"Window" is deliberately not the word**, even though it is his. The copilot is
already *a window* in this app's own sense — `COPILOT-DESIGN.md` records the
correction that made it one, with a tab pill in the strip and the model / effort
/ account cluster above it. Using "window" for "the side that is not the home"
would give one word two meanings inside one feature, and the second meaning would
win in conversation and lose in code.

### 1.2 The two halves of a home, and what the switch is called

A home has a **computer** and a **folder**. Both can be changed and they change
by the same mechanism (§3), so they get one verb:

> **Move.** *"Move your copilot to orion."* *"Move your copilot to a different
> folder."*

Not *migrate*, not *deploy*, not *transfer*, not *relocate*. **Move** is what a
person does with a thing that has one location, which is exactly what a home is,
and it is the only verb in the list that carries "and it is no longer where it
was" without being taught.

The sentence a person reads when they are not moving anything:

> **Your copilot lives on this computer**, in `~/ClaudeAsad`.
> It keeps its memory, its routines and its record of what it did here. Anything
> else you sign in from is a way in — close it and your copilot keeps working.

### 1.3 Words the code already uses, and what happens to them

Settled here rather than discovered later, exactly as `SERVERS-DESIGN.md` §1.3
settles `machine`.

**`home` already means two different things in this codebase, and the collision
is real.** `copilotPaths().root` is the copilot's *folder* — what `COPILOT_HOME_SETTING`
(`'copilot.home'`) selects, what `defaultCopilotHome(userData)` answers, what
`CopilotFolderReport.home` reports. But `copilotHome(storageDir)` in
`copilot-session.ts` answers `<userData>/remote/device-home/copilot`, which is a
**unix home directory** left over from the build that jailed the copilot, kept
only so four transcript readers still find conversations from before that change.

> **Nothing renames.** `copilotHome` keeps its name and its meaning in the code;
> a comment at its declaration says it is not the home this document is about.
> Renaming a function whose value is a path that old installs still contain is a
> way to make an upgrade lose somebody's transcripts, and the argument
> `SERVERS-DESIGN.md` makes about `machines.json` applies with less at stake and
> the same conclusion: **only what a person reads changes.**

**`Machine` in the code means a paired desktop**, per `SERVERS-DESIGN.md` §1.3,
and continues to. A home is a property *of* a machine or a server, not a third
kind of thing in that panel.

**`src/headless/` keeps its directory name.** To a person it is not headless
anything; it is *"your copilot on orion"*. The directory, the npm package name
(`terminaldeck`), the `bin` entries and the `TERMINALDECK_HOST_ENTRY` variable are
all things a rename would break for no gain a person can see.

### 1.4 Words never used in copy

`sync`, `replica`, `primary`, `failover`, `node`, `instance`, `daemon`, `agent
runtime`, `deploy`, `provision`, plus everything already banned by
`plain-words.test.ts`.

**`sync` is the one that matters** and it is banned harder than the rest. Nothing
in this design synchronises anything, ever, and the word promises the precise
thing the invariant forbids: two copies kept in step, which is two-sided coverage
by another name. The day a screen says "syncing your copilot's memory" is the day
the feature has been rebuilt wrong, and the word will arrive before the code
does.

---

## 2 · What actually lives at a home

Read out of the source rather than imagined. Everything below was located in
`src/main/copilot-*.ts`, `src/main/routines/**`, `src/main/deck-control/**` and
`src/main/confine/records.ts` on 2026-08-18.

### 2.1 In the home folder — `paths.root`

`<userData>/copilot` by default, or a folder the person chose. `copilotPaths()`
composes all of it; `scaffoldCopilotHome()` creates only what this app owns, and
writes **nothing at all** into a folder that is not ours (`paths.ownFolder`).

| What | Path | Written by | Notes |
|---|---|---|---|
| The working directory | `<root>` | — | Fixed at `exec`. This is why §3 is a restart. |
| The folder's own instructions | `<root>/CLAUDE.md` | the person, **never** this app | `folderInstructions()`. Listed in the pane *even when absent*, because its absence is the proof that nothing there claims to be a copilot. |
| Memory | `<root>/memory/*.md` | the copilot | One file per fact. Scaffolded only when the folder is ours. |
| Memory index | `<root>/memory/MEMORY.md` | seeded once by the app, then the copilot | `memoryIndexSeed()`. |
| Briefs it wrote for sub-sessions | `<root>/specs/<slug>.md` | `deck-control/brief.ts` `writeSpec` | `specsDir(copilotRoot)`. Reached from `sessions.start` with a brief. |
| Where to find its tools | `<root>/deck-control.json` | the app, 0600, rewritten every start | Holds a bearer token. **Must never be rendered** in the folder listing. |
| The same, for unattended runs | `<root>/deck-control-unattended.json` | the app, 0600 | A *different* token, which is the entire mechanism that makes a routine unattended. |

### 2.2 Under `<userData>` — this app's own storage

These do not move when the *folder* moves, and they do not follow the copilot to
another computer. They are the install's, and each home has its own.

| What | Path | Why it is here and not in the folder |
|---|---|---|
| The persona — yours | `<userData>/copilot-layer/instructions.md` | Identity on the folder's disk is identity inherited by every session started there. |
| The tool contract — generated | `<userData>/copilot-layer/tools.md` | Regenerated from the live catalogue on every start; hand-editing it is how it drifts from the tools that exist. |
| The two composed | `<userData>/copilot-layer/copilot.md` | Byte for byte what `--append-system-prompt-file` was handed. |
| **The action log** | `<userData>/copilot-log/actions.jsonl` (+ `.1`) | Outside the copilot's writable reach. §5. |
| Routines | `<userData>/routines/*.md` | A file appearing here *is* a live trigger. §6. |
| The routine engine's bookkeeping | `<userData>/routine-state.json` | Run counts, budgets, `pausedReason`. A file the copilot can write is a budget it can zero. |
| Device trust store | `<userData>/remote/remote-auth.json` | scrypt hashes, never secrets. |
| Device kinds | `<userData>/remote/remote-device-kinds.json` | *My device* vs *Guest*. Fails **closed** — unknown is guest. **This is now the file that decides who may drive the copilot** (2026-08-19), which is why §5 wants it fenced. |
| Folder grants | `<userData>/remote/remote-folders.json` | Fails **open** — a corrupt file offers the desktop's folders, it does not lock anyone out. |
| Relay identity | `<userData>/remote/relay-identity.json` | The host secret and the X25519 pair. 0600. Losing it orphans every paired phone. |
| Profiles | `<userData>/profiles/`, `<userData>/profiles.json` | Which Claude account each session runs as. |
| Settings and state | `<userData>/settings.json`, `<userData>/state.json` | `settings.write` is an alter-tier tool, so this is part of what a home holds. |
| The old confined home | `<userData>/remote/device-home/copilot/` | Nothing writes here any more. Kept because upgraded installs hold conversations in it and four readers scan that root. |

### 2.3 Outside the app entirely, and this is the row people forget

| What | Where | Consequence |
|---|---|---|
| **The conversation** | `<configDir>/projects/<encode(root)>/*.jsonl` — the Claude CLI's own store, keyed by the working directory | It is not in the home folder and it does not move with anything. §3 and §4. |
| **The Claude credential** | macOS login keychain, or `<configDir>/.credentials.json`, or `CLAUDE_CODE_OAUTH_TOKEN` (in that order of precedence, measured in `ACCOUNT-MODEL.md`) | The app never holds it. On a server the keychain does not exist, which is gap **G4**. |
| The agent binary | wherever `claude` is on that machine's `PATH` | `AgentUnavailableError` is the refusal, and it names where this app looked. |

### 2.4 In process, on the machine that is the home

Not on disk anywhere, and every one of them is a thing that stops when that
machine stops — which is the whole point of choosing where the home is.

- The one copilot pty and its session id — module state in `copilot-session.ts`,
  behind a promise latch so two windows cannot produce two agents.
- The loopback MCP endpoint on 127.0.0.1 and its two per-run bearer tokens —
  `deck-control/server.ts`.
- The consent gate's outstanding questions — `deck-control/consent.ts`.
- The assembled tool catalogue, built at start from the live surface.
- The routine engine's subscriptions: the git watch (`onGitStatusChanged` +
  `holdGitWatch`), one reference-counted chokidar watcher per watched folder, and
  **one** timer for the earliest due schedule across every routine.
- The idle controller's registered parts, and the one thing held while idle: the
  relay connection, with its WebSocket ping/pong.
- One run per connected device — `remote/copilot-runs.ts`. Same folder, same
  memory, same log, same tools, same profile; different conversation, different
  token.

### 2.5 What I could not place — the gaps

Named rather than papered over. Each is a real hole in this design as the code
stands today, and an honest gap is the reason to write this document before the
code.

**G1 · The server side does not exist.** `grep -rn 'copilot\|routine\|deck-control'
src/headless/` returns **nothing**. Not a reduced version, not a stub: the
headless host assembles `createHostCore`, `registerRemoteIpc`,
`registerMachinesIpc` and `createPublicHost`, and stops — four calls, against
fifty-seven in `src/main/index.ts`. Every capability in §2.1–§2.4 is desktop-only
today. This document describes work, not a description of what is there.

**And it does not look that way from the import graph, which matters.** Five of
the eight copilot modules are *already reachable* from `src/headless/daemon.ts`,
because `host-core.ts` imports `copilotHomeScope` and `isCopilotSession` for
transcript scoping. Nothing calls them for the purpose; no copilot has ever run
there. A reachability check would report five of these capabilities as present.
§10.1 is that measurement in full, and it is the reason the guard in §10 is two
assertions rather than one.

The measurement that says how big that work is, and it is smaller than it looks:
walking the import closure from the eight modules that make up the copilot
(`copilot-session`, `copilot-home`, `copilot-layer`, `copilot-folder`,
`copilot-inspect`, `deck-control/index`, `routines/index`, `confine/records`)
reaches **144 source files, of which 11 have a runtime Electron import** — and
six of those eleven are one capability (§G2). The rest are `copilot-inspect.ts`
(`shell`, for Reveal in Finder), `ipc-trace.ts` (`app`), `link-open.ts`
(`BrowserWindow`, `Menu`, `clipboard`, `shell`) and `settings-extra.ts` (`app`,
`session`, `shell`). Every `IpcMain` in the eight is already **type-only**, so
`seam.test.ts` would not object to any of them; what needs narrowing is three
signatures — `registerCopilotIpc`, `registerRoutinesIpc` and
`registerDeckControlIpc` take Electron's `IpcMain` where they should take
`InvokeRegistrar`, which is one method wide and is what `ChannelDesk` already
implements.

**G2 · The drivable browser cannot exist at a server home.** `browser.open`,
`browser.read`, `browser.screenshot`, `browser.step` and `browser.handover` are
implemented by a Chromium `WebContentsView` inside the desktop app —
`browser-tab.ts`, `browser-driver.ts`, `browser-profiles.ts`,
`browser-isolation.ts`, `browser-session.ts` and `browser-popup.ts` all import
Electron at runtime, and `HEADLESS.md` is explicit that the server component
ships *"no Electron, no Chromium"*.

This is the one capability in the permitted-exception shape from §0, and the
decision is: **absent at a server home, never proxied.** A `browser.open` at a
server home that dialled back to the laptop's Chromium is the exact failure the
invariant exists to prevent — it would work all day and fail at 03:00 with the
lid shut, which is worse than not existing, because the routine that depended on
it was written while it worked. The catalogue at a server home does not contain
these five tools, the install says so in one sentence before anything is written,
and §10's guard fails if a sixth capability ever joins this list silently.

**G3 · There is no measured way for the copilot to sign in on a server.**
`ACCOUNT-MODEL.md` establishes the precedence chain — env var beats keychain beats
`.credentials.json` — and establishes that *this app cannot obtain a token*: the
CLI runs its own login flow and writes to the keychain, and every route the app
could take goes through a prompt, an impersonation, or a paste. On Linux there is
no keychain, so `<configDir>/.credentials.json` is the honoured store and the
CLI's own flow is the only thing that writes it. **Whether `claude`'s login flow
completes over a server terminal with no browser on the far end has not been
measured by anybody in this repository.** It is the single largest unknown in
this design, it is a fifteen-minute measurement, and it must be made before §8 is
built rather than discovered by the first person who installs.

**G4 · `routines.*` are still not tools.** `catalogue.ts` says they are
*"deliberately absent"* because *"there is no routine engine"* — which was true
when it was written and is not true now: `src/main/routines/` is complete and is
wired in `index.ts`. So today the copilot can *run* routines (the engine calls
it) and cannot *create* one, on any home. `routines/ipc.ts` already records the
tiers they must have (`create`/`update`/`remove` are alter, `run`/`pause`/`resume`
are act, `saveText` has **no** tier at which a model may call it). This is work
owed, and it is owed at both homes equally.

**G5 · A connected device's copilot run cannot start sessions.**
`deck-control/live-surface.ts` deliberately does not implement `deviceFolders`,
so `requireDeviceFolder` refuses every remote `sessions.start` outright. That is
the correct refusal for a surface that cannot honour `forDevice`, and it is
harmless on a desktop where the person can start a session themselves. At a
server home, **every** caller is remote, so the refusal is the whole product for
that tool. `live-surface.ts` says the two halves must arrive together and that
`live-surface.test.ts` fails if one appears without the other; that ordering
constraint now has a deadline.

**G6 · Cost is not exposed at all.** Nothing in the catalogue reads spend, and the
usage bar reads local files. A person whose copilot lives on a server and bills
against their account all night has no way to see what it cost from a way in.
Named here rather than solved; it belongs to the cost work.

**G7 · `<root>` holds two token files.** `deck-control.json` and
`deck-control-unattended.json` are 0600 inside the home folder. That is already
true on the desktop and is stated in `deck-control/index.ts`. It becomes sharper
on a server where the home folder may also be a deploy directory that other
things read. Not a new exposure, but the fence design in §5 must not accidentally
make these unreadable to the copilot, which needs the first one.

---

## 3 · The switch

### 3.1 It is a restart, and the app already knows how to say so

A working directory is fixed at `exec`. `copilot-folder.ts` states it plainly and
refuses to imply otherwise:

> *"A working directory is fixed at `exec`: nothing in this app can move a
> running process, and a pane that implied otherwise would be the third time this
> feature has described a thing it does not do."*

Moving a home to a different **computer** is that same fact with more of it. So
`CopilotFolderReport` grows one field, not a new mechanism: `runningIn` already
reports where the live copilot actually started, and `restartNeeded` already
compares it to what is chosen. Both become machine-aware. The sentence stays the
shape it is — *"it is still working in X"* and not *"restart it"* — because that
is the true one.

### 3.2 What a person is told, before

The move is a question with a list in it, and the list is the point. Somebody
switching homes is about to leave things behind, and every one of them is
countable from disk before a single byte moves.

> **Move your copilot to `orion`?**
>
> It will start again over there, in a folder you choose, and it will be a fresh
> start.
>
> - **Its memory stays here.** 41 things it has remembered. You can copy them
>   across once, by hand — after that the two do not follow each other.
> - **Its routines stay here.** 6 of them. 3 watch folders that only exist on
>   this computer.
> - **What it did stays here.** 2,340 entries, going back to 12 August.
> - **This conversation stays here.** You can still read it whenever you like.
> - **You will sign it in again over there.**
>
> Once it is running on `orion`, you can close this computer.

Every number in that list is read from disk, not estimated: memory is
`listMemoryFiles(paths.memory)`, routines is the store's count with the folder
check applied, the log count and its oldest row come from `copilot-inspect.ts`'s
reader, and the conversation is the transcript directory for
`encode(paths.root)`.

The last line is not decoration. It is the thing he asked for, and a person who
does not see it written down will not believe the feature does what it does.

### 3.3 What happens to the conversation

**It stays where it was, it is not carried, and it is not lost.**

The transcript lives in the Claude CLI's own store, keyed by the working
directory — `<configDir>/projects/<encode(root)>/*.jsonl` — on the machine that
ran it. Nothing this app does moves it, and nothing should: it is not ours, it is
keyed by a path that does not exist on the other machine, and two copies of one
conversation is the forking failure `ACCOUNT-MODEL.md` says has *"no honest
recovery"*.

That is not a loss, because continuity was never the scrollback.
`copilot-session.ts` spawns with `resume: false` and says so in as many words:
*"continuity is `memory/`"*. `remote/copilot-runs.ts` reaches the same conclusion
from the other direction — a phone's run shares the folder and the memory and has
its own conversation, and *"what it gives up is a scrollback, and the scrollback
was never the thing."*

So after a move: a new conversation, over there, reading the memory that is over
there. The old conversation is still on the old machine, still openable in the
transcript viewer, still costed. The pane says which machine it is on.

### 3.4 The order of operations, which matters

1. The new home is set up and **proved to work** before anything is said to be
   moved: the component installed, the folder chosen and validated, the account
   signed in, one turn taken successfully.
2. Only then does the app record the move.
3. The old copilot is **stopped, not deleted.** Its folder, memory, log and
   routines stay exactly where they are.
4. The old machine's copilot pane becomes a way in, and says so:
   *"Your copilot lives on orion. This is a way in."*

Step 1 before step 2 is the whole safety property. A move that flips a setting
first and installs second produces a person with no copilot anywhere and a
sentence claiming they have one on a server they cannot reach.

---

## 4 · Memory is per-home

### 4.1 The decision

**Nothing is carried automatically. Ever. Not memory, not routines, not the log.**

### 4.2 Why, and the argument is not caution

The alternative is a copy that is kept up to date, and the moment that exists the
invariant is dead. A memory that syncs is a memory that is *stale on the server
whenever the laptop was off* — which is precisely when the server is doing the
work nobody is watching. A 03:00 routine acting on facts that stopped arriving at
19:00 is worse than one acting on facts it owns, because it is confidently wrong
rather than obviously limited.

`remote/copilot-runs.ts` already settled the neighbouring question and the
argument transfers exactly: *"The one thing that must not be per-device is
`memory/` itself. Two memories is two copilots."* One copilot per home is the
design; two homes are two copilots; and pretending otherwise by copying bytes
between them produces a third thing that is neither.

### 4.3 So the carry is a one-time, by-hand, listed act

Offered once, at the move, and available afterwards from the pane:

> **Copy 41 remembered things from your old copilot?**
>
> They will be copied across as they are. After that the two are separate — a
> change on one does not reach the other.
>
> *(the 41 file names, with their dates, each one tickable)*

File names, because that is what one-file-per-fact is *for* —
`copilot-home.ts` says a directory row saying "memory: 11 files" *"would answer
nothing; the point of one-file-per-fact is that the names are the summary."* A
person choosing which facts follow them to a server is a person reading a list
they can actually read.

Conflicts are not merged. A name that exists at both homes is offered as
**Keep both**, with the incoming one suffixed, because a merge of two Markdown
files is a thing no code here can do correctly and a silent overwrite is how
somebody loses a fact they wrote by hand.

### 4.4 What is never offered for carrying, and why each

| Not carried | Reason |
|---|---|
| **The action log** | It is the record of what happened *on that machine*. Two logs interleaved by timestamp is an ordering nobody measured, in a file whose entire value is that it was not composed. |
| **Routines** | A routine names a folder. `~/Projects/x` on a laptop is nothing on a server, and a routine that fires against a folder that does not exist is a failure every ten minutes. They are **re-made** at the new home, from a list of the old ones shown side by side, with each folder re-chosen. That is deliberately more work than a copy. |
| **The MCP config files** | Regenerated at every start with a fresh token. A copied one authenticates nothing, which is the design. |
| **The conversation** | §3.3. |
| **The relay identity** | Copying it would give two machines one `hostId`, and every paired phone would find whichever answered first. |
| **The credential** | The app does not hold it (`ACCOUNT-MODEL.md`), so there is nothing to copy even if it were wise. |

### 4.5 Making it visible rather than a surprise

The requirement is that a person does not discover this by switching and finding
yesterday gone. Three places say it, and they are all places somebody already is:

1. **The copilot pane, always**, under the home line: *"41 things remembered on
   this computer."* Not a count of a hidden store — a link to the list.
2. **The move dialog**, §3.2, before anything happens.
3. **The new home's first run.** The copilot's own opening state says it plainly:
   *"This is a new home. I do not have the memory from your old one yet."* A
   copilot that quietly says "I don't recall that" is the failure; a copilot that
   says *why* is a fact.

---

## 5 · The action log boundary, on a server

### 5.1 What holds it today, and where it does not

Locally the log lives outside the folder the copilot may write to, and the
mechanism is `confine/records.ts`: an `(allow default)` Seatbelt profile with a
deny per fenced path, applied at spawn. Five paths — `routines/`,
`routine-state.json`, `copilot-log/`, `remote/copilot-link.json`,
`remote/remote-auth.json`. `copilot-log-boundary.test.ts` proves the refusals
against a real `sandbox-exec`.

> **The list is one path out of date, and in the direction that matters.
> 2026-08-19.** The separate copilot connection was deleted — pairing a device as
> *My device* is now the copilot authorisation — so `remote/copilot-link.json` is
> a path nothing writes, and `remote/remote-device-kinds.json` is the file that
> decides whether a device may drive the copilot. It is **not** in the list.
>
> Both halves have to move together, and `COPILOT-REMOTE.md` §0.5 argues it at
> length. The short version: a deny over a deleted store refuses nothing while
> looking like a protection, which is a defect this repository has already paid
> for once; and the kinds file is now the *whole* authorisation rather than one
> factor of it, because there is no longer a credential an edit would also have
> to forge. One line appended to it by an agent that has `Write` promotes a guest
> to *My device*, with no tool call, no confirmation and no log row.

And the limit is stated in that file, unambiguously:

> *"**macOS only.** Seatbelt is the only deny mechanism this repository has
> measured that can be applied to an otherwise-unconstrained process. The Linux
> namespace mechanism works by *replacing* the mount namespace, which is a jail
> by construction, and an AppContainer grants by ACL from a deny-everything
> baseline. Neither expresses 'everything, except these few'."*

**Every server is Linux.** So the mechanism that holds the boundary at a desktop
home holds nothing at a server home, and his sentence — *"it should not be like
if they choose server so like audit log cannot be there"* — is aimed exactly
here. An audit log that exists on the server but that the audited party can
rewrite is the thing he said must not happen.

### 5.2 What holds it on a server — measured

Two mechanisms were measured on `terminaldeck-server` (Ubuntu 24.04, ext4) on
2026-08-18. Both are plain POSIX; neither is a namespace, a container or a jail.

**(a) Two accounts.** The component runs as one account and spawns the copilot as
another. The fenced paths are owned by the component's account with modes chosen
per path. Measured, with the copilot's account attempting each:

```
== routines: readable, not writable (the macOS decision, matched) ==
read a routine                         -> ok
list routines                          -> ok
create a routine                       -> refused
delete a routine                       -> refused
rename the routines folder             -> refused
== the log: neither read nor write ==
read the log                           -> refused
append to the log                      -> refused
== its own home folder: ordinary ==
write a memory                         -> ok
delete a memory                        -> ok
```

That is the macOS fence's decisions reproduced exactly, including the asymmetry
`records.ts` argues for at length — routines readable because *"refusing it the
folder that describes them would be theatre"*, the log not readable because
*"being able to check which of its actions were recorded is the first move
anybody makes before shaping behaviour around a record."*

**(b) The append-only attribute**, for the log file specifically. `chattr +a`,
measured on the same box, as root:

```
append   -> ok
truncate -> refused        (Operation not permitted)
rm       -> refused        (Operation not permitted)
mv       -> refused        (Operation not permitted)
edit     -> refused        (sed -i cannot rename its temp file into place)
read     -> ok
```

and an unprivileged account cannot clear the flag:
`chattr: Operation not permitted while setting flags on …` — clearing it needs
`CAP_LINUX_IMMUTABLE`.

(b) is strictly weaker than (a) in one named way and stronger in another. Weaker:
**read is allowed**, so the copilot can see its own record, which macOS denies.
Stronger: it holds *even against the account that owns the file*, so it survives
an arrangement where two accounts were not possible. It also only works on
filesystems that implement the attribute — ext4 and xfs do, overlayfs does not,
which matters because a server component installed inside a container is on
overlayfs.

### 5.3 So the fence is a detected tier, with a third state

The rule from `SERVERS-DESIGN.md` §3 applies without modification: **detect, do
not assume**, and a fact with no answer is `cannot`, never `yes` and never `no`.

| Tier | What was achieved | When |
|---|---|---|
| **Held** | Two accounts, plus `+a` on the log where the filesystem takes it | Install had enough privilege to create an account |
| **Held (record only)** | `+a` on the log; routines and state protected by ownership alone | One account, but privilege at install time |
| **Not held** | Nothing. The copilot's account can rewrite its own record. | Neither was possible |

The tier is decided **at install**, recorded, and shown on the server's page and
in Settings → Copilot forever after — not re-derived at each start, because a
tier that silently downgrades is worse than one that was never claimed.

`records.ts` already has the right failure direction and it is kept:
`buildRecordsFence` answers `null` rather than throwing, `CopilotState` carries
the reason, and Settings draws it. The fence protects the *record*, not the
person's disk, so a machine that cannot hold it is *a machine with worse
auditing* — not one where an agent has escaped. Refusing to install over it would
be refusing the whole feature on the machines it was built for.

What must not happen is the quiet version. At **Not held**, the Activity list
carries a permanent line, in the person's words:

> **This record is not protected on this server.** Your copilot could change it.
> Everything it does is still written down — but on this server, nothing stops it
> editing what was written.

### 5.4 The equivalent proof

`copilot-log-boundary.test.ts` proves the macOS refusal against a real
`sandbox-exec`. Its equivalent cannot be a unit test, because the thing being
proved is a kernel's answer on a machine that is not this one. So it is two
tests, and both are needed:

1. **`servers/home-fence.live.test.ts`** — the same shape as the repository's
   existing `actions.live.test.ts` and `reach.live.test.ts`: gated on an
   environment variable naming a real server, it opens a real connection, creates
   the two accounts in a scratch directory, and runs the ten refusals in §5.2(a)
   plus the six in §5.2(b), asserting each answer. It cleans up after itself —
   accounts removed, directory removed — per `SERVERS-DESIGN.md` §8.5. Skipped
   with a *reason* when the variable is unset, never silently green.

2. **`servers/fence-tier-is-honest.test.ts`** — an ordinary unit test, and the one
   that actually runs in CI. It asserts the property no live test can: **the tier
   the installer recorded is the tier the copy claims.** Feed it each of the three
   tiers and assert that the sentence drawn contains a refusal claim only at
   `Held`, that `Not held` produces the §5.3 warning verbatim, and that no code
   path can produce a `Held` tier without the install having recorded a
   successful probe. The hole that guard covers is the one that matters, because
   the failure everybody actually ships is not a broken fence — it is a working
   product with a sentence on it that is no longer true.

---

## 6 · Routines are the proof case

They are the reason the invariant exists. An automated job that stops when a lid
closes is worthless, and his sentence names it: *"they might set up some routine
job, some automated things… which should work seamlessly and that's not reliable
on the local device."*

### 6.1 Where they run

**At the home, entirely.** The engine, its subscriptions, its timer, its
bookkeeping, the runner and every process it spawns are on the machine that is
the home. Nothing about a routine reaches a way in.

The engine is already built to make this true rather than to hope for it: it has
**no interval anywhere**. Every trigger except `schedule` is a method something
else calls when something the app was already doing produced an event, and the
timers that do exist are delays after an event rather than polls. A machine
holding the relay connection and nothing else, per `idle.ts`, still has every one
of those subscriptions available the moment a session starts — because they hang
off events the host itself produces.

### 6.2 What they can reach, and what they cannot

| Trigger | At a laptop home | At a server home |
|---|---|---|
| session finished / failed / idle | ✅ | ✅ — sessions there are the server's |
| alert fires | ✅ | ✅ |
| git state changed | ✅ | ✅ — for repositories **on the server** |
| a file or folder changed | ✅ | ✅ — folders **on the server** |
| a schedule | ✅ | ✅ |
| manual / by name | ✅ | ✅ — asked from any way in, or from the CLI |

The row that carries the whole design is `git-change` and `file-change`. A
routine at a server home watches the server's disk. It **cannot** watch a folder
on the laptop, and there is no mechanism to make it — that would be a watcher on
one machine feeding a trigger on another, which is two-sided coverage in its
purest form and would go dead the first time the laptop slept.

This is why §4.4 refuses to carry routines across a move. It is not tidiness: a
copied routine names a path that is not there, and the honest UI is a
side-by-side list where each folder is chosen again.

### 6.3 Nobody is watching, and that is enforced by a token

Every run the engine starts is unattended, as a flat rule rather than a property
of the trigger. The mechanism survives the trip out of the process and back in,
because it is not a flag: the run is launched with the **unattended MCP config**,
carrying a different bearer token, and `server.ts` dispatches anything bearing it
with `attended: false`. An alter-tier call from a run is refused at the boundary
with `not-permitted-unattended` rather than waiting on a dialog nobody will see.

At a server home this stops being a nicety and becomes the ordinary case. Which
raises the question §7 has to answer.

### 6.4 The consequence for grants, stated so nobody treats it as a bug

`SERVERS-DESIGN.md` §6.3 already records it and it holds here: **a routine can
read and cannot change, unless there is a live grant.** A nightly *"tell me if
anything stopped"* works with no grant at all. A nightly *"restart it if it
stopped"* requires one, deliberately.

---

## 7 · Pairing a phone directly to the server

### 7.1 The server is a machine in its own right

Once the component is installed, the server joins the relay as itself: its own
host identity (`relay-identity.json`, minted there), its own `hostId`, its own
X25519 pair, its own six-digit code. **No laptop is in the path.** A phone
photographs a QR shown on the server's page — or reads the code out of
`terminaldeck pair` in a terminal — and from then on talks to the server whether
any desktop exists or not.

This is not new machinery. It is `remote/host-identity.ts`,
`remote/device-auth.ts` and `remote/relay-client.ts` doing on the server exactly
what they do on a Mac, and the headless host already assembles all three.

### 7.2 Two stores, two answers, and this is the invariant working

Device kinds and folder grants are per machine — `remote-device-kinds.json` and
`remote-folders.json` under that machine's own `<userData>`. So a phone can be
**my device** on the server and a **guest** on the laptop, with different folders
on each, and nothing has to reconcile them because nothing is shared. That is not
a compromise; it is the correct answer, and it falls out of the design rather
than being built.

**Revised 2026-08-19.** This section used to add a second ceremony on top: a
separate copilot connection with its own six-digit code, its own credential and
its own record, which had to be performed on the server as well. That is deleted.
**The kind decides the copilot too**: a phone that is *My device* on the server
can drive the server's copilot from the moment it is approved there, and a guest
on the server has no copilot reach and is not shown that it hasn't.

Which makes the per-machine property above stronger rather than weaker, and it is
worth saying because it is the answer to the obvious worry. There is exactly one
question, asked once per machine, by somebody standing at that machine: *is this
one of mine here?* A phone that is his on the server and a guest on the laptop
gets the server's copilot and not the laptop's — no reconciliation, no
inheritance, and no way for an approval on one box to imply anything on another.

### 7.3 The space on the server's page

Inside the server's page, in zone three — behind **Advanced**, beside the other
sharp things, for the reason `SERVERS-DESIGN.md` §5.3 gives about all of them.
It reads:

> **Phones and computers**
>
> Anything paired here talks to this server directly. It keeps working when this
> computer is off.
>
> *Show a code* — a six-digit code and a QR, good for a minute.
>
> *(the roster: each device, when it was added, whether it is one of yours or a
> guest, and what folders it can open)*

The roster used to carry a fourth column — *whether it can use your copilot* —
and it was dropped on 2026-08-19 rather than left as a read-only echo. It would
now say exactly what the second column says, and a column that restates its
neighbour is a column somebody will eventually try to click.

Two sentences do the real work. *"talks to this server directly"* is the fact
somebody needs in order to believe the feature. *"It keeps working when this
computer is off"* is the thing he asked for, said where a person is standing when
they decide.

### 7.4 Who answers a confirmation, when there is no screen

This is the sharpest consequence of a server home and it must not be discovered.

An alter-tier call draws a question. The question goes to a surface that can
answer it: the renderer, or a connected device (`ConsentRelay`). A server has no
renderer. `live-surface.ts` records what that means today — *"A build with no
remote layer — the headless daemon … delivers to the window and nowhere else"* —
and `consent.ts` resolves `no-approver` when nothing that can answer saw it.

So at a server home with nothing connected, **every alter-tier call is refused**,
promptly, with a reason, and a row in the log. That is correct behaviour and it
is also a product state a person has to be told about, once, at install:

> **Nothing here can answer a question yet.**
>
> Your copilot asks before it changes anything. There is no screen on this
> server, so until you connect a phone or this app to it, anything that needs
> permission will be refused — it will still tell you what it wanted to do.

And the fix is one sentence long and is on the same screen: pair a device here as
**My device**, and that device answers. What makes this safe is the same thing
that makes it simple — the second factor for the alter tier moved from *be at the
desk* to *somebody at this machine said this device is one of theirs*, which is a
boundary rather than a geography, and it is a boundary a device cannot cross by
itself on any number of other machines. `COPILOT-REMOTE.md` §4 carries that
argument and §6 carries the ceremony that used to sit on top of it.

### 7.5 The SSH-only tier, where direct pairing is genuinely impossible

A server the app can reach but cannot install onto — no Node, no npm, no writable
prefix, or a person who declined — has **no** relay presence, and therefore no
code to show. There is nothing to pair to.

What that page says, and it says it in one place rather than by omitting a
button:

> **A phone can't reach this server on its own.**
>
> Nothing is installed here for a phone to talk to. You can still control this
> server from this app, but this computer has to be on.
>
> *Set up your copilot on this server* → (§8)

And, said plainly on the same page rather than left to be inferred: **a server at
this tier cannot hold a home.** You can run commands on it. Your copilot cannot
live there. Those are different things and the page must not blur them, because a
person who believes their routines are running on a server that has nothing
installed will find out at the worst possible moment.

---

## 8 · Installing, over the connection the app already holds

### 8.1 What it uses

`ServerConnections.runScript(serverId, script)` — already built, already the
transport for every action on a server page, already host-key-checked. The script
is `scripts/install-headless.sh`, which wraps `npm install -g terminaldeck`. No
second transport, no `curl | sh` in the product (that stays as the manual route
for someone at a terminal).

### 8.2 What is asked before a byte is written

Four questions, and the reason each is asked rather than assumed is that each one
is a thing the person would be entitled to be angry about discovering afterwards.

1. **Where its files go.** Named in full — `~/.local/share/terminaldeck` on a
   server, per `nodePaths` and XDG. Not "in the usual place".
2. **Whether to make a second account for it.** With what it buys, in a sentence:
   *"Your copilot cannot change the record of what it did. Without this, on this
   server, it can."* If the answer is no, or if it is not possible, §5.3's tier
   is recorded as such **at that moment**, and it is what the page says forever.
3. **Which folder it lives in on the server**, and the standing warning
   `copilot-folder.ts` already makes about a folder that may hold credentials —
   said at the picker so it is chosen rather than discovered, with deliberately
   no scanner guessing which folders are sensitive.
4. **Which Claude account it signs in as** — and here the honest answer is G3.
   Until that is measured, this step says what it actually is: *"You will sign it
   in yourself, in a terminal on this server, after this finishes."* A step that
   claims to sign somebody in and then cannot is worse than a step that hands
   them the command.

Plus one statement that is not a question, because there is nothing to decide:

> When this finishes, your copilot will be running on this server. It keeps
> running when you close this app, and when this computer is off.

### 8.3 What the person sees

A running list, one line per step, each line a fact rather than a spinner:

```
Checking what this server has           …  Node 22.11, npm 10.9
Installing                              …  done
Making a place for its files            …  ~/.local/share/terminaldeck
Making a separate account for it        …  done — your copilot can't change its own record
Starting it                             …  running
Joining so your phone can find it       …  ready
```

Every one of those is a thing that can fail on its own and say so on its own
line, which is the difference between "the install failed" and a person knowing
which half to fix.

### 8.4 When the server cannot take it

The installer already refuses early, with a sentence, rather than letting npm
fail halfway through a native build. The refusals it can produce were **measured
on the reference server**, and the reference server fails two of them:

```
$ ssh terminaldeck-server 'node --version; command -v npm'
v18.19.1
(no npm)
```

So `terminaldeck-server` — the box every measurement in `SERVERS-DESIGN.md` was
taken on — would refuse this install twice over: Node 18 against a floor of 22,
and npm absent entirely. That is not a problem with the box. It is the ordinary
state of a rented Linux server, it is what most people's servers look like, and
it means **the refusal path is the common path, not the edge case.**

Which sets the bar for what it says. The installer's own sentences are already
written for a person and are kept:

> *"Node 18.19.1 is installed and this needs 22 or newer. The host uses features
> that are not in older runtimes, and failing here is better than failing inside
> a native build."*

The app adds exactly two things and neither is an attempt to fix it:

- **The command that would fix it**, for their server, shown as text they can
  copy — not run for them. Installing a language runtime on somebody's production
  server is provisioning, and `SERVERS-DESIGN.md` §7 puts provisioning out of
  scope for a reason that holds here: *"a half-installed server has no way
  back."*
- **The state it leaves them in**, said out loud: *"Nothing was written to this
  server."* True, because the installer refuses before `npm install`, and worth
  saying because the alternative assumption is the frightening one.

And if it fails **after** something was written, the same page says what was
written and where, and offers to remove it. A failed install that leaves an
unnamed directory on somebody's server is how a person stops trusting a tool.

---

## 9 · What becomes of the headless host

`HEADLESS.md` describes *"the same machine, without a window"* — a peer-machine
product whose lead case is WSL and whose second case is "a machine with no
screen". Both are wrong now: he will not use it on WSL, and the machine-with-no-
screen case does not exist for him. It is reshaped into **the server side of a
home**, which is a different product with a different definition of done.

### 9.1 Deleted, concretely

| What | Where | Why |
|---|---|---|
| The public demo host | `src/headless/demo.ts`, `src/headless/public-host.ts`, `src/headless/public-host.test.ts`, the `demo` input in `vite.headless.config.ts` | It is a third program in this bundle whose only purpose is to **auto-approve any device that redeems a code**. It exists for App Review. A server component people install to hold their copilot must not contain that code path at all; if App Review still needs the demo box, it moves to its own directory with its own build config, out of this bundle. |
| `HostStatus.publicHost` | `src/headless/host.ts` | Goes with the above. |
| `PUBLIC_HOST_OFFER`, `HeadlessHostOptions.publicHost`, `HeadlessHost.publicHost` | same | same |
| `HostStatus.neverRunning` | `src/headless/host.ts` | It exists to list *"things the desktop build idles that this one has never had"*. Under the invariant the server side has no such list — anything on it is work owed, not a status line. Deleting the field is what turns a documented shortfall into a bug report. |
| The WSL reachability branch and all its copy | `src/main/reachability.ts` (`HostKind: 'wsl'`, `wsl`, `distro`, `wslRootWindowsPath`), the WSL section of `renderStatus` in `src/headless/cli.ts`, the closing WSL advice in `scripts/install-headless.sh` | *"Even on my WSL I will not use it."* The whole "the distro shuts down when the last terminal closes" apparatus is answering a question nobody is asking. It is a substantial amount of careful work and it is right to delete it rather than keep it warm — it is the largest single source of the peer-machine framing, and every reader of `status` currently pays for it. |
| `HEADLESS.md` | the file | Superseded by this one. Two paragraphs survive and move here or into the code: the crypto note (`@noble/ciphers` with deliberately no native path, because Electron's BoringSSL ships no ChaCha) and the packaging note (Node not Electron; npm plus a shell script; small enough that installing it on a server is an easy decision). |

### 9.2 Kept, and re-aimed

- **`ChannelDesk`** (`src/headless/desk.ts`) — the whole trick, and the thing that
  makes the completion cheap. `registerRemoteIpc`, `registerMachinesIpc` and
  `registerWslIpc` already take an `InvokeRegistrar`; `registerCopilotIpc`,
  `registerRoutinesIpc` and `registerDeckControlIpc` are narrowed to the same
  interface and register against the same desk.
- **The four commands** — `pair`, `status`, `folders`, `stop` — but re-aimed. They
  are no longer *"the basic UI to just connect"*; the server's page in Machines is
  the UI. They are the **recovery surface**: what you use when you cannot reach it
  from the app. The help text says that in one line, because a CLI that presents
  itself as the primary interface teaches people to use it as one.
- **Idle mode** (`src/main/idle.ts`), unchanged and now load-bearing: a home
  holding one relay connection and nothing else, waking on attach.
- **`status`**, which grows the only thing it is now missing: the home. Where the
  copilot's folder is, whether it is running, which account it is signed in as,
  how many routines are armed, and — the important one — **which fence tier
  §5.3 recorded.**

### 9.3 Added, which is the actual work

Assembled in the headless host, against the desk, in this order:

1. `scaffoldCopilotHome` + `copilotLayerPaths` — the folder and the layer.
2. `registerCopilotIpc` — the session.
3. `registerDeckControlIpc` — the loopback MCP endpoint, the catalogue, consent,
   the action log. Its catalogue at a server home excludes the five browser tools
   (§G2).
4. `createRoutines` + `registerRoutinesIpc` + `engine.setControl(control.unattended())`
   — and `unattended()` is not a detail of that line, it *is* the line.
5. The Linux records fence (§5.2), producing a tier rather than a boolean.
6. `registerCopilotInspectIpc` — behind a seam for `shell.showItemInFolder`,
   which is the one runtime Electron call in the copilot's own eight modules.

### 9.4 Definition of done

Not *"installed and paired"*. The definition is the invariant, exercised:

> A routine set up on a server, that fires and completes, and is read back from a
> phone — with the desktop app **quit** and the laptop **shut**, and having been
> so for hours. Proved by reading the run's own output and the action log's own
> rows on the far side, not by the app claiming it is connected.

---

## 10 · How the invariant is enforced by a test

This is the most important section. `SERVERS-DESIGN.md` and this document are
both prose, and prose does not fail a build. This repository has seven
"mechanism written, connection absent" defects on record this week, and its best
guards are the ones that read the source — `seam.test.ts` walks the real import
graph, `plain-words.test.ts` reads the real copy, `contract.test.ts` reads the
real preload. The guard below is written in that tradition and it is the only
thing that will still be true in three months.

### 10.1 The first version of this guard was wrong, and finding out is the point

The obvious guard is: walk the import graph from each shell's entry point and
assert that every capability's module is reachable from both. It is one
assertion, it is in the shape `seam.test.ts` already uses, and it is **wrong** —
measured, on this tree, today:

```
desktop closure: 212 files    server closure: 98 files

desktop YES  server YES   src/main/copilot-session.ts
desktop YES  server YES   src/main/copilot-home.ts
desktop YES  server YES   src/main/copilot-layer.ts
desktop YES  server YES   src/main/copilot-folder.ts
desktop YES  server no    src/main/copilot-inspect.ts
desktop YES  server no    src/main/deck-control/index.ts
desktop YES  server no    src/main/routines/index.ts
desktop YES  server YES   src/main/confine/records.ts
```

Five of the eight are **already reachable** from `src/headless/daemon.ts`, and no
copilot has ever run there. The cause is one line: `host-core.ts` imports
`copilotHomeScope` and `isCopilotSession` from `copilot-session.ts`, for
transcript scoping and for telling one kind of session from another — and that
one import drags four more modules into the graph behind it.

So a reachability guard would have passed on five capabilities that do not exist
on that side. That is this repository's own named defect class arriving inside
the test written to prevent it: **mechanism present, connection absent.** The
module is importable; nothing imports it *for the purpose*; `registerCopilotIpc`
is never called; there is no copilot.

The correction is that reachability is **necessary and not sufficient**, and the
sufficient half is the one `seam.test.ts` already knows how to check — it looks
for the literal call, not for the import, and says why: written *"as a branch
rather than as a default argument so the plain-Node call still reads literally as
`installPaths(nodePaths(…))`, which `seam.test.ts` looks for."*

Measured, the assembly halves are unambiguous. `src/headless/host.ts` calls
`createHostCore`, `registerRemoteIpc`, `registerMachinesIpc` and
`createPublicHost` — four. `src/main/index.ts` calls **fifty-seven**
`registerXIpc` functions plus `createRoutines`. That gap is the work, and it is a
gap a test can read.

### 10.2 The register

A real module, not a test fixture, because the settings pane and the installer
both need it — the pane to say what this home holds, the installer to say what a
server home will not have.

```ts
// src/main/home-capabilities.ts

/** One thing a home does. */
export interface HomeCapability {
  /** What a person would call it. Appears in the install summary. */
  name: string
  /** The module that implements it, repo-relative, `/`-separated. */
  module: string
  /**
   * The literal call that *assembles* it, e.g. `registerDeckControlIpc(`.
   *
   * Separate from {@link module} because a module being importable is not a
   * feature being wired, and this repository has paid for that distinction more
   * than for any other — see §10.1, where five capabilities were reachable from
   * a shell that has never run one of them.
   */
  assembles: string
  /** Every tool id this capability answers for. Empty for capabilities with no tool. */
  tools: readonly string[]
  /** Where its state lives, *relative to a home*. There is deliberately no fourth value. */
  state: 'home-folder' | 'app-state' | 'process' | 'none'
  /**
   * Homes that can hold it. A capability absent from a kind of home is absent
   * from its catalogue, named at install, and never proxied — §0 and §G2.
   */
  homes: readonly ('desktop' | 'server')[]
}

export const HOME_CAPABILITIES: readonly HomeCapability[] = [ /* … */ ]
```

The `state` union has no `'other-side'` member, and that is the invariant made
unwriteable rather than merely stated. There is no way to declare a capability
whose state lives on a machine that is not the home, because the type has no word
for it.

### 10.3 The guard

```ts
// src/main/home-capabilities.test.ts
//
// The invariant, asserted mechanically: no capability of a home may require a
// second machine to be running. A paragraph asking nicely is not a guard, and
// this repository's history says the connection is what goes missing, never the
// mechanism — which is why every capability is checked twice, once for being
// reachable and once for being *assembled*. See §10.1 for the five capabilities
// that passed the first check while not existing.

import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { describe, expect, it } from 'vitest'
import { HOME_CAPABILITIES } from './home-capabilities'

const ROOT = resolve(__dirname, '..', '..')

/**
 * The two shells: where each one starts, and where each one assembles.
 *
 * They are different files for the server and the same file for the desktop,
 * which is not a wrinkle to tidy — `daemon.ts` is an argument parser that calls
 * `createHeadlessHost`, and `host.ts` is where the parts are actually put
 * together. Pointing the assembly check at `daemon.ts` would look for calls in
 * the file that does not make them.
 */
const SHELLS = {
  desktop: { entry: 'src/main/index.ts', assembly: ['src/main/index.ts'] },
  server: { entry: 'src/headless/daemon.ts', assembly: ['src/headless/host.ts'] },
} as const

function resolveSpec(spec: string, from: string): string | null {
  let base: string
  if (spec.startsWith('@shared/')) base = join(ROOT, 'src/shared', spec.slice('@shared/'.length))
  else if (spec.startsWith('.')) base = resolve(dirname(from), spec)
  else return null
  for (const c of [`${base}.ts`, `${base}.tsx`, join(base, 'index.ts'), join(base, 'index.tsx')]) {
    if (existsSync(c)) return c
  }
  return null
}

/** Every source file one shell can reach. The same walk `seam.test.ts` uses. */
function closure(entry: string): Set<string> {
  const seen = new Set<string>()
  const stack = [join(ROOT, entry)]
  while (stack.length > 0) {
    const file = stack.pop() as string
    if (seen.has(file)) continue
    seen.add(file)
    const source = readFileSync(file, 'utf8')
    for (const m of source.matchAll(/(?:from\s*|import\s*\(\s*)['"]([^'"]+)['"]/g)) {
      const r = resolveSpec(m[1], file)
      if (r !== null) stack.push(r)
    }
  }
  return new Set([...seen].map((f) => relative(ROOT, f).split(sep).join('/')))
}

/**
 * A shell's assembly source, with comments stripped.
 *
 * Stripped for the reason `seam.test.ts` learnt the hard way: this file's own
 * prose names the calls it looks for, and a scanner that cannot tell prose from
 * code reported the module that *fixed* a problem as the one causing it.
 */
function assemblyOf(shell: keyof typeof SHELLS): string {
  return SHELLS[shell].assembly
    .map((f) => readFileSync(join(ROOT, f), 'utf8'))
    .join('\n')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^[ \t]*\/\/.*$/gm, '')
}

const REACHES = { desktop: closure(SHELLS.desktop.entry), server: closure(SHELLS.server.entry) }
const ASSEMBLY = { desktop: assemblyOf('desktop'), server: assemblyOf('server') }

describe('a home is complete on its own', () => {
  // The failure mode of every source-scanning guard, named by
  // `plain-words.test.ts`: the collector breaks, finds nothing, passes forever.
  // The numbers are floors under what was measured on 2026-08-18 — 212 and 98.
  it('walked something', () => {
    expect(REACHES.desktop.size).toBeGreaterThan(150)
    expect(REACHES.server.size).toBeGreaterThan(60)
    expect(ASSEMBLY.server.length).toBeGreaterThan(2000)
    expect(HOME_CAPABILITIES.length).toBeGreaterThan(8)
  })

  for (const capability of HOME_CAPABILITIES) {
    for (const home of capability.homes) {
      // Necessary: an implementation the shell cannot even import is an
      // implementation that shell does not have. This is what catches a
      // capability written against Electron.
      it(`${capability.name}: a ${home} home can reach it`, () => {
        expect(REACHES[home].has(capability.module)).toBe(true)
      })

      // Sufficient: and the shell must actually put it together. This is the
      // half §10.1 was missing, and it is the half that fails today.
      it(`${capability.name}: a ${home} home assembles it`, () => {
        expect(ASSEMBLY[home]).toContain(capability.assembles)
      })
    }
  }
})
```

**It fails today, and the shape of the failure is the plan.** Against
`src/headless/host.ts`, which calls exactly `createHostCore`,
`registerRemoteIpc`, `registerMachinesIpc` and `createPublicHost`:

| Capability | reaches | assembles |
|---|---|---|
| The copilot session | ✅ | ❌ `registerCopilotIpc(` |
| Its folder and layer | ✅ | ❌ `scaffoldCopilotHome(` |
| Its tools and its log | ❌ | ❌ `registerDeckControlIpc(` |
| Routines | ❌ | ❌ `createRoutines(` |
| Its memory, read back | ❌ | ❌ `registerCopilotInspectIpc(` |
| The records fence | ✅ | ❌ (built inside the spawn path) |
| Sessions, grants, relay | ✅ | ✅ |
| Devices and pairing | ✅ | ✅ |

Six failing capabilities, twelve failing assertions, and every one of them names
a line somebody has to write. That is worth more than the §9.3 list it duplicates,
because the list can be forgotten and the test cannot.

### 10.4 The three assertions that stop the register rotting

A register maintained by hand is a register that goes stale, and a stale register
turns a guard into decoration. So the register is checked against three things
that move on their own:

```ts
it('covers every tool in the catalogue', () => {
  // A tool added without a home is a capability nobody decided the home of.
  const registered = new Set(HOME_CAPABILITIES.flatMap((c) => c.tools))
  for (const id of assembledCatalogueIds()) expect(registered.has(id)).toBe(true)
})

it('covers every path the records fence names', () => {
  // `recordsFencePaths` is the list of things that are *about* the copilot
  // rather than done by it. Every one of them belongs to some capability, or
  // the fence is guarding something nobody has placed.
  for (const path of Object.values(recordsFencePaths('<userData>'))) {
    expect(HOME_CAPABILITIES.some((c) => c.state !== 'none' && ownsPath(c, path))).toBe(true)
  }
})

it('names what a server home will not have, and only that', () => {
  // The install summary is generated from the register, so the sentence a
  // person is shown before anything is written cannot drift from the catalogue
  // they will actually get. Today the answer is exactly the five browser tools.
  const missing = HOME_CAPABILITIES.filter((c) => !c.homes.includes('server'))
  expect(missing.flatMap((c) => c.tools).sort()).toEqual([
    'browser.handover', 'browser.open', 'browser.read',
    'browser.screenshot', 'browser.step',
  ])
})
```

The third is the one that does the most work. It makes the exception in §0 cost
something: a sixth tool that cannot run on a server has to be *added to that
list*, by hand, in a commit somebody reviews — and the same list is what the
installer prints. There is no way to quietly ship a capability that only half
exists on a server, because the sentence the person reads is generated from the
thing the test asserts.

### 10.5 Two more guards, smaller and still worth having

- **`no-capability-reaches-across.test.ts`** — no module named in the register may
  import `src/main/servers/connection.ts` or `remote/relay-client.ts` *in order
  to satisfy its own capability*. The copilot may drive servers through
  `servers.*` tools; the routine **engine** may not depend on a connection to
  another machine to do its job. This is the difference between a tool and a
  dependency, and it is the shape the invariant will actually be broken in.
- **`fence-tier-is-honest.test.ts`** — §5.4(2). No path produces a claim of
  protection stronger than the tier the install recorded.

### 10.6 Landing it

The guard above is deliberately **not** on disk as a `.test.ts` in this pass.
Another agent is building in `src/main/servers/**` and `src/renderer/machines/**`
in this same working tree and will legitimately run `npm test`; seven red
assertions in a file they do not own is noise they cannot act on. Whoever picks
up §9.3 lands `src/main/home-capabilities.ts` and
`src/main/home-capabilities.test.ts` together as the first commit of that work —
red — and the branch is done when they are green.

---

## 11 · Out of scope for the first version

Named plainly, each with the reason.

| Not in v1 | Why |
|---|---|
| **Two homes at once** | It is the invariant inverted. Two copilots, two memories, two logs, and a person who cannot answer "where does it live". If it is ever built it is *two copilots*, named separately, not one copilot in two places. |
| **Any automatic carrying of memory** | §4.2. The one-time by-hand copy is the whole of it. |
| **Moving a live conversation between homes** | §3.3. The transcript is the CLI's, keyed by a path that does not exist on the other machine. |
| **The drivable browser at a server home** | §G2. Absent, named, never proxied. |
| **Installing a language runtime on somebody's server** | §8.4. That is provisioning, and a half-provisioned server has no way back. |
| **Windows servers** | `SERVERS-DESIGN.md` §7 already rules them out for the facts probe; the fence in §5.2 is POSIX ownership and has no Windows equivalent measured here. |
| **A home inside a container** | The fence's second mechanism does not work on overlayfs and the first needs account creation the image may not permit. It is a real deployment shape and it needs its own measurement, not an assumption. |
| **Per-account cost at a server home** | §G6, and it is downstream of the cost work. |
| **A web UI served by the server component** | The PWA is a way in and already exists; a *second* one served from the server is a second client to keep correct. |
| **Automatic failover of any kind** | The banned word list in §1.4 is doing real work here. There is one home. It is where you put it. |

---

## 12 · Open, and worth his answer

- **Does the account question get measured, or does it get asked?** G3 is the
  blocking unknown. If the Claude CLI's login flow works over a server terminal,
  §8.2 step 4 becomes a step. If it does not, the honest product is "paste a
  token", which `ACCOUNT-MODEL.md` calls *"the opposite of smooth"* — and which
  may still be the right answer for a server, where a person is already doing
  server-shaped things.
- **Two accounts, or one?** §5.2(a) is the strongest fence available on Linux and
  it needs the install to create a user. That is a bigger ask of somebody's server
  than `npm install -g` is. It is defensible — it is the difference between an
  audit log and a file — but it is his call whether the default is to ask, or to
  ask only when the install has the privilege anyway.
- **Does a home belong to the app, or to a project?** Everything in the `foot`
  group is app-wide today, and `SERVERS-DESIGN.md` §9 asks the same question about
  servers. The copilot's folder is already per-app, so this document assumes
  app-wide. But somebody with three servers may want a copilot on each, and that
  is the "two homes at once" this document rules out of v1 — worth knowing whether
  he wants it ruled out of v2 as well.
- **What does the desktop's copilot pane become when the home is elsewhere?** This
  document says it becomes a way in and says the sentence. It does not say whether
  the pane keeps the full window with its model / effort / account cluster, or
  becomes something smaller. Those controls belong to the session, and the session
  is on the server — so they should still work, driven over the connection. That
  is the right answer and it is the one place in this document where "it should
  work" has not been traced to a mechanism.

---

## 13 · An account belongs to a machine

Raised by him on 2026-08-18, and it is a schema change rather than a label:

> *"Since we have accounts switching… we might need that separately for server and
> separate for local machine. So we need to have the selection there — what
> actually we are selecting up there, local machine or ours, which one we are
> switching. Maybe we can have both separately: we can set something else on
> local machine, something else for server side."*

### 13.1 · The collision that already exists

Everything that identifies an account keys on `configDir` **alone**:

| what | key | file |
|---|---|---|
| pooled usage readings | `claudeByAccount.get(configDir)` | `src/main/usage-ipc.ts` |
| the remembered "no subscription limits" answer | `read/write/forget(configDir)` | `src/main/account-limits.ts` |
| the account itself | `profiles[].configDir` | `src/main/profiles.ts` |

A laptop's `/Users/apple/.claude` and a server's `/root/.claude` do not collide, and
that is luck rather than design. **Two Linux servers signed in as root are the same
key.** On the second server: usage readings pool across both, and a `no-limits`
answer remembered for one suppresses the fetch for the other. The reading is then
attributed to a machine it never came from.

This is dormant today only because there is one server. It becomes wrong the moment
there are two, and it will present as "the usage bar shows the wrong number", which
is a symptom nobody traces back to a map key.

### 13.2 · The identity

An account is **where it lives, plus its configuration directory** — `local` and
`/Users/apple/.claude`, or `srv_<id>` and `/root/.claude`. The home is already the
concept this document is built on (§1), so accounts inherit it rather than needing a
second idea.

That also states the rule the invariant implies and nothing enforces today: **a
session's account must belong to the machine the session runs on.** A server session
cannot run as a laptop login — the credential is in a store on the other computer,
and §0 forbids reaching across for it. So the picker on a remote session offers that
machine's logins or none, and "none" is an honest, drawable state.

### 13.3 · What a person sees

The account control names the machine it is choosing for, and each machine holds its
own selection. Codex on the laptop and Claude Code on the server is a legitimate
setup, not a mistake to be reconciled — they are different computers with different
logins and no reason to agree.

When the copilot's home moves (§3), its account moves with it, because the account
is part of the home. That is worth saying on the switch screen: somebody who has
`imzapremium` selected locally and nothing signed in on the server should be told
before the move, not after.

### 13.4 · Migration

Keys already written to disk are bare `configDir` strings. They are all local by
construction — no server has ever been a home — so the migration reads an unprefixed
key as `local` and writes the prefixed form back. It must not delete what it cannot
parse: an unreadable entry is a lost reading, and a lost reading silently re-asks by
typing into somebody's session, which is the defect this whole area spent 2026-08-18
removing.
