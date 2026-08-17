import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { copilotPaths } from '../copilot-home'
import { installPaths, resetPaths } from '../platform/paths'
import type { RoutineRunRequest, RoutineRunner } from './engine'
import { createRoutines, type RoutinesHandle } from './index'
import { routinesDirFor } from './store'

/**
 * The whole thing, assembled, on a real disk.
 *
 * `engine.test.ts` drives the rules with a fake clock and injected sources, and
 * `sources.test.ts` proves the real watchers fire. Neither of them proves that
 * `createRoutines` wires the two together — and that is exactly the kind of gap
 * this repository has shipped before: every part tested, the assembly not, and
 * the feature does nothing in the running app.
 *
 * So this one uses the real assembly, the real `<userData>/routines`
 * layout, a real file watcher, and the real action log. The only thing supplied
 * by the test is the runner, because the runner is the copilot, and it is a
 * later pass.
 */

let dir: string
let project: string
let routines: RoutinesHandle
const started: RoutineRunRequest[] = []

const runner: RoutineRunner = {
  cancellable: false,
  async run(request) {
    started.push(request)
    return { ok: true }
  },
}

async function until(check: () => boolean, ms: number): Promise<boolean> {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (check()) return true
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  return check()
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-routines-live-'))
  project = join(dir, 'project')
  mkdirSync(project, { recursive: true })
  started.length = 0
  // The same thing both shells do at boot: say where this app keeps its files.
  resetPaths()
  installPaths({
    userData: () => dir,
    home: () => dir,
    downloads: () => dir,
    appRoot: () => dir,
  })
})

afterEach(async () => {
  await routines?.stop()
  resetPaths()
  rmSync(dir, { recursive: true, force: true })
})

describe('routines, end to end', () => {
  it('runs a routine somebody wrote by hand, from a real file change', async () => {
    // A routine file, written the way a person would write one — no API call.
    mkdirSync(routinesDirFor(dir), { recursive: true })
    writeFileSync(
      join(routinesDirFor(dir), 'on-edit.md'),
      [
        '# On edit',
        '',
        'when: file-change src/**',
        `in: ${project}`,
        'quiet-for: 1s',
        '',
        '---',
        '',
        'Something under src changed. Have a look.',
        '',
      ].join('\n'),
      'utf8',
    )

    routines = createRoutines({
      runner,
      allowFolder: (folder) => (folder === project ? { ok: true } : { ok: false, reason: 'not a project' }),
    })
    routines.engine.start()

    const view = routines.engine.get('on-edit')
    expect(view?.state).toBe('armed')
    expect(view?.folder).toBe(project)

    // chokidar returns before it is watching.
    await new Promise((resolve) => setTimeout(resolve, 400))
    mkdirSync(join(project, 'src'), { recursive: true })
    writeFileSync(join(project, 'src', 'app.ts'), 'export const x = 1', 'utf8')

    expect(await until(() => started.length > 0, 8000)).toBe(true)
    expect(started[0].routine.prompt).toBe('Something under src changed. Have a look.')
    expect(started[0].cause.kind).toBe('file-change')

    // And it is in the copilot's own action log, in the file the design names.
    // `copilotPaths` rather than a hand-composed path: the log sits *outside*
    // the copilot's folder, because the agent it records can write inside that
    // folder, and one spelling of its location is the whole point.
    const log = copilotPaths(dir).actions
    expect(await until(() => readFileSync(log, 'utf8').includes('routine.run'), 5000)).toBe(true)
    const rows = readFileSync(log, 'utf8')
      .split('\n')
      .filter((line) => line !== '')
      .map((line) => JSON.parse(line) as Record<string, unknown>)
    expect(rows.some((row) => row.action === 'routine.run' && row.outcome === 'started')).toBe(true)
    expect(rows.some((row) => row.action === 'routine.run' && row.outcome === 'ok')).toBe(true)
    expect(rows.every((row) => row.routine === 'on-edit')).toBe(true)
  }, 30000)

  it('ignores a change that does not match the routine’s pattern', async () => {
    mkdirSync(routinesDirFor(dir), { recursive: true })
    writeFileSync(
      join(routinesDirFor(dir), 'on-edit.md'),
      `# On edit\n\nwhen: file-change src/**\nin: ${project}\n\n---\n\nGo.\n`,
      'utf8',
    )
    routines = createRoutines({ runner, allowFolder: () => ({ ok: true }) })
    routines.engine.start()

    await new Promise((resolve) => setTimeout(resolve, 400))
    writeFileSync(join(project, 'README.md'), '# hello', 'utf8')
    await new Promise((resolve) => setTimeout(resolve, 1500))
    expect(started).toHaveLength(0)

    mkdirSync(join(project, 'src'), { recursive: true })
    writeFileSync(join(project, 'src', 'app.ts'), 'x', 'utf8')
    expect(await until(() => started.length > 0, 8000)).toBe(true)
  }, 30000)

  it('says the copilot is missing rather than looking ready, when no runner is registered', () => {
    mkdirSync(routinesDirFor(dir), { recursive: true })
    writeFileSync(
      join(routinesDirFor(dir), 'on-edit.md'),
      `# On edit\n\nwhen: file-change src/**\nin: ${project}\n\n---\n\nGo.\n`,
      'utf8',
    )
    /*
     * `runner: null` explicitly, and the explicitness is the point.
     *
     * The shipping build no longer has this shape — `createRoutines` defaults
     * to a real copilot runner, because a feature whose wiring a shell has to
     * remember is a feature that ships inert. What has to keep working is the
     * *reporting*: a shell that genuinely has nothing on the other end of its
     * triggers — a headless host with no Claude CLI, a test — must show every
     * routine as unarmed with the reason attached, rather than as a routine
     * that simply has not fired yet. Those two look identical from outside and
     * only one of them is worth waiting for.
     */
    routines = createRoutines({ runner: null, allowFolder: () => ({ ok: true }) })
    routines.engine.start()
    const view = routines.engine.get('on-edit')
    expect(view?.state).toBe('unarmed')
    expect(view?.reason).toContain('copilot is not running')
  })

  it('picks up a routine created through the API without a restart', async () => {
    routines = createRoutines({ runner, allowFolder: () => ({ ok: true }) })
    routines.engine.start()
    expect(routines.api.list()).toHaveLength(0)

    const created = routines.api.create({
      name: 'By hand',
      when: 'manual',
      in: project,
      prompt: 'Do it.',
    })
    expect(created.ok).toBe(true)
    expect(routines.api.list()).toHaveLength(1)

    const result = await routines.api.run('by-hand')
    expect(result.started).toBe(true)
    expect(await until(() => started.length > 0, 5000)).toBe(true)
  }, 30000)
})
