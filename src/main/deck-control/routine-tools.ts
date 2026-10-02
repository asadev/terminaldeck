/**
 * Routines — saved instructions that run on a trigger — as tools.
 *
 * ## These exist now because the engine does
 *
 * `catalogue.ts` kept `routines.*` out on purpose, and said why: *there is no
 * routine engine… a tool that writes a file nothing ever executes would pass a
 * demo and lie.* That is no longer true. `src/main/routines/` has a store, a
 * trigger engine, a runner and a scheduler, armed at launch, and
 * `routines/ipc.ts` opens by saying the MCP server should call {@link
 * RoutineApi} rather than reach into the engine — so this file takes exactly
 * that object as its deps and adds nothing between a tool call and a click.
 *
 * ## The tiers are the ones `routines/ipc.ts` wrote down
 *
 * `ROUTINE_TIERS` is the table: list/get/text are read, run/pause/resume are
 * act, create/update/delete are alter. It was written for this file to obey,
 * and it is obeyed — `routine-tools.test.ts` reads the table and checks every
 * tool here against it rather than trusting this comment.
 *
 * The fourth tier there is `human`, worn by `saveText`, which writes the exact
 * bytes a person typed. **It is not a tool and must not become one**: those
 * bytes skip `routineFromDraft`'s header-injection guard, and a model handed it
 * could write a routine whose folder is the root of the disk from a field a UI
 * treats as a label. The window's editor (`routines:save-text`) is reached here
 * through `routines.save`, which goes through the draft — the same edit, the
 * guarded way. Nothing is lost by that except the ability to bypass the guard.
 *
 * ## While a tour is driving the screen
 *
 * `control.ts` refuses every `routines.` id for the length of a tour, by
 * prefix, and has since before these existed. Nothing to wire.
 */

import { isValidId, parseRoutine, serializeDuration, serializeTrigger, type RoutineDraft } from '../routines/format'
import type { RoutineView, RunRequestResult } from '../routines/engine'
import type { WriteResult } from '../routines/ipc'
import { requireKnownFolder, type JsonSchema, type ToolSpec } from './catalogue'
import { optBool, optNumber, optStr, optStrings, str } from './agents-area-args'
import { Refused } from './surface'

/** The operations `RoutineApi` exposes, by the names it gives them. `routines.api` satisfies this. */
export interface RoutineToolDeps {
  list(): RoutineView[]
  get(id: unknown): RoutineView | null
  text(id: unknown): { ok: true; id: string; text: string; file: string } | { ok: false; problems: string[] }
  create(draft: unknown): WriteResult
  update(id: unknown, draft: unknown): WriteResult
  remove(id: unknown): { ok: boolean; problems?: string[] }
  run(id: unknown, by?: 'user' | 'copilot'): Promise<RunRequestResult>
  pause(id: unknown, reason: unknown): boolean
  resume(id: unknown): boolean
}

const ROUTINE_ID = { type: 'string', description: 'The routine id from routines.list, like nightly-sweep.' }

/** What a routine is made of, as a model fills it in. */
const DRAFT_PROPERTIES = {
  name: { type: 'string', description: 'What it is called.' },
  when: {
    type: 'array',
    items: { type: 'string' },
    description:
      'One or more triggers: "schedule 02:30", "schedule weekdays 09:00", "schedule every 30m", ' +
      '"session-finished", "session-failed", "session-idle 15m", "alert", "alert critical", "git-change", ' +
      '"file-change src/**", "manual".',
  },
  folder: { type: 'string', description: 'The open folder it runs in and watches. See projects.list.' },
  prompt: { type: 'string', description: 'What the copilot is told to do each time it runs.' },
  enabled: { type: 'boolean' },
  overlap: { type: 'string', enum: ['queue', 'skip', 'cancel'], description: 'If it fires while still running.' },
  maxRunsPerHour: { type: 'number' },
  maxRunsPerDay: { type: 'number' },
  quietFor: { type: 'string', description: 'Wait for things to settle first, like 30s.' },
  expectEvery: { type: 'string', description: 'Warn if it has not run in this long, like 1d.' },
} as const

/**
 * The routine as it is on disk, as a draft — so an update can change one field.
 *
 * Read through `parseRoutine`, the loader's own parser, rather than off the
 * view: the view does not carry `quiet-for` or `expect-every`, and an update is
 * a wholesale replace, so building the draft from the view would quietly reset
 * both to their defaults on every edit. Null when the file does not parse —
 * then the caller must send the whole routine, and the parser's sentences say
 * what is missing.
 */
export function currentDraft(deps: RoutineToolDeps, id: string): RoutineDraft | null {
  const text = deps.text(id)
  if (!text.ok) return null
  const parsed = parseRoutine(id, text.text)
  if (!parsed.ok) return null
  const routine = parsed.routine
  return {
    name: routine.name,
    when: routine.triggers.map(serializeTrigger),
    in: routine.folder,
    prompt: routine.prompt,
    enabled: routine.enabled,
    overlap: routine.overlap,
    maxRunsPerHour: routine.maxRunsPerHour,
    maxRunsPerDay: routine.maxRunsPerDay,
    quietFor: serializeDuration(routine.quietForMs),
    ...(routine.expectEveryMs === null ? {} : { expectEvery: serializeDuration(routine.expectEveryMs) }),
  }
}

/** Only what the caller actually sent, in the draft's own field names. */
function patchOf(args: Record<string, unknown>): RoutineDraft {
  const patch: RoutineDraft = {}
  const name = optStr(args, 'name')
  if (name !== null) patch.name = name
  const when = optStrings(args, 'when')
  if (when !== null) patch.when = when
  const folder = optStr(args, 'folder')
  if (folder !== null) patch.in = folder
  if (typeof args['prompt'] === 'string') patch.prompt = args['prompt']
  if (args['enabled'] !== undefined) patch.enabled = optBool(args, 'enabled', true)
  const overlap = optStr(args, 'overlap')
  if (overlap !== null) patch.overlap = overlap
  const perHour = optNumber(args, 'maxRunsPerHour')
  if (perHour !== undefined) patch.maxRunsPerHour = perHour
  const perDay = optNumber(args, 'maxRunsPerDay')
  if (perDay !== undefined) patch.maxRunsPerDay = perDay
  const quiet = optStr(args, 'quietFor')
  if (quiet !== null) patch.quietFor = quiet
  const expect = optStr(args, 'expectEvery')
  if (expect !== null) patch.expectEvery = expect
  return patch
}

function failed(result: { ok: boolean; problems?: string[] }, what: string): never {
  throw new Refused('not-permitted', `${what}: ${(result.problems ?? []).join(' ') || 'it was refused.'}`)
}

export function routineTools(deps: RoutineToolDeps): ToolSpec[] {
  const idOnly: JsonSchema = {
    type: 'object',
    properties: { routineId: ROUTINE_ID },
    required: ['routineId'],
    additionalProperties: false,
  }
  const exists = (id: string): RoutineView => {
    const view = deps.get(id)
    if (view === null) throw new Refused('not-permitted', `there is no routine called ${id}. routines.list shows them.`)
    return view
  }

  return [
    {
      id: 'routines.list',
      wire: 'routines_list',
      tier: 'read',
      title: 'List routines',
      description:
        'Every routine on this computer: what triggers it, the folder it runs in, whether it is armed, paused ' +
        'or broken and why, when it last ran and how that went, when it is next due, and any calls its runs ' +
        'were not allowed to make. A routine is a saved prompt the copilot runs on a trigger — a schedule, a ' +
        'session finishing, an alert, a file change — with nobody watching.',
      index: 'List the routines (saved prompts that run on a trigger) and how each is doing.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'List the routines',
      run: async () => {
        const routines = deps.list()
        return { value: { routines }, summary: { routines: routines.length } }
      },
    },

    {
      id: 'routines.get',
      wire: 'routines_get',
      tier: 'read',
      title: 'Read a routine',
      description:
        'One routine in full: its state and history, and the text of its file exactly as written (a short ' +
        'header of when:/in: lines, then the prompt). Read this before changing one with routines.save.',
      index: 'Read one routine in full, including its file text.',
      inputSchema: idOnly,
      summary: (args) => `Read the routine ${optStr(args, 'routineId') ?? '?'}`,
      run: async (args) => {
        const view = exists(str(args, 'routineId'))
        const text = deps.text(view.id)
        return {
          value: { routine: view, file: text.ok ? { path: text.file, text: text.text } : { problems: text.problems } },
          summary: { routineId: view.id },
        }
      },
    },

    {
      id: 'routines.save',
      wire: 'routines_save',
      tier: 'alter',
      title: 'Create or change a routine',
      description:
        'Create a routine, or change one by naming its routineId. A new one needs name, when, folder and ' +
        'prompt. When changing, fields you leave out keep their current values. The routine is checked by the ' +
        'same parser its file goes through, and every problem is named. The person confirms it. A routine runs ' +
        'with nobody at the machine, so anything it would need confirmed is refused at the time and reported.',
      index: 'Create a routine, or change one (fields left out stay as they are).',
      inputSchema: {
        type: 'object',
        properties: {
          routineId: { type: 'string', description: 'To change one. For a new one, optional: lowercase-with-hyphens.' },
          ...DRAFT_PROPERTIES,
        },
        additionalProperties: false,
      },
      precheck: (args, context) => {
        const folder = optStr(args, 'folder')
        if (folder !== null) requireKnownFolder(context.surface, folder)
        const id = optStr(args, 'routineId')
        if (id !== null && !isValidId(id)) {
          throw new Refused('not-permitted', `${id} is not a usable routine id. Use lowercase letters, digits and hyphens.`)
        }
      },
      summary: (args) => {
        const id = optStr(args, 'routineId')
        const changing = id !== null && deps.get(id) !== null
        const fields = Object.keys(args).filter((key) => key !== 'routineId')
        return changing
          ? `Change the routine ${id}: ${fields.join(', ') || 'nothing'}`
          : `Create a routine called ${optStr(args, 'name') ?? id ?? '?'} in ${optStr(args, 'folder') ?? '?'}, ` +
              `run ${(optStrings(args, 'when') ?? []).join(' or ') || '?'}`
      },
      run: async (args, context) => {
        const folder = optStr(args, 'folder')
        if (folder !== null) requireKnownFolder(context.surface, folder)
        const id = optStr(args, 'routineId')
        const patch = patchOf(args)

        if (id !== null && deps.get(id) !== null) {
          const base = currentDraft(deps, id) ?? {}
          const result = deps.update(id, { ...base, ...patch })
          if (!result.ok) failed(result, `${id} was not changed`)
          return { value: { saved: 'changed', routine: result.view }, summary: { routineId: id, created: false } }
        }

        const result = deps.create(id === null ? patch : { ...patch, id })
        if (!result.ok) failed(result, 'the routine was not created')
        return { value: { saved: 'created', routine: result.view }, summary: { routineId: result.id, created: true } }
      },
    },

    {
      id: 'routines.delete',
      wire: 'routines_delete',
      tier: 'alter',
      title: 'Delete a routine',
      description: 'Delete a routine’s file. It stops running at once. A run already in progress finishes.',
      index: 'Delete a routine.',
      inputSchema: idOnly,
      summary: (args) => `Delete the routine ${optStr(args, 'routineId') ?? '?'}`,
      run: async (args) => {
        const id = str(args, 'routineId')
        const result = deps.remove(id)
        if (!result.ok) failed(result, `${id} was not deleted`)
        return { value: { deleted: id }, summary: { routineId: id } }
      },
    },

    {
      id: 'routines.run',
      wire: 'routines_run',
      tier: 'act',
      title: 'Run a routine now',
      description:
        'Run a routine now, whatever its triggers say, within its own limits on runs per hour and per day. ' +
        'Returns at once with the run id; routines.get shows how it went.',
      index: 'Run a routine now.',
      inputSchema: idOnly,
      summary: (args) => `Run the routine ${optStr(args, 'routineId') ?? '?'} now`,
      run: async (args) => {
        const view = exists(str(args, 'routineId'))
        const result = await deps.run(view.id, 'copilot')
        if (!result.started) throw new Refused('not-permitted', `${view.id} did not start: ${result.reason}`)
        return { value: { routineId: view.id, runId: result.runId }, summary: { routineId: view.id, runId: result.runId } }
      },
    },

    {
      id: 'routines.pause',
      wire: 'routines_pause',
      tier: 'act',
      title: 'Pause a routine',
      description:
        'Stop a routine from firing without touching its file, with a reason the person will see. ' +
        'routines.resume arms it again.',
      index: 'Pause a routine without editing it.',
      inputSchema: {
        type: 'object',
        properties: { routineId: ROUTINE_ID, reason: { type: 'string', description: 'One sentence, shown to the person.' } },
        required: ['routineId'],
        additionalProperties: false,
      },
      summary: (args) => `Pause the routine ${optStr(args, 'routineId') ?? '?'}`,
      run: async (args) => {
        const view = exists(str(args, 'routineId'))
        const paused = deps.pause(view.id, optStr(args, 'reason') ?? 'Paused by the copilot.')
        return { value: { routineId: view.id, paused, routine: deps.get(view.id) }, summary: { routineId: view.id, paused } }
      },
    },

    {
      id: 'routines.resume',
      wire: 'routines_resume',
      tier: 'act',
      title: 'Resume a routine',
      description: 'Arm a paused routine again.',
      index: 'Resume a paused routine.',
      inputSchema: idOnly,
      summary: (args) => `Resume the routine ${optStr(args, 'routineId') ?? '?'}`,
      run: async (args) => {
        const view = exists(str(args, 'routineId'))
        const resumed = deps.resume(view.id)
        return { value: { routineId: view.id, resumed, routine: deps.get(view.id) }, summary: { routineId: view.id, resumed } }
      },
    },
  ]
}
