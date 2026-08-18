/**
 * What the Copilot pane asks `window.deck`, and the narrowing that turns its
 * `unknown` answers into something the pane can draw.
 *
 * A bridge of its own rather than an extension of `SettingsBridge`, following
 * `PowerSection`'s `LidAwakeBridge`: none of these channels reads or writes a
 * *setting*. They read a folder, a log and a list of automations, so routing
 * them through the settings bridge would hand the section an object whose other
 * thirty methods it has no use for and put its shapes in a file about stored
 * values.
 *
 * The method names here are the preload's, not this file's preference.
 * `src/preload/contract.test.ts` matches every `\w*Bridge\w*` interface a
 * renderer file declares against what the preload actually exposes, so a near
 * miss fails a build instead of quietly rendering the "not in this build"
 * fallback — which is the failure mode that made `browserViewClaim` look like
 * an unimplemented feature for a week.
 *
 * ## Everything is `Partial`, and that is not defensiveness
 *
 * A section that finds a method missing has to say which capability is
 * unavailable and why, in the place the control would have been. That is the
 * house rule for this pane — *a control that cannot act is disabled with a
 * reason rather than inert* — and it is only expressible if the absence is a
 * value the component can see.
 */

/* -------------------------------------------------------------- the bridge -- */

export interface CopilotBridge {
  /* the session — `src/main/copilot-session.ts` */
  copilotState(): Promise<unknown>
  ensureCopilot(): Promise<unknown>
  stopCopilot(): Promise<unknown>
  copilotSignIn(): Promise<unknown>
  copilotReadInstructions(): Promise<unknown>
  copilotWriteInstructions(text: string): Promise<unknown>
  copilotResetInstructions(): Promise<unknown>
  /* the app's half, read-only — there is no writer behind either of these */
  copilotReadContract(): Promise<unknown>
  copilotReadComposed(): Promise<unknown>

  /* its folder — `src/main/copilot-folder.ts` */
  copilotFolder(): Promise<unknown>
  copilotPickFolder(): Promise<unknown>
  copilotClearFolder(): Promise<unknown>

  /* looking at it — `src/main/copilot-inspect.ts` */
  copilotScaffold(): Promise<unknown>
  copilotMemory(): Promise<unknown>
  copilotMemoryRead(name: string): Promise<unknown>
  copilotMemoryWrite(name: string, text: string): Promise<unknown>
  copilotMemoryDelete(name: string): Promise<unknown>
  copilotActions(limit?: number): Promise<unknown>
  copilotReveal(place: string): Promise<unknown>

  /**
   * The one stored value this pane owns: whether the scan is put on the screen.
   *
   * The section's header says it holds no settings, and for everything else that
   * is still true — every other block reads a folder, a log or a list. This one
   * is here because the thing it switches has no other home: `copilot.interactive`
   * decides whether driving mode *shows* itself, and driving mode is the copilot.
   * Putting it in Appearance or General would file it under the surface it paints
   * rather than under the agent it belongs to, which is the rule the settings
   * schema builds its whole rail on — a section is a subject.
   *
   * The generic settings channels rather than a copilot-shaped pair, because the
   * value lives in `settings.json` with everything else and is written the same
   * way. `SettingsWindow` deliberately hands this section no `values` and no
   * `save` (see `CopilotSectionView`), so it reads and writes them itself.
   */
  getSettings(): Promise<unknown>
  setSettings(patch: Record<string, unknown>): Promise<unknown>

  /* routines — `src/main/routines/ipc.ts` */
  routinesList(): Promise<unknown>
  routinesText(id: string): Promise<unknown>
  /**
   * Replace a routine file with the exact text somebody typed.
   *
   * The one method on this bridge with no counterpart in `deck-control`, and
   * that is the point rather than an omission: routines live outside the
   * copilot's writable folder precisely so that authoring one takes a human, and
   * writing chosen bytes into that folder is wider than any tool the copilot
   * could be given. `routines/ipc.ts` marks the operation `human` and says why.
   * A window is a person; this is the door for one.
   */
  routinesSaveText(id: string, text: string): Promise<unknown>
  routinesRun(id: string): Promise<unknown>
  routinesPause(id: string, reason?: string): Promise<unknown>
  routinesResume(id: string): Promise<unknown>
  routinesDelete(id: string): Promise<unknown>
}

const BRIDGE_METHODS: ReadonlyArray<keyof CopilotBridge> = [
  'copilotState',
  'ensureCopilot',
  'stopCopilot',
  'copilotSignIn',
  'copilotReadInstructions',
  'copilotWriteInstructions',
  'copilotResetInstructions',
  'copilotReadContract',
  'copilotReadComposed',
  'copilotFolder',
  'copilotPickFolder',
  'copilotClearFolder',
  'copilotScaffold',
  'copilotMemory',
  'copilotMemoryRead',
  'copilotMemoryWrite',
  'copilotMemoryDelete',
  'copilotActions',
  'copilotReveal',
  'getSettings',
  'setSettings',
  'routinesList',
  'routinesText',
  'routinesSaveText',
  'routinesRun',
  'routinesPause',
  'routinesResume',
  'routinesDelete',
]

/**
 * The bridge as it actually exists, each method called through its host.
 *
 * `globalThis` rather than `window`, and the methods wrapped rather than torn
 * off, for the two reasons the other bridges in this folder give: this file is
 * read as a string in tests that have no window, and a preload whose functions
 * live on a prototype throws on `this` the first time a button is pressed —
 * which only ever surfaces in a packaged build.
 */
export function resolveCopilotBridge(host?: unknown): Partial<CopilotBridge> {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as Partial<CopilotBridge>
}

/* ----------------------------------------------------------------- shapes -- */

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function str(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

function optStr(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

function bool(value: unknown, fallback = false): boolean {
  return typeof value === 'boolean' ? value : fallback
}

function optNum(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function num(value: unknown, fallback = 0): number {
  return optNum(value) ?? fallback
}

function list(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function strings(value: unknown): string[] {
  return list(value).filter((entry): entry is string => typeof entry === 'string')
}

/* ----------------------------------------------------------- the session -- */

/** Mirrors `StartupFile` in `src/main/copilot-home.ts`. */
export interface StartupFile {
  path: string
  purpose: string
  exists: boolean
  size: number | null
  modifiedAt: number | null
  /** Whose file it is: this app's, the person's, or the working folder's. */
  owner: 'app' | 'yours' | 'folder'
}

/** Mirrors `CopilotFolderReport` in `src/main/copilot-folder.ts`. */
export interface CopilotFolder {
  home: string
  chosen: string | null
  isDefault: boolean
  problem: string | null
  runningIn: string | null
  restartNeeded: boolean
}

/** Mirrors `FolderChangeResult` in `src/main/copilot-folder.ts`. */
export interface FolderChange {
  folder: CopilotFolder | null
  problem: string | null
  cancelled: boolean
}

export function toCopilotFolder(raw: unknown): CopilotFolder | null {
  const entry = record(raw)
  if (!entry || typeof entry.home !== 'string') return null
  return {
    home: entry.home,
    chosen: optStr(entry.chosen),
    // Defaults to true, and the direction is the safe one: `isDefault` gates
    // every sentence claiming the copilot is working inside somebody's own
    // workspace, and a build that could not read the field must not claim it.
    isDefault: entry.isDefault !== false,
    problem: optStr(entry.problem),
    runningIn: optStr(entry.runningIn),
    restartNeeded: bool(entry.restartNeeded),
  }
}

export function toFolderChange(raw: unknown): FolderChange {
  const entry = record(raw)
  if (!entry) return { folder: null, problem: 'That did not work.', cancelled: false }
  return {
    folder: toCopilotFolder(entry.report),
    problem: optStr(entry.problem),
    cancelled: bool(entry.cancelled),
  }
}

/** Mirrors `LayerReadResult` in `src/main/copilot-layer.ts`. */
export interface LayerRead {
  text: string | null
  path: string
  error: string | null
}

export function toLayerRead(raw: unknown): LayerRead {
  const entry = record(raw)
  if (!entry) return { text: null, path: '', error: 'This build could not read that file.' }
  return {
    text: typeof entry.text === 'string' ? entry.text : null,
    path: str(entry.path),
    error: optStr(entry.error),
  }
}

/** Mirrors `InstructionsState` in `src/main/copilot-home.ts`. */
export type InstructionsState = 'missing' | 'current' | 'superseded' | 'edited'

export type CopilotStatus = 'stopped' | 'starting' | 'running'

/** Mirrors `CopilotRecords` in `src/main/copilot-session.ts`. */
export interface CopilotRecords {
  kind: string
  enforced: boolean
  reason: string | null
  paths: string[]
}

/** Mirrors `CopilotState` in `src/main/copilot-session.ts`. */
export interface CopilotState {
  status: CopilotStatus
  sessionId: string | null
  paths: {
    root: string
    ownFolder: boolean
    instructions: string
    memory: string
    log: string
    actions: string
    layer: { dir: string; yours: string; contract: string; composed: string }
  }
  folder: CopilotFolder | null
  home: string
  startedAt: number | null
  problem: string | null
  records: CopilotRecords
  profile: { id: string; name: string } | null
  instructionsAreDefault: boolean
  instructions: InstructionsState
  startupFiles: StartupFile[]
  layerFiles: StartupFile[]
}

function toStartupFile(raw: unknown): StartupFile | null {
  const entry = record(raw)
  if (!entry || typeof entry.path !== 'string') return null
  return {
    path: entry.path,
    purpose: str(entry.purpose),
    exists: bool(entry.exists),
    size: optNum(entry.size),
    modifiedAt: optNum(entry.modifiedAt),
    // `folder` is the default because it is the only value that promises
    // nothing: a row this build cannot classify is drawn as one of the working
    // directory's, which is a file the app does not claim to have written.
    owner: entry.owner === 'app' || entry.owner === 'yours' ? entry.owner : 'folder',
  }
}

function toInstructionsState(value: unknown): InstructionsState {
  return value === 'current' || value === 'superseded' || value === 'edited' ? value : 'missing'
}

export function toCopilotState(raw: unknown): CopilotState | null {
  const entry = record(raw)
  if (!entry) return null
  const paths = record(entry.paths)
  if (!paths || typeof paths.root !== 'string') return null
  const records = record(entry.records)
  const profile = record(entry.profile)
  const status = entry.status
  return {
    status: status === 'running' || status === 'starting' ? status : 'stopped',
    sessionId: optStr(entry.sessionId),
    paths: {
      root: paths.root,
      ownFolder: paths.ownFolder !== false,
      instructions: str(paths.instructions),
      memory: str(paths.memory),
      log: str(paths.log),
      actions: str(paths.actions),
      layer: {
        dir: str(record(paths.layer)?.dir),
        yours: str(record(paths.layer)?.yours),
        contract: str(record(paths.layer)?.contract),
        composed: str(record(paths.layer)?.composed),
      },
    },
    folder: toCopilotFolder(entry.folder),
    home: str(entry.home),
    startedAt: optNum(entry.startedAt),
    problem: optStr(entry.problem),
    records: {
      kind: str(records?.kind, 'none'),
      // Defaults to false rather than true, and the direction matters: this
      // boolean feeds the sentence "the routines and the action log are held
      // against it", so a build that could not read the field must say no.
      enforced: bool(records?.enforced),
      reason: optStr(records?.reason),
      paths: strings(records?.paths),
    },
    profile:
      profile && typeof profile.id === 'string'
        ? { id: profile.id, name: str(profile.name, profile.id) }
        : null,
    instructionsAreDefault: bool(entry.instructionsAreDefault),
    instructions: toInstructionsState(entry.instructions),
    startupFiles: list(entry.startupFiles)
      .map(toStartupFile)
      .filter((file): file is StartupFile => file !== null),
    layerFiles: list(entry.layerFiles)
      .map(toStartupFile)
      .filter((file): file is StartupFile => file !== null),
  }
}

/** Mirrors `CopilotSignIn` in `src/main/copilot-session.ts`. */
export interface CopilotSignIn {
  state: 'signed-in' | 'signed-out' | 'unknown'
  account: string | null
  plan: string | null
  /** Which account this answer is about — the profile the copilot runs as. */
  profileId: string
  profileName: string
  checkedAt: number
}

export function toCopilotSignIn(raw: unknown): CopilotSignIn | null {
  const entry = record(raw)
  if (!entry) return null
  const state = entry.state
  return {
    state: state === 'signed-in' || state === 'signed-out' ? state : 'unknown',
    account: optStr(entry.account),
    plan: optStr(entry.plan),
    profileId: str(entry.profileId),
    profileName: str(entry.profileName),
    checkedAt: num(entry.checkedAt),
  }
}

/** Mirrors `ResetResult` in `src/main/copilot-home.ts`, plus the state it returns with. */
export interface InstructionsResetResult {
  reset: boolean
  backup: string | null
  error: string | null
  state: CopilotState | null
}

export function toResetResult(raw: unknown): InstructionsResetResult {
  const entry = record(raw)
  return {
    reset: bool(entry?.reset),
    backup: optStr(entry?.backup),
    error: optStr(entry?.error),
    state: toCopilotState(entry?.state),
  }
}

/** Mirrors `InstructionsReadResult` in `src/main/copilot-home.ts`. */
export type InstructionsReadResult =
  | { ok: true; text: string; state: InstructionsState }
  | { ok: false; error: string }

export function toInstructionsRead(raw: unknown): InstructionsReadResult {
  const entry = record(raw)
  /*
   * `ok === true` *and* a string, rather than either alone.
   *
   * A frame that answered `{ ok: true }` with no text would otherwise put an
   * empty box in front of somebody over a file that is not empty — and the
   * button under that box saves what is in it. The failure branch is the safe
   * one to fall into, because it disables the save and prints a sentence.
   */
  if (entry?.ok === true && typeof entry.text === 'string') {
    return { ok: true, text: entry.text, state: toInstructionsState(entry.state) }
  }
  return { ok: false, error: str(entry?.error, 'Its instructions could not be read.') }
}

/** Mirrors `InstructionsWriteResult` in `src/main/copilot-home.ts`, plus the state. */
export interface InstructionsWriteResult {
  saved: boolean
  backup: string | null
  error: string | null
  state: CopilotState | null
}

export function toInstructionsWrite(raw: unknown): InstructionsWriteResult {
  const entry = record(raw)
  return {
    saved: bool(entry?.saved),
    backup: optStr(entry?.backup),
    error: optStr(entry?.error),
    state: toCopilotState(entry?.state),
  }
}

/** Mirrors `ScaffoldResult` in `src/main/copilot-home.ts`. */
export interface ScaffoldResult {
  created: string[]
  removed: string[]
  error: string | null
}

export function toScaffoldResult(raw: unknown): ScaffoldResult {
  const entry = record(raw)
  return {
    created: strings(entry?.created),
    removed: strings(entry?.removed),
    error: optStr(entry?.error),
  }
}

/** Mirrors `RevealResult` in `src/main/copilot-inspect.ts`. */
export function toRevealMessage(raw: unknown): string {
  const entry = record(raw)
  return str(entry?.message, 'Nothing happened.')
}

/* ------------------------------------------------------------- the showing -- */

/** The key `main/deck-control/tour-tool.ts` reads before it stages a scan. */
export const INTERACTIVE_SETTING = 'copilot.interactive'

/**
 * Whether the scan is put on the screen, read exactly as the main process reads
 * it.
 *
 * **Anything other than an explicit `false` is on**, which is `interactiveDriving`
 * in `tour-tool.ts` character for character, and the agreement is the whole
 * point: the setting is not in the settings *schema* — the Copilot pane is not
 * given this window's settings bridge, so there is no schema row to carry a
 * default — and `settings-extra.ts` keeps keys it does not know without filling
 * one in. So the default lives in whoever reads the value, and two readers with
 * two defaults would put a switch on screen that disagrees with the behaviour it
 * describes.
 *
 * It handles the envelope and the bare map for the same reason `toStoredSettings`
 * does: `settings:get` answers with `{ version, values }` and older builds
 * answered with the map itself.
 */
export function toInteractiveDriving(raw: unknown): boolean {
  const entry = record(raw)
  const values = record(entry?.values) ?? entry
  return values?.[INTERACTIVE_SETTING] !== false
}

/* ------------------------------------------------------------------ memory -- */

/** Mirrors `MemoryFact` in `src/main/copilot-inspect.ts`. */
export interface MemoryFact {
  name: string
  path: string
  bytes: number
  modifiedAt: number
  description: string | null
  type: string | null
  scope: string | null
  verified: string | null
  index: boolean
}

/** Mirrors `MemoryReport` in `src/main/copilot-inspect.ts`. */
export interface MemoryReport {
  dir: string
  exists: boolean
  facts: MemoryFact[]
  error: string | null
}

export function toMemoryReport(raw: unknown): MemoryReport | null {
  const entry = record(raw)
  if (!entry || typeof entry.dir !== 'string') return null
  return {
    dir: entry.dir,
    exists: bool(entry.exists),
    error: optStr(entry.error),
    facts: list(entry.facts).flatMap((item) => {
      const fact = record(item)
      if (!fact || typeof fact.name !== 'string') return []
      return [
        {
          name: fact.name,
          path: str(fact.path),
          bytes: num(fact.bytes),
          modifiedAt: num(fact.modifiedAt),
          description: optStr(fact.description),
          type: optStr(fact.type),
          scope: optStr(fact.scope),
          verified: optStr(fact.verified),
          index: bool(fact.index),
        },
      ]
    }),
  }
}

export type MemoryReadResult =
  | { ok: true; name: string; text: string; truncated: boolean }
  | { ok: false; error: string }

export function toMemoryRead(raw: unknown): MemoryReadResult {
  const entry = record(raw)
  if (entry?.ok === true && typeof entry.text === 'string') {
    return { ok: true, name: str(entry.name), text: entry.text, truncated: bool(entry.truncated) }
  }
  return { ok: false, error: str(entry?.error, 'That file could not be read.') }
}

export interface MemoryDeleteResult {
  ok: boolean
  error: string | null
  memory: MemoryReport | null
}

export function toMemoryDelete(raw: unknown): MemoryDeleteResult {
  const entry = record(raw)
  return {
    ok: bool(entry?.ok),
    error: optStr(entry?.error),
    memory: toMemoryReport(entry?.memory),
  }
}

/**
 * Mirrors `MemoryWriteResult` in `src/main/copilot-inspect.ts`.
 *
 * Identical in shape to the delete, and kept as its own name rather than shared,
 * because the two results are read into two different sentences and a shared
 * alias is how one of them ends up saying "forgotten" about a save.
 */
export type MemoryWriteResult = MemoryDeleteResult

export function toMemoryWrite(raw: unknown): MemoryWriteResult {
  return toMemoryDelete(raw)
}

/* -------------------------------------------------------------- action log -- */

/** Mirrors `LoggedAction` in `src/main/copilot-inspect.ts`. */
export interface LoggedAction {
  at: string
  action: string
  detail: string
  tool: string | null
  tier: string | null
  outcome: 'ok' | 'refused' | 'error' | null
  confirmationRequired: boolean | null
  confirmed: boolean | null
  confirmedBy: string | null
  refusedReason: string | null
  caller: 'local' | 'remote' | null
  ms: number | null
  error: string | null
  sessionId: string | null
}

/** Mirrors `ActionLogReport` in `src/main/copilot-inspect.ts`. */
export interface ActionLogReport {
  dir: string
  file: string
  exists: boolean
  bytes: number
  outsideCopilotFolder: boolean
  rows: LoggedAction[]
  more: boolean
  error: string | null
}

function toOutcome(value: unknown): LoggedAction['outcome'] {
  return value === 'ok' || value === 'refused' || value === 'error' ? value : null
}

function optBool(value: unknown): boolean | null {
  return typeof value === 'boolean' ? value : null
}

export function toActionLog(raw: unknown): ActionLogReport | null {
  const entry = record(raw)
  if (!entry || typeof entry.file !== 'string') return null
  return {
    dir: str(entry.dir),
    file: entry.file,
    exists: bool(entry.exists),
    bytes: num(entry.bytes),
    // As with `enforceable` above: the safe default is the one that does not
    // make a claim. This feeds the sentence "the copilot cannot write it".
    outsideCopilotFolder: bool(entry.outsideCopilotFolder),
    more: bool(entry.more),
    error: optStr(entry.error),
    rows: list(entry.rows).flatMap((item) => {
      const row = record(item)
      if (!row || typeof row.at !== 'string' || typeof row.action !== 'string') return []
      return [
        {
          at: row.at,
          action: row.action,
          detail: str(row.detail),
          tool: optStr(row.tool),
          tier: optStr(row.tier),
          outcome: toOutcome(row.outcome),
          confirmationRequired: optBool(row.confirmationRequired),
          confirmed: optBool(row.confirmed),
          confirmedBy: optStr(row.confirmedBy),
          refusedReason: optStr(row.refusedReason),
          caller: row.caller === 'local' || row.caller === 'remote' ? row.caller : null,
          ms: optNum(row.ms),
          error: optStr(row.error),
          sessionId: optStr(row.sessionId),
        },
      ]
    }),
  }
}

/* ---------------------------------------------------------------- routines -- */

export type RoutineStateName =
  | 'armed'
  | 'running'
  | 'disabled'
  | 'broken'
  | 'unarmed'
  | 'paused'
  | 'stale'

/** Mirrors the half of `RoutineView` (`src/main/routines/engine.ts`) this pane draws. */
export interface RoutineRow {
  id: string
  name: string
  file: string
  folder: string | null
  triggers: string[]
  prompt: string
  enabled: boolean
  state: RoutineStateName
  reason: string | null
  problems: string[]
  warnings: string[]
  lastRunAt: number | null
  lastFinishedAt: number | null
  lastOutcome: 'ok' | 'failed' | null
  lastError: string | null
  consecutiveFailures: number
  running: boolean
  runsLastHour: number
  runsLastDay: number
  /** When a paused routine recovers on its own. Null when a person has to act. */
  pausedUntil: number | null
  nextDueAt: number | null
  missedWhileClosed: number
  /** Refusals its runs hit — almost always an alter call with nobody at the machine. */
  refusedCalls: Array<{ at: number; tool: string; reason: string }>
}

const ROUTINE_STATES: readonly RoutineStateName[] = [
  'armed',
  'running',
  'disabled',
  'broken',
  'unarmed',
  'paused',
  'stale',
]

/** Mirrors `RoutineApi.text` in `src/main/routines/ipc.ts`. */
export type RoutineTextResult =
  | { ok: true; text: string; file: string }
  | { ok: false; problems: string[] }

export function toRoutineText(raw: unknown): RoutineTextResult {
  const entry = record(raw)
  // Same argument as `toInstructionsRead`: an `ok` with no text would show an
  // empty box over a file that has something in it, above a Save button.
  if (entry?.ok === true && typeof entry.text === 'string') {
    return { ok: true, text: entry.text, file: str(entry.file) }
  }
  const problems = strings(entry?.problems)
  return { ok: false, problems: problems.length > 0 ? problems : ['That routine could not be read.'] }
}

/** Mirrors `WriteResult` in `src/main/routines/ipc.ts`. */
export type RoutineWriteResult = { ok: true; id: string } | { ok: false; problems: string[] }

export function toRoutineWrite(raw: unknown): RoutineWriteResult {
  const entry = record(raw)
  if (entry?.ok === true) return { ok: true, id: str(entry.id) }
  const problems = strings(entry?.problems)
  return { ok: false, problems: problems.length > 0 ? problems : ['That routine could not be saved.'] }
}

export function toRoutineRows(raw: unknown): RoutineRow[] {
  return list(raw).flatMap((item) => {
    const view = record(item)
    if (!view || typeof view.id !== 'string') return []
    const state = ROUTINE_STATES.find((name) => name === view.state) ?? 'unarmed'
    const outcome = view.lastOutcome
    return [
      {
        id: view.id,
        name: str(view.name, view.id),
        file: str(view.file),
        folder: optStr(view.folder),
        triggers: strings(view.triggers),
        prompt: str(view.prompt),
        enabled: bool(view.enabled, true),
        state,
        reason: optStr(view.reason),
        problems: strings(view.problems),
        warnings: strings(view.warnings),
        lastRunAt: optNum(view.lastRunAt),
        lastFinishedAt: optNum(view.lastFinishedAt),
        lastOutcome: outcome === 'ok' || outcome === 'failed' ? outcome : null,
        lastError: optStr(view.lastError),
        consecutiveFailures: num(view.consecutiveFailures),
        running: bool(view.running),
        runsLastHour: num(view.runsLastHour),
        runsLastDay: num(view.runsLastDay),
        pausedUntil: optNum(view.pausedUntil),
        nextDueAt: optNum(view.nextDueAt),
        missedWhileClosed: num(view.missedWhileClosed),
        refusedCalls: list(view.refusedCalls).flatMap((entry) => {
          const refusal = record(entry)
          if (!refusal || typeof refusal.tool !== 'string') return []
          return [{ at: num(refusal.at), tool: refusal.tool, reason: str(refusal.reason) }]
        }),
      },
    ]
  })
}
