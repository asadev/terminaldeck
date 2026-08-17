/**
 * The tools, their tiers, and every bound they are held inside.
 *
 * One table. A tool is a name, a tier, a JSON Schema, a sentence for the
 * confirmation dialog, and a function that calls something the app already
 * does. Nothing here reaches the filesystem or a process directly — it all goes
 * through {@link DeckSurface}, which is what makes the dangerous decisions in
 * `control.ts` testable without an Electron app around them.
 *
 * ## Names
 *
 * The canonical id is the dotted form the design document uses — `sessions.send`
 * — and that is what the action log records and what a person reads. The name
 * on the wire replaces the dot with an underscore, because the tool eventually
 * reaches the Anthropic API as `mcp__deck-control__sessions_send` and tool names
 * there are `[a-zA-Z0-9_-]` only. A dot would be rejected by the API, not by
 * this app, which is the worst place to find out. `catalogue.test.ts` pins the
 * charset, and — see {@link MAX_CATALOGUE_TOKENS} — the token cost of the whole
 * assembled listing, which is what a tool actually charges on every turn.
 *
 * ## What is deliberately absent
 *
 * `routines.list`, `routines.create`, `routines.delete`. They are in the design
 * document, and there is no routine engine — no trigger subscriptions, no
 * runner, no `routines/` folder being read by anything. A tool that returns an
 * empty list and a tool that writes a file nothing ever executes would both
 * pass a demo and lie to the user about what their copilot can do. House rule
 * three: a tool that cannot do the thing must not exist. They land with the
 * engine.
 *
 * Nothing exposes cost, either. The cost work is landing in parallel and this
 * task may not touch it; a tool built against an API in motion would be wrong
 * by the time it shipped.
 *
 * ## The one tool here that exists to take a capability away
 *
 * `log.note` gives the copilot no power it did not have — it *replaces* one. The
 * action log used to live inside the copilot's own folder, which is the one
 * directory it may write to, so appending a row was a shell redirect and so were
 * editing, truncating and deleting the file. `copilot-home.ts` explains the move
 * to `<userData>/copilot-log/`; this is the other half of it. The copilot can
 * still put a line in the record, and now the line arrives through the same
 * dispatcher every other call does — tiered, budgeted, timed, and stamped with
 * who asked.
 */

import type { CreateSessionInput, ProviderId } from '../../shared/types'
import { attentionOf, byAttention, statusOf } from './attention'
import { checkSettingsValues, problemSentence } from './settings-validate'
import { Refused, type DeckSurface, type SessionView, type Tier, type TranscriptMessage } from './surface'

/* -------------------------------------------------------------- constants -- */

/** Providers a session may be started as. Mirrors `ProviderId`. */
const PROVIDERS: readonly ProviderId[] = ['claude', 'codex', 'gemini', 'shell']

/**
 * The terminal size a copilot-started session is given.
 *
 * A real session is sized by the window that draws it. This one has no window
 * yet — it appears in the sidebar and gets resized the moment somebody opens
 * it — so it needs a starting shape, and 120×30 is the same pair
 * `registerDevServerIpc` already uses for the sessions it starts headlessly.
 * Agent CLIs render a status line against the reported width, so a nonsense
 * width produces a garbled first screen even after the resize corrects it.
 */
const START_COLS = 120
const START_ROWS = 30

/** Longest text `sessions.send` will type into a session in one call. */
export const MAX_SEND_CHARS = 4000

/**
 * Longest note `log.note` will write into the action log.
 *
 * Far shorter than a message to a session, and deliberately. The action log is
 * a list a person scans; `action-log.ts` describes `detail` as "one line a
 * person can read", and every other writer of the file obeys that. A tool that
 * let the copilot paste four thousand characters into one row would turn the
 * one surface built for skimming into a second, worse transcript — and the
 * copilot has a real transcript already.
 */
export const MAX_NOTE_CHARS = 300

/**
 * Transcript reading, bounded three ways.
 *
 * A transcript on this machine reaches 154 MB (measured — see `ChatReader`), so
 * "read the transcript" cannot mean "read the file". `windowBytes` is how much
 * of the *end* of the file is parsed, `limit` is how many messages come back,
 * and `MAX_MESSAGE_CHARS` × `MAX_TRANSCRIPT_CHARS` bound the payload after
 * that. All three are reported in the result, so the copilot can tell the
 * difference between "that is the whole conversation" and "that is the last
 * page of it" instead of guessing.
 */
export const DEFAULT_TRANSCRIPT_LIMIT = 40
export const MAX_TRANSCRIPT_LIMIT = 200
export const DEFAULT_WINDOW_BYTES = 256 * 1024
export const MAX_WINDOW_BYTES = 4 * 1024 * 1024
export const MAX_MESSAGE_CHARS = 4000
export const MAX_TRANSCRIPT_CHARS = 64 * 1024
/** Tail of a terminal screen returned for a session that writes no transcript. */
export const MAX_SCREEN_CHARS = 8000

/* ------------------------------------------------------- catalogue budget -- */

/**
 * What this catalogue is allowed to cost, in tokens, on every single turn.
 *
 * A tool definition is not free and it is not paid once. Its name, description
 * and schema sit in the context of *every* request the copilot makes, so a
 * verbose tool is a standing tax on every question Asad asks — including the
 * ones that will never call it. The field numbers are stark: GitHub's MCP
 * server is roughly 55K tokens for 93 tools, a single definition runs 100–500
 * tokens, and reported degradation starts somewhere around five to seven
 * connected servers. `deck-control` is a permanent server on a permanently-open
 * session, which is the worst case of that shape.
 *
 * ## Why a token ceiling and not a tool count
 *
 * A count says nothing about cost. Eleven tools with terse schemas and eleven
 * tools whose descriptions each recite their own security model differ by
 * thousands of tokens and are the same number.
 *
 * What was here before was weaker even than a count. The header of this file
 * claimed `catalogue.test.ts` pinned "the charset and the assembled length";
 * the charset assertion was real and the length one had never been written, so
 * the only thing holding the size down was a list of eleven tool ids in an
 * `toEqual`. One tool with a fifty-line schema would have doubled the standing
 * cost with every test still green. `catalogue.test.ts` now measures the bytes
 * that actually cross to the model and fails on the budget.
 *
 * The count cap stays as well, because it answers a different question: past
 * twenty tools the problem is not the tokens, it is that a model choosing
 * between twenty things chooses worse. Whichever binds first is the one that
 * should.
 *
 * ## Past this point, disclose progressively
 *
 * The instruction for whoever hits this: do not raise the number. Add a
 * `tools.describe` meta-tool and move the rarely-used definitions behind it, so
 * the standing cost is a short index and the full schema is fetched by the one
 * turn that needs it.
 */
export const MAX_CATALOGUE_TOOLS = 20
export const MAX_CATALOGUE_TOKENS = 8_000

/**
 * Characters per token, for the estimate below.
 *
 * There is no tokenizer in this repository and no offline way to get the exact
 * number — Claude's is not published as a library and counting through the API
 * would make a test require a network and a key. So this is an estimate, and it
 * is deliberately an estimate that reads *high*:
 *
 *  - English prose runs about four characters per token, which is Anthropic's
 *    own published rule of thumb and covers the descriptions, which are most of
 *    the payload by volume.
 *  - JSON is denser. Punctuation, quotes and short structural keys tokenise at
 *    closer to two and a half to three characters each, and a tool listing is
 *    prose wrapped in a great deal of JSON.
 *
 * 3.5 sits between the two and nearer the pessimistic end, so the measured
 * number is high rather than low against the real cost. That is the direction a
 * budget must err in: a ceiling computed from an optimistic estimate is a
 * ceiling that is already breached by the time it fails.
 *
 * Anybody replacing this with a real tokenizer should keep the constant and the
 * function name, and expect the measured figure to fall.
 */
export const ESTIMATED_CHARS_PER_TOKEN = 3.5

export function estimateTokens(text: string): number {
  return Math.ceil(text.length / ESTIMATED_CHARS_PER_TOKEN)
}

/**
 * One tool, in exactly the shape `tools/list` puts on the wire.
 *
 * Exported and used by `server.ts` rather than duplicated there, because the
 * measurement below is only worth anything if it measures the real payload. A
 * second copy of this mapping is a second answer to "what does the model
 * actually see", and the budget would then be pinned against the wrong one.
 */
export function advertiseTool(spec: ToolSpec): Record<string, unknown> {
  return {
    name: spec.wire,
    title: spec.title,
    description: spec.description,
    inputSchema: spec.inputSchema,
    // Advertised so a client can colour the dangerous ones without calling
    // them. `readOnlyHint` is the one clients actually act on today.
    annotations: {
      title: spec.title,
      readOnlyHint: spec.tier === 'read',
      destructiveHint: spec.tier === 'alter',
      openWorldHint: false,
    },
  }
}

export interface CatalogueCost {
  tools: number
  /** Serialised length of the whole `tools/list` payload. A measurement, not an estimate. */
  chars: number
  /** {@link estimateTokens} of that. See {@link ESTIMATED_CHARS_PER_TOKEN}. */
  tokens: number
  /** True when either ceiling is exceeded. */
  overBudget: boolean
}

/**
 * What the assembled catalogue costs.
 *
 * Takes the tool list rather than calling `buildCatalogue()` itself, because the
 * catalogue that reaches the model is the built-in one *plus* whatever
 * `DeckControl` was handed as `extraTools`. Measuring only the built-ins would
 * leave the one growth path nobody is watching — a feature contributing six
 * verbose tools of its own — outside the budget it is meant to be held to.
 */
export function catalogueCost(tools: readonly ToolSpec[]): CatalogueCost {
  const payload = JSON.stringify({ tools: tools.map(advertiseTool) })
  const tokens = estimateTokens(payload)
  return {
    tools: tools.length,
    chars: payload.length,
    tokens,
    overBudget: tools.length > MAX_CATALOGUE_TOOLS || tokens > MAX_CATALOGUE_TOKENS,
  }
}

/**
 * Settings the copilot may never write, whatever a person clicks.
 *
 * This is not a confirmation list — these keys are refused at the tool
 * boundary, before any dialog is drawn, and there is no argument that unlocks
 * them. The reasoning is in `settings.write`'s description below and in the
 * report that accompanies this work; the short form is that a permission system
 * an agent can edit is a suggestion, and a dialog reading "change one setting"
 * looks identical whether the setting is the theme or the thing that decides
 * whether dialogs appear at all.
 *
 * Prefixes, so a namespace stays closed as it grows. `copilot.` and
 * `deckControl.` are reserved ahead of the settings pane that will fill them —
 * a key added there next month is protected the day it exists rather than the
 * day somebody remembers this list.
 */
export const PROTECTED_SETTING_PREFIXES: readonly string[] = [
  // Whether this machine accepts connections from other devices at all.
  'remote.',
  // The copilot's own configuration, including anything about its permissions.
  'copilot.',
  'deckControl.',
  // Reserved for anything that describes a boundary rather than a preference.
  'security.',
  'confine.',
]

export const PROTECTED_SETTING_KEYS: readonly string[] = [
  // Keeping browser credentials on disk between runs. A persistence decision
  // about somebody's logged-in sessions is not an assistant's to make.
  'browser.persistSession',
  // Turns on the IPC trace, which writes every channel call and its arguments
  // to a file. An agent that can switch on a global recorder can arrange for
  // secrets to be written down and then read them with the Read tool it
  // already has.
  'advanced.debugMode',
]

/** Preferences (`store.ts`) the copilot may write. Anything else is refused. */
export const WRITABLE_PREFERENCES: readonly string[] = [
  'theme',
  'defaultProvider',
  'restoreSessions',
  'notifyOnComplete',
]

export function isProtectedSetting(key: string): boolean {
  if (PROTECTED_SETTING_KEYS.includes(key)) return true
  return PROTECTED_SETTING_PREFIXES.some((prefix) => key.startsWith(prefix))
}

/* ------------------------------------------------------------------ types -- */

/** A JSON Schema, carried untyped because it crosses to a client that parses it. */
export type JsonSchema = Record<string, unknown>

export interface ToolOutput {
  /** The structured value the tool returns, serialised into the MCP result. */
  value: unknown
  /**
   * A handful of fields describing what happened, for the action log.
   *
   * Never the payload. `sessions.transcript` returns sixty kilobytes and
   * summarises itself as three numbers, because the log is an audit trail and
   * not a second copy of the app's data.
   */
  summary: Record<string, unknown>
}

export interface ToolContext {
  surface: DeckSurface
  /**
   * The id of the action-log row this call is about to write.
   *
   * Minted by `DeckControl.call` before the handler runs, and handed down here
   * for one purpose: a session the copilot starts records it as
   * `SessionMeta.originRunId`, so the sidebar row and the Activity row point at
   * each other. "Why does this exist" is then answerable in both directions
   * from data rather than from a guess about timing — which was the only other
   * way to pair a session with the turn that started it, and it is wrong the
   * moment two starts land in the same second.
   *
   * It is the row id and not a second identifier of its own, because a second
   * one would have to be written into the log as well to be resolvable, and
   * then the log would carry two ids for one event.
   */
  callId: string
  /** Did this run's copilot start that session? Drives the tier escalation. */
  startedByCopilot(sessionId: string): boolean
  /** Remember a session the copilot started, so later calls on it stay `act`. */
  noteStarted(sessionId: string): void
  /**
   * The dispatcher's clock, not `Date.now`.
   *
   * `viewOf` reports how long a session has needed attention, which is a
   * subtraction against now — and a tool that read the wall clock directly
   * would be the one part of this file a test could not pin. `DeckControl`
   * already takes a `now` for its budget windows; this is that same one, so a
   * test that freezes time freezes all of it.
   */
  now(): number
}

export interface ToolSpec {
  /** Canonical dotted id: what the log records and a person reads. */
  id: string
  /** Name on the wire: the dotted id with underscores. See the header. */
  wire: string
  tier: Tier
  title: string
  description: string
  inputSchema: JsonSchema
  /**
   * Raise the tier for these particular arguments.
   *
   * Only ever upwards — `control.ts` takes the higher of this and `tier`, so a
   * buggy escalation cannot weaken a gate, only tighten one.
   */
  escalate?(args: Record<string, unknown>, context: ToolContext): Tier
  /**
   * Refuse arguments that can never be allowed, before anything else happens.
   *
   * Runs ahead of the budgets and ahead of the confirmation gate, and that
   * ordering is the whole reason it exists rather than being folded into
   * `run`. A rule like "the copilot may not write `remote.enabled`" is not a
   * rule if the person is shown a dialog for it first: they answer it in the
   * same shape as the four harmless ones they approved earlier, and a refusal
   * that arrives after a yes has already trained them to click yes.
   *
   * Throws `Refused` for a rule and `BadArgument` for a malformed call. Silence
   * means "these arguments are at least permitted"; it is not a claim that the
   * call will succeed.
   */
  precheck?(args: Record<string, unknown>, context: ToolContext): void
  /** One sentence naming what will happen. Shown in the dialog, kept in the log. */
  summary(args: Record<string, unknown>, context: ToolContext): string
  run(args: Record<string, unknown>, context: ToolContext): Promise<ToolOutput>
}

/* --------------------------------------------------------- argument types -- */

/**
 * Hand-written argument checks rather than a schema validator.
 *
 * The SDK ships `ajv`, and the schemas below are advertised to the client so a
 * well-behaved one will already have checked. Neither fact is a reason to trust
 * the arguments: the client is a language model, and the schema is a hint to it
 * rather than a contract it is bound by. These functions are the actual
 * boundary, they are eleven lines, and each one throws a message a model can
 * act on rather than a validator's path expression.
 */

class BadArgument extends Error {}

function str(args: Record<string, unknown>, key: string): string {
  const value = args[key]
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new BadArgument(`${key} is required and must be a non-empty string`)
  }
  return value
}

function optBool(args: Record<string, unknown>, key: string, fallback: boolean): boolean {
  const value = args[key]
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'boolean') throw new BadArgument(`${key} must be true or false`)
  return value
}

function optInt(args: Record<string, unknown>, key: string, fallback: number, min: number, max: number): number {
  const value = args[key]
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new BadArgument(`${key} must be a number`)
  }
  return Math.min(Math.max(Math.trunc(value), min), max)
}

function optStr(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') throw new BadArgument(`${key} must be a string`)
  return value
}

function record(args: Record<string, unknown>, key: string): Record<string, unknown> {
  const value = args[key]
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new BadArgument(`${key} must be an object`)
  }
  return value as Record<string, unknown>
}

export { BadArgument }

/* ------------------------------------------------------------- view model -- */

/**
 * One session, as a tool result — with the triage answer already worked out.
 *
 * The `attention` fields come from `attention.ts` and the raw status is kept
 * beside them. Deriving here rather than leaving it to the model is the whole
 * of `COPILOT-CAPABILITIES.md` item 7: the copilot is asked "which of these
 * needs me", and answering that from six status values requires knowing that
 * `waiting` means an empty prompt and not "waiting for you", which is a fact
 * about this codebase that no model can be expected to hold.
 */
function viewOf(context: ToolContext, meta: ReturnType<DeckSurface['listSessions']>[number]): SessionView {
  const live = context.surface.sessionStatus(meta.id)
  const status = statusOf(meta.exitCode, live?.status)
  const statusSince = live?.at ?? meta.createdAt
  /*
   * When the current state began — and null when that is genuinely unknown.
   *
   * A session with no live status has never been classified, so `createdAt` is
   * the honest answer: it has been exactly as quiet as it is old. An *exited*
   * session with no live status is a different thing. Its entry is written on
   * exit and deleted in the same turn (`onExit` in `src/main/index.ts`), so what
   * is missing is the end time, not the history — and `createdAt` there would
   * report the session's whole lifetime as "how long it has been finished".
   */
  const attentionSince = meta.exitCode !== null && !live ? null : statusSince
  return {
    id: meta.id,
    cwd: meta.cwd,
    title: meta.title,
    provider: meta.provider,
    status,
    statusSince,
    ...attentionOf({ status, statusSince: attentionSince, exitCode: meta.exitCode, now: context.now() }),
    createdAt: meta.createdAt,
    exitCode: meta.exitCode,
    resumed: meta.resumed === true,
    profileName: meta.profileName ?? null,
    startedByCopilot: context.startedByCopilot(meta.id),
  }
}

/**
 * Folders the copilot may name.
 *
 * The projects this desktop has open, plus the folder of any live session. Not
 * "any absolute path": the narrowest input a tool can take and still do its job
 * is the rule the rest of this codebase already follows — `registerSearchIpc`
 * is handed an `isAllowedRoot` for precisely this reason — and it means a
 * confused or steered copilot cannot use `git.status` or `alerts.list` to walk
 * the disk looking for repositories.
 *
 * It is not a confinement boundary and does not pretend to be one; the copilot
 * has `Bash` and `Read` from being a CLI session, held inside the folder
 * confinement that already exists. This is about not handing it a second,
 * wider door through the app's own IPC.
 */
function knownFolders(surface: DeckSurface): Set<string> {
  const folders = new Set<string>()
  for (const project of surface.listProjects()) folders.add(project.path)
  for (const session of surface.listSessions()) folders.add(session.cwd)
  return folders
}

function requireKnownFolder(surface: DeckSurface, path: string): string {
  if (knownFolders(surface).has(path)) return path
  throw new Refused(
    'not-permitted',
    `${path} is not a folder this app has open. Use projects.list to see the folders you can ask about.`,
  )
}

function requireSession(context: ToolContext, id: string): SessionView {
  const meta = context.surface.listSessions().find((session) => session.id === id)
  if (!meta) throw new BadArgument(`there is no live session with id ${id}`)
  return viewOf(context, meta)
}

/* ----------------------------------------------------------------- typing -- */

/**
 * What `sessions.send` is allowed to type.
 *
 * Printable text and nothing else. Every C0 control character is refused,
 * including the ones a terminal treats as commands rather than as text:
 *
 *  - `\x1b` starts an escape sequence. With it, "send some text" becomes
 *    "reposition the cursor, change the title, query the terminal, paste
 *    through bracketed-paste as if a human had".
 *  - `\x03` is Ctrl-C, `\x04` is Ctrl-D, `\x1a` is Ctrl-Z. Those are process
 *    control wearing the costume of a message.
 *  - `\r` and `\n` submit. Allowing them inside the text would let one call
 *    become several — type a prompt, submit it, type a shell command, submit
 *    that — which is the difference between sending a message and driving a
 *    keyboard.
 *
 * Submission is a separate boolean, and this function appends exactly one
 * carriage return when it is set. So one call is at most one submitted message,
 * and the shape of what was sent is legible in the action log rather than
 * hidden inside an escape sequence.
 *
 * This does not make `sessions.send` safe — a plain-text prompt to an agent
 * that has Bash is still a prompt injection, and that is why the tier depends
 * on whose session it is. It makes it *only* a prompt.
 */
export function sanitizeSendText(raw: string): string {
  if (raw.length === 0) throw new BadArgument('text must not be empty')
  if (raw.length > MAX_SEND_CHARS) {
    throw new BadArgument(`text must be ${MAX_SEND_CHARS} characters or fewer; got ${raw.length}`)
  }
  for (const char of raw) {
    const code = char.codePointAt(0) ?? 0
    // C0 (including CR and LF) and DEL. Everything above U+009F is allowed:
    // this has to carry ordinary prose in any language.
    if (code < 0x20 || code === 0x7f) {
      throw new BadArgument(
        'text may only contain printable characters — no newlines, tabs, escape sequences or control keys. ' +
          'Set submit: true to send the line rather than embedding a newline.',
      )
    }
    // C1 controls, which some terminals accept as single-byte escapes.
    if (code >= 0x80 && code <= 0x9f) {
      throw new BadArgument('text may not contain control characters')
    }
  }
  return raw
}

/**
 * What `log.note` is allowed to write.
 *
 * One line of printable text. The two refusals are for different reasons and
 * both are worth stating:
 *
 *  - **Length.** See {@link MAX_NOTE_CHARS}. Refused rather than truncated,
 *    because `scrubArgs` would silently cut it at two thousand characters and a
 *    log row that quietly says less than the caller meant is the wrong failure
 *    for the one file that exists to be believed.
 *  - **Control characters, including newlines.** `JSON.stringify` escapes them,
 *    so the file could not actually be torn — but the row's `detail` is rendered
 *    as a line in a list, and a note carrying `\n` can draw what looks like two
 *    rows, or indent itself to look like a different writer's entry. The whole
 *    point of routing the copilot's appends through a tool is that a row it
 *    wrote is distinguishable from a row the app wrote; a note that can forge
 *    layout gives back the half of that which matters to somebody reading.
 */
export function sanitizeNote(raw: string): string {
  const note = raw.trim()
  if (note.length === 0) throw new BadArgument('note must not be empty')
  if (note.length > MAX_NOTE_CHARS) {
    throw new BadArgument(
      `note must be ${MAX_NOTE_CHARS} characters or fewer; got ${note.length}. ` +
        'The action log is a list somebody scans — say the one line, not the story.',
    )
  }
  for (const char of note) {
    const code = char.codePointAt(0) ?? 0
    if (code < 0x20 || code === 0x7f || (code >= 0x80 && code <= 0x9f)) {
      throw new BadArgument('note must be a single line of printable text — no newlines or control characters')
    }
  }
  return note
}

/* ---------------------------------------------------------------- helpers -- */

function capText(text: string): { text: string; truncated: boolean } {
  if (text.length <= MAX_MESSAGE_CHARS) return { text, truncated: false }
  return { text: `${text.slice(0, MAX_MESSAGE_CHARS)}…`, truncated: true }
}

/**
 * Take the newest messages that fit inside the payload cap.
 *
 * Newest first while filling, then reversed, because a conversation cut from
 * the *front* is the useful half: the question being asked of this tool is
 * always about now.
 */
function fitTail(messages: TranscriptMessage[], limit: number): { kept: TranscriptMessage[]; dropped: number } {
  const kept: TranscriptMessage[] = []
  let chars = 0
  for (let i = messages.length - 1; i >= 0 && kept.length < limit; i -= 1) {
    const capped = capText(messages[i].text)
    const entry: TranscriptMessage = { ...messages[i], ...capped }
    if (chars + entry.text.length > MAX_TRANSCRIPT_CHARS && kept.length > 0) break
    chars += entry.text.length
    kept.push(entry)
  }
  kept.reverse()
  return { kept, dropped: messages.length - kept.length }
}

/**
 * Everything `settings.write` refuses, decided from the arguments alone.
 *
 * Pulled out so the same rules run twice: once in `precheck`, before any budget
 * is spent or dialog drawn, and once inside `run`. The first call is what makes
 * the rule a rule rather than a prompt; the second is what makes it true for
 * any caller, including one that arrives without going through the dispatcher.
 *
 * The whole patch is refused when one key in it is protected, and that is the
 * important half. Applying the permitted keys and dropping the rest would tell
 * the model no while doing half of what it asked, which is the worst available
 * outcome — nobody can then say what state the settings are in.
 */
function checkSettingsPatch(args: Record<string, unknown>): {
  scope: 'settings' | 'preferences'
  patch: Record<string, unknown>
  keys: string[]
} {
  const scope = str(args, 'scope')
  if (scope !== 'settings' && scope !== 'preferences') {
    throw new BadArgument('scope must be "settings" or "preferences"')
  }
  const patch = record(args, 'patch')
  const keys = Object.keys(patch)
  if (keys.length === 0) throw new BadArgument('patch must name at least one key')

  if (scope === 'settings') {
    const blocked = keys.filter((key) => isProtectedSetting(key))
    if (blocked.length > 0) {
      throw new Refused(
        'not-permitted',
        `these settings cannot be changed through the copilot: ${blocked.join(', ')}. ` +
          'Ask the person to change them in Settings if they want them changed.',
      )
    }
    return { scope, patch, keys }
  }

  const unknown = keys.filter((key) => !WRITABLE_PREFERENCES.includes(key))
  if (unknown.length > 0) {
    throw new Refused(
      'not-permitted',
      `preferences has no writable key called ${unknown.join(', ')}. ` +
        `Writable preferences are: ${WRITABLE_PREFERENCES.join(', ')}.`,
    )
  }
  return { scope, patch, keys }
}

/**
 * The whole of `settings.write`'s pre-flight, in the order the order matters in.
 *
 * 1. **The rules no answer unlocks.** A protected key is refused before a person
 *    is ever shown a dialog about it — `control.ts` explains at length why a
 *    rule put to somebody first is not a rule.
 * 2. **The schema.** A value outside its enum, a key that names no setting, a
 *    number that is not a number: all refused here, *before* the dialog, because
 *    a person cannot meaningfully consent to a change that is going to fail. The
 *    OpenClaw case this comes from is `tools.profile: "none"` — one value
 *    outside one enum, which took down their entire gateway rather than the one
 *    agent it was set on, and needed a different app on a different machine to
 *    hand-edit the JSON back.
 * 3. **The snapshot.** Only once the patch is known to be writable, and still
 *    before the dialog, because the way back has to exist before the change
 *    does. A person who is about to be asked "may the copilot change this" is
 *    being asked to trust that they can undo it.
 *
 * Taking the snapshot for a write that is then declined is deliberate and
 * harmless: what it captures is the current, unmodified state, so the worst case
 * is a last-good file that is merely accurate. Taking it *after* approval would
 * mean the one write nobody expected — the one they clicked through — is the one
 * with no copy behind it.
 *
 * Returns what the confirmation and the log should say. Throws `Refused` for a
 * rule, `BadArgument` for a patch the schema will not take, and a plain `Error`
 * when the snapshot cannot be written — that last one stops the call, because a
 * settings write with no way back is the state this exists to prevent.
 */
function prepareSettingsWrite(
  args: Record<string, unknown>,
  context: ToolContext,
): { scope: 'settings' | 'preferences'; patch: Record<string, unknown>; keys: string[]; snapshot: string } {
  const { scope, patch, keys } = checkSettingsPatch(args)

  const checked = checkSettingsValues(scope, patch)
  if (checked.problems.length > 0) {
    throw new BadArgument(
      `that patch would not be accepted, so it was not put to the person: ${problemSentence(checked.problems)}`,
    )
  }

  let snapshot: { path: string; at: number }
  try {
    snapshot = context.surface.snapshotSettings()
  } catch (error) {
    throw new Error(
      'could not save a copy of the current settings first, so nothing was changed: ' +
        (error instanceof Error ? error.message : String(error)),
    )
  }

  return { scope, patch, keys, snapshot: snapshot.path }
}

/* ------------------------------------------------------------- the tools -- */

export function buildCatalogue(): ToolSpec[] {
  const tools: ToolSpec[] = [
    /* ---------------------------------------------------------- sessions -- */
    {
      id: 'sessions.list',
      wire: 'sessions_list',
      tier: 'read',
      title: 'List sessions',
      description:
        'Every session running in this app right now, ordered by who needs a person first. Read `attention` ' +
        'before anything else: "blocked" is stopped until somebody answers a question, "running" is working, ' +
        '"quiet" is neither (an idle prompt — usually nothing to do), "done" has finished or exited. ' +
        '`attentionReason` says what was observed and `attentionForMs` how long it has been that way — null ' +
        'means nobody recorded when it started, which is normal for a session that has already exited. The raw ' +
        '`status` is kept too, but do not reinterpret it: "waiting" means an empty prompt is on screen, not ' +
        'that anyone is waiting for you. Start here for any question about what else is going on.',
      inputSchema: {
        type: 'object',
        properties: {
          cwd: { type: 'string', description: 'Only sessions in this folder. Omit for all of them.' },
        },
        additionalProperties: false,
      },
      summary: () => 'List the running sessions',
      run: async (args, context) => {
        const cwd = optStr(args, 'cwd')
        const sessions = context.surface
          .listSessions()
          .filter((meta) => cwd === null || meta.cwd === cwd)
          .map((meta) => viewOf(context, meta))
          // Sorted here rather than left to the caller. A model reading a list
          // in creation order has to hold all of it to find the blocked one,
          // and the whole point of the derived field is that the answer to
          // "who needs me" is the first row.
          .sort(byAttention)
        const needsSomebody = sessions.filter((session) => session.attention === 'blocked').length
        return {
          value: { sessions, count: sessions.length, blocked: needsSomebody },
          summary: { count: sessions.length, blocked: needsSomebody },
        }
      },
    },

    {
      id: 'sessions.get',
      wire: 'sessions_get',
      tier: 'read',
      title: 'Get one session',
      description:
        'One session in detail, including whether it has a readable transcript and how large that transcript is. ' +
        'Use sessions.transcript to read it.',
      inputSchema: {
        type: 'object',
        properties: { sessionId: { type: 'string' } },
        required: ['sessionId'],
        additionalProperties: false,
      },
      summary: (args) => `Read session ${optStr(args, 'sessionId') ?? '?'}`,
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        const transcriptPath = await context.surface.newestTranscript(session.cwd)
        const transcriptBytes = transcriptPath ? await context.surface.transcriptBytes(transcriptPath) : 0
        return {
          value: { session, transcriptPath, transcriptBytes },
          summary: { sessionId: session.id, status: session.status },
        }
      },
    },

    {
      id: 'sessions.transcript',
      wire: 'sessions_transcript',
      tier: 'read',
      title: 'Read a session transcript',
      description:
        'The recent conversation in a session: what was asked and what the agent said, without tool calls or ' +
        'usage records. Transcripts reach hundreds of megabytes, so this always reads a window from the END of ' +
        'the file and says so — check `partial` and `fromByte` in the result. Raise `windowBytes` to look ' +
        'further back. For a session running an agent that keeps no transcript (a plain shell), this returns ' +
        'the terminal screen instead and sets `source` to "terminal".',
      inputSchema: {
        type: 'object',
        properties: {
          sessionId: { type: 'string' },
          limit: {
            type: 'integer',
            description: `How many messages to return, newest last. Default ${DEFAULT_TRANSCRIPT_LIMIT}, max ${MAX_TRANSCRIPT_LIMIT}.`,
          },
          windowBytes: {
            type: 'integer',
            description: `How many bytes from the end of the transcript to parse. Default ${DEFAULT_WINDOW_BYTES}, max ${MAX_WINDOW_BYTES}.`,
          },
        },
        required: ['sessionId'],
        additionalProperties: false,
      },
      summary: (args) => `Read the transcript of session ${optStr(args, 'sessionId') ?? '?'}`,
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        const limit = optInt(args, 'limit', DEFAULT_TRANSCRIPT_LIMIT, 1, MAX_TRANSCRIPT_LIMIT)
        const windowBytes = optInt(args, 'windowBytes', DEFAULT_WINDOW_BYTES, 4096, MAX_WINDOW_BYTES)

        const path = await context.surface.newestTranscript(session.cwd)
        if (path === null) {
          /*
           * No transcript. That is not a failure — a plain shell writes none,
           * and neither does an agent this app cannot redirect — so the screen
           * is the honest answer to "what is happening in there". It is labelled
           * `terminal` rather than dressed up as a conversation, because a
           * rendered screen is not a transcript and a caller that treats it as
           * one will read a progress bar as a sentence.
           */
          const screen = (await context.surface.sessionScreen(session.id)) ?? ''
          const text = screen.length > MAX_SCREEN_CHARS ? screen.slice(-MAX_SCREEN_CHARS) : screen
          return {
            value: {
              sessionId: session.id,
              cwd: session.cwd,
              source: screen === '' ? 'none' : 'terminal',
              transcriptPath: null,
              partial: screen.length > text.length,
              messages: [],
              screen: text,
            },
            summary: { source: screen === '' ? 'none' : 'terminal', chars: text.length },
          }
        }

        const fileBytes = await context.surface.transcriptBytes(path)
        const fromByte = Math.max(0, fileBytes - windowBytes)
        const parsed = await context.surface.readTranscriptFrom(path, fromByte)
        const { kept, dropped } = fitTail(parsed, limit)

        return {
          value: {
            sessionId: session.id,
            cwd: session.cwd,
            source: 'chat',
            transcriptPath: path,
            fileBytes,
            fromByte,
            /*
             * True when this is a tail rather than the whole conversation —
             * either because the window started mid-file, or because messages
             * inside the window did not fit the payload cap. Reported rather
             * than implied: a caller that summarises a partial transcript as if
             * it were the whole one will confidently describe a session's
             * "start" that it never read.
             */
            partial: fromByte > 0 || dropped > 0,
            inWindow: parsed.length,
            returned: kept.length,
            messages: kept,
          },
          summary: {
            source: 'chat',
            fileBytes,
            fromByte,
            returned: kept.length,
            inWindow: parsed.length,
          },
        }
      },
    },

    {
      id: 'sessions.start',
      wire: 'sessions_start',
      tier: 'act',
      title: 'Start a session',
      description:
        'Start a new agent session in one of the folders this app has open. It appears in the sidebar like any ' +
        'other session and can be stopped. This spends money: an agent session bills for everything it does. ' +
        'Use projects.list to see which folders you may name.',
      inputSchema: {
        type: 'object',
        properties: {
          cwd: { type: 'string', description: 'An open project folder. See projects.list.' },
          provider: { type: 'string', enum: [...PROVIDERS] },
          resume: { type: 'boolean', description: 'Continue the most recent conversation in that folder.' },
        },
        required: ['cwd'],
        additionalProperties: false,
      },
      summary: (args) =>
        `Start a ${optStr(args, 'provider') ?? 'default'} session in ${optStr(args, 'cwd') ?? '?'}`,
      // Ahead of the budget: a call that was never going to be allowed should
      // not consume one of the five sessions the copilot may start in ten
      // minutes.
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'cwd'))
      },
      run: async (args, context) => {
        const cwd = requireKnownFolder(context.surface, str(args, 'cwd'))
        const provider = optStr(args, 'provider')
        if (provider !== null && !PROVIDERS.includes(provider as ProviderId)) {
          throw new BadArgument(`provider must be one of ${PROVIDERS.join(', ')}`)
        }
        const input: CreateSessionInput = {
          cwd,
          cols: START_COLS,
          rows: START_ROWS,
          resume: optBool(args, 'resume', false),
          ...(provider === null ? {} : { provider: provider as ProviderId }),
          /*
           * Who wanted this session, written onto the session itself.
           *
           * It is a *label* and never a permission — `session-origin.test.ts`
           * pins that a copilot-started session runs in the same folder, under
           * the same profile and the same confinement as one the person starts.
           * What it buys is that the sidebar can group these under their own
           * heading instead of dropping them into the middle of somebody's own
           * work with nothing saying where they came from. A tab you did not
           * open and cannot account for is the thing this app must not produce.
           *
           * `originRunId` is the id of the action-log row this very call is
           * writing, so the two link both ways: the sidebar row can open the
           * turn that started it, and the Activity row can open the session it
           * started. Pairing them by timestamp instead would be a guess, and a
           * wrong one for any two starts inside the same second.
           */
          origin: 'copilot',
          originRunId: context.callId,
        }
        const meta = await context.surface.startSession(input)
        context.noteStarted(meta.id)
        return {
          value: { session: viewOf(context, meta) },
          summary: { sessionId: meta.id, cwd: meta.cwd, provider: meta.provider },
        }
      },
    },

    {
      id: 'sessions.send',
      wire: 'sessions_send',
      tier: 'act',
      title: 'Send text to a session',
      description:
        'Type a line into a running session, as if a person had typed it. Printable text only — no newlines, ' +
        'tabs or control keys — and `submit` decides whether it is sent. Sending into a session YOU started is ' +
        'an ordinary action. Sending into a session the person started needs their confirmation each time, ' +
        'because that session is theirs and they may be mid-thought in it.',
      inputSchema: {
        type: 'object',
        properties: {
          sessionId: { type: 'string' },
          text: { type: 'string', description: `Printable characters only, ${MAX_SEND_CHARS} max.` },
          submit: { type: 'boolean', description: 'Press return afterwards. Default true.' },
        },
        required: ['sessionId', 'text'],
        additionalProperties: false,
      },
      escalate: (args, context) => {
        const id = optStr(args, 'sessionId')
        return id !== null && context.startedByCopilot(id) ? 'act' : 'alter'
      },
      // Before the gate, so a request full of escape sequences is refused
      // rather than shown to somebody as a dialog quoting text that is about to
      // be rejected anyway.
      precheck: (args) => {
        sanitizeSendText(str(args, 'text'))
      },
      summary: (args) => {
        const text = optStr(args, 'text') ?? ''
        const shown = text.length > 120 ? `${text.slice(0, 120)}…` : text
        return `Type into session ${optStr(args, 'sessionId') ?? '?'}: “${shown}”`
      },
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        const text = sanitizeSendText(str(args, 'text'))
        const submit = optBool(args, 'submit', true)
        if (session.exitCode !== null) {
          throw new BadArgument(`session ${session.id} has already exited; there is nothing to type into`)
        }
        // The carriage return is appended here rather than accepted in `text`,
        // so one call is at most one submitted line. See `sanitizeSendText`.
        context.surface.writeToSession(session.id, submit ? `${text}\r` : text)
        return {
          value: { sessionId: session.id, sent: text.length, submitted: submit },
          summary: { sessionId: session.id, chars: text.length, submitted: submit, text },
        }
      },
    },

    {
      id: 'sessions.stop',
      wire: 'sessions_stop',
      tier: 'act',
      title: 'Stop a session',
      description:
        'Kill a running session. Stopping one YOU started is an ordinary action. Stopping one the person ' +
        'started needs their confirmation, because an agent killed mid-edit loses whatever it was holding.',
      inputSchema: {
        type: 'object',
        properties: { sessionId: { type: 'string' } },
        required: ['sessionId'],
        additionalProperties: false,
      },
      escalate: (args, context) => {
        const id = optStr(args, 'sessionId')
        return id !== null && context.startedByCopilot(id) ? 'act' : 'alter'
      },
      summary: (args) => `Stop session ${optStr(args, 'sessionId') ?? '?'}`,
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        context.surface.killSession(session.id)
        return {
          value: { sessionId: session.id, stopped: true },
          summary: { sessionId: session.id, cwd: session.cwd },
        }
      },
    },

    /* ---------------------------------------------------------- projects -- */
    {
      id: 'projects.list',
      wire: 'projects_list',
      tier: 'read',
      title: 'List projects',
      description:
        'The folders this app has open, newest first. These are the only folders you may name in ' +
        'sessions.start, git.status and alerts.list.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'List the open projects',
      run: async (_args, context) => {
        const projects = context.surface.listProjects()
        return { value: { projects, count: projects.length }, summary: { count: projects.length } }
      },
    },

    /* --------------------------------------------------------------- git -- */
    {
      id: 'git.status',
      wire: 'git_status',
      tier: 'read',
      title: 'Git status',
      description:
        'Working-tree status for an open project: branch, ahead/behind, and the staged, unstaged, untracked ' +
        'and conflicted files. Answers "is there uncommitted work in there" without shelling out.',
      inputSchema: {
        type: 'object',
        properties: { cwd: { type: 'string' } },
        required: ['cwd'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'cwd'))
      },
      summary: (args) => `Read git status for ${optStr(args, 'cwd') ?? '?'}`,
      run: async (args, context) => {
        const cwd = requireKnownFolder(context.surface, str(args, 'cwd'))
        const status = await context.surface.gitStatus(cwd)
        const repo = typeof status === 'object' && status !== null && (status as { repo?: unknown }).repo === true
        return { value: status, summary: { cwd, repo } }
      },
    },

    /* ------------------------------------------------------------ alerts -- */
    {
      id: 'alerts.list',
      wire: 'alerts_list',
      tier: 'read',
      title: 'List alerts',
      description:
        'What this app thinks is wrong in a project right now: a session blocked waiting for input, a context ' +
        'window filling up, an unusually expensive session, a working tree left dirty. This reads transcripts ' +
        'and runs git, so it is the slowest read here — a few seconds on a busy project.',
      inputSchema: {
        type: 'object',
        properties: { projectPath: { type: 'string' } },
        required: ['projectPath'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'projectPath'))
      },
      summary: (args) => `Read alerts for ${optStr(args, 'projectPath') ?? '?'}`,
      run: async (args, context) => {
        const path = requireKnownFolder(context.surface, str(args, 'projectPath'))
        const report = await context.surface.alerts(path)
        const alerts = (report as { alerts?: unknown[] } | null)?.alerts
        return {
          value: report,
          summary: { projectPath: path, alerts: Array.isArray(alerts) ? alerts.length : 0 },
        }
      },
    },

    /* ---------------------------------------------------------- settings -- */
    {
      id: 'settings.read',
      wire: 'settings_read',
      tier: 'read',
      title: 'Read settings',
      description:
        "This app's settings and preferences, plus the list of setting keys that cannot be changed through " +
        'these tools at all. Read this before proposing a change so you do not offer one that will be refused.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Read the app settings',
      run: async (_args, context) => {
        const { settings, preferences } = context.surface.readSettings()
        return {
          value: {
            settings,
            preferences,
            writablePreferences: WRITABLE_PREFERENCES,
            protectedSettingKeys: PROTECTED_SETTING_KEYS,
            protectedSettingPrefixes: PROTECTED_SETTING_PREFIXES,
          },
          summary: { keys: Object.keys(settings).length },
        }
      },
    },

    {
      id: 'settings.write',
      wire: 'settings_write',
      tier: 'alter',
      title: 'Change a setting',
      description:
        'Change app settings or preferences. The patch is checked against the settings schema and a copy of ' +
        'the current settings is saved BEFORE the person is asked, so anything they confirm is a change that ' +
        'will actually land and can be put back; the result names the file the copy went to, and it is worth ' +
        'telling them. An unknown key or a value outside its allowed range is refused without asking anyone. ' +
        'Some keys are refused outright and no confirmation will be offered for them: anything under remote., ' +
        'copilot., security. or confine., plus browser.persistSession and advanced.debugMode. Those decide who ' +
        'can reach this machine and what gets recorded, and they are not an assistant\'s to change. Call ' +
        'settings.read for the current list.',
      inputSchema: {
        type: 'object',
        properties: {
          scope: {
            type: 'string',
            enum: ['settings', 'preferences'],
            description:
              '"settings" is the settings window (dotted keys like appearance.theme). "preferences" is the ' +
              `small set the app itself reads: ${WRITABLE_PREFERENCES.join(', ')}.`,
          },
          patch: {
            type: 'object',
            description: 'Keys to change. A key set to null goes back to its default (settings scope only).',
          },
        },
        required: ['scope', 'patch'],
        additionalProperties: false,
      },
      /*
       * The sentence the person reads, naming the value that will actually be
       * written rather than the one that was asked for.
       *
       * The two differ whenever the schema clamps — `coerce` snaps a number into
       * its declared range instead of rejecting it, deliberately — and a dialog
       * that quoted the request would be asking somebody to approve a change
       * that is not the change. It runs the same check `precheck` does, so the
       * dialog and the outcome are computed from one function; when the patch is
       * invalid the sentence falls back to the bare key list, and it is never
       * shown anyway because `precheck` refuses first.
       */
      summary: (args) => {
        const scope = optStr(args, 'scope') ?? '?'
        const patch = args.patch
        const keys =
          typeof patch === 'object' && patch !== null && !Array.isArray(patch)
            ? Object.keys(patch as Record<string, unknown>)
            : []
        if (keys.length === 0) return `Change ${scope}: (nothing)`
        if (scope !== 'settings' && scope !== 'preferences') return `Change ${scope}: ${keys.join(', ')}`

        const checked = checkSettingsValues(scope, patch as Record<string, unknown>)
        if (checked.problems.length > 0) return `Change ${scope}: ${keys.join(', ')}`

        const parts = keys.map((key) => {
          if (!(key in checked.effective)) return `${key} back to its default`
          const value = JSON.stringify(checked.effective[key])
          return checked.adjusted.includes(key)
            ? `${key} to ${value} (asked for ${JSON.stringify((patch as Record<string, unknown>)[key])})`
            : `${key} to ${value}`
        })
        return `Change ${scope}: ${parts.join(', ')}`
      },
      precheck: (args, context) => {
        prepareSettingsWrite(args, context)
      },
      run: async (args, context) => {
        /*
         * The whole pre-flight again, cheaply, rather than trusted to have been
         * prechecked. The gate is the caller's discipline; the refusal is this
         * tool's, and a handler that could be reached with a protected key — or
         * with no snapshot behind it — by a caller that skipped a step is a
         * handler with a hole in it.
         *
         * The second snapshot overwrites the first with the same content: the
         * settings have not changed between the two calls, because the only
         * thing that happened in between was a person answering a dialog.
         */
        const { scope, patch, keys, snapshot } = prepareSettingsWrite(args, context)
        if (scope === 'settings') {
          const settings = context.surface.writeSettings(patch)
          return { value: { scope, settings, snapshot }, summary: { scope, keys, snapshot } }
        }
        const preferences = context.surface.writePreferences(patch)
        return { value: { scope, preferences, snapshot }, summary: { scope, keys, snapshot } }
      },
    },

    /* --------------------------------------------------------------- log -- */
    {
      id: 'log.note',
      wire: 'log_note',
      tier: 'act',
      title: 'Write a line in the action log',
      description:
        'Record one line in the action log the person reads to see what you have been doing — something you ' +
        'noticed, something you decided, something worth being able to find later. This is the only way you can ' +
        'put a row in that file: the log itself is outside your folder and the operating system refuses your ' +
        'writes to it, because a record you could compose is not a record anybody can check you against. Keep ' +
        `it to one line of ${MAX_NOTE_CHARS} characters or fewer. Everything else you do is already logged ` +
        'without you asking — every call, including the refused ones — so do not narrate your own tool calls ' +
        'here.',
      inputSchema: {
        type: 'object',
        properties: {
          note: {
            type: 'string',
            description: `The line to record. One line, ${MAX_NOTE_CHARS} characters or fewer.`,
          },
          sessionId: {
            type: 'string',
            description: 'The session this is about, when it is about one. Omit otherwise.',
          },
        },
        required: ['note'],
        additionalProperties: false,
      },
      /*
       * The sentence a person reads *is* the note.
       *
       * `control.ts` puts `summary` in the row's `detail` for every call at
       * every tier, which is the field an Activity pane renders — so quoting
       * the note here is what makes the row say the thing rather than say that
       * a thing was said. It is quoted rather than interpolated bare so a note
       * that happens to read like a sentence of the app's own cannot be
       * mistaken for one.
       */
      summary: (args) => `Noted: "${sanitizeNote(str(args, 'note'))}"`,
      precheck: (args) => {
        // Ahead of the budget and the gate, so a note that is too long or
        // carries a newline costs nothing and comes back as something the model
        // can fix rather than as a spent call.
        sanitizeNote(str(args, 'note'))
      },
      /*
       * There is nothing to do here, and that is the design rather than a stub.
       *
       * The append this tool exists for is the dispatcher's own row. Every call
       * through `DeckControl.call` writes exactly one line to the action log,
       * inside a `finally`, carrying the time, the note, the tier, who called
       * and how it ended — so a second write from this handler would be the
       * same fact recorded twice, in two shapes, by two writers with two
       * rotation policies. What the tool changes is not *whether* a line is
       * written but *what* the line says, and that is `summary` above.
       *
       * The consequence worth stating: a row from this tool is
       * `tool.log.note`, with a `tool`, a `tier` and a `caller`, and a row the
       * app wrote is `session.started` with none of them. The copilot can add
       * to the record and cannot impersonate the app inside it, which is the
       * property the file lost when the copilot could write it directly.
       */
      run: async (args) => {
        const note = sanitizeNote(str(args, 'note'))
        return {
          value: {
            recorded: true,
            note,
            // Said back so the model does not go looking for the file, and does
            // not tell the person it wrote one itself.
            where: 'the action log; this app wrote the row, attributed to you',
          },
          summary: { chars: note.length },
        }
      },
    },
  ]

  return tools
}
