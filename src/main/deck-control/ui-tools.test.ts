import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import { UI_COMMANDS } from './actions/ui'
import { contextFor, fakeSurface, toolNamed } from './sessions-lane.fixture'
import { Refused } from './surface'
import { UI_GLOBAL, UI_REFUSED, uiDoCall, uiTools } from './ui-tools'

/**
 * The window's half and this half, run against each other.
 *
 * The expression this file builds is evaluated here exactly as
 * `executeJavaScript` would evaluate it in the page — against a global the real
 * renderer module published. The failure this pins is the one `where-tool.ts`
 * names for its own global: *"the two drifting apart fails silently as 'there is
 * no window' on a window that is plainly open."*
 */

/**
 * The renderer's half, loaded by a path the compiler does not follow.
 *
 * The main and window halves are two TypeScript projects, and the main one may
 * not list a renderer file — which is the boundary this test exists to check
 * across, so it is crossed at run time instead: vitest loads the real module,
 * and the types below are the shape `ui-bridge.ts` exports, restated. If that
 * file is renamed this import fails loudly, which is the point.
 */
const RENDERER_BRIDGE = '../../renderer/driving/ui-bridge'

interface UiHandlers {
  commands(): ReadonlyArray<{ id: string; title: string; group: string; enabled?: boolean }>
  run(id: string): boolean
  sessions(): ReadonlyArray<{ id: string; title: string }>
  focusSession(id: string): void
  sections(): readonly string[]
  openSettings(section: string): void
  addProject(path: string): void
}

let publishUi: (current: () => UiHandlers | null) => () => void = () => () => {}
let RENDERER_GLOBAL = ''

beforeAll(async () => {
  const module = (await import(/* @vite-ignore */ RENDERER_BRIDGE)) as {
    publishUi: typeof publishUi
    UI_GLOBAL: string
  }
  publishUi = module.publishUi
  RENDERER_GLOBAL = module.UI_GLOBAL
})

function handlers(log: string[]): UiHandlers {
  return {
    commands: () => [
      { id: 'view.files', title: 'Files', group: 'View', enabled: true },
      { id: 'session.new', title: 'New session…', group: 'Session', enabled: true },
    ],
    run: (id) => {
      log.push(`run ${id}`)
      return id === 'view.files' || id.startsWith('features.install.')
    },
    sessions: () => [{ id: 's1', title: 'api' }],
    focusSession: (id) => {
      log.push(`focus ${id}`)
    },
    sections: () => ['general', 'copilot'],
    openSettings: (section) => {
      log.push(`settings ${section}`)
    },
    addProject: (path) => {
      log.push(`project ${path}`)
    },
  }
}

/** `executeJavaScript`, in this process: the expression, evaluated against `globalThis`. */
async function evaluate(code: string): Promise<unknown> {
  return new Function(`return (${code})`)() as unknown
}

let unpublish: (() => void) | null = null
afterEach(() => {
  unpublish?.()
  unpublish = null
})

describe('the bridge, both halves', () => {
  it('names the same global on both sides', () => {
    expect(UI_GLOBAL).toBe(RENDERER_GLOBAL)
  })

  it('runs a palette command through the window’s own dispatcher', async () => {
    const log: string[] = []
    unpublish = publishUi(() => handlers(log))
    const output = await toolNamed(uiTools({ evaluate }), 'ui.do').run(
      { action: 'run', target: 'view.files' },
      contextFor(fakeSurface().surface),
    )
    expect(output.value).toEqual({ done: true, did: 'ran view.files' })
    expect(log).toEqual(['run view.files'])
  })

  it('brings a session to the front and opens a Settings section', async () => {
    const log: string[] = []
    unpublish = publishUi(() => handlers(log))
    const ui = toolNamed(uiTools({ evaluate }), 'ui.do')
    await ui.run({ action: 'focus', target: 's1' }, contextFor(fakeSurface().surface))
    await ui.run({ action: 'settings', target: 'copilot' }, contextFor(fakeSurface().surface))
    expect(log).toEqual(['focus s1', 'settings copilot'])
  })

  it('reports what the window does not have, rather than claiming it worked', async () => {
    unpublish = publishUi(() => handlers([]))
    const ui = toolNamed(uiTools({ evaluate }), 'ui.do')
    await expect(ui.run({ action: 'focus', target: 'nope' }, contextFor(fakeSurface().surface))).rejects.toThrow(/no session nope/)
    await expect(ui.run({ action: 'settings', target: 'secrets' }, contextFor(fakeSurface().surface))).rejects.toThrow(/no section/)
  })

  it('cannot be turned into code by what it is asked to run', async () => {
    const log: string[] = []
    unpublish = publishUi(() => handlers(log))
    const sneaky = `x"}); globalThis.pwned = true; ({"a":"`
    await expect(
      toolNamed(uiTools({ evaluate }), 'ui.do').run({ action: 'run', target: sneaky }, contextFor(fakeSurface().surface)),
    ).rejects.toThrow(/no command/)
    expect((globalThis as Record<string, unknown>).pwned).toBeUndefined()
    expect(log).toEqual([`run ${sneaky}`])
    expect(uiDoCall({ kind: 'run', target: '\u2028' })).toContain('\\u2028')
  })

  it('says there is no window when nothing was published', async () => {
    const list = await toolNamed(uiTools({ evaluate }), 'ui.list').run({}, contextFor(fakeSurface().surface))
    expect(list.value).toMatchObject({ window: null })
    const done = await toolNamed(uiTools({ evaluate }), 'ui.do').run({ action: 'run', target: 'view.files' }, contextFor(fakeSurface().surface))
    expect(done.value).toMatchObject({ done: false })
  })

  it('lists commands without the ones it refuses, and says what to use for those', async () => {
    unpublish = publishUi(() => handlers([]))
    const list = (await toolNamed(uiTools({ evaluate }), 'ui.list').run({}, contextFor(fakeSurface().surface))).value as {
      commands: Array<{ id: string }>
      refused: Record<string, string | null>
      sessions: unknown[]
    }
    expect(list.commands.map((command) => command.id)).toEqual(['view.files'])
    expect(list.refused['session.new']).toBe('sessions.start')
    expect(list.sessions).toEqual([{ id: 's1', title: 'api' }])
  })
})

describe('what ui.do will not do', () => {
  it('refuses a command that opens a dialog nobody can answer, before anything moves', () => {
    const ui = toolNamed(uiTools({ evaluate }), 'ui.do')
    expect(() => ui.precheck?.({ action: 'run', target: 'project.open' }, contextFor(fakeSurface().surface))).toThrow(Refused)
    expect(() => ui.precheck?.({ action: 'run', target: 'session.close' }, contextFor(fakeSurface().surface))).toThrow(
      /sessions\.stop/,
    )
  })

  it('confirms installing a feature, and nothing else it does', () => {
    const ui = toolNamed(uiTools({ evaluate }), 'ui.do')
    const context = contextFor(fakeSurface().surface)
    expect(ui.escalate?.({ action: 'run', target: 'features.install.split' }, context)).toBe('alter')
    expect(ui.escalate?.({ action: 'run', target: 'view.files' }, context)).toBe('act')
  })

  it('agrees with the table: every refused command points at the tool the refusal names', () => {
    for (const [id, instead] of Object.entries(UI_REFUSED)) {
      const entry = UI_COMMANDS[id]
      expect(entry, id).toBeTruthy()
      if (entry === null || entry === undefined) continue
      if (instead === null) {
        expect('skip' in entry, id).toBe(true)
        continue
      }
      expect('tool' in entry, id).toBe(true)
      if (!('tool' in entry)) continue
      const tools = typeof entry.tool === 'string' ? [entry.tool] : entry.tool
      expect(tools, id).toContain(instead)
    }
  })

  it('and every command the table sends to ui.do is one it will actually run', () => {
    for (const [id, entry] of Object.entries(UI_COMMANDS)) {
      if (entry === null || !('tool' in entry)) continue
      const tools = typeof entry.tool === 'string' ? [entry.tool] : entry.tool
      if (tools.includes('ui.do')) expect(id in UI_REFUSED, id).toBe(false)
    }
  })
})
