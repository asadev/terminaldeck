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
  port: number | null
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
      port: typeof endpoint?.port === 'number' ? endpoint.port : null,
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
 * ours and sitting in the file, but it points at the port and token of a
 * previous run, so it fires into nothing. Counting it would put "All hooks
 * installed" above a block that reports nothing at all.
 */
export function hookSummary(block: SetupHookBlock): string {
  if (block.state === 'unsupported') return 'Not supported'
  if (block.state === 'error') return 'Could not be read'
  const total = block.events.length
  const installed = block.installedEvents.length
  const stale = block.staleEvents.length
  if (total > 0 && installed === total) return 'All hooks installed'
  if (installed === 0 && stale === 0) return 'Not installed'
  // Without the second half this read "0 of 10 installed" directly above
  // "Installed, but 10 events still point at a previous run" — two true
  // sentences that look like a contradiction.
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
