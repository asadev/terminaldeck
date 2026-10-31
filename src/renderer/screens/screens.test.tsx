import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { PANELS } from '../shell/panels'
import { ScreenPage } from './ScreenPage'
import { SESSION_MESSAGES, openWindowMessage, screenRoute, screenUrl, sessionScreenState } from './screen-route'

/**
 * A screen in a window of its own: the routes, and that every one of them
 * shows something — a view, a terminal, or a plain sentence — never a blank.
 */

describe('the routes', () => {
  it('opens any sidebar view by its id, on a named project or none', () => {
    for (const panel of PANELS) {
      expect(screenRoute(`?screen=panel&id=${panel.id}`)).toEqual({ kind: 'panel', id: panel.id, project: null })
    }
    expect(screenRoute('?screen=panel&id=files&project=%2Fwork%2Fapi')).toEqual({
      kind: 'panel',
      id: 'files',
      project: '/work/api',
    })
  })

  it('opens a session by its id', () => {
    expect(screenRoute('?screen=session&id=abc-123')).toEqual({ kind: 'session', id: 'abc-123' })
  })

  it('says what is wrong with a route that names nothing it can show', () => {
    expect(screenRoute('?screen=panel&id=nonsense')).toEqual({ kind: 'unknown', message: 'There is no page called “nonsense”.' })
    expect(screenRoute('?screen=panel')).toEqual({ kind: 'unknown', message: 'No page was named.' })
    expect(screenRoute('?screen=session')).toEqual({ kind: 'unknown', message: 'No session was named.' })
    expect(screenRoute('?screen=elsewhere&id=x')).toEqual({ kind: 'unknown', message: 'This window has nothing to show.' })
  })

  it('is not a screen at all without ?screen', () => {
    expect(screenRoute('')).toBeNull()
    expect(screenRoute('?settings=1')).toBeNull()
  })

  it('writes the URLs it reads', () => {
    expect(screenUrl({ kind: 'panel', id: 'tasks' })).toBe('/?screen=panel&id=tasks')
    expect(screenUrl({ kind: 'session', id: 's 1' })).toBe('/?screen=session&id=s+1')
    expect(screenRoute(screenUrl({ kind: 'panel', id: 'files', project: '/a b' }).slice(1))).toEqual({
      kind: 'panel',
      id: 'files',
      project: '/a b',
    })
    expect(screenRoute(screenUrl({ kind: 'session', id: 's 1' }).slice(1))).toEqual({ kind: 'session', id: 's 1' })
  })

  it('is what main.tsx renders, before the app and instead of it', () => {
    const main = readFileSync(join(__dirname, '../main.tsx'), 'utf8')
    expect(main).toContain('const screen = screenRoute(location.search)')
    expect(main).toContain('<ScreenPage route={screen} />')
  })
})

describe('opening a window', () => {
  const APP = readFileSync(join(__dirname, '../App.tsx'), 'utf8')

  it('is the contract\u2019s message', () => {
    expect(openWindowMessage('session', 's1', 'fix login')).toEqual({
      type: 'open-window',
      kind: 'session',
      id: 's1',
      title: 'fix login',
    })
  })

  it('is what every pop-out posts in the native window, named as the rail names the session', () => {
    const at = APP.indexOf('const popOutSession = useCallback(')
    const body = APP.slice(at, APP.indexOf('[sessionWindows.popOut]', at))
    expect(body).toContain('if (isNativeShell()) {')
    expect(body).toContain("postToNative(openWindowMessage('session', id, sessionTitle.current(id)))")
    expect(APP).toContain("return tab ? labelOf(tab) : 'Session'")
    // Every way to pop a session out goes through it: the bar's button, the
    // palette row, the application menu, and the rail's and strip's moves.
    expect(APP.match(/popOutSession\(popOutTarget\)/g)).toHaveLength(3)
    expect(APP).toContain('popOut: (tabId: string, at?: { x: number; y: number } | null) => popOutSession(tabId, at),')
    expect(APP.match(/sessionWindows\.popOut\(/g)).toHaveLength(1)
  })
})

describe('a session\u2019s window', () => {
  it('shows the terminal only while the session runs', () => {
    expect(sessionScreenState(undefined, null)).toBe('connecting')
    expect(sessionScreenState(null, null)).toBe('missing')
    expect(sessionScreenState({ exitCode: 0 }, null)).toBe('ended')
    expect(sessionScreenState({ exitCode: null }, 'exited')).toBe('ended')
    expect(sessionScreenState({ exitCode: null }, 'working')).toBe('live')
    expect(sessionScreenState({ exitCode: null }, null)).toBe('live')
  })

  it('has a sentence for each of the other three', () => {
    for (const text of Object.values(SESSION_MESSAGES)) expect(text.trim().length).toBeGreaterThan(10)
  })
})

describe('never a blank window', () => {
  const render = (search: string): string => {
    const route = screenRoute(search)
    if (route === null) throw new Error('not a screen')
    return renderToStaticMarkup(<ScreenPage route={route} />)
  }

  it('says so for a route it cannot show', () => {
    const html = render('?screen=panel&id=nonsense')
    expect(html).toContain('class="screen-message"')
    expect(html).toContain('There is no page called')
  })

  it('says it is connecting, before it knows whether the session is there', () => {
    const html = render('?screen=session&id=abc')
    expect(html).toContain('class="screen-message"')
    expect(html).toContain(SESSION_MESSAGES.connecting)
  })

  it('draws a view in its own window', () => {
    const html = render('?screen=panel&id=tasks')
    expect(html).toContain('class="screen screen-panel"')
  })
})
