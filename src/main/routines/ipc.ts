/**
 * The routine channels.
 *
 * These are the same operations `COPILOT-DESIGN.md` lists for the `deck-control`
 * MCP server — `routines.list`, `routines.create`, `routines.delete` — plus the
 * two that surface the engine's own state. Wired here first, and deliberately:
 * the MCP server in phase 2 should call {@link RoutineApi} rather than reach
 * into the engine, so a tool call and a click go through one implementation
 * with one set of checks.
 *
 * ## The tier every operation belongs to
 *
 * The design document splits the copilot's powers into Read (always allowed),
 * Act (allowed and logged) and Alter (**confirmed in the UI**, logged). The
 * split maps onto these calls exactly, and it is recorded here in code because
 * the phase-2 server will need it and a table in a document is not a check:
 *
 *  - Read: `list`, `get`
 *  - Act:  `run`, `pause`, `resume`
 *  - Alter: `create`, `update`, `remove`
 *
 * Nothing in this file enforces the confirmation — a confirmation is a window,
 * and a window is a later pass. What it does do is refuse to pretend: every
 * Alter operation is marked, so the surface that gets built on top of it cannot
 * quietly skip the ones that need asking.
 *
 * ## This is now the *only* way a routine comes into existence
 *
 * It was not, briefly. The routines folder lived inside `<userData>/copilot/`,
 * which is the one directory the copilot session can write to, so the copilot
 * could author a routine file directly and the engine would pick it up and run
 * it — the Alter marking above describing a gate that a `Write` walked around.
 * `store.ts` explains the move and `copilot-writable-boundary.test.ts` proves
 * the kernel now refuses that write.
 *
 * Which puts the weight on this file. Two callers reach these operations and
 * both are gated, differently:
 *
 *  - **`registerRoutinesIpc`** — a person clicking in the app. The click *is*
 *    the confirmation; there is nobody else to ask.
 *  - **`deck-control`** — the copilot, when `routines.create` and friends are
 *    added to `catalogue.ts`. Declare them `tier: 'alter'` and the consent gate,
 *    the budgets and the action log all apply with no code here: `control.ts` is
 *    the only door, and it holds a contributed tool to exactly the same rules as
 *    a built-in one. A routine tool declared `act` to save a dialog would put
 *    the hole back, in a place where it is much harder to see than a folder
 *    path was.
 */

import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import { isValidId, routineFromDraft, serializeTrigger, suggestId, type RoutineDraft } from './format'
import type { RoutineEngine, RoutineView, RunRequestResult } from './engine'
import type { RoutineStore } from './store'
import { MAX_ROUTINES } from './store'

export const ROUTINES_LIST = 'routines:list'
export const ROUTINES_GET = 'routines:get'
export const ROUTINES_CREATE = 'routines:create'
export const ROUTINES_UPDATE = 'routines:update'
export const ROUTINES_DELETE = 'routines:delete'
export const ROUTINES_RUN = 'routines:run'
export const ROUTINES_PAUSE = 'routines:pause'
export const ROUTINES_RESUME = 'routines:resume'

/** Which permission tier an operation sits in. See the module header. */
export type RoutineTier = 'read' | 'act' | 'alter'

export const ROUTINE_TIERS: Readonly<Record<string, RoutineTier>> = {
  [ROUTINES_LIST]: 'read',
  [ROUTINES_GET]: 'read',
  [ROUTINES_RUN]: 'act',
  [ROUTINES_PAUSE]: 'act',
  [ROUTINES_RESUME]: 'act',
  [ROUTINES_CREATE]: 'alter',
  [ROUTINES_UPDATE]: 'alter',
  [ROUTINES_DELETE]: 'alter',
}

export type WriteResult =
  | { ok: true; id: string; view: RoutineView | null }
  | { ok: false; problems: string[] }

/**
 * Everything anybody may do to a routine, in one object.
 *
 * A class rather than a bag of handlers because the MCP server, the settings
 * pane and the tests all want the same eight operations and none of them wants
 * Electron. `registerRoutinesIpc` is a thin wrapper that puts `ipcMain` in front
 * of this and nothing else.
 */
export class RoutineApi {
  constructor(
    private readonly engine: RoutineEngine,
    private readonly store: RoutineStore,
  ) {}

  list(): RoutineView[] {
    return this.engine.list()
  }

  get(id: unknown): RoutineView | null {
    return typeof id === 'string' && isValidId(id) ? this.engine.get(id) : null
  }

  /** Alter. Creates a file; refuses to overwrite one that exists. */
  create(draft: unknown): WriteResult {
    if (typeof draft !== 'object' || draft === null) {
      return { ok: false, problems: ['A routine needs a name, a trigger, a folder and a prompt.'] }
    }
    const input = draft as RoutineDraft & { id?: unknown }
    const existing = new Set(this.engine.list().map((view) => view.id))
    if (existing.size >= MAX_ROUTINES) {
      return { ok: false, problems: [`This app will not keep more than ${MAX_ROUTINES} routines.`] }
    }

    const wanted = typeof input.id === 'string' ? input.id : suggestId(String(input.name ?? ''), existing)
    if (!isValidId(wanted)) {
      return {
        ok: false,
        problems: [`\`${wanted}\` is not a usable routine name. Use lowercase letters, digits and hyphens.`],
      }
    }
    if (existing.has(wanted)) {
      return { ok: false, problems: [`There is already a routine called \`${wanted}\`.`] }
    }

    const parsed = routineFromDraft(wanted, input)
    if (!parsed.ok) return { ok: false, problems: parsed.problems }

    /*
     * The same routine twice is a mistake, not two routines.
     *
     * Without an explicit id, `suggestId` moves out of the way of a name that
     * is taken — which is right for a person pressing New, and wrong for an
     * agent retrying a call it thought had failed: that produces `sweep-2`,
     * `sweep-3`, and two copies of the same automation both spending money on
     * the same trigger. Matching on what the routine *does* rather than on what
     * it is called catches the retry and lets a genuinely different routine
     * with a similar name through.
     */
    const duplicate = this.engine
      .list()
      .find(
        (view) =>
          view.folder === parsed.routine.folder &&
          view.prompt === parsed.routine.prompt &&
          view.triggers.join('|') === parsed.routine.triggers.map(serializeTrigger).join('|'),
      )
    if (duplicate) {
      return {
        ok: false,
        problems: [`\`${duplicate.id}\` already does exactly this. Edit it rather than adding a second.`],
      }
    }

    this.store.save(parsed.routine)
    this.engine.reload()
    return { ok: true, id: wanted, view: this.engine.get(wanted) }
  }

  /** Alter. Replaces a routine's file wholesale — see `store.save` for why atomically. */
  update(id: unknown, draft: unknown): WriteResult {
    if (typeof id !== 'string' || !isValidId(id)) {
      return { ok: false, problems: ['That is not a usable routine name.'] }
    }
    if (typeof draft !== 'object' || draft === null) {
      return { ok: false, problems: ['Nothing was supplied to change.'] }
    }
    if (this.engine.get(id) === null) {
      return { ok: false, problems: [`There is no routine called \`${id}\`.`] }
    }
    const parsed = routineFromDraft(id, draft as RoutineDraft)
    if (!parsed.ok) return { ok: false, problems: parsed.problems }
    this.store.save(parsed.routine)
    this.engine.reload()
    return { ok: true, id, view: this.engine.get(id) }
  }

  /** Alter. */
  remove(id: unknown): { ok: boolean; problems?: string[] } {
    if (typeof id !== 'string' || !isValidId(id)) {
      return { ok: false, problems: ['That is not a usable routine name.'] }
    }
    const removed = this.store.remove(id)
    this.engine.reload()
    return removed ? { ok: true } : { ok: false, problems: [`There is no routine called \`${id}\`.`] }
  }

  /** Act. Runs a routine by name, whatever its triggers say. */
  async run(id: unknown, by: 'user' | 'copilot' = 'user'): Promise<RunRequestResult> {
    if (typeof id !== 'string' || !isValidId(id)) {
      return { started: false, reason: 'That is not a usable routine name.' }
    }
    return this.engine.runNow(id, by)
  }

  /** Act. Stops a routine without editing the file its owner wrote. */
  pause(id: unknown, reason: unknown): boolean {
    if (typeof id !== 'string' || !isValidId(id)) return false
    const text = typeof reason === 'string' && reason.trim() !== '' ? reason.trim().slice(0, 300) : 'Paused.'
    return this.engine.pause(id, text)
  }

  /** Act. */
  resume(id: unknown): boolean {
    return typeof id === 'string' && isValidId(id) ? this.engine.resume(id) : false
  }
}

/**
 * Wire the routine channels. One call from the main process:
 *
 *     const routines = createRoutines({ … })
 *     registerRoutinesIpc(ipcMain, routines.api)
 */
export function registerRoutinesIpc(ipcMain: IpcMain, api: RoutineApi): void {
  ipcMain.handle(ROUTINES_LIST, () => api.list())
  ipcMain.handle(ROUTINES_GET, (_event: IpcMainInvokeEvent, id: unknown) => api.get(id))
  ipcMain.handle(ROUTINES_CREATE, (_event: IpcMainInvokeEvent, draft: unknown) => api.create(draft))
  ipcMain.handle(ROUTINES_UPDATE, (_event: IpcMainInvokeEvent, id: unknown, draft: unknown) =>
    api.update(id, draft),
  )
  ipcMain.handle(ROUTINES_DELETE, (_event: IpcMainInvokeEvent, id: unknown) => api.remove(id))
  // Always `user` from this channel. The renderer is a person pressing a button;
  // the copilot's own calls arrive through the MCP server in phase 2 and say so,
  // and the difference is what the action log records.
  ipcMain.handle(ROUTINES_RUN, (_event: IpcMainInvokeEvent, id: unknown) => api.run(id, 'user'))
  ipcMain.handle(ROUTINES_PAUSE, (_event: IpcMainInvokeEvent, id: unknown, reason: unknown) =>
    api.pause(id, reason),
  )
  ipcMain.handle(ROUTINES_RESUME, (_event: IpcMainInvokeEvent, id: unknown) => api.resume(id))
}
