import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { nativeCommands } from './native-commands'
import { nativeScreens, setNativeScreens } from './native-screens'

/**
 * The screens the native window draws itself are not mounted again underneath:
 * the command that says which, and the three places the page stops mounting
 * them — a view's page, a browser page, a session's terminal — keeping what is
 * state (which view is selected, which session is in front) as it was.
 */

const APP = readFileSync(join(__dirname, 'App.tsx'), 'utf8')

afterEach(() => {
  setNativeScreens([])
})

describe('native-screens', () => {
  it('takes the whole list each time, and nothing that is not a list of ids', () => {
    expect(setNativeScreens(['artifacts', 'session'])).toBe(true)
    expect([...nativeScreens()]).toEqual(['artifacts', 'session'])
    expect(setNativeScreens(['simulators'])).toBe(true)
    expect([...nativeScreens()]).toEqual(['simulators'])
    expect(setNativeScreens('artifacts')).toBe(false)
    expect(setNativeScreens([1, 2])).toBe(false)
    expect([...nativeScreens()]).toEqual(['simulators'])
  })

  it('arrives through tdNative.run, even before the window has mounted', () => {
    const commands = nativeCommands(() => null)
    expect(commands.run('native-screens', ['artifacts', 'browser'])).toBe(true)
    expect([...nativeScreens()]).toEqual(['artifacts', 'browser'])
    expect(commands.run('native-screens', { artifacts: true })).toBe(false)
  })

  it('is read by the window as state, before anything it gates', () => {
    expect(APP).toContain('const drawnNatively = useNativeScreens()')
    expect(APP.indexOf('const drawnNatively = useNativeScreens()')).toBeLessThan(APP.indexOf('if (needsOnboarding && !onboardingDone)'))
  })
})

describe('what is not mounted when the native window draws it', () => {
  it('a view: the selection stands, the page is a placeholder', () => {
    const at = APP.indexOf('if (showingPanel && panel) {')
    const branch = APP.slice(at, APP.indexOf('<PanelView', at))
    expect(branch).toContain('if (drawnNatively.has(panel)) return <div className="native-screen" data-screen={panel} />')
  })

  it('a session’s terminal: the one in front leaves its room, the rest leave nothing', () => {
    expect(APP).toContain(
      `if (drawnNatively.has('session')) {\n            return active ? <div key={session.id} className="native-screen" data-screen="session" /> : null`,
    )
  })

  it('a browser page', () => {
    expect(APP).toContain(".filter((tab) => tab.kind === 'browser' && !drawnNatively.has('browser'))")
  })

  it('has a rule for its placeholder', () => {
    const css = readFileSync(join(__dirname, 'shell/shell.css'), 'utf8')
    expect(css).toMatch(/^\.native-screen \{/m)
  })
})

describe('the side panel’s current project', () => {
  it('is the project every view from the rail is handed', () => {
    expect(APP).toContain('projectPath={activeProjectPath}')
    const input = APP.slice(APP.indexOf('railInput.current = {'), APP.indexOf('stripInput.current = {'))
    expect(input).toContain('project: activeProjectPath,')
  })
})
