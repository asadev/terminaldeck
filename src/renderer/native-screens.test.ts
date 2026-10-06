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

describe('every page hears which screens are native', () => {
  it('through the shim, which leaves the list on the window with an event, under the same names', async () => {
    // The shim's half is tested beside it (native-web/page-features.test.ts); this
    // side holds the two names to the shim's source text, so neither can drift.
    const { NATIVE_SCREENS_GLOBAL, NATIVE_SCREENS_EVENT } = await import('./native-screens')
    const shim = readFileSync(join(__dirname, '../native-web/page-features.ts'), 'utf8')
    expect(shim).toContain(`export const NATIVE_SCREENS_GLOBAL = '${NATIVE_SCREENS_GLOBAL}'`)
    expect(shim).toContain(`export const NATIVE_SCREENS_EVENT = '${NATIVE_SCREENS_EVENT}'`)
  })

  it('answers native-screens on every page, ahead of the page’s own commands', () => {
    const features = readFileSync(join(__dirname, '../native-web/page-features.ts'), 'utf8')
    expect(features).toContain("registerShimCommand(host, 'native-screens', (arg) => leaveNativeScreens(host, arg))")
  })
})

describe('what each page stops mounting', () => {
  const read = (path: string): string => readFileSync(join(__dirname, path), 'utf8')

  it('Hoot’s window, every session at once, the split window, and sessions on other machines', () => {
    expect(APP).toContain("const copilotWindow = (visible: boolean) => drawnNatively.has('hoot') ? (")
    expect(APP).toContain(`if (drawnNatively.has('swarm')) return <div className="native-screen" data-screen="swarm" />`)
    expect(APP).toContain(`if (drawnNatively.has('split')) return <div className="native-screen" data-screen="split" />`)
    expect(APP).toContain("!drawnNatively.has('machine-session') &&")
    expect(APP).toContain("!drawnNatively.has('server-session') &&")
  })

  it('a Settings section the native Settings window draws', () => {
    const panel = read('settings/SettingsWindow.tsx')
    expect(panel).toContain('const drawnNatively = useNativeScreens().has(settingsScreenId(section))')
    expect(panel).toContain('{drawnNatively ? null : <View')
  })

  it('Tools drawn natively still keeps the voice feature in step with the stored key', () => {
    const panel = read('settings/SettingsWindow.tsx')
    expect(panel).toContain("{drawnNatively && section === 'features' ? <VoiceFeatureSync /> : null}")
    const tools = read('settings/sections/ToolsSection.tsx')
    expect(tools).toContain("export const VOICE_CHANGED_EVENT = 'td:voice-changed'")
    expect(tools).toContain("if (features.on('voice') !== hasKey) features.setEnabled('voice', hasKey)")
    // The section itself runs the same sync, as it always did.
    expect(tools.slice(tools.indexOf('export function ToolsSection'))).toContain('useVoiceFeatureSync()')
  })

  it('Hoot driving, when the native window drives the app itself', () => {
    const main = read('main.tsx')
    expect(main).toContain("return useNativeScreens().has('drive') ? null : <DriveHost />")
    expect(main).toContain('<PageDriveHost />')
    expect(main).not.toContain('    <DriveHost />')
  })

  it('a screen in a window of its own, and the island', () => {
    expect(read('screens/ScreenPage.tsx')).toContain("if (drawnNatively.has(route.kind === 'panel' ? route.id : 'session')) {")
    expect(read('island/IslandPage.tsx')).toContain("const drawnNatively = useNativeScreens().has('island')")
  })
})
