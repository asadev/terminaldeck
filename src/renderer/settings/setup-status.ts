/**
 * The Setup panel's half of the `setup:status` contract.
 *
 * Everything crosses the bridge as `unknown` — the main-process modules own
 * their types, and duplicating them in `shared/types.ts` is how the two drift —
 * so `src/main/setup.ts`'s shapes are mirrored here and parsed on arrival, the
 * way `settings-bridge.ts` mirrors the rest.
 *
 * The wording lives here too, not in the component: "3 of 5 installed" is a
 * sentence with rules (what counts as installed, what a stale entry counts as,
 * what a tool with no hooks at all says) and rules that can be tested belong
 * where a test can reach them without a DOM.
 */

import { asRecord } from './settings-bridge'

/* ------------------------------------------------------------- mirrored -- */

export type ToolState = 'ready' | 'installed-not-authed' | 'missing' | 'unknown'

export interface SetupProbe {
  /** The command that was run, e.g. `which copilot`. */
  command: string
  /** What the shell said, verbatim when it said anything. */
  line: string
}

export interface SetupTool {
  id: string
  label: string
  state: ToolState
  version?: string
  /** One line: what this tool is needed for. */
  purpose: string
  /** What to do about it, when something is wrong. */
  remedy?: string
  /** True even when nothing is wrong — a caveat, not a fix. */
  note: string | null
  url?: string
  /** Present only for a tool that could not be found. */
  probe: SetupProbe | null
}

export type SetupHookState =
  | 'none'
  | 'partial'
  | 'complete'
  | 'stale'
  | 'error'
  | 'unsupported'

export interface SetupHookBlock {
  id: string
  label: string
  state: SetupHookState
  unsupportedReason: string | null
  events: string[]
  installedEvents: string[]
  staleEvents: string[]
  missingEvents: string[]
  file: string | null
  fileExists: boolean
  foreignHooks: number
  foreignOwners: string[]
  message: string
  requirement: string | null
}

export interface SetupEndpoint {
  running: boolean
  /** The socket path, or null when it is not listening. Never the token. */
  address: string | null
}

export interface SetupSnapshot {
  tools: SetupTool[]
  canRunSessions: boolean
  needsLogin: boolean
  hooks: SetupHookBlock[]
  endpoint: SetupEndpoint
  checkedAt: number
}

/** Mirrors `HookWriteResult` in `src/main/hooks.ts`, minus the status it repeats. */
export interface HookWriteOutcome {
  ok: boolean
  message: string
}

/* ------------------------------------------------------------ narrowing -- */

function asString(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

function asOptionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

function asBoolean(value: unknown, fallback = false): boolean {
  return typeof value === 'boolean' ? value : fallback
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string') : []
}

const TOOL_STATES = new Set<string>(['ready', 'installed-not-authed', 'missing', 'unknown'])
const HOOK_STATES = new Set<string>(['none', 'partial', 'complete', 'stale', 'error', 'unsupported'])

function toProbe(raw: unknown): SetupProbe | null {
  const record = asRecord(raw)
  if (!record || typeof record.line !== 'string' || record.line === '') return null
  return { command: asString(record.command), line: record.line }
}

function toTool(raw: unknown): SetupTool[] {
  const record = asRecord(raw)
  if (!record || typeof record.id !== 'string') return []
  return [
    {
      id: record.id,
      label: asString(record.label, record.id),
      state: TOOL_STATES.has(asString(record.state)) ? (record.state as ToolState) : 'unknown',
      version: asOptionalString(record.version),
      purpose: asString(record.purpose),
      remedy: asOptionalString(record.remedy),
      note: asOptionalString(record.note) ?? null,
      url: asOptionalString(record.url),
      probe: toProbe(record.probe),
    },
  ]
}

function toHookBlock(raw: unknown): SetupHookBlock[] {
  const record = asRecord(raw)
  if (!record || typeof record.id !== 'string') return []
  return [
    {
      id: record.id,
      label: asString(record.label, record.id),
      state: HOOK_STATES.has(asString(record.state)) ? (record.state as SetupHookState) : 'error',
      unsupportedReason: asOptionalString(record.unsupportedReason) ?? null,
      events: asStrings(record.events),
      installedEvents: asStrings(record.installedEvents),
      staleEvents: asStrings(record.staleEvents),
      missingEvents: asStrings(record.missingEvents),
      file: asOptionalString(record.file) ?? null,
      fileExists: asBoolean(record.fileExists),
      foreignHooks: typeof record.foreignHooks === 'number' ? record.foreignHooks : 0,
      foreignOwners: asStrings(record.foreignOwners),
      message: asString(record.message),
      requirement: asOptionalString(record.requirement) ?? null,
    },
  ]
}

export function toSetupSnapshot(raw: unknown): SetupSnapshot | null {
  const record = asRecord(raw)
  if (!record || !Array.isArray(record.tools)) return null
  const endpoint = asRecord(record.endpoint)
  return {
    tools: record.tools.flatMap(toTool),
    canRunSessions: asBoolean(record.canRunSessions),
    needsLogin: asBoolean(record.needsLogin),
    hooks: Array.isArray(record.hooks) ? record.hooks.flatMap(toHookBlock) : [],
    endpoint: {
      running: asBoolean(endpoint?.running),
      address: typeof endpoint?.address === 'string' && endpoint.address !== '' ? endpoint.address : null,
    },
    checkedAt: typeof record.checkedAt === 'number' ? record.checkedAt : 0,
  }
}

/**
 * An install or remove, reduced to what the panel says about it.
 *
 * `ok: false` is the normal way `hooks.ts` reports a config it refused to
 * rewrite, so a result with no `ok` at all is treated as a failure rather than
 * quietly congratulating the user on a write that may not have happened.
 */
export function toHookWriteOutcome(raw: unknown): HookWriteOutcome {
  const record = asRecord(raw)
  return {
    ok: record?.ok === true,
    message: asString(record?.message, 'The change was made, but nothing was reported back.'),
  }
}

/* ----------------------------------------------------------- the wording -- */

/** The word on the right of a tool row. */
export const TOOL_STATE_LABEL: Record<ToolState, string> = {
  ready: 'Installed',
  'installed-not-authed': 'Sign in needed',
  missing: 'Not found',
  unknown: 'Unknown',
}

/**
 * The version chip beside a tool's name — or nothing, where nothing is honest.
 *
 * `prerequisites.ts` reads a version by running `<bin> --version` with a closed
 * stdin and a four-second cap, and reports a failure or a timeout as no version
 * at all. So a tool can be found on PATH and still have none, which is exactly
 * what Codex does on this machine: `codex` resolves to a Homebrew shim whose
 * vendored binary is missing, so `--version` errors and the row printed the
 * name with a blank where Claude Code and Gemini both print a number.
 *
 * That blank read as a rendering bug. It is a finding: something about that
 * install does not work. So the row says so, in the same slot, rather than
 * leaving the reader to notice an absence.
 */
export const NO_VERSION = 'version not reported'

export const NO_VERSION_HINT =
  'Found on PATH, but it did not answer when asked for its version — usually a broken or partial install.'

/**
 * A `--version` line says more than a version, and the extra is usually the
 * tool's own name.
 *
 * `claude --version` prints `2.1.233 (Claude Code)`, so a row headed
 * "Claude Code" read **Claude Code  2.1.233 (Claude Code)** — the product named
 * twice on one line, with the second one in the mono face reserved for data.
 * Only a trailing parenthetical that repeats the label is dropped; a
 * parenthetical saying something else (a build tag, a channel) is information
 * and stays.
 */
function trimRepeatedName(version: string, label?: string): string {
  if (!label) return version
  const match = /^(.*?)\s*\(([^()]*)\)$/.exec(version)
  if (!match) return version
  const normalise = (text: string): string => text.toLowerCase().replace(/[^a-z0-9]/g, '')
  if (normalise(match[2]) !== normalise(label)) return version
  return match[1].trim() || version
}

export function toolVersionLabel(tool: {
  state: ToolState
  version?: string
  label?: string
}): string | null {
  if (tool.version) return trimRepeatedName(tool.version, tool.label)
  // Nothing was found to ask, so there is nothing to report and no finding.
  if (tool.state === 'missing') return null
  return NO_VERSION
}

/** The state of one event inside a provider's block. */
export type EventState = 'installed' | 'stale' | 'missing'

export function eventState(block: SetupHookBlock, event: string): EventState {
  if (block.installedEvents.includes(event)) return 'installed'
  if (block.staleEvents.includes(event)) return 'stale'
  return 'missing'
}

/**
 * The one-line state of a provider's hooks.
 *
 * A stale entry is deliberately *not* counted as installed: it is tagged as
 * ours and sitting in the file, but it is aimed somewhere other than this app's
 * endpoint, so it fires into nothing. Counting it would put "All hooks
 * installed" above a block that reports nothing at all.
 *
 * That rule has one shape it must not be applied to literally. When *every*
 * entry is stale, arithmetic gives "0 of 10 installed · 10 out of date", which
 * is a pair of numbers nobody can hold at once: ten entries are out of date, and
 * none is installed, so where did the ten come from? It was printed directly
 * above the block's own sentence, which says the opposite in words. Both were
 * derived from the same two arrays, so neither was wrong; the count was simply
 * answering a question ("how many are live?") in a form that reads as an answer
 * to a different one ("how many are there?").
 *
 * All-stale used to be the ordinary state of every machine, because the endpoint
 * took a new port on each launch and the port was written into the command. It
 * is now the rare case it was always meant to be — see `hook-server.ts` — but
 * the wording stays, because "rare" is not "impossible" and an older install
 * still lands here exactly once.
 *
 * So the all-stale case is named rather than counted, and the count is kept for
 * the mixed case, where "3 of 10 installed · 7 out of date" adds up to the ten
 * on screen and nothing has to be reconciled.
 */
export function hookSummary(block: SetupHookBlock): string {
  if (block.state === 'unsupported') return 'Not supported'
  if (block.state === 'error') return 'Could not be read'
  const total = block.events.length
  const installed = block.installedEvents.length
  const stale = block.staleEvents.length
  if (total > 0 && installed === total) return 'All hooks installed'
  if (installed === 0 && stale === 0) return 'Not installed'
  if (installed === 0) {
    // Present, ours, and aimed at something that is not this app's endpoint.
    // "Out of date" is the same word the event chips underneath carry, so the
    // heading and the ten marks below it are saying one thing.
    return stale === total ? 'All hooks out of date' : `${stale} of ${total} out of date`
  }
  const count = `${installed} of ${total} installed`
  return stale > 0 ? `${count} · ${stale} out of date` : count
}

/** What somebody else's hooks in the same file get told about themselves. */
export function foreignNote(block: SetupHookBlock): string | null {
  if (block.foreignHooks < 1) return null
  const owners = block.foreignOwners.length > 0 ? block.foreignOwners.join(' and ') : 'another app'
  const count = block.foreignHooks === 1 ? '1 hook' : `${block.foreignHooks} hooks`
  return `${count} from ${owners} also live in this file. Nothing here ever touches them.`
}

/** Whether the three buttons can do anything, given the state on disk. */
export function hookActions(block: SetupHookBlock, endpointRunning: boolean): {
  install: boolean
  repair: boolean
  remove: boolean
} {
  // 'error' is a settings file we could not parse, which `hooks.ts` refuses to
  // rewrite on purpose. Every button would fail with the same message the block
  // is already showing, so none of them is offered.
  if (block.state === 'unsupported' || block.state === 'error') {
    return { install: false, repair: false, remove: false }
  }
  const present = block.installedEvents.length + block.staleEvents.length > 0
  return {
    // Writing needs somewhere to point: with no endpoint, `installHooks` refuses
    // and says so, and a button that can only fail is worse than a disabled one.
    install: endpointRunning && !present,
    repair: endpointRunning && present,
    remove: present || block.state === 'partial',
  }
}
