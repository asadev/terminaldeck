/**
 * The app's own map of itself, handed to every session at the top of its
 * context and to nobody else.
 *
 * ## What he asked for
 *
 * Asad, 2026-08-21, twice in one recording:
 *
 * > *"when any session starts, even from the remote, even from the office PC,
 * > local machine, or even if it is starting from the server … we can give a
 * > proper context file or a map."*
 *
 * > *"which will be an invisible kind of context, not somewhere in the
 * > settings, no file will be visible to edit it. But it will be inside the
 * > application. It will just back in the backend, it will inject it during, in
 * > the beginning."*
 *
 * > *"later if AI agent wants to know more anything, it knows already the map of
 * > context and it can come go to the path inside the application and it can
 * > read from there whatever more context it needs and tools and all of this
 * > stuff."*
 *
 * The gap he was pointing at is measured rather than assumed. A session started
 * on the Office PC, asked *"which app are you running now, are you told in the
 * boot"*, answered out of `CLAUDE_CODE_ENTRYPOINT` and a `which claude` — a
 * table naming the CLI, its version and its binary, and never this app. It was
 * told nothing at boot because the headless host started the endpoint with no
 * `contextFor` at all: the channel existed there and answered `204` to every
 * knock. `src/headless/host.ts` is where that is fixed; this module is what it
 * now has to say.
 *
 * ## Why a map rather than the context itself
 *
 * `browser-binding.ts` argues at its own `hookContext` that a line earns its
 * place only by changing what the agent *does*, because that answer rides every
 * prompt. This one rides once per context (see {@link bootMapFor}) so it can
 * afford three sentences — and three sentences is still not room for how
 * browser windows work, what a machine is, or what `B2` means. So the injection
 * names a directory and the directory holds the rest. An agent that never needs
 * it never pays for it, which is his *"later if AI agent wants to know more"*
 * read literally.
 *
 * ## Why the documents are generated and not shipped
 *
 * Two reasons, and the second is the one he stated:
 *
 *  - They carry this install's own facts — its version, its machine, whether
 *    the `open` shim is on a session's PATH — and a checked-in Markdown file
 *    cannot know any of them.
 *  - **Nothing here may be an editable setting.** These are rewritten from code
 *    at every start, exactly like `open-shim.ts`'s script and `hook-server.ts`'s
 *    Windows client, and each one says so in its own first line. There is no
 *    settings field, no path picker and no file in anybody's project: they live
 *    inside the app's own data directory, which is the *"inside the
 *    application"* half of what he asked for.
 *
 * ## Where they live, and the one thing that had to be granted
 *
 * `<userData>/context/`. A session started by a paired device is confined —
 * `confine/plan.ts` deliberately keeps `<userData>` out of every read root,
 * because that directory also holds transcripts, pairing credentials and
 * `state.json`. So the map would have named a path that a remote session, which
 * is precisely the case he filmed, cannot open. `host-core.ts` grants these
 * files by name through `DeviceConfinement.files`, the same door the guest git
 * credential helper already uses: individual files, read only, chosen here and
 * regenerated every launch.
 */

import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { BRAND } from '../shared/brand'
import { writeFileAtomic } from './atomic-write'
import { currentPlatform, isWindows, type Platform } from './platform/host'

/* ------------------------------------------------------------------ types -- */

/** What this install is, as far as an agent inside it needs to care. */
export interface AppContextInput {
  /** The app's data directory. The documents go in a folder inside it. */
  dir: string
  /** `app.getVersion()` in the window, `hostVersion()` headless. */
  version: string
  /** What this computer calls itself — `describeThisMachine().name`. */
  machineName: string
  /**
   * Whether this run put its `open` shim on a session's PATH.
   *
   * The same gate `hookContext` applies to the same sentence, for the same
   * reason: `open-shim.ts` writes nothing on Windows, or on a Linux box with no
   * real opener behind it, and a document telling an agent that `open <url>`
   * lands in this app would be a confident falsehood on both.
   */
  opensInApp: boolean
  /** Which platform's spelling. Defaults to this machine's. */
  platform?: Platform
}

/** What was written, and where. */
export interface AppContext {
  /** The directory holding every file below. */
  dir: string
  /** The index the injected map names — the one file an agent is told to read. */
  index: string
  /** Every file written, index included. Absolute paths, for the read grants. */
  files: readonly string[]
  /** The text injected at the top of a session's context. */
  map: string
}

/* -------------------------------------------------------------- constants -- */

/** The directory inside the app's data directory. Stable across runs. */
export const CONTEXT_DIR = 'context'

/** The one file the injected map names by name. */
export const INDEX_FILE = 'INDEX.md'

/**
 * The events that carry the map, in each CLI's spelling, and why these two.
 *
 * `SessionStart` is Claude's and Codex's door and it is the right one twice
 * over: it is *"in the beginning"*, and it fires again on `resume`, `clear` and
 * `compact` — every moment a context is rebuilt and the map would otherwise
 * have been lost out of it. So it is answered every time rather than latched.
 *
 * `BeforeAgent` is Gemini's, and it is here only because Gemini's `SessionStart`
 * is deliberately not answered at all: `hook-server.ts` measured that its
 * `additionalContext` lands as a synthesised **user** turn, which is the thing
 * Asad objected to out loud when an account switch put a line in his message.
 * `BeforeAgent` fires on every prompt, so this one *is* latched — see
 * {@link bootMapFor}.
 *
 * Claude's `UserPromptSubmit` is not here and must not be. `SessionStart` has
 * already carried the map into that same context, and repeating it above every
 * prompt he types is the wall of statements he has banned.
 */
export const MAP_EVENTS: ReadonlySet<string> = new Set(['SessionStart', 'BeforeAgent'])

/** The one of those that repeats, and so has to be said once and then stop. */
const LATCHED_EVENTS: ReadonlySet<string> = new Set(['BeforeAgent'])

/* ---------------------------------------------------------------- writing -- */

/** Where the documents live for one data directory. */
export function contextDir(dir: string): string {
  return join(dir, CONTEXT_DIR)
}

/**
 * What this run wrote, or null before it wrote anything.
 *
 * Module state rather than an argument threaded through `createHostCore`, for
 * the reason `open-shim.ts` states about its own: the documents can only be
 * written once the app knows its version and its data directory, and a session
 * is started long afterwards by a file that has no business knowing either.
 */
let current: AppContext | null = null

/** The documents this run wrote, for the two callers that need their paths. */
export function currentAppContext(): AppContext | null {
  return current
}

/**
 * Write the documents and compose the map that names them.
 *
 * Called once at start, from the window's `index.ts` and from the headless
 * host, before anything can start a session — the same ordering `writeOpenShim`
 * is given and for the same reason: a session started before this exists would
 * be handed a map to a directory that is not there.
 */
export function writeAppContext(input: AppContextInput): AppContext {
  const platform = input.platform ?? currentPlatform()
  const dir = contextDir(input.dir)
  mkdirSync(dir, { recursive: true })

  const pages: Record<string, string> = {
    [INDEX_FILE]: indexPage(input, dir, platform),
    'sessions-and-machines.md': sessionsPage(input),
    'browser-windows.md': browserPage(input, platform),
  }

  const files: string[] = []
  for (const [name, body] of Object.entries(pages)) {
    const file = join(dir, name)
    writeFileAtomic(file, body, platform)
    files.push(file)
  }

  current = {
    dir,
    index: join(dir, INDEX_FILE),
    files,
    map: mapText({ version: input.version, machineName: input.machineName, dir }),
  }
  return current
}

/**
 * The three sentences that ride in the agent's context.
 *
 * Exported so a test can read them without a filesystem, and because the map is
 * the part with a budget: it is composed once here rather than assembled at the
 * call site, where a second spelling of it would drift from the documents it
 * names.
 *
 * One path in it, not two. The directory was named as well as the index inside
 * it, which is the same fact twice — the second is the first with a filename on
 * the end — and a data directory is sixty bytes of the budget on a Mac. An agent
 * holding the index can list the folder it is in.
 *
 * It opens mid-sentence on purpose — *"It is version…"* — because it is inserted
 * directly under `hookContext`'s first line, *"You are running inside Terminal
 * Deck, a terminal app with browser windows of its own."* Naming the app again
 * here would be the same fact twice in two consecutive lines.
 */
export function mapText(input: { version: string; machineName: string; dir: string }): string {
  return [
    `It is version ${input.version}, running on ${input.machineName}.`,
    'What else is true of this app is written in files on this machine.',
    `${join(input.dir, INDEX_FILE)} is a short index naming which of them answers what — read it when a question about this app comes up, and not before.`,
  ].join(' ')
}

/* ---------------------------------------------------------------- the map -- */

/**
 * Sessions that have already been handed the map by a latched event.
 *
 * One session id per session for the life of the process, which is a few dozen
 * bytes each on a machine that started a few hundred sessions without a
 * restart. It is not cleared when a session exits, and that is deliberate
 * rather than overlooked: a session id is never reused, so an entry left behind
 * can only ever suppress a repeat of something that was already said.
 *
 * Two honest imprecisions, neither worth a mechanism:
 *
 *  - An id lands here even when the caller then answers `null` — a Gemini
 *    session in his own terminal, whose hook fires because the hook is
 *    installed for the whole account, is latched and told nothing. Suppressing
 *    a repeat of nothing is free, and the alternative is this module knowing
 *    which sessions the app started, which is exactly the dependency
 *    `browser-binding.ts` refuses for the same reason.
 *  - The set is what makes the latch per session; the process is what bounds
 *    it. A desktop that ran for a month with a thousand sessions is holding
 *    forty kilobytes of strings.
 */
const told = new Set<string>()

function keyOf(sessionId: string, machineId: string): string {
  return `${machineId} ${sessionId}`
}

/**
 * The map, when this knock is one that should carry it, and null otherwise.
 *
 * Null is the common case and it is free: the caller falls back to the standing
 * answer `hookContext` composes, or to the empty `204` this endpoint has always
 * given a session it does not know.
 *
 * The latch applies to `BeforeAgent` and to nothing else. Gemini's is the only
 * door here that fires on every prompt, and paying for these sentences on every
 * turn is exactly the cost this whole design is shaped to avoid. The price of
 * the latch is stated rather than hidden: a Gemini session that clears its
 * context mid-life does not get the map back, because the one event that would
 * tell us it happened is the one this app refuses to answer for Gemini.
 */
export function bootMapFor(event: string, sessionId: string | null, machineId = ''): string | null {
  if (sessionId === null || current === null) return null
  if (!MAP_EVENTS.has(event)) return null
  if (!LATCHED_EVENTS.has(event)) return current.map
  const key = keyOf(sessionId, machineId)
  if (told.has(key)) return null
  told.add(key)
  return current.map
}

/** Test seam. Nothing in the app calls this. */
export function resetForTests(): void {
  current = null
  told.clear()
}

/* -------------------------------------------------------------- the pages -- */

/**
 * The line every page opens with.
 *
 * It says the file is regenerated, in the same words `open-shim.ts` puts at the
 * top of its script and for the same reason: this must not become something
 * anybody edits. An edit here survives until the next launch, which is the worst
 * of both — it looks permanent and is not.
 */
function preamble(version: string): string {
  return [
    `<!-- Written by ${BRAND.name} ${version} at every start. Do not edit: this file is`,
    'rewritten on the next launch, so a change here would look permanent and be lost. -->',
  ].join('\n')
}

/** The noun a platform gets called in a sentence. */
function platformNoun(platform: Platform): string {
  if (isWindows(platform)) return 'Windows'
  return platform === 'darwin' ? 'macOS' : 'Linux'
}

function indexPage(input: AppContextInput, dir: string, platform: Platform): string {
  const opener = input.opensInApp
    ? '`open <url>` inside a session opens a window in this app. See `browser-windows.md`.'
    : "`open` inside a session is the machine's own opener; this build does not shim it here."
  return `${preamble(input.version)}

# ${BRAND.name} — what a session can look up about the app around it

A session running in this app was told, at the top of its context, that this
directory exists. This file is the index: it says what the other files answer, so
that a question about this app can be looked up rather than guessed at.

Nothing here is a secret and nothing here needs repeating back. It is a
description of the surroundings, so that "open it in the browser", "which machine
is this" and "look at B2" mean something specific.

## This install

- Version: ${input.version}
- Machine: ${input.machineName} (${platformNoun(platform)})
- This directory: ${dir}
- ${opener}

## The other files here

- \`sessions-and-machines.md\` — what a session is here, which machine it is
  running on, and how this app learns what a session is doing.
- \`browser-windows.md\` — the browser windows this app has of its own, how one
  comes to belong to a session, what \`B1\` and \`B2\` mean, and what that lets a
  session do.
`
}

function sessionsPage(input: AppContextInput): string {
  return `${preamble(input.version)}

# Sessions and machines

## What a session is here

One agent CLI, in one pseudo-terminal, in one folder, started by ${BRAND.name}.
Every session has an id, and a session's own id is in its environment as
\`${BRAND.sessionEnvVar}\`.

That variable is also how this app tells its own sessions apart from everything
else on the machine. The hooks below are installed for the whole account, so they
fire for a \`claude\` somebody started in a plain terminal too — and that one is
answered with nothing, deliberately. If you were given this map, you are inside
the app.

The agents this build starts are Claude Code, Codex CLI, Gemini CLI, a plain
shell, and any other command the person added themselves.

## How the app knows what a session is doing

Through the CLI's own hook file — \`~/.claude/settings.json\`,
\`~/.codex/hooks.json\` or \`~/.gemini/settings.json\` — which this app writes one
entry into per lifecycle event, each tagged \`# ${BRAND.id}-hook\`. Entries
belonging to anything else are never touched.

Each event POSTs the CLI's own event JSON to a unix socket (a named pipe on
Windows) that only this account can open. The app reads the event name, the
working directory and the tool being called, and turns them into the status shown
on that session's tab.

The reply to that same POST is how the context at the top of this session
arrived. It reaches the model through the CLI's own hook output, so no character
of it is typed into the terminal the person is looking at, and there is nothing
for them to scroll back to.

## Machines

${BRAND.name} runs sessions on more than one machine: this one, and any machine
paired with it. The machines are listed under Integrations in the app's sidebar,
and a session started on one of them runs *there* — with that machine's
filesystem, shell, network and logins.

This matters most when it is least obvious. The person reading your output may be
sitting at a different computer from the one you are running on. Their files are
not the files you can see, their \`localhost\` is not your \`localhost\`, and a path
they paste may not exist here.

This session is running on ${input.machineName}.
`
}

function browserPage(input: AppContextInput, platform: Platform): string {
  const opening = input.opensInApp
    ? `## Opening a page

\`open <url>\` is on this session's PATH ahead of the machine's own opener, so a
\`http://\` or \`https://\` URL you open lands in a window in this app and the
command prints which one. If a window is already attached to this session, the
page goes there. If none is, the app opens one, attaches it, and says so.

Everything that is not a single http(s) URL — \`open .\`, \`open -a Xcode f.swift\`,
\`open -R\`, a PDF, a bare \`open\` — is handed to the real opener untouched. So is
every URL when this app is not running: the command falls through to the machine
and says that it did, rather than exiting quietly having opened nothing.`
    : `## Opening a page

This build does not put an opener on a session's PATH on ${platformNoun(platform)},
so \`open\` here is the machine's own and a URL you open does not land in this
app. Windows already attached to this session are still yours to read about
below.`

  return `${preamble(input.version)}

# Browser windows

${BRAND.name} has browser windows of its own, in the same window as the sessions.
One of them can be attached to a session, and that relation is what gives "the
browser" an address instead of leaving it a guess.

## Names

A window attached to a session is called \`B1\`, \`B2\`, \`B3\` … The number belongs
to that session, is given out when the window is attached, and is never reused —
so \`B2\` means the same window for as long as the session lives, including after
\`B1\` has been detached.

When the windows attached to a session change, that session is told: at the top
of its next turn, or at its very next tool call if it is already working. The
line for a window carries its name, its title and its address — each part left
off entirely when the window has not reported it, rather than filled in with a
placeholder that would read like a fact.

It carries one more part only when that part is true: the machine actually
serving the page. A page reached through this app's tunnel wears a \`localhost\`
address on the machine it is being viewed from, so the URL alone would say the
opposite of the truth, and \`— served by <machine>\` is the correction.

## How a window comes to belong to a session

A person does this. Two places, and they are the same relation seen from either
end:

- from the session — the \`⋯\` menu beside it, then **Connect browser**, then the
  window;
- from the browser window — its own menu, then the session.

Both are checklists: the ticked row is the current relation, ticking another
moves it, and unticking the ticked one detaches. A session cannot attach a window
to itself, so asking for one is a request for the person to act on, not a tool
call to look for.

${opening}

## What a session can and cannot do with a window

It can be told what is in one, and it can put a page in front of the person. It
cannot click, type, scroll or read the page — a session has no tool for any of
that. Driving a page belongs to the copilot, which is a separate session with its
own tool surface and its own confirmation gate.

So "look at B2" from the person means: the page in that window is the subject.
Ask them what it says, or open something into it.
`
}
