import { describe, expect, it, vi } from 'vitest'
import type { RoutineView } from '../routines/engine'
import { fakeContext, tool } from './agents-area.fixture'
import { currentDraft, routineTools, type RoutineToolDeps } from './routine-tools'

const FILE = [
  '# Nightly sweep',
  '',
  'when: schedule 02:30',
  'in: /work/api',
  'enabled: yes',
  'quiet-for: 2m',
  'expect-every: 1d',
  '',
  '---',
  '',
  'Run the tests. If anything fails, open a session and start fixing it.',
  '',
].join('\n')

function view(id: string): RoutineView {
  return { id, name: 'Nightly sweep', folder: '/work/api', triggers: ['schedule 02:30'], prompt: 'Run the tests.' } as RoutineView
}

function deps(overrides: Partial<RoutineToolDeps> = {}): RoutineToolDeps {
  return {
    list: () => [view('nightly-sweep')],
    get: (id) => (id === 'nightly-sweep' ? view(id) : null),
    text: (id) =>
      id === 'nightly-sweep' ? { ok: true, id, text: FILE, file: '/state/routines/nightly-sweep.md' } : { ok: false, problems: ['missing'] },
    create: (draft) => ({ ok: true, id: 'new-one', view: view('new-one'), draft } as never),
    update: (id) => ({ ok: true, id: String(id), view: view(String(id)) }),
    remove: (id) => (id === 'nightly-sweep' ? { ok: true } : { ok: false, problems: [`There is no routine called \`${id}\`.`] }),
    run: async () => ({ started: true, runId: 'run-1' }),
    pause: () => true,
    resume: () => true,
    ...overrides,
  }
}

describe('changing a routine keeps what was not mentioned', () => {
  it('reads the current routine through the loader’s own parser, quiet-for and expect-every included', () => {
    // The view carries neither; an update is a wholesale replace; so a draft
    // built off the view would reset both on every edit.
    expect(currentDraft(deps(), 'nightly-sweep')).toMatchObject({
      name: 'Nightly sweep',
      when: ['schedule 02:30'],
      in: '/work/api',
      quietFor: '2m',
      expectEvery: '1d',
    })
  })

  it('overlays only the fields sent', async () => {
    const update = vi.fn<RoutineToolDeps['update']>((id) => ({ ok: true, id: String(id), view: view(String(id)) }))
    const { context } = fakeContext()
    await tool(routineTools(deps({ update })), 'routines.save').run({ routineId: 'nightly-sweep', when: ['schedule 03:00'] }, context)
    expect(update).toHaveBeenCalledWith(
      'nightly-sweep',
      expect.objectContaining({ when: ['schedule 03:00'], in: '/work/api', quietFor: '2m', expectEvery: '1d', prompt: expect.stringContaining('Run the tests.') }),
    )
  })

  it('creates when the id is new, passing the id through', async () => {
    const create = vi.fn<RoutineToolDeps['create']>(() => ({ ok: true, id: 'mine', view: view('mine') }))
    const { context } = fakeContext()
    await tool(routineTools(deps({ create })), 'routines.save').run(
      { routineId: 'mine', name: 'Mine', when: 'manual', folder: '/work/web', prompt: 'Say hi.' },
      context,
    )
    expect(create).toHaveBeenCalledWith({ id: 'mine', name: 'Mine', when: ['manual'], in: '/work/web', prompt: 'Say hi.' })
  })

  it('refuses a folder this app does not have open, before anyone is asked', () => {
    const { context } = fakeContext()
    expect(() => tool(routineTools(deps()), 'routines.save').precheck?.({ name: 'x', folder: '/', prompt: 'x' }, context)).toThrow(
      /not a folder this app has open/,
    )
  })

  it('says the parser’s problems when a save is refused', async () => {
    const { context } = fakeContext()
    const spec = tool(routineTools(deps({ create: () => ({ ok: false, problems: ['This routine has no `when:` line.'] }) })), 'routines.save')
    await expect(spec.run({ name: 'x', folder: '/work/api', prompt: 'x' }, context)).rejects.toThrow(/no `when:` line/)
  })
})

describe('running and holding routines', () => {
  it('runs as the copilot, so the action log can tell it from a click', async () => {
    const run = vi.fn<RoutineToolDeps['run']>(async () => ({ started: true, runId: 'run-9' }))
    const { context } = fakeContext()
    const out = await tool(routineTools(deps({ run })), 'routines.run').run({ routineId: 'nightly-sweep' }, context)
    expect(run).toHaveBeenCalledWith('nightly-sweep', 'copilot')
    expect(out.value).toEqual({ routineId: 'nightly-sweep', runId: 'run-9' })
  })

  it('reports a run the engine would not start, with its reason', async () => {
    const { context } = fakeContext()
    const spec = tool(routineTools(deps({ run: async () => ({ started: false, reason: 'It has run 6 times this hour.' }) })), 'routines.run')
    await expect(spec.run({ routineId: 'nightly-sweep' }, context)).rejects.toThrow(/6 times this hour/)
  })

  it('returns the file text with the view', async () => {
    const { context } = fakeContext()
    const out = await tool(routineTools(deps()), 'routines.get').run({ routineId: 'nightly-sweep' }, context)
    expect((out.value as { file: { text: string } }).file.text).toBe(FILE)
  })
})
