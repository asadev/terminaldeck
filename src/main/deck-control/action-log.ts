/**
 * `actions.jsonl` — every tool call the copilot ever made.
 *
 * Append-only, one JSON object per line, at `<userData>/copilot-log/`. It is a
 * *user-facing artefact*, not telemetry: `COPILOT-DESIGN.md` puts it in
 * Settings → Copilot → Activity, and the reason it exists is written there in
 * one sentence — "an agent that can silently rewrite your settings is not an
 * assistant, it is a fault."
 *
 * Which is also why it is not where it looks like it is. The layout the copilot
 * is shown puts the log beside its `CLAUDE.md` and its `memory/`, and for a
 * while it really was there — inside the one directory the copilot may write to,
 * so the audited party could append rows that never happened, edit rows that
 * did, or delete the file. `copilot-home.ts` has the move and the argument;
 * `copilot-log-boundary.test.ts` proves the refusal against a real
 * `sandbox-exec`. The copilot's own appends now arrive through the `log.note`
 * tool, which means they arrive through {@link DeckControl.call} like everything
 * else and land in the row this module writes.
 *
 * Three decisions are worth defending.
 *
 * **Every tier, not only the dangerous ones.** A log that records only what was
 * confirmed answers "what did I approve", which is the question you already
 * know the answer to. The question people actually have is "what has this thing
 * been doing", and reads are most of that: a copilot that listed your sessions
 * and read three transcripts before answering has spent your money and looked
 * at your work, and both belong in the record.
 *
 * **Refusals are logged, and are the most valuable rows in the file.** A gate
 * that denies silently is indistinguishable from a gate that was never reached.
 * A refused row with its reason is how somebody finds out their copilot has
 * been trying to write `remote.enabled` all afternoon.
 *
 * **Written before the answer is known, finished after.** Two writes per call
 * would make the file harder to read, so instead the row is composed in memory
 * and appended once the call settles — but the append is inside a `finally`, so
 * a handler that throws, a refusal, and a success all produce exactly one line.
 * The only way to act without leaving a line is to crash the process between
 * the call and the append, and nothing here can prevent that.
 *
 * ## Redaction, and why it is narrow
 *
 * `redact.ts` exists for support bundles and folds identity as well as secrets:
 * it rewrites `/Users/asad` to `/Users/<user>` and runs an entropy sweep that
 * treats a UUID-shaped string as a possible key. Both are right for something
 * you paste into an issue and wrong for this file. This log lives in the user's
 * own application-support directory, beside `state.json` and `settings.json`,
 * and its entire job is to let them audit their own machine — a log in which
 * the session ids are `[redacted]` and the project paths are `<user>` is a log
 * that cannot answer the question it was written for.
 *
 * So: secret-looking *keys* are dropped by name, free prose (the text of a
 * `sessions.send`) goes through the shape-based redactor with identity folding
 * switched off, and everything else is recorded as written and capped for
 * length. See {@link scrubArgs}.
 *
 * ## This file has a second writer, and that shapes everything below
 *
 * `copilot-home.ts` owns the copilot's folder and appends its own lifecycle
 * lines here — `home.created`, `session.started` — through
 * `appendCopilotAction`. There is one action log, not two, because a person
 * asking "what did my copilot do this morning" should not have to read two
 * files and interleave them by timestamp.
 *
 * Three consequences, and each is a decision rather than an accident:
 *
 *  1. **Field conventions are theirs.** `at` is an ISO string, `action` is a
 *     dotted name, `detail` is one human-readable line. The structured fields
 *     this module needs sit alongside them, which is exactly what that module's
 *     own comment invites: "anything that needs structure gets its own key
 *     alongside these two, which JSONL tolerates without a migration". A reader
 *     that only understands the short shape still renders these rows.
 *  2. **Rotation has to agree.** Same ceiling, same single kept generation,
 *     same `.1` suffix — so whichever writer rolls the file first, the other
 *     finds the layout it expects rather than a second scheme beside it.
 *  3. **The size is read, not remembered.** `AppLog` tracks bytes in memory and
 *     is right to, because it is the only writer of its file. Here a cached
 *     count goes stale the moment the other writer appends or rolls, so every
 *     write stats first. One `stat` per copilot tool call is nothing next to
 *     the work the call itself does.
 */

import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { redact } from '../redact'
import type { RefusalReason, Tier } from './surface'

/* -------------------------------------------------------------- constants -- */

export const ACTION_LOG_VERSION = 1

/** File name inside the copilot's `log/` folder. Named in `COPILOT-DESIGN.md`. */
export const ACTION_LOG_FILE = 'actions.jsonl'

/**
 * Size at which the live file rolls over, and how many rolled files are kept.
 *
 * Both numbers are `copilot-home.ts`'s, matched deliberately: four megabytes
 * and one kept generation. They are not this module's to choose while another
 * writer shares the file, and two rotation policies on one path is how a log
 * ends up with `actions.jsonl.1` written by one scheme and read by another.
 */
export const DEFAULT_MAX_BYTES = 4 * 1024 * 1024
export const DEFAULT_KEEP = 1

/**
 * Per-string ceiling inside a logged argument object.
 *
 * A prompt sent to a session is the long one, and 2000 characters is enough to
 * read what was asked without turning the audit log into a copy of every
 * conversation the copilot ever had.
 */
export const MAX_LOGGED_STRING = 2000

/** Ceiling on one composed row, after which the args and result are dropped. */
export const MAX_ROW_BYTES = 32 * 1024

/**
 * Argument keys whose value is never recorded.
 *
 * No tool in the catalogue takes a credential today. The list is here because
 * the next one might, and a log that started recording secrets on the day a
 * tool was added — with no line of code changed here — is the failure this
 * closes in advance.
 */
const SECRET_KEY = /(token|secret|password|passwd|api[-_]?key|credential|cookie|authorization|bearer)/i

/**
 * Argument keys whose value is prose the copilot composed.
 *
 * These get the shape-based redactor: it catches `sk-…`, `ghp_…`, an
 * `Authorization:` header and a PEM block by structure, which is worth having
 * in a file a person may well paste somewhere. Identity folding is switched off
 * (`home: ''`) so the user's own paths survive.
 *
 * `note` is here because `log.note` is the copilot writing free prose *straight
 * into this file* — the one argument in the catalogue whose whole purpose is to
 * become a row a person reads. The copilot's own `CLAUDE.md` tells it never to
 * repeat something that looks like a credential; this is the check behind that
 * sentence, and the case it covers is the honest one, where a secret arrives
 * inside a note about something else.
 */
const PROSE_KEY = /^(text|prompt|message|body|note)$/i

/* ------------------------------------------------------------------ types -- */

/** What happened to the call. Three outcomes, and they are not the same thing. */
export type ActionOutcome =
  /** The tool ran and returned. */
  | 'ok'
  /** A rule stopped it. Nothing was done. */
  | 'refused'
  /** It ran and failed, or the arguments were rejected. */
  | 'error'

export interface ConfirmationRecord {
  /** Whether this call's tier demanded a human answer. */
  required: boolean
  /**
   * Whether a human actually said yes.
   *
   * `false` for every read and act call, not null — "no human confirmed this"
   * is the honest reading of a call that was never put to one, and a nullable
   * field here invites a reader to treat absent as approved.
   */
  granted: boolean
  /** Set when the answer came from a person: which window answered. */
  by: string | null
  /** Epoch ms of the answer, when there was one. */
  at: number | null
  /** Why it was not granted, when it was required and not granted. */
  reason: RefusalReason | null
}

export interface ActionRow {
  /**
   * ISO 8601, stamped when the call *arrived* rather than when it finished.
   *
   * A string and not epoch milliseconds, because `copilot-home.ts` writes ISO
   * into this same file and one field cannot honestly be two types. An
   * alter-tier call can sit for a minute waiting on a person, and ordering the
   * log by when things were attempted is what makes a burst of refusals read as
   * a burst; `ms` carries how long each one then took.
   */
  at: string
  /**
   * Dotted name, the convention the other writer of this file uses.
   *
   * `tool.<id>` for a call, so `tool.settings.write` sorts and greps beside
   * `home.created` and `session.started` without anybody having to know which
   * module wrote which.
   */
  action: string
  /** One line a person can read, and the only field a short-shape reader shows. */
  detail: string
  /** The session this call concerned, when it concerned one. */
  sessionId?: string
  v: number
  /** Unique per call, so a row can be pointed at from a UI or another log. */
  id: string
  /** Canonical tool id — the dotted form, `sessions.send`. */
  tool: string
  /** The tier this call was actually judged at, after any escalation. */
  tier: Tier
  /** The tier the catalogue declares, when escalation moved it. */
  baseTier?: Tier
  args: Record<string, unknown>
  outcome: ActionOutcome
  confirmed: ConfirmationRecord
  /**
   * Where the call came from.
   *
   * `local` is the copilot session running on this machine. `remote` is a paired
   * device that was granted copilot access, and then the device id is the only
   * way to answer "which of my phones did that" — a question that has exactly
   * one place to be answered from, because a relayed call leaves no other trace
   * in this app.
   *
   * Optional on the type and written on every row from the day this shipped, so
   * a reader can tell "before the field existed" from "local". A row with no
   * `caller` is a row from an older build, not a local call.
   */
  caller?: { kind: 'local' | 'remote' | 'session'; deviceId?: string }
  /** Wall-clock duration of the call, including any time spent waiting on a human. */
  ms: number
  /**
   * A *summary* of what came back, never the payload.
   *
   * `sessions.transcript` can return sixty kilobytes of conversation and
   * copying that into the log would double the app's transcript storage for no
   * reader's benefit. Each tool decides what its summary is; most of them are
   * three numbers.
   */
  result: Record<string, unknown> | null
  /** Message when `outcome` is `error`, or the refusal sentence when refused. */
  error: string | null
}

/* ------------------------------------------------------------- scrubbing -- */

function capString(value: string): string {
  return value.length <= MAX_LOGGED_STRING
    ? value
    : `${value.slice(0, MAX_LOGGED_STRING)}…[${value.length} chars]`
}

/**
 * Reduce a tool's arguments to something worth writing down.
 *
 * Deliberately shallow-ish: tool arguments in this catalogue are flat objects
 * of primitives, one level of nesting at most (`settings.write` takes a patch).
 * Anything deeper is summarised rather than walked, because an argument shape
 * nobody designed is not one to serialise faithfully into an append-only file.
 */
export function scrubArgs(args: unknown, depth = 0): Record<string, unknown> {
  if (typeof args !== 'object' || args === null || Array.isArray(args)) return {}
  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(args as Record<string, unknown>)) {
    if (SECRET_KEY.test(key)) {
      out[key] = '[redacted]'
      continue
    }
    if (typeof value === 'string') {
      // Identity folding off: this is the user's own audit log of their own
      // machine, and `/Users/<user>/Projects/x` answers no question that
      // `/Users/asad/Projects/x` did not answer better.
      out[key] = capString(PROSE_KEY.test(key) ? redact(value, { home: '', username: '' }) : value)
      continue
    }
    if (value === null || typeof value === 'number' || typeof value === 'boolean') {
      out[key] = value
      continue
    }
    if (Array.isArray(value)) {
      out[key] = depth === 0 ? value.slice(0, 20).map((item) => scrubValue(item)) : `[${value.length} items]`
      continue
    }
    if (typeof value === 'object') {
      out[key] = depth === 0 ? scrubArgs(value, depth + 1) : '[object]'
      continue
    }
    // `undefined`, a function, a symbol: nothing a JSON tool argument can be.
    out[key] = String(value)
  }
  return out
}

function scrubValue(value: unknown): unknown {
  if (typeof value === 'string') return capString(value)
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return value
  return '[object]'
}

/* ------------------------------------------------------------------- log -- */

export interface ActionLogOptions {
  /** The copilot's `log/` directory. Created on first write. */
  dir: string
  maxBytes?: number
  keep?: number
  now?: () => number
}

/**
 * The file, with rotation and no way to throw at a caller.
 *
 * Modelled on `app-log.ts`, which solved the same problem for the application
 * log, but not shared with it: that one formats human-readable lines with a
 * level and a scope, this one writes machine-readable rows that a settings pane
 * parses. A common base would have to be generic over the line format, which is
 * the only thing the two disagree about.
 *
 * A write that fails is swallowed and the log marks itself broken, exactly as
 * `AppLog` does — a read-only volume or a full disk must not turn every
 * subsequent copilot call into an exception. It is worth being clear about what
 * that costs: on such a machine the copilot keeps working and stops being
 * audited. `broken` is exposed so the status channel can say so out loud rather
 * than letting the Activity pane look merely quiet.
 */
export class ActionLog {
  readonly dir: string
  readonly file: string
  private readonly maxBytes: number
  private readonly keep: number
  private readonly now: () => number
  private failed = false

  constructor(options: ActionLogOptions) {
    this.dir = options.dir
    this.file = join(this.dir, ACTION_LOG_FILE)
    this.maxBytes = Math.max(options.maxBytes ?? DEFAULT_MAX_BYTES, 4096)
    this.keep = Math.max(options.keep ?? DEFAULT_KEEP, 0)
    this.now = options.now ?? Date.now
  }

  /** True once a write has failed. Surfaced so the UI can say "not recording". */
  get broken(): boolean {
    return this.failed
  }

  private currentSize(): number {
    try {
      return statSync(this.file).size
    } catch {
      return 0
    }
  }

  private generation(index: number): string {
    return `${this.file}.${index}`
  }

  private rotate(): void {
    try {
      if (this.keep === 0) {
        rmSync(this.file, { force: true })
        return
      }
      rmSync(this.generation(this.keep), { force: true })
      for (let i = this.keep - 1; i >= 1; i -= 1) {
        if (existsSync(this.generation(i))) renameSync(this.generation(i), this.generation(i + 1))
      }
      // `renameSync` over an existing target replaces it atomically on every
      // platform this app runs on, so there is no window in which neither file
      // exists — the same reasoning `copilot-home.ts` gives for its own roll.
      if (existsSync(this.file)) renameSync(this.file, this.generation(1))
    } catch (error) {
      // A roll that failed leaves an oversized log, which is better than a lost
      // one. The next append will try again.
      console.error('[deck-control] could not roll the action log:', error)
    }
  }

  /**
   * Append one row.
   *
   * The row is serialised first and measured: a pathological one — an argument
   * object far larger than anything the catalogue can produce — is written with
   * its `args` and `result` replaced rather than dropped, because the fact that
   * a call happened is the part of a row that must never be lost.
   */
  append(row: ActionRow): void {
    if (this.failed) return
    let line = `${JSON.stringify(row)}\n`
    if (Buffer.byteLength(line) > MAX_ROW_BYTES) {
      line = `${JSON.stringify({
        ...row,
        args: { note: 'arguments were too large to record' },
        result: { note: 'result summary was too large to record' },
      })}\n`
    }
    const size = Buffer.byteLength(line)
    try {
      // 0700 and 0600 to match the other writer of this folder. The log names
      // the sessions somebody is running and quotes what was typed into them;
      // on a shared machine that is nobody else's to read.
      mkdirSync(this.dir, { recursive: true, mode: 0o700 })
      // Stat rather than a remembered count: `copilot-home.ts` appends to and
      // rolls this same file, so a cached size is wrong as soon as it does.
      if (this.currentSize() + size > this.maxBytes) this.rotate()
      appendFileSync(this.file, line, { encoding: 'utf8', mode: 0o600 })
    } catch {
      // Read-only volume, a full disk, a sandbox that will not let us write:
      // stop trying rather than throwing on every subsequent tool call. The
      // status channel reports `logging: false` so this is visible.
      this.failed = true
    }
  }

  /**
   * The most recent `count` rows, oldest first.
   *
   * Walks back through the rotated generations the way `AppLog.tail` does, and
   * for the same reason: a busy afternoon can roll the file, and an Activity
   * pane that only read the live one would show the last ten minutes of a story
   * that started this morning.
   *
   * Unparseable lines are skipped rather than throwing. A row half-written when
   * the machine lost power is one bad line in a file whose other ten thousand
   * are fine.
   */
  tail(count = 200): ActionRow[] {
    const want = Number.isFinite(count) ? Math.floor(count) : 0
    if (want <= 0) return []

    let lines = this.readLines(this.file)
    for (let i = 1; i <= this.keep && lines.length < want; i += 1) {
      lines = [...this.readLines(this.generation(i)), ...lines]
    }
    const rows: ActionRow[] = []
    for (const line of lines.slice(-want)) {
      try {
        const parsed: unknown = JSON.parse(line)
        if (typeof parsed === 'object' && parsed !== null) rows.push(parsed as ActionRow)
      } catch {
        /* a torn line; the rest of the file is still readable */
      }
    }
    return rows
  }

  private readLines(path: string): string[] {
    try {
      return readFileSync(path, 'utf8').split('\n').filter((line) => line.length > 0)
    } catch {
      return []
    }
  }

  /**
   * Compose and append a row in one call.
   *
   * Returns the row so a caller can push it at a UI without re-reading the
   * file. `at` is supplied by the caller because it is stamped when the call
   * *arrived*, and an alter-tier call can sit for two minutes waiting on a
   * human before it finishes.
   */
  record(input: Omit<ActionRow, 'v'>): ActionRow {
    const row: ActionRow = { v: ACTION_LOG_VERSION, ...input }
    this.append(row)
    return row
  }

  /** Epoch ms, from the injected clock. Tests drive this. */
  clock(): number {
    return this.now()
  }
}
