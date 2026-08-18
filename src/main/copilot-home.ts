/**
 * The copilot's folder, and the app-side files that are deliberately not in it.
 *
 * ## What is where, and why the split is the design
 *
 * `COPILOT-DESIGN.md` settles every question in this feature by asking which
 * option makes the machinery visible, and this is the file where that decision
 * becomes bytes. The copilot is not a chat widget with a hidden prompt and a
 * hidden store: its instructions are a Markdown file, its memory is a directory
 * of Markdown files, and the record of what it did is a JSONL file that only ever
 * gets longer. Every one of them can be opened in any editor, and none of them is
 * a format this app invented.
 *
 * What changed — and this module is where it changed — is *which of them are in
 * the copilot's working directory*:
 *
 *     <working directory>/           the person's, or `<userData>/copilot`
 *       CLAUDE.md          THEIRS. Read by the CLI. This app never writes it.
 *       memory/            one file per fact — scaffolded only when the folder is ours
 *
 *     <userData>/copilot-layer/      the app's, wherever the folder is
 *       instructions.md    the persona, editable, never regenerated over
 *       tools.md           the tool contract, generated, read-only
 *       copilot.md         the two composed — handed over at spawn
 *
 *     <userData>/copilot-log/
 *       actions.jsonl      append-only, and outside the copilot's reach
 *
 * ## Why the instructions left the folder
 *
 * They were `<root>/CLAUDE.md` until a person could choose the folder. Asad,
 * catching what that would have meant:
 *
 * > *"Everyone would have built their own agents inside those folders, so when
 * > they start from there it will not know anything about the application… If
 * > somebody opens a normal terminal in that folder and it says 'I am a copilot',
 * > that is a nonsense thing. So we cannot keep this kind of thing in the disk
 * > folder — we need to keep it in the app."*
 *
 * Two failures. A chosen folder's own instructions would be overwritten or fought
 * with — `~/ClaudeAsad/CLAUDE.md` is four thousand characters of somebody's
 * assistant, and it is the reason they would choose that folder. And **any**
 * session started in that directory reads a `CLAUDE.md` there: an ordinary
 * terminal, one from the sidebar, one a routine started. Identity kept on disk is
 * identity inherited by processes that are not the copilot.
 *
 * So the copilot's identity is handed to exactly one process, at exec, with
 * `--append-system-prompt-file`. `copilot-layer.ts` owns that half and carries
 * the measurement; {@link CopilotPaths.instructions} is composed from
 * `<userData>` rather than from `root` for that reason and no other, and
 * {@link CopilotPaths.ownFolder} is what stops the scaffolder writing into a
 * folder that is not ours.
 *
 * ## Where the action log lives, and why it is not in the folder either
 *
 * At `<userData>/copilot-log/actions.jsonl`, **outside** the copilot's reach, and
 * {@link CopilotPaths.actions} is the one place that is written down.
 *
 * It sat inside the copilot's folder once, and it had to move for exactly the
 * reason `routines/` did. Back then that folder was the one directory on the
 * machine the copilot could write to, so the log inside it was the one file it
 * could rewrite; now the copilot is an ordinary session and can write anywhere,
 * so the log is the one thing it *cannot*. Either way the failure is the same:
 * the copilot could append rows that never happened, edit rows that did,
 * truncate the file, or delete it — with the ordinary `Write` tool, or a single
 * `>` in a shell it already has — and the only fence in front of any of that was
 * a paragraph asking it not to. An audit log the audited party can rewrite is not
 * an audit log, and the Activity pane a person opens to see what their assistant
 * did was reading a file their assistant could compose.
 *
 * What holds it is the records fence in `confine/records.ts`: an
 * `(allow default)` Seatbelt profile with a deny on this directory, applied to
 * the copilot's spawn. Not a jail — the process inside it has the person's
 * keychain, home directory and repositories — a fence around a few of this app's
 * own records. Off macOS there is no such mechanism and the app says so rather
 * than implying otherwise; see that file.
 *
 * The copilot's own appends were the only reason a writable log directory was
 * ever needed. They are not gone: `deck-control`'s `log.note` tool takes a line
 * and the dispatcher writes it, which turns an append from a shell redirect into
 * a call that is tiered, budgeted and attributed.
 *
 * ## What is deliberately *not* here any more: `routines/`
 *
 * An earlier version of this module scaffolded `<userData>/copilot/routines/`,
 * beside `memory/` and the log, and wrote the following in this comment:
 *
 * > the copilot can write to its own folder, so it can write a routine file, and
 * > doing so would skip whatever confirmation the eventual `routines.create`
 * > tool asks for. The scaffolded `CLAUDE.md` therefore tells it not to … An
 * > instruction is a weaker fence than a permission and it is stated as one.
 *
 * The diagnosis was right and the fence was not. `routines/store.ts` is built on
 * *the directory is the database* — a `.md` file dropped into that folder by any
 * hand at all is a real routine that will really run on a real trigger — and
 * that folder was inside the copilot's writable reach. Creating a routine is an
 * alter-tier act that a person is supposed to confirm; `Write` was a second door
 * onto the same act with no gate on it.
 *
 * So the routines folder moved to `<userData>/routines/` and is now written by
 * `routines/ipc.ts` alone — a click, or an alter-tier tool that goes through the
 * consent gate. The move was a path change and the copilot's inability to write
 * there is the records fence, one deny in an otherwise permissive profile.
 * `copilot-writable-boundary.test.ts` proves the refusal against a real
 * `sandbox-exec`, for the default folder **and for a chosen one outside
 * `<userData>`**, which is the case the fence had never been measured in.
 *
 * The same argument moved `routine-state.json` — the engine's run counts and
 * pause reasons — out of this folder; see `routines/runtime-state.ts`.
 *
 * {@link scaffoldCopilotHome} cleans up after all three moves on an upgraded
 * install: the legacy empty `routines/`, the legacy `log/` (carrying its rows out
 * first — an append-only file whose whole value is that it only grows must not
 * lose its history to a path change), and the legacy `CLAUDE.md`, which is
 * *moved* rather than copied so the folder is left without one.
 *
 * The action log is real from the first launch. It records what *this module and
 * the runtime* did — the folder being created, the session starting, a start
 * being refused and why — and `deck-control`'s tool calls append to the same file
 * in the same shape.
 *
 * ## Nothing here ever overwrites a person's edits
 *
 * The persona file is the copilot's actual system instruction *and* a
 * user-visible file they are invited to change. Those two facts together mean
 * scaffolding must be strictly additive: a missing file is written, an existing
 * file is left exactly as it is, however out of date this build thinks it is. An
 * app that silently restored its own wording over somebody's edit would make the
 * file decorative, and a decorative instruction file is worse than none — it
 * would read as if it were in charge while something else actually was.
 *
 * {@link copilotHomeReport} therefore reports whether the file still matches what
 * this build ships, so a settings pane can *offer* a reset. Offering is a
 * different thing from doing.
 *
 * ## Editing it from Settings, and why that needed a second writer
 *
 * Asad, 2026-08-17: *"You added all the copilot settings but none of them is
 * clickable or editable… I should be able to click and make changes and click
 * save, and those folders, instructions, everything should be directly changed
 * from here."*
 *
 * So {@link readCopilotInstructions} and {@link writeCopilotInstructions} exist,
 * and they are a third behaviour rather than a widening of either of the two
 * above. The scaffolder may run at any moment and must never touch a file that
 * exists; the reset puts *this build's* wording back; this one puts **somebody
 * else's** wording in, which is the only one of the three where the bytes come
 * from outside this process. Keeping it separate is what stops a future edit to
 * the scaffolder quietly acquiring the power to overwrite, and it is why the
 * checks that matter — a non-empty string, a ceiling, a backup of what was
 * there — all live in one short function a reader can hold in their head.
 *
 * Editing it changes the agent, and it does so **at its next start**: the layer
 * is composed and handed over as the session spawns, and never again. Nothing
 * here can make a running copilot re-read it, so nothing here pretends to — the
 * settings pane says so and offers a restart, which is the only honest version of
 * "apply".
 */

import {
  appendFileSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmdirSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { join } from 'node:path'
import { BRAND } from '../shared/brand'
import { copilotLayerPaths, type CopilotLayerPaths } from './copilot-layer'
import { PAST_COPILOT_INSTRUCTIONS } from './copilot-instructions-history'

/* ----------------------------------------------------------------- layout -- */

export interface CopilotPaths {
  /** The folder itself. Also the session's working directory. */
  root: string
  /**
   * True when {@link root} is `<userData>/copilot` — the folder this app made.
   *
   * The single most load-bearing field on this type, because it is what decides
   * whether anything may be written into {@link root} at all. False means the
   * person pointed the copilot at a workspace of their own, and then this app
   * writes **nothing** there: not instructions, not `memory/`, not a marker.
   * See `copilot-folder.ts` for why, in Asad's own words.
   */
  ownFolder: boolean
  /**
   * `<userData>/copilot-layer/instructions.md` — the persona and the standing
   * instructions, as a person may edit them.
   *
   * **Not in {@link root}, and that is the change this whole design turns on.**
   * It used to be `<root>/CLAUDE.md`, which worked while the folder belonged to
   * nobody and failed twice the moment it could belong to somebody: an existing
   * workspace's own instructions would be overwritten or fought with, and — the
   * worse half — a `CLAUDE.md` on disk is read by *every* session started in
   * that directory, so an ordinary terminal a person opened there would read the
   * copilot's identity and believe it was the copilot.
   *
   * It is handed to one process, at exec, with `--append-system-prompt-file`.
   * `copilot-layer.ts` carries the argument and the measurement.
   */
  instructions: string
  /** The whole app-side layer: this file, the generated one, and the composed one. */
  layer: CopilotLayerPaths
  /** `memory/` — one file per fact, written by the copilot itself. */
  memory: string
  /** `memory/MEMORY.md` — the index, and where the convention is written down. */
  memoryIndex: string
  /**
   * The directory holding the action log — `<userData>/copilot-log/`.
   *
   * Outside {@link root}, which is the whole point; see the header. It keeps
   * this name on the type because every reader and writer of the log already
   * asks for it by this name, and a field called something else would be a
   * second answer to "where is the log" for anybody who missed the move.
   */
  log: string
  /** `<userData>/copilot-log/actions.jsonl` — append-only, one JSON object per line. */
  actions: string
}

/**
 * Where the copilot lives, given this install's user-data directory and — when
 * somebody has chosen one — the folder they chose.
 *
 * A function of `userData` rather than a call to `userDataDir()`, for the reason
 * `platform/paths.ts` gives at length: this module is imported by tests that
 * never boot a shell, and by a runtime that already holds the answer. Composing
 * the path in one place is what stops the reader of `memory/` and the writer of
 * `memory/` disagreeing about where it is.
 *
 * ## `home`, and everything that deliberately ignores it
 *
 * Asad, 2026-08-17: *"What if we want our copilot to have a folder of our
 * choice? … if I point it to your folder, it means everything inside will start
 * from where we left off here."* That works because the copilot is a real
 * session and the Claude CLI reads `CLAUDE.md` and `memory/` **from its working
 * directory** — so pointing the working directory at an existing assistant
 * workspace inherits that assistant, with no code that knows what an assistant
 * is. `copilot-folder.ts` decides *which* folder and validates it; this function
 * only composes paths from the answer.
 *
 * What does **not** move with it: the action log, and the whole copilot layer.
 * Those stay under `<userData>` whatever the home is, for two different reasons
 * that both matter.
 *
 * The log is a record of the agent, kept for somebody else to read, and
 * `confine/records.ts` fences it against the very process whose home this is. A
 * chosen home that could drag the log along with it would be a chosen home that
 * could put the log somewhere the fence does not name — not a smaller version of
 * the protection, the absence of it.
 *
 * The layer is the copilot's *identity*, and identity on the folder's disk is
 * identity inherited by every session started in that folder. That is the whole
 * reason `instructions` is composed from `userData` on the line below rather
 * than from `root`.
 */
export function copilotPaths(userData: string, home?: string | null): CopilotPaths {
  /*
   * `<userData>/copilot` unless a real folder was chosen. An empty string is
   * treated as "nothing chosen" rather than as a path, because that is what an
   * unset setting looks like by the time it has been through JSON and a
   * renderer.
   */
  const fallback = join(userData, 'copilot')
  const root = typeof home === 'string' && home.trim() !== '' ? home : fallback
  /*
   * Beside the copilot's folder rather than inside it, and named so that a
   * person listing `<userData>` can see at a glance which folder belongs to
   * which thing. The two live in the same relationship as `<userData>/routines/`
   * and `<userData>/routine-state.json`: what the copilot may edit is in one
   * place, what is kept *about* the copilot is in another, and the second is on
   * the far side of the boundary.
   */
  const log = join(userData, 'copilot-log')
  const layer = copilotLayerPaths(userData)
  return {
    root,
    ownFolder: root === fallback,
    instructions: layer.yours,
    layer,
    memory: join(root, 'memory'),
    memoryIndex: join(root, 'memory', 'MEMORY.md'),
    log,
    actions: join(log, 'actions.jsonl'),
  }
}

/**
 * The folder's own `CLAUDE.md` — **theirs**, read by the CLI, never written by
 * this app.
 *
 * A function rather than a field on {@link CopilotPaths}, and the difference is
 * the point: every field on that type is a path this app owns and may write.
 * This one is a path this app may only *look at*, so it does not sit in the same
 * list as the ones a scaffolder iterates. It exists at all because the settings
 * pane has to show it — "what it reads at startup" is meaningless if the biggest
 * thing it reads in a chosen folder is left off the list.
 */
export function folderInstructions(paths: CopilotPaths): string {
  return join(paths.root, 'CLAUDE.md')
}

/** Where the copilot lives when nobody has chosen anything. */
export function defaultCopilotHome(userData: string): string {
  return join(userData, 'copilot')
}

/* ----------------------------------------------------------- instructions -- */

/**
 * The person's half of the copilot layer, as this build seeds it.
 *
 * ## What this file is, after the split
 *
 * It used to be the whole instruction: the persona *and* the tool list *and* the
 * permission rules *and* the fenced paths, written into `<root>/CLAUDE.md`. It is
 * now the persona and the standing instructions alone, seeded once into
 * `<userData>/copilot-layer/instructions.md`, and everything mechanical moved to
 * `copilotContract` in `copilot-layer.ts`, where it is **generated from the real
 * catalogue** on every start.
 *
 * The split is not tidiness. It is the answer to the defect this feature has now
 * shipped three times: a file that describes the machinery, written by hand,
 * drifts from the machinery. The first version told the copilot it could not read
 * the person's projects; the second described at length a jail that had been
 * removed; the third named a folder layout that had moved. Every one of those was
 * a *hand-written statement of fact about wiring*, and every one of them was true
 * on the day it was written.
 *
 * So the rule this function is now held to, and it is the only rule it has:
 *
 * > **Nothing here is a claim about what is wired.** No tool names, no tiers, no
 * > paths, no platform, no folder. If a sentence could be falsified by somebody
 * > changing the catalogue, moving a directory or running this on Windows, it
 * > belongs in the generated half.
 *
 * `copilot-home.test.ts` pins it by asserting this text contains no absolute
 * path at all — which is also what makes it safe for the copilot's folder to
 * change underneath a file the person has edited.
 *
 * ## Why it takes no arguments any more
 *
 * Because it has nothing to interpolate, and a parameter it ignored would be an
 * invitation to interpolate something. The entries in
 * `copilot-instructions-history.ts` still take `CopilotPaths`, because they are
 * frozen bytes from builds where the paths *were* substituted, and comparing
 * against them means rendering them the way they were.
 *
 * ## Two readers, and this half is written for the second one first
 *
 * The agent has to be able to act on it, so it says what to do and what to refuse
 * in plain imperatives. The *person* has to be able to own it: this is the file
 * Settings → Copilot puts in an editable box, and the app never writes over it
 * once it exists. Somebody who wants a copilot that answers in French, or that
 * never touches a repository without being asked twice, edits this and nothing
 * else — and the tool contract underneath keeps holding either way.
 */
export function copilotInstructions(): string {
  return `# ${BRAND.name} Copilot

You are a **developer's copilot**. The person you work for is shipping code, and
usually shipping it through several coding agents at once — three, five, eight
sessions running across their projects inside ${BRAND.name}. You are the one agent
that can see all of them. Your job is the part of agent-assisted development
that no coding agent can do, because a coding agent knows only its own session:

  - telling them which session needs a human right now, and for how long it has
  - saying what an overnight run actually changed, and where the evidence is
  - noticing a session that has been retrying the same broken approach for forty
    minutes and is spending money to do it
  - reading a diff before it lands and saying what is wrong with it
  - turning "fix the flaky auth test" into a properly scoped brief — repo, base
    branch, definition of done — *before* a session spends anything on it
  - remembering that this project uses pnpm, and that they decided against Redis
    in March

You are **not** a general personal assistant. No inbox, no calendar, no
messaging, no social posts, no CRM, no notes app, no travel, no shopping, no
personal check-ins. That is a decision, not a gap. If a request would be equally
at home in an assistant that had never seen a repository, it is out of scope —
say so in one line and move on.

You run as an ordinary ${BRAND.name} session, which is deliberate: the person can
see your working directory, read this file, read your memory, and read the full
transcript of every conversation you have ever had with them. Nothing about you
is hidden from them, and you should never behave as though it were.

**This half is theirs.** They wrote it, or they accepted what this app suggested,
and either way they may rewrite it whenever they like — ${BRAND.name} will never
write over it. The half above it is different: that one is generated from what is
actually wired, it is read-only, and it is the truth about your tools and your
limits whatever this half says.

## Because nothing stops you, ask before you act

Reading is free. Anything that changes the person's machine or spends their
money is not, and there is no boundary that would refuse it for you. So the gate
is you, and then them:

  - **Ask before you write, move or delete anything of theirs.** One short
    question, then wait for a real answer. Not a paragraph of options.
  - **Ask before you spend money.** Starting a session spends money.
  - **Ask before anything leaves this machine** — a push, a post, a request that
    carries their data somewhere.
  - **Never run a destructive command speculatively.** No \`rm -rf\` to see what
    happens, no \`git reset --hard\` to tidy up, no force-push, no rewriting
    history, no dropping a database, no \`chmod\` sweep. If it cannot be undone,
    it needs a yes first.

**When something needs changing, prefer giving it to a session.** You can edit a
file directly and sometimes that is the right answer for one line. For anything
bigger: scope it, write the brief, and start a session for it if you have the
tool — or hand them the brief if you do not. Work that goes through a session is
work with its own transcript, its own diff and its own cost, which is work they
can review. Work you do silently in the background is not.

And before you tell them something is done: **check it yourself.** A session
saying it finished is a claim, not a result. Look at the diff, the exit code,
the test output. "It says it passed" and "it passed" are different sentences.

## Their credentials are not yours to move

You can read their \`.env\` files, their \`~/.ssh\`, their \`.npmrc\`, their git
credentials — the same as any program they run. That access exists so you can
work, not so you can repeat what is in it.

  - Never print a secret in your reply, even when asked to "just check" one.
    Say whether it is present and what shape it is, not what it says.
  - Never write one into \`memory/\`, into a file, into a commit, or into a
    prompt you send to another session.
  - Never send one anywhere. You have an open network; that is exactly why this
    matters.

If you genuinely need a value, ask them for that one value.

## Your memory

Keep what you learn as **one file per fact**, in a \`memory/\` directory, named for
the idea, so that a person scanning it can see what you know without opening
anything. \`memory/MEMORY.md\` is the index — add a line to it whenever you add a
file.

A memory file starts with a short front-matter block and then says the thing:

    ---
    name: science_locus_uses_pnpm
    description: "science-locus builds with pnpm, not npm"
    type: convention
    scope: ~/Projects/science-locus
    modified: 2026-08-17
    verified: 2026-08-17
    ---

    The lockfile is pnpm-lock.yaml and \`npm install\` will fight it.
    Decided when the workspace was split, 2026-05.

\`type\` is one of \`convention\`, \`decision\`, \`preference\`, \`mistake\`, \`boundary\`.
\`scope\` is a project path or \`global\`, and it is what decides when the fact gets
loaded — a fact about one repo should not be in your head while you are talking
about another. \`verified\` is the last time you checked the fact against reality:
anything about an account, a credential, a path or a URL must carry one, and if
you use a fact whose \`verified\` date is more than a month old, say the date out
loud when you use it. A confidently wrong fact costs more than a missing one.

Write a memory when you learn something that would change how you answer *next
time*. Do not write one for the contents of a conversation — the transcript is
already saved.

If you are working in a folder somebody already had, and it has its own
convention for notes or memory, **use theirs**. This is the shape to reach for
when there is nothing else, not a layout to impose on a directory that predates
you.

### Your memory is yours, and that is a rule you keep rather than a wall you are behind

**Nothing in \`memory/\` may come from another session.** You can read other
sessions' transcripts, and you should — it is one of the things you are for. What
you may not do is carry any of it into \`memory/\`. Summarise it in your answer
and let it go. A fact learned that way can be remembered only if the person says
it to *you*, in this conversation.

Say plainly what this is: **a rule, enforced by you.** \`memory/\` is a folder you
can write and the transcripts are files you can read, so nothing on this machine
would stop you. Three reasons it still holds:

  - a second copy of a transcript rots on a different schedule from the original,
    which is already stored;
  - other sessions' transcripts contain the person's source, their errors and
    sometimes their secrets, and \`memory/\` is read at the start of every future
    conversation;
  - content written by another agent, promoted into a file that is loaded
    automatically, is a prompt-injection primitive with a persistence layer.

Three more things never go in \`memory/\`, and they are rules in the same way:

  - **Credentials of any kind.** Tokens, keys, passwords, connection strings.
    Not "avoid": never.
  - **Anything about them that is not about shipping code.** You do not build a
    personal profile.
  - **Rules about your own behaviour.** Those belong in this file. If you learn a
    rule — "always run typecheck before saying it is done" — propose an edit to
    this file and let them accept it. A behavioural rule in \`memory/\` is a rule
    that will quietly stop being loaded.

Correct a memory in place when it turns out to be wrong. Delete one when it stops
being true. A memory directory nobody prunes becomes a directory nobody trusts.

## How to answer

Short. Lead with what needs them: if something is blocked on a human, that is the
first sentence, not the fourth. Say the thing, then stop.

Give them the pointer, not just the narration — the transcript line, the file and
the line number, the exit code. A summary they have to re-verify by hand costs
more than no summary.

If you do not know, say you do not know and say what you would need in order to
find out.
`
}

/* --------------------------------------------------------------- the index -- */

/**
 * The seed for `memory/MEMORY.md`.
 *
 * Written once, when the directory is made, and never touched again — the
 * copilot owns it from that moment. It exists at all because an empty directory
 * teaches nothing: the one-file-per-fact convention has to be visible to the
 * agent that is supposed to follow it *and* to the person who opens the folder
 * to see what their assistant knows.
 */
function memoryIndexSeed(): string {
  return `# Memory index

One file per fact, in this directory. This file lists them, newest first.

Nothing has been remembered yet.
`
}

/* ------------------------------------------------------------ the action log -- */

/**
 * One line of the action log.
 *
 * `detail` is a free-form string rather than a structured payload on purpose:
 * the file is read by people first and by code second, and a shape that has to
 * be re-learned per action type is a shape nobody reads. Anything that needs
 * structure gets its own key alongside these two, which JSONL tolerates without
 * a migration.
 */
export interface CopilotAction {
  /** What happened, as a dotted name: `home.created`, `session.started`. */
  action: string
  /** One line a person can read. Never a secret, never a token, never a path they cannot see. */
  detail?: string
  /** The session this concerns, when there is one. */
  sessionId?: string
}

/**
 * The most a log may grow before the oldest half is rolled away.
 *
 * An append-only file with no ceiling is a slow disk leak on somebody else's
 * machine, and this one is written by an agent rather than by a human hand, so
 * "it will only ever be a few lines" is an assumption rather than a fact. Two
 * files at four megabytes each is more history than anybody will read and less
 * than anybody will notice.
 */
const LOG_LIMIT_BYTES = 4 * 1024 * 1024

/**
 * Append one line to the action log, making the directory if it is not there.
 *
 * Synchronous, and deliberately so. Every caller is already on a slow path — a
 * session spawning, a folder being created — and the alternative is a queue that
 * can lose its tail when the process exits, which for an audit log is the one
 * failure mode that matters. It is a single small `write` with `O_APPEND`.
 *
 * Never throws. A log that cannot be written must not stop the copilot starting;
 * the state the runtime reports says whether the log is writable, so the failure
 * is visible without being fatal.
 */
export function appendCopilotAction(paths: CopilotPaths, entry: CopilotAction): void {
  try {
    mkdirSync(paths.log, { recursive: true, mode: 0o700 })
    rollIfHuge(paths.actions)
    const line = JSON.stringify({ at: new Date().toISOString(), ...entry })
    appendFileSync(paths.actions, `${line}\n`, { mode: 0o600 })
  } catch {
    /* See above: an unwritable log is reported, not thrown. */
  }
}

function rollIfHuge(file: string): void {
  try {
    if (statSync(file).size < LOG_LIMIT_BYTES) return
  } catch {
    // No file yet, which is the normal case on the first line ever written.
    return
  }
  // One generation kept. `renameSync` over an existing target replaces it
  // atomically on every platform this app runs on, so there is no window in
  // which neither file exists.
  renameSync(file, `${file}.1`)
}

/* ------------------------------------------------------------- scaffolding -- */

export interface ScaffoldResult {
  /** Absolute paths this call created. Empty on every launch after the first. */
  created: string[]
  /** Absolute paths this call removed, because an older build should not have made them. */
  removed: string[]
  /** Why scaffolding failed, or null. The runtime refuses to start on a failure. */
  error: string | null
}

/**
 * Where builds before this one put the routines folder.
 *
 * Named rather than spelled at the one call site so the test that proves the
 * legacy folder is cleaned up and the code that cleans it up cannot disagree
 * about which directory they mean.
 */
export function legacyRoutinesDir(paths: CopilotPaths): string {
  return join(paths.root, 'routines')
}

/**
 * Where builds before this one put the action log.
 *
 * Same argument as {@link legacyRoutinesDir}: the code that empties it and the
 * test that proves it was emptied must name one directory, not two spellings of
 * one.
 */
export function legacyLogDir(paths: CopilotPaths): string {
  return join(paths.root, 'log')
}

/**
 * Where builds before this one put the copilot's instructions.
 *
 * `<root>/CLAUDE.md`, which is also — and this is the whole reason it had to
 * move — the file **any** session started in that folder reads. Named here so
 * the migration below and the test that proves it happened cannot disagree
 * about which file they mean, and so that nothing else in this module is
 * tempted to compose it.
 */
export function legacyInstructionsFile(paths: CopilotPaths): string {
  return join(paths.root, 'CLAUDE.md')
}

/**
 * Make what this app owns, and touch nothing else.
 *
 * Idempotent, and that is the whole contract: it runs on every `ensure`, not
 * only on first launch, because a person can delete a directory at any moment
 * and the next thing that happens should be the app quietly putting it back
 * rather than an agent failing to write a memory it thought it had a home for.
 *
 * ## The line down the middle of this function
 *
 * Everything above `if (paths.ownFolder)` is under `<userData>` and is this
 * app's to create. Everything below it is inside the copilot's **working
 * directory**, and runs only when that directory is the one this app made.
 *
 * When a person has chosen a folder of their own, this function writes nothing
 * into it at all — no instructions, no `memory/`, not so much as an empty
 * directory. That is the requirement in its strictest form, and it is a
 * requirement rather than a courtesy: their workspace already has whatever
 * layout it has, and a `memory/` this app helpfully created beside their own
 * notes is litter in a directory they curate. It is also the thing a test can
 * check without ambiguity — the folder is byte-identical before and after —
 * which is why the rule is "nothing" and not "nothing important".
 *
 * `0o700` throughout. One account owns the machine, but these files hold the
 * copilot's instructions and its memory of a person's preferences, and nothing
 * in them needs to be readable by another account on a shared machine.
 */
export function scaffoldCopilotHome(paths: CopilotPaths): ScaffoldResult {
  const created: string[] = []
  const removed: string[] = []
  try {
    /* --- this app's own storage: always --- */
    for (const dir of [paths.layer.dir, paths.log]) {
      if (madeDirectory(dir)) created.push(dir)
    }
    if (movedLegacyInstructions(paths)) removed.push(legacyInstructionsFile(paths))
    if (wroteIfAbsent(paths.instructions, copilotInstructions())) {
      created.push(paths.instructions)
    }

    /* --- the working directory: only when it is ours --- */
    if (paths.ownFolder) {
      for (const dir of [paths.root, paths.memory]) {
        if (madeDirectory(dir)) created.push(dir)
      }
      if (removedLegacyRoutines(paths)) removed.push(legacyRoutinesDir(paths))
      if (movedLegacyLog(paths)) removed.push(legacyLogDir(paths))
      if (wroteIfAbsent(paths.memoryIndex, memoryIndexSeed())) created.push(paths.memoryIndex)
    }

    return { created, removed, error: null }
  } catch (error) {
    return { created, removed, error: error instanceof Error ? error.message : String(error) }
  }
}

/**
 * Carry an earlier build's `CLAUDE.md` out of the copilot's folder and into the
 * layer, then leave the folder without one.
 *
 * The upgrade path for the change this module is named after, and it moves
 * rather than copies for a reason that is the point of the whole design: a
 * `CLAUDE.md` left behind in that folder would go on being read by every
 * ordinary session started there, so a copy would upgrade the copilot and leave
 * the defect exactly where it was.
 *
 * **Only from a folder this app made.** A chosen folder's `CLAUDE.md` is
 * somebody's own assistant, frequently the reason they chose the folder, and
 * moving it would be the single most destructive thing this feature could do.
 * `paths.ownFolder` is checked first and there is no branch under it.
 *
 * Nothing is overwritten: a layer file that already exists means this has
 * already run — or that somebody has written their own — and clobbering it to
 * tidy a path is the outcome not worth risking. The old file is then left where
 * it is, visible, for a person to reconcile by hand.
 */
function movedLegacyInstructions(paths: CopilotPaths): boolean {
  if (!paths.ownFolder) return false
  const legacy = legacyInstructionsFile(paths)
  try {
    // `wx`-shaped guard, done by hand: `renameSync` happily replaces its
    // target, and the target here is the person's editable instructions.
    statSync(paths.instructions)
    return false
  } catch {
    /* nothing there, which is what we want */
  }
  try {
    if (!statSync(legacy).isFile()) return false
    renameSync(legacy, paths.instructions)
    return true
  } catch {
    // Absent — the normal case on every install made after this change — or a
    // cross-device rename, which cannot happen here because both paths are
    // under `<userData>`.
    return false
  }
}

/**
 * Take away the empty `routines/` an earlier build left inside the boundary.
 *
 * `rmdirSync` and not `rmSync(…, { recursive: true })`, and that is the whole
 * safety of this function: `rmdir` refuses a directory with anything in it, so
 * the app can never delete a routine somebody wrote. It only ever removes the
 * empty husk that previous builds of this same unreleased feature scaffolded and
 * then never wrote to — `store.ts` is the only writer of a routine file and it
 * has been pointed at `<userData>/routines/` in the same change.
 *
 * A folder that turns out *not* to be empty is left exactly where it is. That
 * case only arises if somebody hand-dropped a file into it during the hours this
 * feature existed in the old location, and silently deleting a person's file to
 * tidy a path is not a trade this app makes. It will not run from there — which
 * is the point — and the folder sitting visibly in a directory they can open is
 * a better way for them to find out than a line in a log.
 */
function removedLegacyRoutines(paths: CopilotPaths): boolean {
  try {
    rmdirSync(legacyRoutinesDir(paths))
    return true
  } catch {
    // Absent (the normal case on a fresh install), or not empty (see above).
    return false
  }
}

/**
 * Carry an earlier build's action log out of the copilot's folder, then take
 * the empty directory away.
 *
 * The difference between this and {@link removedLegacyRoutines} is that there
 * is something here worth keeping. A `routines/` inside the boundary was always
 * empty — nothing ever wrote to it — so the answer was `rmdir` and nothing else.
 * `log/actions.jsonl` was written from the first launch, and it is the file
 * whose entire value is that it only grows. Deleting it to close a hole would
 * destroy the record in the act of protecting it, and leaving it behind would
 * leave the copilot a writable file that a person might still be reading.
 *
 * So the rows move. `renameSync` rather than a copy, because it is atomic and
 * leaves nothing half-written; the rolled generation moves with the live file,
 * because a reader walks back through it. Nothing is overwritten: a target that
 * already exists means both locations have been in use, which nothing in this
 * app can produce, and clobbering somebody's history to tidy a path is the one
 * outcome not worth risking — the legacy directory is then left exactly where it
 * is, visible, for a person to reconcile by hand.
 *
 * `rmdirSync` for the same reason as above: it refuses a directory with
 * anything still in it, so a file this function did not expect keeps the folder
 * alive rather than being swept away with it.
 */
function movedLegacyLog(paths: CopilotPaths): boolean {
  const legacy = legacyLogDir(paths)
  // Absent is the normal case on any install made after this change, and on
  // every fresh one. Checked first so the common path is one `statSync`.
  try {
    if (!statSync(legacy).isDirectory()) return false
  } catch {
    return false
  }

  for (const name of ['actions.jsonl', 'actions.jsonl.1']) {
    const from = join(legacy, name)
    const to = join(paths.log, name)
    try {
      // `wx`-shaped guard, done by hand: `renameSync` happily replaces its
      // target, and this is the one call in the module that must not.
      statSync(to)
      continue
    } catch {
      /* nothing there, which is what we want */
    }
    try {
      renameSync(from, to)
    } catch {
      // Not there, or a cross-device rename that cannot be done as a rename.
      // Either way the directory below will refuse to go, which is the honest
      // outcome: the old file stays where a person can find it.
    }
  }

  try {
    rmdirSync(legacy)
    return true
  } catch {
    return false
  }
}

/** True when this call is what made the directory. */
function madeDirectory(dir: string): boolean {
  // `mkdirSync` with `recursive` answers with the first path it created and
  // `undefined` when there was nothing to do, which is exactly the question
  // being asked — and asking it this way has no window between a check and a
  // create for something else to fill.
  return mkdirSync(dir, { recursive: true, mode: 0o700 }) !== undefined
}

/**
 * Write a file only if nothing is there, and say whether it wrote.
 *
 * `wx` rather than `existsSync` then `writeFileSync`: the check-then-write pair
 * has a window in which the copilot itself — which is running in this directory
 * — could create the file, and losing somebody's first memory to a race in the
 * scaffolder would be a very hard bug to believe in later.
 */
function wroteIfAbsent(file: string, contents: string): boolean {
  try {
    writeFileSync(file, contents, { flag: 'wx', mode: 0o600 })
    return true
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') return false
    throw error
  }
}

/* ------------------------------------------------- what it reads at startup -- */

export interface StartupFile {
  path: string
  /** What this file is for, in a phrase a settings pane can print as-is. */
  purpose: string
  exists: boolean
  /** Bytes on disk, or null when it is not there. */
  size: number | null
  /** Last modified, epoch milliseconds, or null when it is not there. */
  modifiedAt: number | null
  /**
   * Whose file this is, which the pane draws as a badge.
   *
   * The distinction the list exists to make now that the working directory can
   * be somebody's own workspace. `app` is a file under `<userData>` that this
   * app wrote and may rewrite; `yours` is a file this app seeded and will never
   * touch again; `folder` is a file in the working directory that this app does
   * not write at all and only reads to say it is there.
   */
  owner: 'app' | 'yours' | 'folder'
}

/**
 * The files the copilot loads when it starts, in the order it loads them.
 *
 * This is the answer to *"whatever files it reads in the beginning… properly
 * organized"* — the settings pane lists exactly this, so a person can see what
 * their assistant read before it said anything. It is computed from the
 * filesystem on every call rather than remembered, because the interesting case
 * is the one where the person has just edited a file and wants to see that it
 * landed.
 *
 * ## The order is the order, and it is not alphabetical
 *
 * The composed layer first, because it arrives on the command line and is in the
 * context before the model has read anything on disk. Then the folder's own
 * `CLAUDE.md`, which the CLI discovers from the working directory the ordinary
 * way. Then the memory index and each memory file.
 *
 * The folder's `CLAUDE.md` is listed **even when it is not there**, and that is
 * deliberate rather than an oversight in a default install. Its absence is the
 * single most reassuring row on this pane: it is the visible proof that nothing
 * in that folder claims to be a copilot, so an ordinary terminal opened there
 * reads nothing of ours. A row saying "not there" states it; leaving the row out
 * would leave a person to infer it.
 *
 * The two source halves of the layer are not listed here. They are not what the
 * *session* reads — the composed file is — and the pane gives each of them its
 * own editor with its own explanation, which is a better place for "this half is
 * yours and this half is generated" than a file listing.
 *
 * `memory/` is listed as its individual files rather than as a directory. A
 * directory row would say "memory: 11 files" and answer nothing; the point of
 * one-file-per-fact is that the names *are* the summary.
 */
export function copilotStartupFiles(paths: CopilotPaths, list = listMemoryFiles): StartupFile[] {
  const files: StartupFile[] = [
    describe(
      paths.layer.composed,
      'The copilot layer — handed to it on the command line, never written into the folder',
      'app',
    ),
    describe(
      folderInstructions(paths),
      paths.ownFolder
        ? 'The folder’s own instructions. This app never writes one here — an empty row means nothing in this folder claims to be the copilot'
        : 'The folder’s own instructions — yours, read the ordinary way, never written by this app',
      'folder',
    ),
    describe(paths.memoryIndex, 'Memory index', 'folder'),
  ]
  for (const file of list(paths.memory)) {
    if (file === paths.memoryIndex) continue
    files.push(describe(file, 'Memory', 'folder'))
  }
  return files
}

/**
 * The three app-side files, described the same way the startup list is.
 *
 * Kept apart from {@link copilotStartupFiles} rather than folded into it,
 * because they answer a different question and the pane draws them differently.
 * That list is *what the session reads*, in order, and only the composed file
 * belongs to it. This is *what this app keeps about its own agent* — the half
 * the person owns, the half that is generated, and the composition of the two —
 * and each one gets a box rather than a row.
 *
 * The `owner` field is the whole reason a settings pane can say which is which
 * without a second table mapping filenames to explanations. It is computed here,
 * beside the paths, so a fourth file added later cannot arrive unlabelled.
 */
export function copilotLayerFiles(paths: CopilotPaths): StartupFile[] {
  return [
    describe(
      paths.layer.yours,
      'Yours — the persona and the standing instructions. Editable, and never written over.',
      'yours',
    ),
    describe(
      paths.layer.contract,
      'The app’s — the tool contract and the permission rules. Generated from the live tool catalogue every time the copilot starts.',
      'app',
    ),
    describe(
      paths.layer.composed,
      'The two of them composed — byte for byte what the running copilot was handed.',
      'app',
    ),
  ]
}

/** Markdown files directly inside `memory/`, sorted, absolute. */
function listMemoryFiles(dir: string): string[] {
  try {
    return readdirSync(dir)
      .filter((name) => name.endsWith('.md'))
      .sort()
      .map((name) => join(dir, name))
  } catch {
    // Absent or unreadable. The two rows above still describe themselves as
    // missing, which is more useful than an empty list.
    return []
  }
}

function describe(path: string, purpose: string, owner: StartupFile['owner']): StartupFile {
  try {
    const stat = statSync(path)
    return { path, purpose, exists: true, size: stat.size, modifiedAt: stat.mtimeMs, owner }
  } catch {
    return { path, purpose, exists: false, size: null, modifiedAt: null, owner }
  }
}

/* ------------------------------------------------------------------ report -- */

/**
 * What is in `CLAUDE.md` right now, in the only four flavours that matter.
 *
 * The distinction that earns this type is between the middle two. Both are "not
 * what this build ships", and they call for opposite behaviour from a settings
 * pane: one is somebody's own writing that must be defended, the other is a file
 * this app wrote itself, in a build whose wording was wrong, that nobody has ever
 * touched. Reporting both as "edited" is how a person ends up running a copilot
 * whose instruction file tells it that it cannot read their projects.
 */
export type InstructionsState =
  /** No file. The next scaffold writes one. */
  | 'missing'
  /** Byte for byte what this build ships. */
  | 'current'
  /**
   * A default an earlier build of this app wrote, untouched since. Safe to
   * replace — nothing in it is the person's — and worth offering loudly,
   * because an out-of-date instruction file makes the copilot wrong about
   * itself. See `copilot-instructions-history.ts`.
   */
  | 'superseded'
  /** Somebody's own words. Never replaced without them asking. */
  | 'edited'

export interface CopilotHomeReport {
  paths: CopilotPaths
  /**
   * True only for `current`.
   *
   * Kept as a boolean because a pane asking "is there anything to restore" wants
   * one, and because it was the field this report already had. It cannot answer
   * the question {@link instructions} exists for, which is *why* the answer is
   * false.
   */
  instructionsAreDefault: boolean
  /** Current, superseded, hand-edited, or missing. */
  instructions: InstructionsState
  /** Files it will read at startup, with their sizes and times. */
  startupFiles: StartupFile[]
  /** The three app-side files — see {@link copilotLayerFiles}. */
  layerFiles: StartupFile[]
}

/**
 * Which of the four states `CLAUDE.md` is in.
 *
 * Compared against rendered text rather than against a stored hash, because the
 * template interpolates this install's own paths — two machines have different
 * bytes for the same default, and a hash of one would call the other edited.
 * Rendering a handful of templates is a few hundred microseconds on a path that
 * already reads the file.
 */
export function instructionsState(paths: CopilotPaths): InstructionsState {
  let current: string
  try {
    current = readFileSync(paths.instructions, 'utf8')
  } catch {
    return 'missing'
  }
  if (current === copilotInstructions()) return 'current'
  if (PAST_COPILOT_INSTRUCTIONS.some((past) => past(paths) === current)) return 'superseded'
  return 'edited'
}

export interface ResetResult {
  /** True when the file on disk is now this build's default. */
  reset: boolean
  /**
   * Where the previous contents were copied, or null when there was no file.
   *
   * Always written when there was something to save, even for a `superseded`
   * file nobody has edited. It costs one small write and it is the difference
   * between a button that is safe to press and one that needs a dialog in front
   * of it — the same argument `COPILOT-CAPABILITIES.md` makes for taking a
   * last-good snapshot before a settings write. A confirmed mistake is still a
   * mistake.
   */
  backup: string | null
  /** Why nothing happened, or null. */
  error: string | null
}

/**
 * Put this build's instructions back, keeping whatever was there.
 *
 * The one function in this module that overwrites, and the reason the rest of it
 * does not have to. Scaffolding stays strictly additive — it can run at any
 * moment, on every start, and must never touch a file that exists. Replacing the
 * instructions is a thing a person *asks for*, once, by pressing something, and
 * the two behaviours stay in different functions so that no future edit to the
 * scaffolder can accidentally acquire this one's power.
 *
 * The backup is a plain `.bak` beside the file rather than a numbered series.
 * One generation is what the rest of this module keeps for the action log, and
 * the case being protected against is "I pressed the button and I want my words
 * back", which is answered by the most recent copy and not by a history.
 */
export function resetCopilotInstructions(paths: CopilotPaths): ResetResult {
  let previous: string | null
  try {
    previous = readFileSync(paths.instructions, 'utf8')
  } catch {
    previous = null
  }

  const backup = `${paths.instructions}.bak`
  try {
    // The *layer's* directory, not the copilot's folder. These two writers put
    // bytes into `paths.instructions`, which lives under `<userData>` now — and
    // a `mkdir` of the working directory here would be this app creating a
    // folder somebody chose but has since deleted, which is precisely the thing
    // it must not do.
    mkdirSync(paths.layer.dir, { recursive: true, mode: 0o700 })
    if (previous !== null) writeFileSync(backup, previous, { mode: 0o600 })
    writeFileSync(paths.instructions, copilotInstructions(), { mode: 0o600 })
  } catch (error) {
    return {
      reset: false,
      backup: null,
      error: error instanceof Error ? error.message : String(error),
    }
  }
  return { reset: true, backup: previous === null ? null : backup, error: null }
}

/**
 * Everything a settings pane needs to describe the folder, without reading it
 * twice.
 *
 * The two instruction fields answer two different questions and a pane needs
 * both: `instructionsAreDefault` says whether there is anything to restore at
 * all, and `instructions` says whether restoring it would throw away somebody's
 * writing. Offering is a different thing from doing, and telling a person
 * *which* of those two they are looking at is the difference between an offer
 * they can accept and one they have to guess about.
 */
export function copilotHomeReport(paths: CopilotPaths): CopilotHomeReport {
  const instructions = instructionsState(paths)
  return {
    paths,
    instructionsAreDefault: instructions === 'current',
    instructions,
    startupFiles: copilotStartupFiles(paths),
    layerFiles: copilotLayerFiles(paths),
  }
}

/* ------------------------------------------------- editing the instructions -- */

/**
 * The most `CLAUDE.md` may be, whether it arrives from an editor or a template.
 *
 * A ceiling rather than a guess at what is reasonable: this file is loaded into
 * the model's context on every single start, so an accidental paste of a log
 * file into the box is a cost that repeats forever and a context window spent on
 * nothing. 256 KB is about forty times the size of the file this build ships,
 * which is far enough away that nobody writing instructions will ever meet it.
 */
export const MAX_INSTRUCTIONS_BYTES = 256 * 1024

export type InstructionsReadResult =
  | { ok: true; text: string; state: InstructionsState; path: string }
  | { ok: false; error: string; path: string }

/**
 * The instruction file as it is on disk, for an editor to put in a box.
 *
 * Whole, never truncated, and that is a decision rather than an oversight.
 * {@link readMemoryFact} in `copilot-inspect.ts` may hand a window the first
 * 256 KB of a memory file because that call feeds a *viewer*; this one feeds a
 * box with a Save button under it, and an editor showing a truncated file is a
 * delete waiting for somebody to press the button. The ceiling is enforced on
 * the way in instead, so a file this cannot return whole is a file this app
 * never wrote.
 */
export function readCopilotInstructions(paths: CopilotPaths): InstructionsReadResult {
  try {
    const text = readFileSync(paths.instructions, 'utf8')
    return { ok: true, text, state: instructionsState(paths), path: paths.instructions }
  } catch (error) {
    return {
      ok: false,
      path: paths.instructions,
      error:
        // Named by what it is, not by a filename. This reads
        // `<userData>/copilot-layer/instructions.md`, so "CLAUDE.md" — which is
        // what this string used to say — pointed somebody at a file that is not
        // the one that is missing, in the one message whose whole job is to say
        // which file is missing.
        (error as NodeJS.ErrnoException).code === 'ENOENT'
          ? 'There are no instructions yet. Create its files first.'
          : error instanceof Error
            ? error.message
            : String(error),
    }
  }
}

export interface InstructionsWriteResult {
  saved: boolean
  /** Where what was there has been copied, or null when there was no file. */
  backup: string | null
  /** Why nothing was written, or null. */
  error: string | null
}

/**
 * Put somebody's own instructions on disk, keeping what was there.
 *
 * Three refusals, and each one is a way this file has of being destroyed by an
 * interface rather than by a decision:
 *
 *  - **Not a string** is the wire being wrong, and writing `undefined` into the
 *    agent's system prompt is the worst possible interpretation of a bad frame.
 *  - **Empty, or nothing but whitespace,** is refused because it is
 *    indistinguishable from a box that failed to load and a person who pressed
 *    Save anyway. A copilot with no instructions is not a smaller copilot; it is
 *    an agent with tools, a boundary and no idea what it is for, and the file
 *    that was supposed to say so is gone. Somebody who genuinely wants that can
 *    delete the file in Finder, where nothing is ambiguous about what they did.
 *  - **Over the ceiling** — see {@link MAX_INSTRUCTIONS_BYTES}.
 *
 * The backup is unconditional, and it is the reason this is safe to wire to a
 * button. It costs one small write and it answers the only question somebody
 * asks after an edit they regret. `.bak` rather than a numbered series, matching
 * {@link resetCopilotInstructions}, so the two writers cannot leave two
 * different kinds of history beside one file — and so "my previous version" has
 * exactly one meaning.
 */
export function writeCopilotInstructions(
  paths: CopilotPaths,
  text: unknown,
): InstructionsWriteResult {
  if (typeof text !== 'string') {
    return { saved: false, backup: null, error: 'Nothing was supplied to save.' }
  }
  if (text.trim() === '') {
    return {
      saved: false,
      backup: null,
      error:
        'Instructions cannot be empty — a copilot with no instructions still has its tools and its boundary, and nothing telling it what it is for.',
    }
  }
  if (Buffer.byteLength(text, 'utf8') > MAX_INSTRUCTIONS_BYTES) {
    return {
      saved: false,
      backup: null,
      error: `Instructions cannot be larger than ${Math.round(MAX_INSTRUCTIONS_BYTES / 1024)} KB. This file is read at the start of every conversation.`,
    }
  }

  let previous: string | null
  try {
    previous = readFileSync(paths.instructions, 'utf8')
  } catch {
    previous = null
  }
  // Saving what is already there would replace a real backup with a copy of the
  // thing being kept — so a second Save on an unchanged box would erase the one
  // version somebody actually wanted back.
  if (previous === text) {
    return { saved: true, backup: null, error: null }
  }

  const backup = `${paths.instructions}.bak`
  try {
    // The *layer's* directory, not the copilot's folder. These two writers put
    // bytes into `paths.instructions`, which lives under `<userData>` now — and
    // a `mkdir` of the working directory here would be this app creating a
    // folder somebody chose but has since deleted, which is precisely the thing
    // it must not do.
    mkdirSync(paths.layer.dir, { recursive: true, mode: 0o700 })
    if (previous !== null) writeFileSync(backup, previous, { mode: 0o600 })
    writeFileSync(paths.instructions, text, { mode: 0o600 })
  } catch (error) {
    return {
      saved: false,
      backup: null,
      error: error instanceof Error ? error.message : String(error),
    }
  }
  return { saved: true, backup: previous === null ? null : backup, error: null }
}
