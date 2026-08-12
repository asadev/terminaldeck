/**
 * Model, effort and permission-mode controls for a running Claude Code session.
 *
 * ## The rule this module exists to obey
 *
 * There is no API client in this app. The only channel to the agent is the PTY,
 * so a control here is honest exactly when a person could sit at that terminal
 * and type the same thing. Every command below was driven against the real CLI
 * on this machine (`claude 2.1.228`, ~/.local/bin/claude) inside a pty and the
 * replies were read back off a headless terminal. What was verified:
 *
 * | typed              | the CLI answered                                                |
 * |--------------------|-----------------------------------------------------------------|
 * | `/model sonnet`    | `Set model to Sonnet 5 and saved as your default for new sessions` |
 * | `/model default`   | `Set model to Opus 5 (1M context) (default) and saved as …`      |
 * | `/model nosuchmodel` | `Model 'nosuchmodel' not found`                               |
 * | `/effort xhigh`    | `Set effort level to xhigh (saved as your default …): Deeper …` |
 * | `/effort nosuch`   | `Invalid argument: nosuch. Valid options are: low, medium, high, xhigh, max, ultracode, auto` |
 * | `/fast on`         | `Fast mode unavailable: Fast mode requires usage credits · …`    |
 * | `/plan`            | `Enabled plan mode`                                              |
 * | shift+tab          | footer moves auto → manual → accept edits → plan → bypass → auto |
 *
 * That last row is the important one. `/permissions` does **not** set the mode —
 * driving it opens a rules browser with Allow/Ask/Deny/Workspace tabs, and the
 * command's own description is "Manage allow and deny tool permission rules".
 * The only in-session way to change the mode is the shift+tab cycle, so this
 * module cycles — but never blind. It presses once, re-reads the footer, and
 * repeats. If it cannot read the mode to begin with it refuses to press at all,
 * because pressing without knowing where you started is guessing.
 *
 * ## Where a "current value" is allowed to come from
 *
 * Only from something real, and the reading always says which:
 *
 *   - `screen`   — the session's own terminal, read through the headless
 *                  terminal `session-activity.ts` already keeps per session.
 *   - `transcript` — `message.model` on the newest assistant line, i.e. the
 *                  model that actually served the last reply.
 *   - `settings` — `~/.claude/settings.json`, which is where the CLI itself
 *                  persists `effortLevel`, `ultracode` and `fastMode`.
 *   - `env`      — `CLAUDE_CODE_EFFORT_LEVEL`, which the CLI says overrides
 *                  effort for the session.
 *
 * When none of them answer, the value is `null` and the UI says "unknown".
 * There is no default in this file for anything the user can see.
 */

import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { normalizeModelId } from './cost'
import { stripAnsi } from './session-activity'
import { claudeConfigDir, newestTranscript, transcriptDir } from './transcript'

/* -------------------------------------------------------------------------- */
/* Types                                                                       */
/* -------------------------------------------------------------------------- */

export type ControlId = 'model' | 'effort' | 'fast' | 'permission'

/** Where a displayed value came from. `null` value + `null` source means unknown. */
export type ValueSource = 'screen' | 'transcript' | 'settings' | 'env'

export interface ControlReading {
  /** The machine value, or null when nothing real could be read. */
  value: string | null
  /** What to show. Null when unknown — the UI must not invent one. */
  label: string | null
  source: ValueSource | null
  /** Set when the CLI told us this control is not usable on this account. */
  unavailableReason?: string
}

export interface ControlsReading {
  model: ControlReading
  effort: ControlReading
  fast: ControlReading
  permission: ControlReading
  /** False when no live session was addressable, so nothing could be applied. */
  live: boolean
}

export interface ApplyRequest {
  sessionId: string
  cwd?: string
  control: ControlId
  value: string
}

export interface ApplyResult {
  ok: boolean
  /** What the CLI printed, verbatim, or an explanation of why we did not act. */
  message: string
  /** The reading taken after the change settled. */
  reading: ControlReading
}

/** What this module needs from the session layer. Kept tiny so it is trivially faked. */
export interface SessionAccess {
  /** Type into the session's terminal, exactly as a person would. */
  write(id: string, data: string): void
  /**
   * The session's visible screen once everything written to it has been
   * parsed, or null when there is no such session. Asynchronous because the
   * emulator parses in the background: an unflushed read returns the screen as
   * it was before the last chunk, which reads as "unknown" at exactly the
   * moment the answer has just arrived.
   */
  screen(id: string): Promise<string | null>
}

/* -------------------------------------------------------------------------- */
/* Verified option tables                                                      */
/* -------------------------------------------------------------------------- */

/**
 * Permission modes, in the order shift+tab visits them.
 *
 * Order and footer text are transcribed from a real cycle, not from the flag
 * documentation: pressing shift+tab five times from `bypass` produced auto,
 * manual, accept edits, plan, bypass in that order, and the footer strings are
 * copied character-for-character from the rendered screen.
 *
 * `manual` is the odd one out — its footer ends `· ? for shortcuts` rather than
 * `(shift+tab to cycle)`, so matching on the trailing hint would have missed it.
 *
 * `dontAsk` is deliberately absent. `claude --permission-mode` accepts it, but
 * it never appeared in the cycle on this machine, so there is no way to reach it
 * from a running session and offering it would be a control that does nothing.
 */
export const PERMISSION_MODES = [
  { id: 'auto', label: 'Auto', screen: /auto mode on/i },
  { id: 'manual', label: 'Manual', screen: /manual mode on/i },
  { id: 'acceptEdits', label: 'Accept edits', screen: /accept edits on/i },
  { id: 'plan', label: 'Plan', screen: /plan mode on/i },
  { id: 'bypass', label: 'Bypass', screen: /bypass permissions on/i },
] as const

export type PermissionModeId = (typeof PERMISSION_MODES)[number]['id']

/**
 * Effort levels, quoted from the CLI's own rejection of a bad value:
 * `Invalid argument: nosuchlevel. Valid options are: low, medium, high, xhigh,
 * max, ultracode, auto`. Asking the tool what it accepts beats reading docs.
 */
export const EFFORT_LEVELS = [
  { id: 'low', label: 'Low' },
  { id: 'medium', label: 'Medium' },
  { id: 'high', label: 'High' },
  { id: 'xhigh', label: 'Extra high' },
  { id: 'max', label: 'Max' },
  { id: 'ultracode', label: 'Ultracode' },
  { id: 'auto', label: 'Auto' },
] as const

/**
 * Model aliases, each one typed at the real CLI and confirmed by its reply.
 * `opus` and `default` are genuinely different — `default` answered
 * "Opus 5 (1M context)" and `opus` answered "Opus 5" — so both are listed.
 *
 * This is a list of *aliases the CLI accepts*, not a claim about which models
 * an account may use. A name this account cannot use comes back as
 * `Model 'x' not found`, which is surfaced verbatim rather than swallowed.
 */
export const MODEL_ALIASES = [
  { id: 'default', label: 'Default' },
  { id: 'opus', label: 'Opus' },
  { id: 'fable', label: 'Fable' },
  { id: 'sonnet', label: 'Sonnet' },
  { id: 'haiku', label: 'Haiku' },
] as const

/* -------------------------------------------------------------------------- */
/* Screen reading                                                              */
/* -------------------------------------------------------------------------- */

/** Non-empty lines of a screen, oldest first. */
function lines(screen: string): string[] {
  return stripAnsi(screen)
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '')
}

/**
 * Which permission mode the footer is currently announcing.
 *
 * Only the bottom of the screen is considered. The CLI prints a paragraph
 * explaining auto mode when you enter it, and that paragraph sits in the middle
 * of the screen for the rest of the session — scanning the whole viewport would
 * pin the reading to whatever was last explained rather than what is in force.
 */
export function readPermissionMode(screen: string): PermissionModeId | null {
  const tail = lines(screen).slice(-5)
  for (let i = tail.length - 1; i >= 0; i--) {
    for (const mode of PERMISSION_MODES) {
      if (mode.screen.test(tail[i])) return mode.id
    }
  }
  return null
}

/**
 * The model named by the CLI's own confirmation line, if one is on screen.
 *
 * Both wordings appear: `Set model to X and saved as …` after a change, and
 * `Kept model as X` after cancelling the picker. Everything up to the first
 * ` and saved` is the display name, which is why the capture stops there —
 * `Opus 5 (1M context) (default)` contains parentheses and spaces and would
 * not survive a tighter pattern.
 */
export function readModelFromScreen(screen: string): string | null {
  const text = lines(screen).join('\n')
  const matches = [...text.matchAll(/(?:Set model to|Kept model as)\s+(.+?)(?:\s+and saved\b|$)/gim)]
  const last = matches[matches.length - 1]
  return last ? last[1].trim() || null : null
}

/**
 * The effort level named by the CLI's confirmation line.
 *
 * `Set effort level to xhigh (saved as your default for new sessions): Deeper…`
 * — the level is the bare word before the parenthesis or colon.
 */
export function readEffortFromScreen(screen: string): string | null {
  const text = lines(screen).join('\n')
  const matches = [...text.matchAll(/Set effort level to\s+([a-z]+)/gi)]
  const last = matches[matches.length - 1]
  return last ? last[1].toLowerCase() : null
}

/**
 * Fast mode as the CLI last reported it: on, off, or refused.
 *
 * The refusal is a real answer and is kept, because a control that reports
 * "Fast mode requires usage credits" is useful and a control that silently
 * stays off is a lie.
 */
export function readFastFromScreen(screen: string): ControlReading | null {
  const text = lines(screen).join('\n')
  const refused = /Fast mode (?:unavailable|is not available)[:.]?\s*(.*)$/im.exec(text)
  if (refused) {
    return {
      value: 'off',
      label: 'Off',
      source: 'screen',
      unavailableReason: refused[1].trim() || 'Fast mode is not available on this account',
    }
  }
  const toggled = [...text.matchAll(/Fast mode (ON|OFF)\b/g)]
  const last = toggled[toggled.length - 1]
  if (!last) return null
  const on = last[1] === 'ON'
  return { value: on ? 'on' : 'off', label: on ? 'On' : 'Off', source: 'screen' }
}

/** The CLI's reply to a slash command we just typed, if it has landed yet. */
export function readCommandError(screen: string): string | null {
  const text = lines(screen).join('\n')
  const patterns = [
    /Model '[^']*' not found/i,
    /Invalid argument:[^\n]*/i,
    /Unknown model '[^']*'/i,
    /Fast mode unavailable:[^\n]*/i,
    /Failed to set effort level:[^\n]*/i,
    /Not applied:[^\n]*/i,
  ]
  for (const pattern of patterns) {
    const hit = pattern.exec(text)
    if (hit) return hit[0].trim()
  }
  return null
}

/* -------------------------------------------------------------------------- */
/* Settings and transcript reading                                             */
/* -------------------------------------------------------------------------- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** `~/.claude/settings.json`, or an empty object when it is missing or broken. */
export async function readClaudeSettings(configDir = claudeConfigDir()): Promise<Record<string, unknown>> {
  try {
    const raw = await readFile(join(configDir, 'settings.json'), 'utf8')
    const parsed: unknown = JSON.parse(raw)
    return isRecord(parsed) ? parsed : {}
  } catch {
    return {}
  }
}

/**
 * Effort as persisted by the CLI.
 *
 * `ultracode: true` is a separate flag alongside `effortLevel`, so a settings
 * file reading `{ effortLevel: 'xhigh', ultracode: true }` — which is what this
 * machine actually has — means ultracode, not xhigh.
 */
export function effortFromSettings(settings: Record<string, unknown>): ControlReading {
  if (settings.ultracode === true) return { value: 'ultracode', label: 'Ultracode', source: 'settings' }
  const level = typeof settings.effortLevel === 'string' ? settings.effortLevel.toLowerCase() : ''
  const known = EFFORT_LEVELS.find((entry) => entry.id === level)
  if (!known) return { value: null, label: null, source: null }
  return { value: known.id, label: known.label, source: 'settings' }
}

/** Fast mode as persisted: "when true, fast mode is enabled; when absent or false, off". */
export function fastFromSettings(settings: Record<string, unknown>): ControlReading {
  const on = settings.fastMode === true
  return { value: on ? 'on' : 'off', label: on ? 'On' : 'Off', source: 'settings' }
}

/**
 * The model id on the newest assistant line of the project's live transcript.
 *
 * This is the strongest statement available about the current model, because it
 * is not a setting or an intention — it is the model that served the last reply.
 * Tails the file rather than parsing all of it; transcripts here run to tens of
 * megabytes and the answer is always near the end.
 */
export async function readModelFromTranscript(cwd: string): Promise<string | null> {
  const file = await newestTranscript(transcriptDir(cwd))
  if (!file) return null
  let raw: string
  try {
    raw = await readFile(file.path, 'utf8')
  } catch {
    return null
  }
  const all = raw.split('\n')
  for (let i = all.length - 1; i >= 0 && i >= all.length - 4000; i--) {
    const line = all[i].trim()
    if (line === '' || !line.includes('"model"')) continue
    try {
      const parsed: unknown = JSON.parse(line)
      if (!isRecord(parsed) || parsed.type !== 'assistant') continue
      const message = parsed.message
      if (!isRecord(message)) continue
      const model = message.model
      if (typeof model === 'string' && model.trim() !== '') return model.trim()
    } catch {
      // A partially flushed final line — keep walking back.
    }
  }
  return null
}

/**
 * Turn a raw transcript model id into something a person recognises.
 *
 * Deliberately conservative: it maps the family and says the version it saw
 * rather than pretending to know marketing names. `claude-opus-5[1m]` becomes
 * "Opus 5 · 1M" because `normalizeModelId` strips the `[1m]` tag that Claude
 * Code appends for the long-context beta, and losing that would show the same
 * label for two genuinely different context windows.
 */
export function labelModelId(raw: string): string {
  const long = /\[1m\]$/i.test(raw.trim())
  const id = normalizeModelId(raw)
  const match = /^claude-(opus|sonnet|haiku|fable)-(\d+(?:-\d+)?)/.exec(id)
  if (!match) return raw.trim()
  const family = match[1][0].toUpperCase() + match[1].slice(1)
  const version = match[2].replace(/-/g, '.')
  return `${family} ${version}${long ? ' · 1M' : ''}`
}

/* -------------------------------------------------------------------------- */
/* Reading everything                                                          */
/* -------------------------------------------------------------------------- */

const UNKNOWN: ControlReading = { value: null, label: null, source: null }

export async function readControls(
  access: SessionAccess,
  sessionId: string | undefined,
  cwd: string | undefined,
): Promise<ControlsReading> {
  const screen = sessionId ? await access.screen(sessionId) : null

  const permission = ((): ControlReading => {
    if (screen === null) return UNKNOWN
    const mode = readPermissionMode(screen)
    if (!mode) return UNKNOWN
    const entry = PERMISSION_MODES.find((m) => m.id === mode)
    return { value: mode, label: entry ? entry.label : mode, source: 'screen' }
  })()

  const model = await (async (): Promise<ControlReading> => {
    const confirmed = screen === null ? null : readModelFromScreen(screen)
    if (confirmed) return { value: confirmed, label: confirmed, source: 'screen' }
    if (!cwd) return UNKNOWN
    const raw = await readModelFromTranscript(cwd)
    if (!raw) return UNKNOWN
    return { value: raw, label: labelModelId(raw), source: 'transcript' }
  })()

  const settings = await readClaudeSettings()

  const effort = ((): ControlReading => {
    const override = process.env.CLAUDE_CODE_EFFORT_LEVEL?.trim().toLowerCase()
    if (override) {
      const known = EFFORT_LEVELS.find((entry) => entry.id === override)
      return { value: override, label: known ? known.label : override, source: 'env' }
    }
    const confirmed = screen === null ? null : readEffortFromScreen(screen)
    if (confirmed) {
      const known = EFFORT_LEVELS.find((entry) => entry.id === confirmed)
      return { value: confirmed, label: known ? known.label : confirmed, source: 'screen' }
    }
    return effortFromSettings(settings)
  })()

  const fast = ((): ControlReading => {
    const confirmed = screen === null ? null : readFastFromScreen(screen)
    if (confirmed) return confirmed
    return fastFromSettings(settings)
  })()

  return { model, effort, fast, permission, live: screen !== null }
}

/* -------------------------------------------------------------------------- */
/* Applying                                                                    */
/* -------------------------------------------------------------------------- */

/** How long to wait for the CLI to repaint after a keystroke, and how often to look. */
const POLL_MS = 120
const COMMAND_TIMEOUT_MS = 6000
const CYCLE_STEP_TIMEOUT_MS = 2500

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/** Poll the session's screen until `done` accepts it, or the deadline passes. */
async function waitForScreen<T>(
  access: SessionAccess,
  sessionId: string,
  timeoutMs: number,
  done: (screen: string) => T | null,
): Promise<T | null> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    await sleep(POLL_MS)
    const screen = await access.screen(sessionId)
    if (screen === null) return null
    const answer = done(screen)
    if (answer !== null) return answer
  }
  return null
}

/** Type a slash command into the session the way a person would. */
function sendCommand(access: SessionAccess, sessionId: string, command: string): void {
  access.write(sessionId, `${command}\r`)
}

/**
 * Step the permission cycle exactly one place and report where it landed.
 *
 * shift+tab is CSI Z (back-tab) — the byte sequence a terminal sends for that
 * chord, confirmed by driving the real CLI with it and watching the footer move.
 */
async function cycleOnce(
  access: SessionAccess,
  sessionId: string,
  from: PermissionModeId,
): Promise<PermissionModeId | null> {
  access.write(sessionId, '\x1b[Z')
  return waitForScreen(access, sessionId, CYCLE_STEP_TIMEOUT_MS, (screen) => {
    const now = readPermissionMode(screen)
    return now !== null && now !== from ? now : null
  })
}

/**
 * Move to a permission mode by cycling, checking the footer after every press.
 *
 * The cycle is the only in-session mechanism the CLI offers, but it does not
 * have to be used blind. Refusing to start when the current mode is unreadable,
 * and confirming after each press, means this either lands on the requested
 * mode or says plainly that it could not.
 *
 * The ring is also not fixed: bypass can be disabled by policy and auto can be
 * unavailable, in which case those stops simply do not appear. So the loop is
 * bounded by "we have come back to where we started" rather than by a count.
 */
async function applyPermission(
  access: SessionAccess,
  sessionId: string,
  target: string,
): Promise<{ ok: boolean; message: string; mode: PermissionModeId | null }> {
  const wanted = PERMISSION_MODES.find((mode) => mode.id === target)
  if (!wanted) return { ok: false, message: `${target} is not a permission mode this build can reach.`, mode: null }

  const screen = await access.screen(sessionId)
  if (screen === null) return { ok: false, message: 'That session is no longer running.', mode: null }

  const startedAt = readPermissionMode(screen)
  if (startedAt !== null && startedAt === wanted.id) {
    return { ok: true, message: `Already in ${wanted.label} mode.`, mode: startedAt }
  }

  // `/plan` is the one mode with a direct command — the CLI answers "Enabled
  // plan mode" — so it skips the cycle. It is tried before the unknown-mode
  // check on purpose: a command that names its destination does not care where
  // it started, so plan stays reachable even when the footer cannot be read.
  if (wanted.id === 'plan') {
    sendCommand(access, sessionId, '/plan')
    const landed = await waitForScreen(access, sessionId, COMMAND_TIMEOUT_MS, (later) => {
      const mode = readPermissionMode(later)
      return mode === 'plan' ? mode : null
    })
    if (landed) return { ok: true, message: 'Enabled plan mode.', mode: landed }
    return { ok: false, message: 'Typed /plan but the footer did not change.', mode: readPermissionMode((await access.screen(sessionId)) ?? '') }
  }

  if (startedAt === null) {
    return {
      ok: false,
      message:
        'The permission footer is not on screen, so the current mode is unknown — cycling from an unknown start would be a guess.',
      mode: null,
    }
  }

  let current: PermissionModeId = startedAt
  const start = startedAt
  const seen: PermissionModeId[] = [current]
  for (let press = 0; press < PERMISSION_MODES.length + 1; press++) {
    const next = await cycleOnce(access, sessionId, current)
    if (next === null) {
      return { ok: false, message: `Pressed shift+tab but the footer stayed on ${current}.`, mode: current }
    }
    current = next
    if (current === wanted.id) return { ok: true, message: `Switched to ${wanted.label} mode.`, mode: current }
    if (current === start) {
      return {
        ok: false,
        message: `This session's cycle only offers ${seen.join(', ')} — ${wanted.label} is not available in it.`,
        mode: current,
      }
    }
    seen.push(current)
  }
  return { ok: false, message: `Gave up cycling; the footer is on ${current}.`, mode: current }
}

/**
 * Apply one control and report what the CLI said about it.
 *
 * Success is never assumed from the fact that bytes were written. Each branch
 * waits for the CLI's own line and, failing that, says the change was typed but
 * not confirmed — which is the truth when the agent is mid-turn and the command
 * is sitting in its input queue.
 */
export async function applyControl(access: SessionAccess, request: ApplyRequest): Promise<ApplyResult> {
  const { sessionId, cwd, control, value } = request

  if ((await access.screen(sessionId)) === null) {
    return { ok: false, message: 'That session is no longer running.', reading: UNKNOWN }
  }

  if (control === 'permission') {
    const outcome = await applyPermission(access, sessionId, value)
    const entry = PERMISSION_MODES.find((mode) => mode.id === outcome.mode)
    return {
      ok: outcome.ok,
      message: outcome.message,
      reading: outcome.mode
        ? { value: outcome.mode, label: entry ? entry.label : outcome.mode, source: 'screen' }
        : UNKNOWN,
    }
  }

  if (control === 'model') {
    if (!MODEL_ALIASES.some((alias) => alias.id === value)) {
      return { ok: false, message: `${value} is not one of the aliases the CLI accepts.`, reading: UNKNOWN }
    }
    const before = readModelFromScreen((await access.screen(sessionId)) ?? '')
    sendCommand(access, sessionId, `/model ${value}`)
    const answer = await waitForScreen(access, sessionId, COMMAND_TIMEOUT_MS, (screen) => {
      const failure = readCommandError(screen)
      if (failure) return { ok: false, text: failure }
      const now = readModelFromScreen(screen)
      return now && now !== before ? { ok: true, text: now } : null
    })
    if (!answer) {
      return {
        ok: false,
        message: 'Typed /model but the CLI has not answered yet — it may be mid-turn.',
        reading: await currentModel(access, sessionId, cwd),
      }
    }
    if (!answer.ok) return { ok: false, message: answer.text, reading: await currentModel(access, sessionId, cwd) }
    return {
      ok: true,
      message: `Model is now ${answer.text}.`,
      reading: { value: answer.text, label: answer.text, source: 'screen' },
    }
  }

  if (control === 'effort') {
    if (!EFFORT_LEVELS.some((level) => level.id === value)) {
      return { ok: false, message: `${value} is not one of the levels the CLI accepts.`, reading: UNKNOWN }
    }
    sendCommand(access, sessionId, `/effort ${value}`)
    const answer = await waitForScreen(access, sessionId, COMMAND_TIMEOUT_MS, (screen) => {
      const failure = readCommandError(screen)
      if (failure) return { ok: false, text: failure }
      const now = readEffortFromScreen(screen)
      return now === value ? { ok: true, text: now } : null
    })
    const known = EFFORT_LEVELS.find((level) => level.id === value)
    if (!answer) {
      return {
        ok: false,
        message: 'Typed /effort but the CLI has not answered yet — it may be mid-turn.',
        reading: effortFromSettings(await readClaudeSettings()),
      }
    }
    if (!answer.ok) return { ok: false, message: answer.text, reading: effortFromSettings(await readClaudeSettings()) }
    return {
      ok: true,
      message: `Effort is now ${known ? known.label : value}. The CLI also saves this as the default for new sessions.`,
      reading: { value, label: known ? known.label : value, source: 'screen' },
    }
  }

  if (control === 'fast') {
    if (value !== 'on' && value !== 'off') {
      return { ok: false, message: 'Fast mode is on or off.', reading: UNKNOWN }
    }
    sendCommand(access, sessionId, `/fast ${value}`)
    const answer = await waitForScreen(access, sessionId, COMMAND_TIMEOUT_MS, (screen) => readFastFromScreen(screen))
    if (!answer) {
      return {
        ok: false,
        message: 'Typed /fast but the CLI has not answered yet — it may be mid-turn.',
        reading: fastFromSettings(await readClaudeSettings()),
      }
    }
    if (answer.unavailableReason) return { ok: false, message: answer.unavailableReason, reading: answer }
    return { ok: answer.value === value, message: `Fast mode ${answer.label}.`, reading: answer }
  }

  return { ok: false, message: `Unknown control ${String(control)}.`, reading: UNKNOWN }
}

async function currentModel(
  access: SessionAccess,
  sessionId: string,
  cwd: string | undefined,
): Promise<ControlReading> {
  const screen = await access.screen(sessionId)
  const confirmed = screen === null ? null : readModelFromScreen(screen)
  if (confirmed) return { value: confirmed, label: confirmed, source: 'screen' }
  if (!cwd) return UNKNOWN
  const raw = await readModelFromTranscript(cwd)
  return raw ? { value: raw, label: labelModelId(raw), source: 'transcript' } : UNKNOWN
}

/* -------------------------------------------------------------------------- */
/* IPC                                                                         */
/* -------------------------------------------------------------------------- */

export interface ReadRequest {
  sessionId?: string
  cwd?: string
}

export function registerAgentControlsIpc(ipcMain: IpcMain, access: SessionAccess): void {
  ipcMain.handle('agent:controls:read', (_event, request: ReadRequest) =>
    readControls(access, request?.sessionId, request?.cwd),
  )
  ipcMain.handle('agent:controls:apply', (_event, request: ApplyRequest) => applyControl(access, request))
}
