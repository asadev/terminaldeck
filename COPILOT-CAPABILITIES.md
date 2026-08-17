# Copilot — Capabilities

**Supersedes `COPILOT-DESIGN.md` where the two disagree.** That file settled the
*mechanism* (a real session, an MCP server, a visible folder, an action log) and
it is still right. This file settles *what the thing is for*, which changed on
2026-08-17, and it changes several assumptions the mechanism was built on.

Written from two studies: OpenClaw read first-hand on this machine, and a survey
of the 2026 developer-agent field. Both are cited inline where a number or a
failure came from them. Facts and thresholds are borrowed; no code is.

---

## READ THIS FIRST — eight things that change what is being built right now

Three agents are writing `deck-control/`, `routines/` and `copilot-*.ts` as this
is written. These are the assumptions the new constraint breaks. Each is small
if fixed now and expensive if fixed after the surface is public.

### 1. The copilot cannot read any project. Every project-facing capability must be a tool, not a file read.

`copilotPlan()` in `copilot-session.ts` grants exactly two paths: the copilot's
own folder and its own confined home. `device.writable` is `[]`. That is
correct and should not change — but it means **`Read`, `Grep` and `Bash` are
useless for anything about the user's code.** "Review this diff", "what does
this repo's CLAUDE.md say", "which tests are failing" cannot be answered by the
native tools. They can only be answered through `deck-control`.

Consequence for the catalogue: the tool surface is not a convenience layer over
things the copilot could otherwise do itself. It is the *entire* aperture onto
the developer's work. Tools like `git.diff`, `project.conventions` and
`sessions.result` are therefore not nice-to-haves — without them the developer
copilot has nothing to be a developer copilot *about*. Size the catalogue budget
(item 8) accordingly.

### 2. The scaffolded `CLAUDE.md` is written for a general assistant and contradicts the tools that are landing.

`copilotInstructions()` in `copilot-home.ts` currently says:

> "You are the assistant for the *app itself* and for the person using it."

and

> "You **cannot** read … other sessions' transcripts, settings, or files"

The first is the framing Asad just ruled out. The second is **false the moment
`sessions.transcript` and `settings.read` ship**, and they are shipping in the
same batch. An instruction file that misstates the agent's own powers is worse
than none — the copilot will refuse things it can do and the user will read a
lie in Settings → Copilot.

Rewrite required, with the sections in §3 and §4 of this document. Because
scaffolding is strictly additive and never overwrites, `copilotHomeReport()`
must flag existing installs as out of date and offer the reset it already
supports.

### 3. `routines/` sits inside the copilot's writable folder. That is a hole, and `copilot-home.ts` already says so.

Its own header:

> "the copilot can write to its own folder, so it can write a routine file, and
> doing so would skip whatever confirmation the eventual `routines.create` tool
> asks for. The scaffolded `CLAUDE.md` therefore tells it not to … An
> instruction is a weaker fence than a permission and it is stated as one."

Correct diagnosis; the fix should not be prose. Goose blocks subagents from
creating or modifying scheduled tasks specifically because an agent that can
write its own next trigger is an automation loop with no human in it. Two
options, either acceptable:

- move `routines/` out of the copilot's confined folder to
  `<userData>/routines/`, reachable only through `routines.*` tools; or
- keep the location and add a `PreToolUse` deny hook on the copilot session for
  writes under `routines/`. A `PreToolUse` deny outranks the permission mode —
  it holds even under `bypassPermissions` — which is the only enforcement in
  the Claude Code stack a flag cannot switch off.

Prefer the first. It is a path change, not a security mechanism, and it cannot
be got wrong.

### 4. A routine cannot answer a confirmation dialog, and today it will deadlock.

Routines run *through* the copilot. The copilot's alter tier blocks on a human.
A routine firing at 03:00 produces `no-approver` or `timeout` from
`ConsentBroker` — a full agent turn spent, nothing done, and (worse) the model
told the call failed for a reason it cannot fix.

This is not hypothetical. It is OpenClaw's recorded failure: the heartbeat tried
to run a script, exec needed approval, heartbeat sessions cannot get interactive
approval, the run died with `approval-timeout`, then again, then `user-denied`.
Each failure spent a turn generating an apology. The fix there was to delete the
command.

Required before the engine ships: a routine run is `read`+`act` only. Alter-tier
tools are refused at the boundary with a distinct reason —
`not-permitted-unattended` — and the refusal text tells the model to report what
it would have done rather than retry. Add the reason to `RefusalReason`; the
engine passes an `attended: false` flag into `DeckControl.call`.

### 5. A remote grant must be per-tier, not a boolean.

OpenClaw advisory **GHSA-943q-mwmv-hhvh (OC-02)**: the HTTP gateway did not deny
session-orchestration tools by default, so anyone holding gateway auth could
call `sessions_spawn` and `sessions_send`. Same tool names, same surface,
phase 4.

So when `remote/folder-grants.ts` grows a copilot grant, its type is
`{ read: boolean; act: boolean; alter: boolean }`, defaulting to read-only, and
`alter` is never grantable remotely at all. "My phone can ask the copilot
things" and "my phone can spawn sessions on my Mac" are different decisions.
Free to decide now; a boolean shipped once becomes a migration.

### 6. `settings.write` needs a last-good snapshot, not just a dialog.

One invalid config value — `tools.profile: "none"`, outside the enum — crashed
OpenClaw's *entire* gateway, not just the agent it was set on. Recovery needed a
different app on a different surface to hand-edit JSON. They now keep
`openclaw.json.bak`, `.bak.1`…`.bak.4`, `.last-good` and `.prebridge`.

`PROTECTED_SETTING_PREFIXES` and `WRITABLE_PREFERENCES` in `catalogue.ts` already
make this narrow, which is most of the defence. Add: copy the settings file to
`settings.last-good.json` before any copilot-originated write, and validate
against the renderer's `settings-schema.ts` before the dialog is drawn, so a
confirmed-but-invalid write cannot land. A confirmed brick is still a brick.

### 7. `sessions.list` should return attention, not just status.

`SessionStatus` is `idle | working | waiting | input | completed | exited`. The
copilot has to know that `input` means *a human is blocking this agent* and
`idle` means *nobody is blocking anything* — and it has to know it per provider,
because `hooks.ts EVENT_STATUS` maps different events to `input` for Claude
(`PermissionRequest`, `Notification`) than for Gemini.

Make `viewOf()` derive it once: `attention: 'blocked' | 'running' | 'quiet' |
'done'`, plus `attentionForMs`. The most-reported supervision defect in the
whole field is that blocked, idle and working share one badge. Terminal Deck
already computes all three (`session-activity.ts` classify, `idle.ts`,
`alerts.ts BLOCKED_WARNING_MS = 10m` / `BLOCKED_CRITICAL_MS = 45m`); it just is
not handed to the copilot pre-digested. Ten lines, and it is the difference
between the fleet-triage capability being one tool call and being fifteen.

### 8. Pin a *token* budget on the catalogue, not a character length.

`catalogue.test.ts` pins the assembled length. Make it pin an estimated token
count and fail above a ceiling. A tool definition costs 100–500 tokens in
*every* turn; GitHub's MCP server is ~55K tokens for 93 tools; reported
degradation starts around 5–7 connected servers. `deck-control` is a permanent
server on a permanently-open session, so its schema is a standing tax on every
question Asad asks.

Working numbers: **hard cap 20 tools and 8,000 estimated tokens assembled.** Past
that, switch to progressive disclosure (a `tools.describe` meta-tool) rather
than adding definitions. The current 11 tools are comfortably inside it; the
capabilities below add roughly five more, which is still inside it. Write the
budget into `catalogue.ts` as a constant so the next agent to extend it has to
argue with a number.

---

## 1. What this is for

The copilot is a **developer's assistant that supervises other agents.** You are
running three, five, eight coding sessions across your projects; it is the one
agent that can see all of them at once — their ptys, their transcripts, their
git state, their cost, their lifecycle — and it is pinned above the session list
so you can ask it things and give it work. Its job is the part of agent-assisted
development that no coding agent can do for you, because a coding agent knows
only its own session: telling you which of the eight needs you right now,
telling you what the overnight run actually changed and where the evidence is,
noticing that one of them has been retrying the same broken approach for forty
minutes, turning "fix the flaky auth test" into a properly-scoped prompt with a
repo, a base branch and a definition of done before it spends your money, and
remembering that this project uses `pnpm` and that you decided against Redis in
March.

It is **not** a general personal assistant. It has no inbox, no calendar, no CRM,
no social posting, no notes app, no shopping, no travel, no home automation, no
voice. It does not do your marketing, write your emails, or check in on how your
week is going. Those exclusions are the decision, not an oversight: OpenClaw's
messaging layer is the single largest part of that product and it is the part
that was deliberately cut. Everything here serves someone trying to ship code,
and a feature that would be equally at home in a general assistant is out of
scope by that fact alone.

---

## 2. The capability list

Ordered by value to someone shipping code. Sizing is honest and assumes the
`deck-control` surface, the routine engine and the copilot session all land as
currently built.

| Size | Means |
|---|---|
| **already-possible** | Instruction text or a constant. No new subsystem. |
| **small** | One tool, or one derived field, over data that already exists. |
| **medium** | A new module, but every input it needs is already computed. |
| **large** | A subsystem that does not exist. |

---

### 2.1 Fleet triage — "who needs me?"

**What it does.** One question, one answer, over every session at once: which
agents are blocked on a human and for how long, which are running, which went
quiet without finishing, which are done. Ranked by who is costing you wall-clock,
not by tab order. Asked conversationally ("anything stuck?") and answered in
three lines, not a table dump.

**The problem.** You have eight sessions in the sidebar. Three are thinking, one
is sitting on a permission prompt it hit twenty minutes ago, one finished at
09:04 and nobody noticed, one died. Every one of them shows as a coloured dot.
Finding the blocked one costs a click through all eight — so you stop checking,
and a blocked agent burns wall-clock silently until you next happen to look. This
is the most-reported supervision defect across the entire parallel-agent field
(daintree #3940; JetBrains LLM-20346; vscode-copilot-release #13592).

**Built on.** `sessions.list` + `SessionView.status/statusSince`;
`session-activity.ts` `classify()` (which reads the settled emulator viewport, so
it works for unrendered tabs); `hooks.ts EVENT_STATUS` for the provider-specific
`input` mapping; `alerts.ts` `blockedAlerts()` with its existing 10-minute and
45-minute thresholds; `idle.ts` for the clock.

**Size: small.** The derived `attention` field in item 7 above, plus a sentence
in the copilot's `CLAUDE.md` telling it to lead with the blocked ones. Everything
else exists.

**Sharp edge.** "Blocked" must never be guessed from screen scraping alone when a
hook has spoken. `input` from a `PermissionRequest` hook is a fact; a regex
against the viewport is an inference. When they disagree, the hook wins, and the
tool result should say which one it used.

---

### 2.2 Scoped prompt before spawn — turn a vague ask into a real brief

**What it does.** You say "get the flaky auth test fixed". It asks five to ten
clarifying questions — which repo, which test, is `main` the base, do you want a
branch, what counts as done, may it touch the fixtures — writes the answers into
a durable spec file at `<copilot>/specs/<slug>.md`, shows it to you, and only
then calls `sessions.start` with that spec as the initial prompt. The session
links back to the spec and the spec links forward to the session.

**The problem.** The named failure mode of parallel agent work is that
*ambiguity multiplies*: an under-specified ask propagates through several runs,
each going slightly wrong in a slightly different direction, and you discover it
at review time across all of them at once. The copilot is the one agent that is
allowed to be slow, because the sessions it starts are the ones that cost money.
A spec is also re-runnable when the first attempt fails, which a chat message
scrolled off the top is not.

**Built on.** `copilot-home.ts` (add `specs/` to `CopilotPaths` and the scaffold);
`sessions.start`; the existing `origin: 'copilot'` + `originRunId` fields in
`shared/types.ts`, which already give the both-ways link.

**Size: small.** One folder, one paragraph of instruction, one field on the start
call recording the spec path.

**Prompt discipline to copy verbatim** (from OpenClaw's `coding-agent` skill,
which is the most transferable thing in that product): state the repo, the base
branch and the expected proof up front; write the worker prompt to a file rather
than passing it through a shell; and never start a worker inside an active state
directory — which here means **a copilot-started session may never have
`<userData>` or any path under it as its cwd**, enforced in `sessions.start`, not
in prose.

**Gate.** Beyond two concurrent copilot-started sessions in the same repo, this
needs §2.11 (worktrees). Until that lands, `sessions.start` should refuse a
second session in a cwd that already has one and say why.

---

### 2.3 Stuck-and-looping detection

**What it does.** Flags a session that is spending money without making progress:
the same tool hammered with the same arguments and the same error, output
byte-identical across consecutive windows, context climbing steeply with no file
writes, or the specific signature of context-overflow → compaction → immediately
re-doing the thing that overflowed it.

**The problem.** Agents "loop endlessly trying the same broken approach"; Devin
is specifically criticised for spending significant time on the wrong solution
without recognising it. An unattended session in a loop is the failure that turns
a copilot that can spawn sessions into a liability. It is also the cheapest
safety feature in the design and the one most often skipped.

**Built on.** `session-insights.ts` — already validated against 133 real
transcripts, and already computes `ToolStat` (hammered tool, failing tool),
`CompactionMarker` and `ContextPoint` (context growth). `alerts.ts`
`heavySessionAlerts()` already has the cost side with tuned thresholds
(`HEAVY_MULTIPLE = 3`, `HEAVY_MIN_TOKENS = 1_000_000`). `PtyManager.screen()`
gives the settled viewport for the byte-identical check.

**Size: medium** for the good version, **small** for the first one.

Ship the cheap version first: a new `loop` alert kind derived from what
`session-insights` already aggregates — same tool name, same failure, ≥N times,
no file write in the window. OpenClaw's tuned numbers are worth taking as
starting values: warning at 10 repeats, critical at 20, hard stop at 30, over a
rolling window of 30 tool calls.

The expensive version is the `(tool, args, result)` triple within a 3-step window
after a compaction retry. That needs argument-level parsing of the JSONL, which
`parseInsightLine` is close to but does not do. Worth it later; not worth
blocking on.

**Honest limit.** This works for sessions that write a JSONL transcript. For a
plain shell there is nothing to parse and the only signal is the byte-identical
screen. Say so in the tool result rather than reporting "no problems found".

---

### 2.4 Diff review before it lands, attributed per session

**What it does.** "What has actually changed?" answered across every running
session at once — these four sessions have touched eleven files between them,
here is the diff, here is which session did which. Then: read it, comment on it,
flag the one that touched a file nobody asked it to.

**The problem.** *Verification, not generation, is the bottleneck* — the one point
every 2026 retrospective agrees on. Reading a transcript to find out what an
agent changed is the slow path. Devin users report a 10–20 minute per-task
babysitting tax against a 15–30 minute net gain; Anthropic's own 2026 figure is
that developers use AI for ~60% of their work but can fully hand off 0–20%. A
feature that produces more agent output without producing more *reviewable*
output makes this worse. The diff is the reviewable unit.

**Built on.** `git.ts` already has `readFileDiff`, `parseNumstat`,
`readGitStatus`, `repoRelative` and a live watcher via `onGitStatusChanged` /
`holdGitWatch`. The diff-first review surface is the near-universal architecture
in the field (Conductor, Nimbalyst, Sculptor, Vibe Kanban, Cursor 3) — and none
of them have an agent you can *talk to* about the diff.

**Size: small–medium.** Two pieces:

1. A `git.diff` tool (read tier) returning a bounded unified diff for a cwd,
   with the same three-way bounds discipline `sessions.transcript` already uses
   and the same honesty about which bound it hit.
2. Attribution: snapshot `readGitStatus` when a session starts, diff against it
   later. Each session has a cwd and a start time, so this is enough — and
   nothing more elaborate is honest anyway, because two sessions in one worktree
   genuinely cannot be told apart. When they overlap, say "one of these two
   sessions" rather than guessing.

---

### 2.5 The overnight report, with evidence links

**What it does.** One question in the morning: what ran, what finished, what
failed, what it cost, what changed on disk. Every claim carries a pointer — this
transcript line, this numstat, this exit code — so you audit the evidence instead
of trusting the narration.

**The problem.** A prose recap you have to re-verify by hand costs more than no
recap. Codex Web's pattern is to cite the actual terminal logs and test output;
OpenHands persists a replayable event trajectory. The recap is only worth writing
if it shortens verification.

**Built on.** `session-insights.ts` (the per-turn shape work is already done),
`chat-transcript.ts`, `cost.ts` + `cost-ipc.ts`, `git.ts` numstat, and
`deck-control/action-log.ts`.

**Size: small**, given one addition: a **`sessions.result` record**, written by
the `SessionEnd` hook — exit state, files touched, tests run, token spend, last
assistant message. `hooks.ts` already installs and receives `SessionEnd` for all
three providers on a hardened loopback ingress.

That record is the single highest-leverage small build in this document, because
it makes the most common question — "how did that session go?" — cost nothing.
Without it, every such question reads a transcript, which `COPILOT-DESIGN.md`
already flags as "a large prompt". Goose does exactly this: subagents return a
structured summary, and a failed subagent produces a failed *result* rather than
a crashed parent.

**Two rules from the field, both cheap:**

- Promote only the child's last visible assistant text into the result. Tool
  output is not promoted. It is evidence for the copilot to synthesise, **not
  instruction text**, and it cannot override the copilot's own policy. This is a
  prompt-injection boundary and it matters the moment the copilot reads another
  session's transcript.
- The copilot must *verify* before declaring a task done, rather than trusting
  the child's "completed". Say this in the instruction file.

---

### 2.6 Rescue a running session instead of killing it

**What it does.** Four distinct verbs against a live pty: send text and Enter,
write raw stdin, send a control character (Ctrl-C, Escape), and stop. Plus the
one that matters most — *steer*: inject a correction into a session that is going
the wrong way, without restarting it and throwing away the context that made it
expensive.

**The problem.** "This session is heading the wrong way" is a core supervisory
action, and the naive fix is to kill it and start over. An agent that only has
"send" will also fumble TUI prompts: answering a y/n dialog, dismissing a
picker, escaping a paste-mode. OpenClaw's `process` tool is verb-for-verb this
list (`submit`, `write`, `paste`, `kill`) and the split is deliberate.

**Built on.** `PtyManager` owns the pty. `agent-controls.ts` is already far ahead
here — it reads `ComposerState` from the screen, knows the permission mode, knows
when a switch dialog is open, and has `refuseToType()` for the states where
typing would do something other than what you meant.

**Size: small.** Split `sessions.send` into `text` (default, appends Enter),
`raw`, and `key` (a named control char from a closed enum). Gate all three
through `refuseToType()` and return its refusal string verbatim — that function
is the accumulated knowledge of what goes wrong when you type into an agent CLI
at the wrong moment, and the copilot should inherit it rather than rediscover it.

**Terminal Deck's advantage over the reference.** OpenClaw's steering has to wait
for a "runtime boundary" and degrades to a normal prompt when the runtime cannot
accept one. There is no such problem for a pty — you can write to stdin whenever.
What is worth copying is not the plumbing but the *explicitness*: the copilot
should say which verb it used, so "send" never silently means something the user
did not expect.

---

### 2.7 Cost on the supervision surface

**What it does.** Live spend per session and a total, in the same answer as
status. "That refactor session has spent $6.40 and hasn't written a file in
twenty minutes."

**The problem.** A survey of ten parallel-agent managers found cost and token
dashboards **absent from all of them**. Terminal Deck already computes it. That
makes it the cheapest differentiator in the product, and it answers the open
question `COPILOT-DESIGN.md` leaves about a spend ceiling — you cannot set a
ceiling on something you cannot see.

**Built on.** `cost.ts` (`TokenUsage`, `contextUsage`, `contextWindowFor`,
`isBillableModel`), `cost-ipc.ts`, `usage-ipc.ts`, `plan-limit.ts`. Per-message
cost is in the transcript the copilot already reads, so no separate accounting is
needed.

**Size: small.** One `sessions.cost` tool (read tier) and a ceiling enforced in
`sessions.start` — copilot-started sessions carry a budget; hitting it stops the
session with a reason rather than throttling silently. The catalogue's own note
says cost was deliberately omitted because "the cost work is landing in
parallel". Correct call at the time. It has landed; add the tool.

**Two follow-ons worth the lines:**

- Show a size estimate before an expensive read. OpenClaw's `oracle` skill
  previews the payload and token spend with a dry run *before* spending
  anything. "Reading that transcript will cost about 40K tokens — go ahead?" is
  exactly the right interaction for the copilot's most expensive routine action.
- Put the token cost of the turn on every `actions.jsonl` row, and the routine
  id when the caller was a routine rather than a person.

---

### 2.8 Project memory — conventions, decisions, and why it is like this

**What it does.** Remembers per-project facts that change how it answers next
time: this repo uses `pnpm`, the typecheck command is `npm run typecheck` and it
must pass before anything counts as done, we decided against Redis in March and
here is why, the flaky test is flaky because of the clock and not the network.
Then applies them without being asked — the spec it writes in §2.2 already
contains the repo's conventions.

**The problem.** Every new session starts from zero on facts the last five
sessions learned. The developer re-types the same three constraints into every
prompt, or forgets one and gets a PR that uses the wrong package manager.

**Built on.** `<copilot>/memory/`, one file per fact, already scaffolded with a
front-matter convention in `copilot-home.ts`. Format detail in §4.

**Size: already-possible for storage, small for retrieval.** The storage is
files it can already write. What is missing is the *trigger*: today the index is
read at startup, so the startup read grows without bound. Add path and keyword
triggers so a memory file about `~/Projects/science-locus` loads when that
project is the subject and not otherwise — the pattern `.claude/rules/` and
OpenHands' keyword-triggered microagents both use.

**Hard constraint, from Asad directly.** The copilot's memory is **its own
conversation only**. It may read other sessions' transcripts; it may not copy
them into `memory/`. See §4.

---

### 2.9 Transcript archaeology across every session

**What it does.** "What did we decide about the auth refactor last week?" "Which
session burned all those tokens on Tuesday?" "Show me what that agent actually
did." Grep across *all* sessions' transcripts, not just its own.

**The problem.** Half of what you want to remember is not in any memory file — it
is in a conversation that happened in a session you closed. A CLI agent can grep
its own history. Terminal Deck stores every session's transcript, so the copilot
can grep the whole fleet's, which is strictly more valuable and nobody else can
do it.

**Built on.** `transcript.ts` (`encodeProjectPath` and the project-path index),
`chat-transcript.ts` (the bounded reader), `file-search.ts`,
`session-insights.ts` for the cost side.

**Size: small.** A `sessions.search` tool: a query, an optional cwd and date
range, returning matching message excerpts with session id and timestamp — with
the same bounds discipline and the same reporting of which bound it hit.

**Blocked on a known bug.** `INTEGRATION-OWED.md` records that
`encodeProjectPath` is wrong for every WSL path (`path.resolve` turns
`/home/asad/…` into `C:\home\asad\…` on a Windows host). Chat view and cost read
the same encoded directory. Fix that first or this tool silently finds nothing on
Windows and reports it as "no results", which is the worst possible failure for
a search tool.

**Rule.** Results go into the answer. They never go into `memory/`. §4.

---

### 2.10 Preflight — "can this machine even do that?"

**What it does.** Before starting work: is the CLI installed, is that profile
signed in, is the worktree dirty, is the folder inside a confinement grant, is
the provider rate-limited right now. Answered as "you don't have `gh` — install
it with `brew install gh`", not as a failure at step four.

**The problem.** The most annoying agent failure is the one that happens after
ten minutes of setup, for a reason knowable in one second. OpenClaw's skills
declare `requires: { bins: [...] }` and `openclaw skills check` reports what is
ready — the readiness answer is worth more than the capability list.

**Built on.** `prerequisites.ts`, `agent-binaries.ts`, `profiles-signin.ts`,
`plan-limit.ts`, `git.ts readGitStatus`, `confine/plan.ts`.

**Size: already-possible.** These are all read-tier facts the app computes for
its own panes. One `deck.readiness` tool folds them into one call — which is
better than five tools, per SWE-agent's finding that consolidating important
operations into as few actions as possible moves the score more than the model
does.

**House rule to adopt:** *stop on a dirty worktree unless confirmed.* Every
copilot-started session, every time.

---

### 2.11 One worktree per copilot-started session

**What it does.** Each session the copilot starts gets its own git worktree, so
two agents never edit the same file and each result is reviewable and mergeable
independently.

**The problem.** It is the only mechanism that makes "start three sessions on
this" safe. Without it, copilot-started sessions collide in the working tree and
you arbitrate merge conflicts you did not create. This is the near-universal
architecture everywhere else — Conductor, Crystal/Nimbalyst, Claude Squad,
Cursor's parallel branches, Sculptor with containers — and Terminal Deck has no
worktree concept at all. The only hits in the codebase are a warning comment in
`github.ts` that two worktrees of one repo look like two repositories, and a
path-encoding test.

**Size: large,** and it is a real subsystem: create/list/prune worktrees; teach
the project model that a worktree is a *view* of a project rather than a new
project; teach confinement to grant the worktree root; teach `transcript.ts` that
two encoded project paths can be the same project.

**Sequencing.** It should land before `sessions.start` becomes routine, not
after. Until then the interim is the refusal in §2.2 — one copilot-started
session per cwd — which is a two-line guard and honest about why.

---

### 2.12 Concurrency ceiling

**What it does.** Caps simultaneous copilot-started sessions at a product
default.

**The problem.** Past roughly five, the review queue outruns the reviewer and
parallelism produces review debt instead of throughput. The failure is human, not
technical. The reported sweet spot is 3–5 teammates (token cost scales linearly
with team size) and 3–10 for worktree orchestrators. Asad's own memory records
the same number independently from his parallel-agent work: 4–7.

**Size: already-possible.** A constant and a guard in `sessions.start`. Default
**5**, user-adjustable, refused with the reason rather than queued silently.

---

### 2.13 Checkpoint and rewind, including shell damage

**What it does.** A cheap git stash or tag before a copilot-started session
begins and before any alter-tier action, so "undo what that agent did" is one
command.

**The problem.** Autonomy is only tolerable with an undo. Claude Code has
`/rewind` over file snapshots and Gemini CLI has project-state snapshots — and
both share a documented gap: **changes made through Bash are not captured**,
which is most of what an agent does that actually hurts.

**Size: small–medium**, and it is a genuine improvement on the reference rather
than a copy. Terminal Deck owns git *and* the pty, so a per-session tag at start
covers shell damage the originals miss.

**Care required.** This writes to the user's repo. It must never create a commit,
never touch the index, and never run in a repo mid-rebase or mid-merge — check
for `.git/rebase-merge`, `.git/MERGE_HEAD` and friends and skip with a stated
reason.

---

### 2.14 Playbooks — one procedure, many repos

**What it does.** A written procedure runs across a set of projects: "upgrade the
lockfile in all nine", "add the typecheck gate everywhere it's missing", "check
which repos are behind on the shared config". Results come back in a shape you
can compare across repos.

**The problem.** This is the developer-shaped version of "routine tasks" — the
thing a general assistant would point at email. Devin sells it as playbooks;
Goose does it as recipes with `sub_recipes` returning structured summaries.

**Built on.** `projects.list` already exists, so "this project, then that one" is
reachable. `sessions.result` (§2.5) is the comparable shape.

**Size: medium.** A routine whose scope is a *set* of projects rather than one,
plus the concurrency ceiling from §2.12 applied across the set, plus a rollup.
Needs worktrees to be safe at any real width.

**One correctness detail worth lifting whole.** OpenClaw's `gh-issues` skill
does three duplicate checks before starting anything — existing open PR, existing
`fix/issue-<n>` branch, active local claim — and writes a claim file that
**expires after two hours**, because a permanent claim leaks forever when a
worker dies. Terminal Deck can do better than a file, since it knows whether the
session holding the claim is still alive. Do that: the claim is a live session,
and a dead session's claim is void.

---

### 2.15 Run it on the other machine

**What it does.** "Run the test suite on the Linux box." The same session start,
routed to a paired node instead of this Mac.

**The problem.** Real developer need, and Terminal Deck has the transport already
— `relay.terminaldeck.dev`, a proven headless host, Mac→Windows execution
demonstrated.

**Size: medium**, mostly because of the security shape rather than the plumbing.

**Two rules from the reference:** a node should *advertise its capabilities* so
the copilot picks a target that can actually do the job instead of guessing; and
node execution keeps a **separate** approvals store from local execution —
approving something here must not approve it on the shared box. Terminal Deck's
confinement grants are already per-device, so this lines up.

**Not before phase 4**, and after §5's remote tier split.

---

## 3. What it must refuse

Two kinds of refusal. The first is scope — things that are simply not this
product. The second is safety — things the research showed go wrong.

### 3.1 Out of scope, by decision

It does not read, write, send or manage: **email, calendar, contacts, messaging
(WhatsApp / Telegram / Slack / Discord / iMessage / Signal), social posts, CRM
records, documents, spreadsheets, notes apps, reminders, travel, shopping, home
automation, media playback, or voice.**

It does not do proactive personal check-ins — "you mentioned an interview, how
did it go". OpenClaw's `commitments` feature is exactly that and it is excluded.

Why the line is drawn there and not further out: those capabilities are the
majority of a general personal assistant, they each carry an integration, a
credential and a failure mode, and none of them helps anyone ship code. If a
proposed capability would be equally at home in an assistant that had never seen
a repository, it is out.

**One borderline case, resolved.** OpenClaw's *commitments* mechanism — a hidden
background pass that extracts short-lived open loops from a conversation and
surfaces them later, capped at three per day — is excluded as designed but has a
real developer analogue: "you said you'd come back to that flaky test", "the
migration is being designed in session 4, don't edit the API from here yet". The
useful part is the *shape* of such a note: for anything that changes future
behaviour, record when it applies, when it expires, what unlocks it, and where it
came from. That belongs in the memory format (§4). The personal check-in
behaviour does not.

**The other borderline case, resolved.** Notification *routing* is excluded as a
channel feature. But the requirement underneath it survives: **a routine must
have a defined place its failure appears.** See §5.

### 3.2 Refused for safety

Each of these is a recorded failure somewhere, not a hypothetical.

1. **It never edits Terminal Deck's own state directly.** Not `settings.json`,
   not `state.json`, not the session store, not `routines/` by hand. It calls the
   tool. The copilot's confinement already makes this impossible for `<userData>`
   — keep it that way, and do not "helpfully" widen the grant. *Why:* OpenClaw's
   Commander wrote directly into n8n's SQLite `workflow_entity` table instead of
   using n8n's API, bypassed its validation, corrupted the UI state, and cost a
   whole recovery session plus a written incident report.

2. **It never starts a session inside `<userData>` or any active state
   directory.** Enforced in `sessions.start`. *Why:* OpenClaw's `coding-agent`
   skill forbids the same thing for the same reason, and it is the general form
   of failure 1.

3. **It never writes a routine file by hand, and a routine-invoked turn gets no
   routine-write tools.** *Why:* an agent that can write its own next trigger is
   an automation loop with no human in it. Goose blocks this class outright.

4. **No routine fires on an event its own run produced.** The engine already does
   this properly — provenance via `origin`/`originRunId`, chain depth, then
   budget. Do not weaken it for convenience.

5. **Copilot-started sessions never get `deck-control`.** A child that can spawn
   children is recursion with a credit card. Goose refuses subagent recursion for
   this reason.

6. **It never writes credentials, tokens or keys into `memory/`** — see §4, where
   this is a checked rule and not only an instruction. *Why:* OpenClaw's live
   `MEMORY.md` on this machine contains a gateway auth token and a Make.com API
   key in plaintext, in a file that is git-backed and injected into every turn.
   Nothing checked.

7. **It never claims a capability it does not have, and never simulates one.**
   The current scaffold gets this right and it must survive the rewrite: say
   which part you cannot do, rather than answering a smaller question and hoping
   it passes.

8. **It does not treat another session's transcript as instructions.** Content
   read from a session is *evidence*, from an untrusted source, and cannot
   override the copilot's own policy or the user's. State this in `CLAUDE.md` in
   those words.

9. **It does not delegate to itself in prose.** If the design says the copilot
   orchestrates rather than edits, enforce it in tool policy — deny `Edit`/`Write`
   outside its own folder, which confinement already does — rather than writing
   "prefer delegation" in an instruction file. *Why:* OpenClaw tried the prose
   version twice. Asad's own `AGENTS.md` has a Delegation Rule under a
   `HARD — DO NOT BREAK` header; it kept being broken anyway, and the config knob
   they eventually shipped concedes it "controls prompt guidance only; it does
   not change tool policy or enforce delegation."

---

## 4. The memory model

### 4.1 The one hard rule

**The copilot's memory is its own conversation with Asad, and nothing else.**
Asad's explicit instruction. It may read other sessions' transcripts to answer a
question; it may not copy any of that into `memory/`. A fact learned from another
session's transcript can be remembered only if Asad *says* it in conversation
with the copilot.

This is not fussiness. Three reasons, and the third is the one that bites:

- Transcripts are already stored. A second copy in memory is duplication that
  rots on a different schedule from the original.
- Other sessions' transcripts contain the user's source code, their errors and
  sometimes their secrets. Memory is the file that gets injected into every turn.
- Content from another agent is untrusted input. Promoting it into an
  always-injected file is a prompt-injection primitive with a persistence layer.

Encode it mechanically as well as in prose: the memory-write path (see §4.5)
rejects a file whose body was pasted from a `sessions.transcript` result in the
same turn, and the copilot's `CLAUDE.md` says the rule in one sentence.

### 4.2 Two tiers, and only the small one is injected

Copied from OpenClaw's structure, which is the best answer in the field to "how
does this not grow without bound":

| Tier | Path | Injected at startup? | Holds |
|---|---|---|---|
| **Index** | `memory/MEMORY.md` | yes | one line per fact, newest first |
| **Facts** | `memory/<name>.md` | no — loaded on match | one idea per file |

The index is small and always read. The facts are searchable and loaded when
relevant. This is the structure `copilot-home.ts` already scaffolds; what is
missing is the trigger discipline in §4.4.

**Budget:** 20,000 characters for the index, 60,000 characters total across every
file the startup read touches. Those are OpenClaw's shipped numbers and they are
tight in practice — Asad's real `MEMORY.md` is 13,291 bytes, two-thirds of the
cap, while his `memory/` folder holds 37 files, several of them 14–31KB. When the
index exceeds its budget, **the file on disk stays intact and the injected copy is
truncated**, and the truncation is *shown in Settings → Copilot* as the signal to
move detail down into fact files. Silent truncation is a cost increase nobody can
see; a visible one is a prompt to prune.

Settings → Copilot should show injected size against on-disk size, the way
`openclaw doctor` does. `copilotStartupFiles()` already enumerates exactly what
is read, so this is a number next to a list that already exists.

### 4.3 What a fact looks like

The front-matter block already in the scaffold, with three additions:

```
---
name: science_locus_uses_pnpm
description: "science-locus builds with pnpm, not npm"
type: convention          # convention | decision | preference | mistake | boundary
scope: ~/Projects/science-locus    # or "global"
modified: 2026-08-17
verified: 2026-08-17      # last time this was checked against reality
expires: null             # for facts with a known lifetime
---

The lockfile is pnpm-lock.yaml and `npm install` will fight it.
Decided when the workspace was split, 2026-05.
```

- **`scope`** is the load trigger. §4.4.
- **`verified`** exists because the two worst memory failures found in OpenClaw's
  live install were *durability* failures, not retrieval failures: the curated
  file still said GitHub was authenticated as `AsadIqbalOnline` months after that
  account was retired and everything moved to `asadev`. No amount of better search
  fixes a confidently wrong fact. **Anything about accounts, credentials, paths or
  URLs must carry `verified`, and the copilot must state the date when it uses
  one that is older than 30 days.**
- **`expires`** carries the action-boundary idea from §3.1: a note that changes
  future behaviour records when it stops applying.

`type: boundary` is the one worth naming separately — "don't touch the API from
here while the migration is being designed in session 4" is a fact with a
lifetime and an unlock condition, and it is the most useful memory shape for
someone running several agents at once.

### 4.4 It loads what applies, not everything

Today the index is read at startup, so the startup read grows monotonically with
everything ever learned. Two triggers fix it:

- **Path scope.** A fact with `scope: ~/Projects/foo` loads when the conversation
  is about that project — which the copilot knows from `sessions.list`,
  `projects.list` or the user naming it.
- **Keyword.** The index line carries the fact's `description`; a cheap keyword
  match over the index decides what to open. `file-search.ts` already does the
  search half.

Add a **pre-reply retrieval pass**, conditional rather than unconditional: match
the index first, and only open fact files on a hit. Startup-only reads miss
anything outside the loaded set; an unconditional retrieval turn per reply costs
a turn every time. The conditional version is the compromise, and it is what
keeps §4.2's budget achievable as the folder grows.

### 4.5 What it never writes

- **Credentials of any kind** — tokens, keys, passwords, cookies, connection
  strings. Not "avoid"; *never*. Enforce it: the memory-write path runs the
  entropy/shape check that `scrubArgs` in `action-log.ts` already implements, and
  refuses the write with the offending line quoted back. This is the one place a
  check beats an instruction, because the recorded failure is exactly an
  instruction that was ignored.
- **Another session's transcript content.** §4.1.
- **Conversation contents.** The transcript is already saved. A memory is a thing
  that changes how the next answer is given, not a diary.
- **Anything about the user that is not about shipping code.** The scope
  exclusion in §3.1 applies to memory too — the copilot does not accumulate a
  personal profile.

### 4.6 How it stays useful instead of becoming sludge

Four mechanisms, in descending order of how much they matter.

**1. Pre-compaction flush — the anti-amnesia backstop.** Before a compaction
summarises the copilot's conversation away, run one silent turn whose only job is
"write anything worth keeping to `memory/` first". **On by default, no
configuration.** This is the single best mechanism found in the whole study,
because it is the difference between an agent that remembers because it was
disciplined and one that remembers because the runtime made it. It is directly
validated by failure: Asad's own `AGENTS.md` contains a shouted rule — *"This rule
was established multiple times and kept getting lost because it was only in
session memory. Now it's here permanently. DO NOT IGNORE THIS."* The flush turn
is the mechanical version of that rule, and it is why the prose version stopped
being necessary.

Pin it to a cheap model. It is housekeeping and should not cost frontier tokens.

**2. Weekly prune, default on.** A shipped routine (§5) that re-reads `memory/`,
merges duplicates, resolves contradictions, deletes what is no longer true, and
**logs every deletion to the action log** so the human can see what went. Working
practice in 2026 is to keep memory files under ~300 lines and delete most of what
auto-generation produces, because every line competes for attention. The named
failure is *memory pollution*: superseded facts that stay retrievable and quietly
degrade output — invisible, because it looks like the model getting dumber.

One-file-per-fact is the right substrate for this precisely because it makes
deletion cheap.

**3. Default-on or do not build it.** OpenClaw's scored-promotion system —
short-term recall scored on recall count, query diversity and recency, promoted
into long-term memory past a threshold — is a genuinely good design. In Asad's
live install it ran **approximately once**: the store was last written
2026-04-09, every entry reads `recallCount: 1`, and `DREAMS.md` was never created,
because dreaming is opt-in and off by default and he never turned it on. And the
daily logs stop dead after 2026-04-09 — four months of nothing.

The lesson is not "build scoring". It is: **consolidation must be default-on and
cheap, or it does not happen.** An opt-in background sweep is an opt-in that never
gets opted into. Do not build the scoring system. Build the weekly prune, on by
default.

**4. Behaviour goes in `CLAUDE.md`, facts go in `memory/`.** Two classes of
instruction with different homes. A behavioural rule written into memory is a
rule that will be forgotten, because memory is not always injected — which is the
whole point of memory not being always injected. If the copilot learns a *rule*
("always run typecheck before saying done"), it proposes an edit to `CLAUDE.md`
and the user accepts it; it does not file it as a memory.

### 4.7 In-memory pruning of tool output

The copilot's job is reading other sessions' output, so it will drown in tool
results long before it drowns in conversation. Before each request, trim old
**tool results** — not conversation text — from the in-context history: soft-trim
oversized ones to head + `…` + tail, hard-clear the rest to a placeholder.

Two rules make it safe: **it is in-memory only and never rewrites the on-disk
transcript** — which matters more here than in the reference, because the
transcript *is* a product feature — and it is keyed to the prompt-cache TTL so a
trim does not bust the cache mid-window. Cheaper and less lossy than compaction;
try it first.

**Size: small**, and it belongs to whoever owns the copilot session's request
assembly.

---

## 5. Routines worth shipping by default

Not a framework — the engine exists. These are the actual files that should be in
`routines/` on a fresh install, most disabled until switched on, each one a
developer would recognise.

Every trigger below is an **event**, per the standing preference. The engine
already subscribes rather than polls, and its trigger table maps one-to-one onto
what follows.

### The schema each file must carry

`format.ts`'s `Routine` has triggers, folder, prompt, overlap, budgets and
`expectEveryMs`. Add the two fields that make an autonomous routine safe, from
OpenClaw's standing-orders format:

- **Approval gate** — what inside this routine needs a human, given that the
  routine itself cannot answer a dialog (READ-FIRST item 4). In practice this
  means: what it should *stop and report* rather than do.
- **What NOT to do** — as its own heading. In Asad's own `AGENTS.md` the rules
  that actually held were the ones written as prohibitions under a hard header;
  the aspirational positive rules decayed.

And one field with a failure behind it: **`onFailure`** — where this routine's
own failure appears, plus a consecutive-failure count that **disables the routine
after N and says so**. *Why:* OpenClaw's live `jobs-state.json` on this machine
shows a daily job at `consecutiveErrors: 68` with `lastError: "Unknown system
error -11"` and `delivery: { mode: "none" }`. Sixty-eight consecutive silent
failures. The agent mentioned it conversationally once, in April, and then it
just kept failing. A routine with no failure destination is invisible, and
invisible automation is rot. `expectEveryMs` is already half of this; finish it.

### The default set

**1. `blocked-agent.md` — trigger: `session-idle 10m` where status is `input`.**
Tell me which agent is waiting on me and what it is asking. The single most
valuable routine in the list, because a blocked agent is pure wall-clock loss.
Threshold matches `alerts.ts BLOCKED_WARNING_MS`. Digest, not one alert per
session.

**2. `stuck-session.md` — trigger: `alert` where kind is the new `loop` kind.**
Look at the session, decide whether it is genuinely looping, and if so report
what it has been retrying and what it has spent. Does *not* kill it — reporting
is the routine's job; stopping is Asad's. (§2.3.)

**3. `session-failed.md` — trigger: `session-failed`.** Read the tail, say in two
lines why it died and whether it is worth restarting. Cheap, and it converts a
red dot into a decision.

**4. `overnight.md` — trigger: `schedule`, once each morning; quiet hours
respected.** The §2.5 report over everything that ran since you last looked. This
is the one routine where a schedule genuinely beats an event, because "when I
next sit down" is not an event the machine can see.

**5. `dirty-tree.md` — trigger: `git-change`, debounced.** A session has left
uncommitted changes across N files for M hours — here is the diff summary, do you
want it committed, stashed or reverted? `alerts.ts` already has the streak
counters (`DIRTY_TREE_SESSION_STREAK = 3`, critical at 8).

**6. `memory-prune.md` — trigger: `schedule`, weekly. On by default.** §4.6.2.
The only routine that is default-*enabled* along with 1 and 3, because a
consolidation step the user must switch on is one that never runs.

**7. `ai-marker.md` — trigger: `file-change`, glob over the project.** Watch for a
`// TODO(deck):` marker in a source file, read the surrounding context, and start
a scoped session on it with the file and line as the prompt. This is the most
developer-specific trigger in the entire field — Aider's `AI!` comments — and it
is structurally impossible for a general personal assistant to have a version of.
You stay in your editor; the request is written where the work is, with its
context implicit. `routines/sources.ts` already watches with chokidar over native
FS events, with a never-watch set and a depth cap; `file-search.ts` finds the
marker. Off by default — it starts sessions.

**8. `pr-opened.md` — trigger: `schedule`, short interval. Off by default.** Pull
open PRs through the authenticated GitHub access `github.ts`/`github-app.ts`
already has, and start a review session on new ones. This is the one place a
*poll* is proposed against the standing preference, and the reason is honest:
there is no inbound path. `hook-server.ts` binds 127.0.0.1 only and refuses
non-loopback Host headers, deliberately; `relay/src` is a rendezvous with no HTTP
routes. A webhook ingress on the relay is buildable — Terminal Deck owns the
relay — but it is a **new authenticated public surface** and it is a security
design of its own that must not be bolted onto the copilot work. Poll now, at low
frequency, and say in the routine file that it is a stopgap.

**9. `heartbeat.md` — trigger: `schedule`, 30m during active hours. Off by
default.** Read a human-editable checklist at `<copilot>/HEARTBEAT.md` — is
anything stuck, did a build break, has a branch drifted from `main`, is anything
burning tokens without writing files — and **say nothing if nothing is wrong.**
This is the "commander" behaviour: the difference between an agent that answers
and one that notices. Recurring *work* belongs in the other routines; the
checklist is only for "is anything wrong right now".

Two mechanics that make it survivable, both measured:

- **Silence by default.** OpenClaw's heartbeat replies with a token when it finds
  nothing, the gateway strips the token, and if what remains is under **300
  characters** the reply is dropped entirely. That threshold is a fact worth
  copying exactly. `alerts.ts` already enforces the same invariant for a new
  project — reuse the principle.
- **Isolated session, light context.** A periodic run starts fresh with the
  bootstrap files skipped, rather than appending to the copilot's conversation.
  OpenClaw measures this at **~100K tokens per run down to 2–5K** — 20–50×, and
  the difference between this feature shipping and being switched off.

  **Trap that comes with it:** if a periodic run uses a cheaper model and that
  model persists into the next main-session turn, the next turn hits context
  overflow. A routine's profile must not leak back into the pinned copilot
  session. `profiles.ts` gives per-session profile choice; make the routine's
  choice per-*run*, not a mutation of the copilot's own.

**10. `quality-gate.md` — trigger: `session-finished` on a copilot-started
session.** Run the project's own gate — `npm run typecheck`, and for this repo
the harness render check too — before the session's work counts as done, and
report failure rather than letting it look green. SWE-agent runs a linter after
each edit and *reverts* modifications producing major errors, reporting a
considerable score improvement, not merely tidiness. This repo's own `CLAUDE.md`
is the argument: "two bugs shipped clean typechecks."

### Notification discipline across all of them

**Coalesce.** Five agents finishing within a minute produce one digest, not five
notifications. Notification fatigue is the documented way a supervision surface
dies, and `alerts.ts` + `os-notifications.ts` already own the delivery path and
the silence-by-default invariant.

**Quiet hours.** Two fields on the routine file: an active-hours window with a
timezone, and a `target` that can be `none` so a run happens with no delivery at
all. That last one enables the mode that actually matters — run overnight,
deliver nothing, have the results waiting in the morning. `lid-awake.ts` already
solves the harder half of running anything overnight.

---

## 6. What we should deliberately not build

Each of these was considered and rejected for a stated reason. A capability list
with no exclusions is a wish list.

**A scored memory-promotion system.** Recall counts, query-diversity gates,
weighted six-signal ranking, a consolidation phase. The design is genuinely good.
In the one live install available to measure, it ran once, scored everything at
`recallCount: 1`, and never produced an output file. Build the default-on weekly
prune instead (§4.6). Revisit only if the prune proves insufficient with real
usage behind it.

**A "steer / collect / followup / interrupt" queue-mode taxonomy.** OpenClaw needs
four modes because its runtime cannot always accept a mid-run message. A pty can
be written to whenever. Ship the verb split in §2.6 and one clear default; four
configurable modes is a setting nobody will get right.

**Remembered "allow always" inside the consent broker.** `consent.ts` is right to
refuse this and its reasoning should be preserved verbatim: *"Adding them now, as
a convenience inside the mechanism, is how a gate quietly becomes a formality."*
Confirmation fatigue is real — commercial agents are measured asking repeatedly
"even when the permission had been previously granted" — but the fix is **fewer
alter-tier calls**, not remembered yeses. The `DEFAULT_MAX_PENDING = 3` cap
already handles the flood case, and it fails loud. If scoped grants are ever
added they get their own storage, their own audit rows and their own UI, on
purpose — not as a flag inside the broker.

**A generic plugin/skill registry for the copilot.** Claude Code already has
skills, and the copilot inherits them by being a CLI session — which is one more
argument for the session-based design. What is worth building is not a second
mechanism but the **readiness pane** from §2.10: which routines can run on *this*
machine right now, and which are missing a binary.

**A tree-sitter repo map.** Aider's ranked, PageRank-scored repository map at a
1,024-token budget is the right way to answer "what's the state of that repo"
without a 200K-token read. Nothing like it exists here — `fs-tree.ts` and
`file-search.ts` are path-level — and it is a real subsystem. Not worth it before
the copilot is in daily use. **The useful part now is the number**: 1,024 tokens
is what a whole-repo overview is worth. Budget any future summary against it.

**APNs push to the phone.** The highest-value thing the relay could do for a
developer — agent blocks, phone buzzes, you approve, it continues — and it is
genuinely not reachable: there is no APNs key and no push server, and
`ios/TerminalDeck/App/SessionAlerts.swift` says so in as many words. Android needs
FCM equivalently. What *is* reachable and should be built instead is the degraded
version: a live alert over the already-open relay socket while a client is
connected and foregrounded. That costs nothing new and covers the case where
you are actually looking at your phone. (The Apple team is enrolled — `6U4VNX5W87`
— so the real thing is an afternoon of clicking plus a relay endpoint. It is
infrastructure that does not exist, not a wall.)

**A webhook ingress on the relay, as part of this work.** External triggers
(PR opened, CI failed) are the biggest category missing from the trigger list and
developers genuinely automate on them. But it is a new authenticated public
surface on the relay and it deserves its own security design and its own review.
Poll for now (§5.8) and build it deliberately, later, on its own.

**Anything that increases agent output without increasing reviewable output.**
The stated bottleneck of the year, in every retrospective, is verification rather
than generation. Test every proposed capability against it: does this make more
things happen, or does it make what happened easier to check? §2.4 and §2.5 pass.
"Start more sessions faster" fails.

**A configurable everything.** OpenClaw's heartbeat suppression is deliberately
not configurable, and that is why it works. Ship the defaults in this document as
defaults, not as settings with defaults.

---

## 7. Where this supersedes `COPILOT-DESIGN.md`

| `COPILOT-DESIGN.md` says | Now |
|---|---|
| Mechanism: a real session, MCP server, own folder, action log, permission tiers | **Unchanged and correct.** |
| Purpose framed generally — "the assistant for the app and the person" | **Superseded.** Developer's assistant supervising agents. §1. |
| Tool list: `sessions.*`, `projects.list`, `git.status`, `settings.*`, `alerts.list`, `routines.*` | **Extended.** Add `git.diff`, `sessions.cost`, `sessions.result`, `sessions.search`, `deck.readiness`. Still inside the 20-tool / 8,000-token budget. §2, item 8. |
| `log/actions.jsonl` lives inside the copilot's folder | **Superseded, for the same reason item 3 moved `routines/`.** That folder is the one directory the copilot may write to, so the audited party could append forged rows, edit real ones, truncate the file or delete it — fenced only by a sentence in its own `CLAUDE.md`. The log is now `<userData>/copilot-log/actions.jsonl`, written by the app alone, and the copilot's own appends are a `log.note` tool call: tiered, budgeted and attributed. One file, one story, and a row the copilot wrote can no longer impersonate a row the app wrote. |
| The copilot's home sits under the device-homes root so every transcript reader finds its conversation | **Kept, and narrowed.** The placement is right and stays. But it meant `transcriptDirs(cwd)` consulted the copilot's store for *every* project, so a file it wrote under another project's encoding surfaced in the viewer, chat mode, the usage pane and the alert watcher as that project's conversation. `installHomeScopes` registers the copilot's home as answering for its own working directory only. Paired devices are untouched — narrowing those needs a per-device folder list `remote/folder-grants.ts` deliberately does not always have. |
| Routine = trigger → prompt → where it runs | **Extended.** Plus approval gate, what-NOT-to-do, and `onFailure` with a consecutive-failure disable. §5. |
| Triggers are all local to this Mac | **Acknowledged gap.** External triggers are the missing category; polled stopgap in §5.8, ingress deliberately deferred. §6. |
| Alter tier is confirmed in the UI | **Necessary, not sufficient.** Add schema validation and a last-good snapshot before `settings.write`; add unattended refusal for routine-invoked turns. Items 4 and 6. |
| Remote copilot access is a per-device capability grant | **Sharpened.** Per-*tier* grant, read-only by default, alter never remote. Item 5. |
| Open question: cost ceiling | **Answered.** Yes — a ceiling on copilot-started sessions, a concurrency cap of 5, isolated light-context runs for anything periodic, and cost visible on the supervision surface. §2.7, §2.12, §5.9. |
| Open question: which account | **Answered.** Pin the copilot to one profile. A routine may choose a cheaper profile *per run*; that choice must never mutate the pinned session's. §5.9. |
| Order: 1 session → 2 MCP + tiers → 3 routines → 4 remote | **Unchanged**, with two insertions: the `sessions.result` record belongs in phase 2 (it is what makes phase 3 affordable), and the unattended-refusal path must land *with* the routine engine, not after it. |

Not in `COPILOT-DESIGN.md` at all, and now on the list: **worktree isolation**
(§2.11), which is the prerequisite for `sessions.start` being routinely safe and
is the single largest thing the rest of the field has that this app does not.

---

## 8. What this app has that nobody else does

Worth stating plainly, because it decides what to build first.

The orchestrators — Conductor, Nimbalyst, Claude Squad, Sculptor, Mux, Superset,
Vibe Kanban — are *dashboards over agents*. They show you sessions; there is no
agent you can talk to about them. The personal agents — OpenClaw, Devin — have the
conversational supervisor but no window into the machinery. A supervisor that is
itself an inspectable session, with a tool surface onto the app that runs the
fleet, sits in a gap that is currently empty.

**The differentiator is the architecture, not the feature list.** So the
capabilities that exploit the fleet — §2.1 triage, §2.3 loop detection, §2.4
cross-session diff, §2.5 the overnight report, §2.9 searching every transcript —
are the ones worth building first, and the ones that are cheap here and expensive
everywhere else. The capabilities that any CLI agent could have are the ones to
build last, if at all.

Four things this app already has that most of the field does not, and which
should not be given up for convenience:

- **OS-level confinement** (Seatbelt / AppContainer), resolving through
  `realpathSync` — which is doing real work, given the symlink escape found
  across top agents in July 2026. Of six agents compared head to head, only
  Claude Code enforces anything at the OS: Cursor's rules are advisory, Aider has
  no layer between the model's decision and execution, Copilot's protection is
  legal indemnity.
- **A hardened local hook ingress** — loopback-bound, constant-time token
  comparison, Host-header check against DNS rebinding.
- **A bounded tool surface** — 11 tools, transcript reads bounded three ways that
  *report which bound they hit*. That accidentally implements SWE-agent's
  agent-computer-interface findings and sidesteps the loudest MCP criticism of
  the year. Name the principle in `catalogue.ts` so the next agent to extend it
  does not undo it.
- **`session-insights.ts`**, validated against 133 real transcripts. Most of the
  "what happened" work is already sitting in it.

Two gaps against the best comparable security model, both worth knowing: there is
no network domain allowlist, and no credential masking. **Credential masking is
the more valuable of the two for an agent with Bash**, and it is the missing
check behind §4.5.
