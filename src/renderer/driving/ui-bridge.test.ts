import { afterEach, describe, expect, it } from 'vitest'
import { publishUi, uiBridge, UI_GLOBAL, type UiHandlers } from './ui-bridge'

/**
 * The window's half of `ui.do`, without a DOM.
 *
 * What is pinned is that the bridge only ever does what `App.tsx` handed it, and
 * answers honestly when it is asked for something this window does not have —
 * a command no row answers to, a session with no row, a section that does not
 * exist. A bridge that said "done" to those would be the dead control this app
 * keeps removing, one layer further from anybody who could notice.
 */

function handlers(log: string[], commands = ['view.files']): UiHandlers {
  return {
    commands: () => commands.map((id) => ({ id, title: id, group: 'View' })),
    run: (id) => {
      log.push(`run ${id}`)
      return commands.includes(id)
    },
    sessions: () => [{ id: 's1', title: 'api' }],
    focusSession: (id) => {
      log.push(`focus ${id}`)
    },
    sections: () => ['general'],
    openSettings: (section) => {
      log.push(`settings ${section}`)
    },
    addProject: (path) => {
      log.push(`project ${path}`)
    },
  }
}

afterEach(() => {
  delete (globalThis as Record<string, unknown>)[UI_GLOBAL]
})

describe('the window’s clicks, for a caller who is not in front of it', () => {
  it('runs what the window answers to, and says so when it answers to nothing', () => {
    const log: string[] = []
    const bridge = uiBridge(() => handlers(log))
    expect(bridge.do({ kind: 'run', target: 'view.files' })).toEqual({ ok: true, did: 'ran view.files' })
    expect(bridge.do({ kind: 'run', target: 'view.nowhere' })).toMatchObject({ ok: false })
    expect(log).toEqual(['run view.files', 'run view.nowhere'])
  })

  it('focuses only a session the window has a row for', () => {
    const log: string[] = []
    const bridge = uiBridge(() => handlers(log))
    expect(bridge.do({ kind: 'focus', target: 's1' })).toEqual({ ok: true, did: 'brought api to the front' })
    expect(bridge.do({ kind: 'focus', target: 's9' })).toMatchObject({ ok: false })
    expect(log).toEqual(['focus s1'])
  })

  it('opens only a Settings section that exists', () => {
    const log: string[] = []
    const bridge = uiBridge(() => handlers(log))
    expect(bridge.do({ kind: 'settings', target: 'general' })).toMatchObject({ ok: true })
    expect(bridge.do({ kind: 'settings', target: 'nope' })).toMatchObject({ ok: false })
    expect(log).toEqual(['settings general'])
  })

  it('reads the handlers at the moment it is asked, so a list rebuilt since publishing is the one used', () => {
    const log: string[] = []
    let current = handlers(log, ['view.files'])
    const bridge = uiBridge(() => current)
    current = handlers(log, ['view.files', 'pane.split'])
    expect(bridge.list()?.commands.map((command) => command.id)).toEqual(['view.files', 'pane.split'])
  })

  it('lists plain data only, because the answer crosses by structured clone', () => {
    /*
     * The palette's real rows carry a `run` function. One function anywhere in
     * an `executeJavaScript` answer and the whole answer is refused — which the
     * main side can only read as "there is no window".
     */
    const withRun = (): UiHandlers => ({
      ...handlers([]),
      commands: () => [{ id: 'view.files', title: 'Files', group: 'View', run: () => undefined } as never],
    })
    const listed = uiBridge(withRun).list()
    expect(listed?.commands).toEqual([{ id: 'view.files', title: 'Files', group: 'View' }])
    expect(() => structuredClone(listed)).not.toThrow()
  })

  it('answers plainly before App has handed anything over', () => {
    const bridge = uiBridge(() => null)
    expect(bridge.list()).toBeNull()
    expect(bridge.do({ kind: 'run', target: 'view.files' })).toMatchObject({ ok: false })
  })

  it('publishes itself on the window and takes itself away again', () => {
    const stop = publishUi(() => handlers([]))
    expect(typeof (globalThis as Record<string, unknown>)[UI_GLOBAL]).toBe('object')
    stop()
    expect((globalThis as Record<string, unknown>)[UI_GLOBAL]).toBeUndefined()
  })
})
