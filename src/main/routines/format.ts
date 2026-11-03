/**
 * What a routine *is*, on disk and in memory.
 *
 * A routine is three things and no more — a trigger, a prompt, and the folder
 * it runs in — and this module is the whole of the reading and writing of that.
 * Nothing here subscribes to anything, spawns anything or touches a clock; the
 * engine does that, and it does it against values this module produced.
 *
 * ## Why this is not JSON
 *
 * `COPILOT-DESIGN.md` asks for "one file per routine, readable and editable by
 * hand", and the load-bearing field is the *prompt*, which is prose and is
 * frequently several paragraphs of it. In JSON that prose becomes one string
 * with `\n` in it — unreadable in an editor, and impossible to edit without
 * counting escapes. Every configuration format that has ever had to hold a
 * paragraph solved it the same way: a small header of `key: value` lines, a
 * separator, and then the text verbatim. That is what this is, and the file is
 * given a `.md` extension because that is what it is — a heading, some
 * metadata, a horizontal rule and a body — so every editor on the machine
 * already highlights it and the app never has to ship a viewer for its own
 * private format.
 *
 *     # Nightly sweep
 *
 *     when: schedule 02:30
 *     in: /Users/asad/Projects/terminaldeck
 *     enabled: yes
 *
 *     ---
 *
 *     Run the tests. If anything fails, open a session and start fixing it.
 *
 * ## Why parsing never throws
 *
 * These files are hand-edited by design, so a malformed one is an expected
 * state rather than a bug. A parse that threw would let one mistyped line take
 * the whole engine down at boot, and the failure a person would see is *every*
 * routine silently not running. Every entry point here returns a result with
 * the problems named in sentences, and the engine keeps the routine listed and
 * disarmed with those sentences attached — a routine that is visibly broken is
 * worth ten that are invisibly missing.
 *
 * ## Why unknown keys are kept
 *
 * `settings-extra.ts` carries forward top-level keys it did not write, for the
 * reason that applies here too: a newer build will add a key, and an older
 * build that rewrote the file — which `routines.create` and the settings pane
 * both do — would otherwise delete it. Unknown keys survive a round trip and
 * are reported as warnings so a person can be told their build does not
 * understand one.
 */

import type { AlertSeverity } from '../alerts'
import { parseSchedule, serializeSchedule, type Schedule } from './schedule'

/* ------------------------------------------------------------------ limits */

/**
 * A routine is a saved instruction, not a document store.
 *
 * Both caps are enforced on the way in *and* on the way out, because the two
 * writers are not the same kind of caller: a person editing the file is bounded
 * by patience, and the copilot writing one through `routines.create` is bounded
 * by nothing at all. A prompt of a megabyte would be re-sent to a model on
 * every fire, which is the cost problem arriving through the storage layer.
 */
export const MAX_PROMPT_BYTES = 8 * 1024
export const MAX_NAME_LENGTH = 80
/** Anything larger is not a routine file, whatever its extension says. */
export const MAX_FILE_BYTES = 64 * 1024

/**
 * Ceilings no routine file may raise, however it is edited.
 *
 * These are the answer to "who sets the cost ceiling": the *file* chooses
 * within a range, and the range is here, in code that a hand-edit cannot reach.
 * A routine claiming `max-runs-per-hour: 100000` is clamped to this and told
 * so, rather than being honoured or being refused outright — refusing would
 * disarm the routine, and a routine that stopped working because its budget was
 * too generous is a confusing way to protect somebody from spending.
 */
export const HARD_MAX_RUNS_PER_HOUR = 60
export const HARD_MAX_RUNS_PER_DAY = 500

/** What a routine gets when its file says nothing. Deliberately modest. */
export const DEFAULT_MAX_RUNS_PER_HOUR = 6
export const DEFAULT_MAX_RUNS_PER_DAY = 24
/**
 * The smallest gap between two runs of one routine.
 *
 * Not a rate limit — {@link DEFAULT_MAX_RUNS_PER_HOUR} is that. This is the
 * anti-flap: a git watch reports three changes as a branch checkout lands, and
 * a routine on `git-change` should run once for the checkout rather than three
 * times for its parts.
 */
export const DEFAULT_QUIET_FOR_MS = 30_000

/* ------------------------------------------------------------------- types */

export type TriggerKind =
  | 'session-finished'
  | 'session-failed'
  | 'session-idle'
  | 'alert'
  | 'git-change'
  | 'file-change'
  | 'schedule'
  | 'manual'

/**
 * One reason a routine runs.
 *
 * Discriminated rather than a kind plus a loose argument string, so that the
 * engine cannot read `afterMs` off a trigger that has no such thing — the
 * subscription code branches on `kind` once and is handed exactly the fields
 * that kind carries.
 */
export type Trigger =
  | { kind: 'session-finished' }
  | { kind: 'session-failed' }
  /** A session in this routine's folder has sat idle this long. */
  | { kind: 'session-idle'; afterMs: number }
  /**
   * An alert appeared for this routine's folder. `severity` and `alertKind` are
   * both optional filters; null on both means any alert at all.
   */
  | { kind: 'alert'; severity: AlertSeverity | null; alertKind: string | null }
  | { kind: 'git-change' }
  /** A file changed under the folder. `glob` is relative to it. */
  | { kind: 'file-change'; glob: string }
  | { kind: 'schedule'; schedule: Schedule }
  | { kind: 'manual' }

/** What to do when a trigger fires while the previous run is still going. */
export type OverlapPolicy = 'queue' | 'skip' | 'cancel'

export interface Routine {
  /**
   * Filename without the extension, and the routine's identity everywhere.
   *
   * Deliberately the same thing as the filename rather than a uuid inside the
   * file: renaming the file renames the routine, which is what somebody
   * hand-editing a folder of them expects, and it means a person can say
   * "delete `nightly-sweep`" and mean the file they are looking at.
   */
  id: string
  /** Display name, from the `# ` heading. Falls back to the id. */
  name: string
  /** At least one. Any of them firing runs the routine. */
  triggers: Trigger[]
  /** Absolute path of the folder this routine runs in and watches. */
  folder: string
  prompt: string
  enabled: boolean
  overlap: OverlapPolicy
  maxRunsPerHour: number
  maxRunsPerDay: number
  quietForMs: number
  /**
   * How long this routine may be silent before it should be treated as
   * suspicious. Null means no expectation, which is the honest default: most
   * triggers have no natural rhythm and inventing one would produce a warning
   * on every routine that simply had a quiet week.
   */
  expectEveryMs: number | null
  /** Keys this build does not understand, kept so a rewrite does not lose them. */
  unknown: Record<string, string[]>
}

export type ParseResult =
  | { ok: true; routine: Routine; warnings: string[] }
  | { ok: false; problems: string[] }

/* --------------------------------------------------------------- durations */

const DURATION_UNITS: Record<string, number> = {
  s: 1000,
  m: 60_000,
  h: 3_600_000,
  d: 86_400_000,
}

/**
 * `15m`, `2h`, `30s`, `1d` — and nothing else.
 *
 * Bare numbers are rejected on purpose. "idle 15" is ambiguous between seconds
 * and minutes, and the two differ by a factor of sixty in how often a routine
 * spends money.
 */
export function parseDuration(text: string): number | null {
  const match = /^(\d{1,6})(s|m|h|d)$/.exec(text.trim())
  if (!match) return null
  const value = Number(match[1])
  if (value <= 0) return null
  return value * DURATION_UNITS[match[2]]
}

export function serializeDuration(ms: number): string {
  for (const unit of ['d', 'h', 'm', 's'] as const) {
    const size = DURATION_UNITS[unit]
    if (ms >= size && ms % size === 0) return `${ms / size}${unit}`
  }
  // Not representable in whole units — round to the nearest second rather than
  // writing a value this module could not read back.
  return `${Math.max(1, Math.round(ms / 1000))}s`
}

/* ------------------------------------------------------------------- slugs */

/**
 * A routine's id, and therefore its filename.
 *
 * Aggressively narrow — lowercase letters, digits and hyphens — because this
 * string is concatenated into a path. Everything else is a separator, a device
 * name on Windows, or a `..` waiting to happen, and the whole class goes away
 * if the only characters that survive are ones with no meaning to any
 * filesystem. `routineFileName` is the only place that builds the path and it
 * refuses anything this function would not have produced.
 */
export function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 64)
    .replace(/-+$/g, '')
}

/**
 * Names Windows will not let anything create a file called, extension or not.
 *
 * This app ships on Windows, and `con.md` cannot be written there — the call
 * fails with a permission error that says nothing about device names. A routine
 * called "Continuous" slugs to `con`… only if it were truncated, but "Con" is a
 * perfectly ordinary thing for somebody to name a routine, and the failure it
 * produces is one nobody would ever guess at. Refused on every platform rather
 * than on Windows alone, so a routines folder that works here also works when
 * it is copied to a PC.
 */
const RESERVED_NAMES = new Set([
  'con',
  'prn',
  'aux',
  'nul',
  ...Array.from({ length: 9 }, (_unused, index) => `com${index + 1}`),
  ...Array.from({ length: 9 }, (_unused, index) => `lpt${index + 1}`),
])

/** Is this a string `slugify` could have produced, and therefore safe as a path? */
export function isValidId(id: string): boolean {
  if (RESERVED_NAMES.has(id)) return false
  return /^[a-z0-9][a-z0-9-]{0,63}$/.test(id) && !id.endsWith('-')
}

/* --------------------------------------------------------------- triggers */

const SEVERITIES: readonly string[] = ['critical', 'warning', 'info']

/**
 * One `when:` line.
 *
 * The grammar is one hyphenated keyword and an optional argument, which is
 * enough to be read aloud and small enough that the error message can list
 * every accepted form when somebody gets it wrong. That listing matters more
 * than elegance here: this is the line people will mistype.
 */
export function parseTrigger(text: string): { trigger: Trigger } | { problem: string } {
  const trimmed = text.trim()
  const space = trimmed.indexOf(' ')
  const keyword = (space === -1 ? trimmed : trimmed.slice(0, space)).toLowerCase()
  const argument = space === -1 ? '' : trimmed.slice(space + 1).trim()

  switch (keyword) {
    case 'session-finished':
      return { trigger: { kind: 'session-finished' } }
    case 'session-failed':
      return { trigger: { kind: 'session-failed' } }
    case 'session-idle': {
      const afterMs = parseDuration(argument)
      if (afterMs === null) {
        return { problem: `\`when: session-idle\` needs a duration, like \`session-idle 15m\`` }
      }
      return { trigger: { kind: 'session-idle', afterMs } }
    }
    case 'alert': {
      if (argument === '') return { trigger: { kind: 'alert', severity: null, alertKind: null } }
      if (SEVERITIES.includes(argument)) {
        return { trigger: { kind: 'alert', severity: argument as AlertSeverity, alertKind: null } }
      }
      if (!/^[a-z][a-z-]{0,40}$/.test(argument)) {
        return { problem: `\`when: alert ${argument}\` is neither a severity nor an alert kind` }
      }
      return { trigger: { kind: 'alert', severity: null, alertKind: argument } }
    }
    case 'git-change':
      return { trigger: { kind: 'git-change' } }
    case 'file-change': {
      const glob = argument === '' ? '**/*' : argument
      if (glob.includes('\0') || glob.length > 200) {
        return { problem: '`when: file-change` was given a pattern that is not a pattern' }
      }
      return { trigger: { kind: 'file-change', glob } }
    }
    case 'schedule': {
      const schedule = parseSchedule(argument)
      if ('problem' in schedule) return { problem: schedule.problem }
      return { trigger: { kind: 'schedule', schedule: schedule.schedule } }
    }
    case 'manual':
      return { trigger: { kind: 'manual' } }
    default:
      return {
        problem:
          `\`when: ${trimmed}\` is not a trigger this build knows. The ones it does: ` +
          'session-finished, session-failed, session-idle 15m, alert, git-change, ' +
          'file-change src/**, schedule 09:00, manual.',
      }
  }
}

export function serializeTrigger(trigger: Trigger): string {
  switch (trigger.kind) {
    case 'session-idle':
      return `session-idle ${serializeDuration(trigger.afterMs)}`
    case 'alert':
      return `alert${trigger.severity ? ` ${trigger.severity}` : trigger.alertKind ? ` ${trigger.alertKind}` : ''}`
    case 'file-change':
      return `file-change ${trigger.glob}`
    case 'schedule':
      return `schedule ${serializeSchedule(trigger.schedule)}`
    default:
      return trigger.kind
  }
}

/* ---------------------------------------------------------------- parsing */

const KNOWN_KEYS = new Set([
  'when',
  'in',
  'enabled',
  'overlap',
  'max-runs-per-hour',
  'max-runs-per-day',
  'quiet-for',
  'expect-every',
])

const OVERLAP_POLICIES: readonly string[] = ['queue', 'skip', 'cancel']

function parseBoolean(value: string): boolean | null {
  const lowered = value.trim().toLowerCase()
  if (['yes', 'true', 'on', '1'].includes(lowered)) return true
  if (['no', 'false', 'off', '0'].includes(lowered)) return false
  return null
}

/**
 * A count, clamped to something this app is prepared to do unattended.
 *
 * Clamping rather than rejecting, and warning rather than being silent — see
 * {@link HARD_MAX_RUNS_PER_HOUR} for the argument. The floor is 1 for the same
 * reason: `max-runs-per-hour: 0` reads like "off", and a routine turned off by
 * a number rather than by `enabled: no` is a routine somebody will spend an
 * afternoon on.
 */
function parseCount(
  value: string,
  hardMax: number,
  key: string,
  warnings: string[],
): number | null {
  if (!/^\d{1,9}$/.test(value.trim())) return null
  const parsed = Number(value.trim())
  if (parsed < 1) {
    warnings.push(`\`${key}: ${value.trim()}\` was raised to 1 — use \`enabled: no\` to stop a routine.`)
    return 1
  }
  if (parsed > hardMax) {
    warnings.push(
      `\`${key}: ${parsed}\` was lowered to ${hardMax}, which is the most this app will run a routine unattended.`,
    )
    return hardMax
  }
  return parsed
}

/**
 * Split a routine file into its heading, its header lines and its prompt.
 *
 * Exported because the store shows it to error messages: knowing that a file
 * had no `---` at all is the difference between "your header is wrong" and
 * "this file has no prompt in it".
 */
export function splitDocument(text: string): {
  heading: string | null
  header: string[]
  prompt: string | null
  comments: string[]
} {
  // `\r\n` is not a hypothetical here: these files are edited by hand, and this
  // app already shipped one CRLF parsing bug. Normalised once, at the door.
  const lines = text.replace(/\r\n?/g, '\n').split('\n')
  let heading: string | null = null
  const header: string[] = []
  const comments: string[] = []
  let prompt: string | null = null

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line.trim() === '---') {
      prompt = lines.slice(i + 1).join('\n')
      break
    }
    if (line.trim() === '') continue
    if (line.startsWith('#')) {
      // The first `#` line is the routine's name; any others are a person's
      // notes to themselves, which are kept out of the way rather than parsed.
      const label = line.replace(/^#+\s*/, '').trim()
      if (heading === null) heading = label
      else comments.push(label)
      continue
    }
    header.push(line)
  }

  return { heading, header, prompt, comments }
}

/**
 * Read one routine file.
 *
 * `id` comes from the filename rather than from the text, so the two can never
 * disagree — a file called `nightly.md` holding `id: something-else` would be
 * two answers to "which routine is this" and the wrong one would win depending
 * on who was asking.
 */
export function parseRoutine(id: string, text: string): ParseResult {
  const problems: string[] = []
  const warnings: string[] = []

  if (!isValidId(id)) {
    return {
      ok: false,
      problems: [
        `\`${id}\` is not a usable routine name. Use lowercase letters, digits and hyphens.`,
      ],
    }
  }
  if (text.length > MAX_FILE_BYTES) {
    return { ok: false, problems: [`This file is larger than ${MAX_FILE_BYTES} bytes.`] }
  }

  const { heading, header, prompt } = splitDocument(text)

  const triggers: Trigger[] = []
  const unknown: Record<string, string[]> = {}
  let folder: string | null = null
  let enabled = true
  let overlap: OverlapPolicy = 'queue'
  let maxRunsPerHour = DEFAULT_MAX_RUNS_PER_HOUR
  let maxRunsPerDay = DEFAULT_MAX_RUNS_PER_DAY
  let quietForMs = DEFAULT_QUIET_FOR_MS
  let expectEveryMs: number | null = null

  for (const line of header) {
    const colon = line.indexOf(':')
    if (colon <= 0) {
      problems.push(`\`${line.trim()}\` is not a \`key: value\` line.`)
      continue
    }
    const key = line.slice(0, colon).trim().toLowerCase()
    const value = line.slice(colon + 1).trim()

    if (!KNOWN_KEYS.has(key)) {
      // Kept, not dropped. See the module header.
      ;(unknown[key] ??= []).push(value)
      warnings.push(`This build does not understand \`${key}:\`, so it was left alone.`)
      continue
    }

    switch (key) {
      case 'when': {
        const parsed = parseTrigger(value)
        if ('problem' in parsed) problems.push(parsed.problem)
        else triggers.push(parsed.trigger)
        break
      }
      case 'in':
        folder = value
        break
      case 'enabled': {
        const parsed = parseBoolean(value)
        if (parsed === null) problems.push(`\`enabled: ${value}\` should be yes or no.`)
        else enabled = parsed
        break
      }
      case 'overlap':
        if (!OVERLAP_POLICIES.includes(value)) {
          problems.push(`\`overlap: ${value}\` should be queue, skip or cancel.`)
        } else {
          overlap = value as OverlapPolicy
        }
        break
      case 'max-runs-per-hour': {
        const parsed = parseCount(value, HARD_MAX_RUNS_PER_HOUR, key, warnings)
        if (parsed === null) problems.push(`\`${key}: ${value}\` should be a whole number.`)
        else maxRunsPerHour = parsed
        break
      }
      case 'max-runs-per-day': {
        const parsed = parseCount(value, HARD_MAX_RUNS_PER_DAY, key, warnings)
        if (parsed === null) problems.push(`\`${key}: ${value}\` should be a whole number.`)
        else maxRunsPerDay = parsed
        break
      }
      case 'quiet-for': {
        const parsed = parseDuration(value)
        if (parsed === null) problems.push(`\`quiet-for: ${value}\` should be a duration, like 30s.`)
        else quietForMs = parsed
        break
      }
      case 'expect-every': {
        const parsed = parseDuration(value)
        if (parsed === null) {
          problems.push(`\`expect-every: ${value}\` should be a duration, like 26h.`)
        } else {
          expectEveryMs = parsed
        }
        break
      }
      default:
        break
    }
  }

  if (triggers.length === 0) problems.push('This routine has no `when:` line, so nothing can start it.')
  if (folder === null || folder === '') {
    problems.push('This routine has no `in:` line, so there is nowhere for it to run.')
  }
  if (prompt === null) {
    problems.push('This routine has no `---` line, so there is no prompt beneath it.')
  }

  const body = (prompt ?? '').replace(/^\n+/, '').replace(/\s+$/, '')
  if (prompt !== null && body === '') problems.push('The prompt below `---` is empty.')
  if (Buffer.byteLength(body, 'utf8') > MAX_PROMPT_BYTES) {
    problems.push(`The prompt is longer than ${MAX_PROMPT_BYTES} bytes.`)
  }

  if (problems.length > 0) return { ok: false, problems }

  return {
    ok: true,
    warnings,
    routine: {
      id,
      name: (heading ?? id).slice(0, MAX_NAME_LENGTH),
      triggers,
      // Non-null by construction: a null `folder` is a problem above and this
      // line is unreachable when problems exist.
      folder: folder as string,
      prompt: body,
      enabled,
      overlap,
      maxRunsPerHour,
      maxRunsPerDay,
      quietForMs,
      expectEveryMs,
      unknown,
    },
  }
}

/* ------------------------------------------------------------------ drafts */

/**
 * A routine as a settings pane or an MCP tool would hand it over.
 *
 * Every field is `unknown` because every field is untrusted: this shape arrives
 * over IPC from a renderer, and in phase 2 it arrives from a language model
 * through `routines.create`. Nothing narrows it except {@link routineFromDraft}.
 */
export interface RoutineDraft {
  name?: unknown
  /** One `when:` line, or several. */
  when?: unknown
  /** The folder. Named `in` to match the file. */
  in?: unknown
  prompt?: unknown
  enabled?: unknown
  overlap?: unknown
  maxRunsPerHour?: unknown
  maxRunsPerDay?: unknown
  quietFor?: unknown
  expectEvery?: unknown
}

/**
 * A header value with nothing in it that could become a second line.
 *
 * This is the injection guard, and it is the reason drafts are turned into text
 * and parsed rather than assembled into an object directly. A `name` of
 * `"Sweep\nin: /"` would otherwise write a routine whose folder is the root of
 * the disk, from a field a UI treats as a label. Newlines out, and a length cap
 * so no single value can be the whole file.
 */
function headerValue(value: unknown, limit = 300): string {
  if (typeof value !== 'string') return ''
  return value.replace(/[\r\n]+/g, ' ').trim().slice(0, limit)
}

/**
 * Turn an untrusted draft into a routine — through the same parser a file goes
 * through, deliberately.
 *
 * The alternative is a second validation path that agrees with the first until
 * the day it does not, and the day it does not is the day a routine created
 * through a tool behaves differently from the identical routine typed into a
 * file. So the draft is serialised into the canonical document and parsed, and
 * every rule in {@link parseRoutine} — the clamps, the trigger grammar, the
 * prompt cap — applies to both callers with no second copy of any of it.
 */
export function routineFromDraft(id: string, draft: RoutineDraft): ParseResult {
  const lines: string[] = []
  const name = headerValue(draft.name, MAX_NAME_LENGTH)
  lines.push(`# ${name === '' ? id : name}`, '')

  const when = Array.isArray(draft.when) ? draft.when : draft.when === undefined ? [] : [draft.when]
  for (const entry of when.slice(0, 10)) {
    const text = headerValue(entry)
    if (text !== '') lines.push(`when: ${text}`)
  }
  lines.push(`in: ${headerValue(draft.in, 1000)}`)
  if (draft.enabled !== undefined) lines.push(`enabled: ${draft.enabled === false ? 'no' : 'yes'}`)
  if (draft.overlap !== undefined) lines.push(`overlap: ${headerValue(draft.overlap, 20)}`)
  if (draft.maxRunsPerHour !== undefined) {
    lines.push(`max-runs-per-hour: ${headerValue(String(draft.maxRunsPerHour), 20)}`)
  }
  if (draft.maxRunsPerDay !== undefined) {
    lines.push(`max-runs-per-day: ${headerValue(String(draft.maxRunsPerDay), 20)}`)
  }
  if (draft.quietFor !== undefined) lines.push(`quiet-for: ${headerValue(draft.quietFor, 20)}`)
  if (draft.expectEvery !== undefined) {
    lines.push(`expect-every: ${headerValue(draft.expectEvery, 20)}`)
  }

  lines.push('', '---', '')
  // The prompt is the one field that keeps its newlines — it is prose, and it
  // is below the separator where nothing it contains can be read as a header.
  lines.push(typeof draft.prompt === 'string' ? draft.prompt : '')
  return parseRoutine(id, lines.join('\n'))
}

/** A free id near `name`, given the ones already taken. */
export function suggestId(name: string, taken: ReadonlySet<string>): string {
  const slug = slugify(name)
  // A reserved device name is a valid slug and an invalid filename, so it is
  // moved out of the way here rather than being handed back and refused later.
  const base = slug === '' || RESERVED_NAMES.has(slug) ? `${slug}-routine`.replace(/^-/, '') : slug
  if (!taken.has(base)) return base
  for (let index = 2; index < 1000; index++) {
    const candidate = `${base.slice(0, 58)}-${index}`
    if (!taken.has(candidate)) return candidate
  }
  return `${base.slice(0, 50)}-${Date.now().toString(36)}`
}

/**
 * Write a routine back out in the canonical shape.
 *
 * Only the three keys every routine has are always printed; the rest appear
 * when they differ from the default, so a file somebody opens is a short one
 * that says what is unusual about this routine rather than a form with eight
 * fields at their factory settings. `parseRoutine(serializeRoutine(r))` returns
 * `r`, which is what makes it safe for `routines.create` and a text editor to
 * take turns on the same file.
 */
export function serializeRoutine(routine: Routine): string {
  const lines: string[] = [`# ${routine.name}`, '']
  for (const trigger of routine.triggers) lines.push(`when: ${serializeTrigger(trigger)}`)
  lines.push(`in: ${routine.folder}`)
  lines.push(`enabled: ${routine.enabled ? 'yes' : 'no'}`)
  if (routine.overlap !== 'queue') lines.push(`overlap: ${routine.overlap}`)
  if (routine.maxRunsPerHour !== DEFAULT_MAX_RUNS_PER_HOUR) {
    lines.push(`max-runs-per-hour: ${routine.maxRunsPerHour}`)
  }
  if (routine.maxRunsPerDay !== DEFAULT_MAX_RUNS_PER_DAY) {
    lines.push(`max-runs-per-day: ${routine.maxRunsPerDay}`)
  }
  if (routine.quietForMs !== DEFAULT_QUIET_FOR_MS) {
    lines.push(`quiet-for: ${serializeDuration(routine.quietForMs)}`)
  }
  if (routine.expectEveryMs !== null) {
    lines.push(`expect-every: ${serializeDuration(routine.expectEveryMs)}`)
  }
  for (const [key, values] of Object.entries(routine.unknown)) {
    for (const value of values) lines.push(`${key}: ${value}`)
  }
  lines.push('', '---', '', routine.prompt, '')
  return lines.join('\n')
}
