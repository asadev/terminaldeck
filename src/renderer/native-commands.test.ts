import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { BRAND } from '../shared/brand'
import { NATIVE_MESSAGE_HANDLER, isNativeShell, type NativeHost } from '../shared/native-shell'
import { KEYMAP } from './keymap'
import {
  NATIVE_COMMANDS,
  NATIVE_SIDEBAR_COMMANDS,
  createTitlePublisher,
  nativeCommands,
  nativeTitle,
  publishNativeCommands,
  type NativeHandlers,
  type NativeTitleMessage,
} from './native-commands'
import { EMPTY_NATIVE_RAIL, type NativeSidebarInput } from './shell/native-sidebar'
import type { NativeTabsInput } from './shell/native-tabs'
import { PANELS, isPanelId, type PanelId } from './shell/panels'
import type { WorkspaceTab } from './shell/workspace-tabs'

/**
 * The native window's toolbar and side panel, landing on this window's own
 * actions.
 *
 * Two halves. The command map is exercised against recording handlers: each
 * name reaches the handler it is meant to, and nothing else answers. And
 * because "the same action the app's own control uses" is a claim about
 * `App.tsx`, which these tests cannot render, the source is read: each command
 * id is a real row whose `run` is the very call the matching sidebar control
 * makes, and each side-panel handler is the very function handed to the rail.
 */

const APP = readFileSync(join(__dirname, 'App.tsx'), 'utf8')

const tab = (id: string, extra: Partial<WorkspaceTab> = {}): WorkspaceTab => ({
  id,
  kind: 'session',
  label: id,
  status: 'idle',
  projectPath: '/work/api',
  closable: true,
  ...extra,
})

const RAIL: NativeSidebarInput = {
  ...EMPTY_NATIVE_RAIL,
  panels: PANELS.filter((panel) => panel.id !== 'github'),
  projects: [{ path: '/work/api', name: 'api' }],
  tabs: [tab('s1'), tab('s2', { closable: false }), tab('hoot-tab', { isCopilot: true })],
  held: [{ key: 'k1', cwd: '/work/api', provider: 'claude', reason: 'gone', pick: false, at: 0 }],
  heldRetrying: [],
  machines: [
    { machineId: 'pc', name: 'Office PC', sessions: [tab('machine:pc:r1', { projectPath: 'C:/x' })], canClose: true },
    { machineId: 'old', name: 'Old PC', sessions: [], canClose: false },
  ],
  servers: [{ serverId: 'box', name: 'box', sessions: [tab('server:box:1', { projectPath: undefined })] }],
}

const STRIP: NativeTabsInput = {
  order: ['s1', 's2'],
  tabs: [tab('s1'), tab('s2'), tab('s9'), tab('page', { kind: 'browser', projectPath: undefined })],
  activeTabId: 's1',
  covered: false,
  unread: [],
  canNewBrowser: false,
  serverSessions: [],
  serverShellIds: {},
  mode: 'terminal',
  swarm: false,
  panes: { root: null, focusedPaneId: null },
  modeSwitch: false,
  splitOffer: false,
  swarmSessions: [],
  accountSwitch: null,
}

function recording(answer = true, rail: NativeSidebarInput = RAIL, strip: NativeTabsInput = STRIP) {
  const log: string[] = []
  const note = (entry: string): void => {
    log.push(entry)
  }
  const handlers: NativeHandlers = {
    run: (id) => {
      note(`run ${id}`)
      return answer
    },
    showPanel: (id: PanelId, focus?: string | null) => note(focus ? `panel ${id} ${focus}` : `panel ${id}`),
    showFile: (path) => note(`file ${path}`),
    openInspector: () => note('inspector'),
    showSessions: () => {
      note('sessions')
      return answer
    },
    renameSession: (id, name) => {
      note(`rename ${id} ${name}`)
      return answer
    },
    writeServerShell: (id, text) => {
      note(`write ${id} ${JSON.stringify(text)}`)
      return answer
    },
    serverShellOpened: (id, shellId) => {
      note(`opened ${id} ${shellId}`)
      return answer
    },
    serverShellEnded: (id) => {
      note(`ended ${id}`)
      return answer
    },
    newSessionAs: (path, account, provider) => {
      note(`new as ${String(path)} ${account} ${String(provider)}`)
      return answer
    },
    switchAccount: (id, account) => {
      note(`switch ${id} ${account}`)
      return answer
    },
    openServerShellWith: (id, agent) => {
      note(`server shell ${id} ${String(agent)}`)
      return answer
    },
    manageAccounts: (add) => note(add ? 'add account' : 'accounts'),
    setLayoutMode: (mode) => note(`mode ${mode}`),
    focusPaneById: (id) => {
      note(`focus ${id}`)
      return answer
    },
    resizeSplitTo: (id, ratio) => {
      note(`resize ${id} ${ratio}`)
      return answer
    },
    closePaneById: (id) => {
      note(`close pane ${id}`)
      return answer
    },
    openServerSession: (id, name, startIn) => note(`server session ${id} ${name} ${String(startIn)}`),
    serverRenamed: (id, name) => note(`server renamed ${id} ${name}`),
    rail: () => rail,
    openHoot: () => note('hoot'),
    openTab: (id) => note(`tab ${id}`),
    closeTab: (id) => note(`close ${id}`),
    retryHeld: (key) => note(`retry ${key}`),
    forgetHeld: (key) => note(`forget ${key}`),
    newSessionIn: (path) => note(`new in ${path}`),
    newMachineSession: (id) => note(`new on machine ${id}`),
    newServerSession: (id) => note(`new on server ${id}`),
    openProject: () => note('open project'),
    closeProject: (path) => note(`close project ${path}`),
    closeMachine: (id) => note(`close machine ${id}`),
    closeServer: (id) => note(`close server ${id}`),
    toggleGroup: (id) => note(`toggle ${id}`),
    openAlerts: () => note('alerts'),
    strip: () => strip,
    selectTab: (id) => note(`select tab ${id}`),
    setStripOrder: (order) => note(`order ${order.join(',')}`),
    showInstead: (id) => note(`show ${String(id)}`),
    closeWindow: (id) => note(`close window ${id}`),
    newTerminalTab: () => note('new terminal'),
    newBrowserTab: () => note('new browser'),
  }
  return { log, handlers }
}

describe('tdNative.run — the toolbar', () => {
  const expected: Record<string, string> = {
    'new-session': 'run session.new',
    'toggle-sidebar': 'run view.sidebar',
    'open-hoot': 'run view.copilot',
    'open-settings': 'run app.preferences',
    'open-tasks': 'panel tasks',
    'open-memory': 'panel memory',
  }

  for (const [name, call] of Object.entries(expected)) {
    it(`${name} → ${call}`, () => {
      const { log, handlers } = recording()
      expect(nativeCommands(() => handlers).run(name)).toBe(true)
      expect(log).toEqual([call])
    })
  }

  it('covers exactly the six toolbar names', () => {
    expect(Object.keys(NATIVE_COMMANDS).sort()).toEqual(Object.keys(expected).sort())
  })

  it('answers false, and does nothing, for a name it does not know', () => {
    const { log, handlers } = recording()
    const commands = nativeCommands(() => handlers)
    for (const name of ['', 'open-files', 'session.new', 'toString', '__proto__', 'constructor', 'settings-section']) {
      expect(commands.run(name, 'files'), name).toBe(false)
    }
    expect(commands.run(42 as unknown as string)).toBe(false)
    expect(log).toEqual([])
  })

  it('answers false before the window has mounted', () => {
    const commands = nativeCommands(() => null)
    expect(commands.run('new-session')).toBe(false)
    expect(commands.run('select', 'files')).toBe(false)
  })

  it('passes on what run answered, so a command nothing handled is not reported as done', () => {
    const { handlers } = recording(false)
    expect(nativeCommands(() => handlers).run('open-settings')).toBe(false)
  })

  it('reads the handlers when called, not when published', () => {
    let current = recording()
    const commands = nativeCommands(() => current.handlers)
    const first = current
    current = recording()
    commands.run('new-session')
    expect(first.log).toEqual([])
    expect(current.log).toEqual(['run session.new'])
  })
})

describe('tdNative.run — the side panel', () => {
  const cases: Array<[string, unknown, boolean, string[]]> = [
    // select
    ['select', 'files', true, ['panel files']],
    ['select', 'github', false, []], // not installed: the rail has no row for it
    ['select', 'hoot', true, ['hoot']],
    ['select', 's1', true, ['tab s1']],
    ['select', 'machine:pc:r1', true, ['tab machine:pc:r1']],
    ['select', 'server:box:1', true, ['tab server:box:1']],
    ['select', 'hoot-tab', false, []], // Hoot's own tab is the pinned row, not a session row
    ['select', 'held:k1', true, ['retry k1']],
    ['select', 'held:nope', false, []],
    ['select', 'nope', false, []],
    // close-session
    ['close-session', 's1', true, ['close s1']],
    ['close-session', 's2', false, []], // the row menu would not offer Delete
    ['close-session', 'held:k1', true, ['forget k1']],
    ['close-session', 'nope', false, []],
    // new-session-in
    ['new-session-in', '/work/api', true, ['new in /work/api']],
    ['new-session-in', 'machine:pc', true, ['new on machine pc']],
    ['new-session-in', 'server:box', true, ['new on server box']],
    ['new-session-in', '/elsewhere', false, []],
    ['new-session-in', 'hoot-started', false, []],
    // close-project
    ['close-project', '/work/api', true, ['close project /work/api']],
    ['close-project', 'machine:pc', true, ['close machine pc']],
    ['close-project', 'machine:old', false, []], // its build cannot end sessions from here
    ['close-project', 'server:box', true, ['close server box']],
    // toggle-project
    ['toggle-project', '/work/api', true, ['toggle /work/api']],
    ['toggle-project', 'machine:old', true, ['toggle machine:old']],
    ['toggle-project', 'other', false, []], // no such run is drawn: nothing is outside a project
    // open-project
    ['open-project', undefined, true, ['open project']],
  ]

  for (const [name, arg, answer, calls] of cases) {
    it(`${name}(${String(arg)}) → ${answer ? calls.join(', ') : 'false'}`, () => {
      const { log, handlers } = recording()
      expect(nativeCommands(() => handlers).run(name, arg)).toBe(answer)
      expect(log).toEqual(calls)
    })
  }

  it('refuses a missing or non-string id for every command that takes one', () => {
    const { log, handlers } = recording()
    const commands = nativeCommands(() => handlers)
    for (const name of NATIVE_SIDEBAR_COMMANDS.filter((entry) => entry !== 'open-project')) {
      expect(commands.run(name), name).toBe(false)
      expect(commands.run(name, 7), name).toBe(false)
      expect(commands.run(name, ''), name).toBe(false)
    }
    expect(log).toEqual([])
  })

  it('opens the Alerts sheet from the bell\u2019s row, where the install has a bell', () => {
    const shown = recording(true, { ...RAIL, alerts: { shown: true, count: 2 } })
    expect(nativeCommands(() => shown.handlers).run('select', 'alerts')).toBe(true)
    expect(shown.log).toEqual(['alerts'])
    const hidden = recording()
    expect(nativeCommands(() => hidden.handlers).run('select', 'alerts')).toBe(false)
    expect(hidden.log).toEqual([])
  })

  it('does not retry a held session that is already opening, as its rail row is disabled', () => {
    const { log, handlers } = recording(true, { ...RAIL, heldRetrying: ['k1'] })
    expect(nativeCommands(() => handlers).run('select', 'held:k1')).toBe(false)
    expect(log).toEqual([])
  })
})

describe('tdNative.run — the tabs', () => {
  const cases: Array<[string, unknown, boolean, string[]]> = [
    ['select-tab', 's2', true, ['select tab s2']],
    ['select-tab', 'page', true, ['select tab page']],
    ['select-tab', 's9', false, []], // not on the strip
    ['select-tab', undefined, false, []],
    // The session in front comes off the bar; the strip shows the next one instead.
    ['close-tab', 's1', true, ['order s2', 'show s2']],
    ['close-tab', 's2', true, ['order s1']],
    ['close-tab', 'page', true, ['close window page']],
    ['close-tab', 's9', false, []],
    ['new-terminal-tab', undefined, true, ['new terminal']],
    ['new-browser-tab', undefined, false, []], // no window can open here
  ]
  for (const [name, arg, answer, calls] of cases) {
    it(`${name}(${String(arg)}) → ${answer ? calls.join(', ') : 'false'}`, () => {
      const { log, handlers } = recording()
      expect(nativeCommands(() => handlers).run(name, arg)).toBe(answer)
      expect(log).toEqual(calls)
    })
  }

  it('opens a browser window when one can open', () => {
    const { log, handlers } = recording(true, RAIL, { ...STRIP, canNewBrowser: true })
    expect(nativeCommands(() => handlers).run('new-browser-tab')).toBe(true)
    expect(log).toEqual(['new browser'])
  })
})

describe('tdNative.run — the menu bar', () => {
  /** Every command the Electron application menu sends, read off `main/menu.ts`. */
  const MENU = readFileSync(join(__dirname, '../main/menu.ts'), 'utf8')
  const ids = [...new Set([...MENU.matchAll(/send\('([a-zA-Z.]+)'\)/g)].map((match) => match[1]))]

  it('reads the menu it maps', () => {
    expect(ids.length).toBeGreaterThan(15)
    expect(ids).toEqual(expect.arrayContaining(['app.palette', 'app.preferences', 'session.new', 'view.sidebar']))
  })

  it('runs each Electron menu command through the window\u2019s own dispatcher, by its own id', () => {
    for (const id of ids) {
      const { log, handlers } = recording()
      expect(nativeCommands(() => handlers).run('menu-command', id), id).toBe(true)
      expect(log).toEqual([`run ${id}`])
    }
  })

  it('is the dispatcher the Electron menu reaches, which answers every id it sends', () => {
    expect(APP).toContain('useEffect(() => window.deck.onMenuCommand((command) => void run(command)), [run])')
    // `reachable.test.ts` fails if any id the menu sends has no case in `run`.
    expect(readFileSync(join(__dirname, '../reachable.test.ts'), 'utf8')).toContain('dispatches every command the application menu sends')
  })

  it('answers false for an id nothing handles, a missing id, or before the window has mounted', () => {
    const { handlers } = recording(false)
    expect(nativeCommands(() => handlers).run('menu-command', 'app.nonsense')).toBe(false)
    const { log, handlers: quiet } = recording()
    expect(nativeCommands(() => quiet).run('menu-command')).toBe(false)
    expect(nativeCommands(() => quiet).run('menu-command', 3)).toBe(false)
    expect(nativeCommands(() => quiet).run('menu-command', '')).toBe(false)
    expect(log).toEqual([])
    expect(nativeCommands(() => null).run('menu-command', 'app.palette')).toBe(false)
  })
})

describe('every name lands on the app\u2019s own action', () => {
  const runTargets = Object.values(NATIVE_COMMANDS).flatMap((action) => ('run' in action ? [action.run] : []))
  const panelTargets = Object.values(NATIVE_COMMANDS).flatMap((action) => ('panel' in action ? [action.panel] : []))

  it('names panels the sidebar really has', () => {
    for (const panel of panelTargets) expect(isPanelId(panel), panel).toBe(true)
  })

  it('names commands the keymap binds where a chord exists', () => {
    const bound = new Set(KEYMAP.map((binding) => binding.id))
    for (const id of ['session.new', 'view.sidebar', 'app.preferences']) {
      expect(runTargets).toContain(id)
      expect(bound.has(id), id).toBe(true)
    }
  })

  /*
   * Each command row's `run`, paired with what the sidebar's own control for the
   * same thing calls — so a toolbar press, a chord and a click are one function.
   */
  const pairs: Array<{ id: string; row: string; sidebar: string }> = [
    {
      id: 'session.new',
      row: 'run: () => openNewSessionDialog()',
      sidebar: 'resume ? newSession(projectPath, true) : openNewSessionDialog(projectPath)',
    },
    { id: 'view.sidebar', row: 'run: () => sidebar.toggleCollapsed()', sidebar: 'onToggleCollapsed={sidebar.toggleCollapsed}' },
    { id: 'view.copilot', row: 'run: () => openCopilot()', sidebar: 'onOpenCopilot={(focus) => openCopilot(focus)}' },
    { id: 'app.preferences', row: 'run: () => openSettings()', sidebar: 'onOpenSettings={() => openSettings()}' },
  ]

  for (const { id, row, sidebar } of pairs) {
    it(`${id} is a palette row whose run is the sidebar control\u2019s own call`, () => {
      expect(runTargets).toContain(id)
      const at = APP.indexOf(`id: '${id}',`)
      expect(at, `no command row with id ${id} in App.tsx`).toBeGreaterThan(-1)
      const body = APP.slice(at, APP.indexOf('}', at))
      expect(body).toContain(row)
      expect(APP).toContain(sidebar)
    })
  }

  /*
   * Each side-panel handler, and the rail prop that is the same function. Read
   * as text: the handler object in `App.tsx` must name the very value the rail
   * is handed, or the two could drift into two behaviours for one press.
   */
  const handed: Array<[string, string]> = [
    ['showPanel,', 'onSelectPanel={showPanel}'],
    ['openTab: openTabWindow,', 'onSelectTab={openTabWindow}'],
    ['closeTab,', 'onCloseTab={closeTab}'],
    ['retryHeld: openHeld,', 'onRetryHeld={openHeld}'],
    ['forgetHeld: held.forget,', 'onForgetHeld={held.forget}'],
    ['newMachineSession: (machineId) => openNewSessionDialog(null, machineId),', 'onNewMachineSession={(machineId) => openNewSessionDialog(null, machineId)}'],
    ['newServerSession,', 'onNewServerSession={newServerSession}'],
    ['openProject: () => void openProject(),', 'onOpenProject={openProject}'],
    ['closeProject,', 'onCloseProject={closeProject}'],
    ['closeMachine,', 'onCloseMachine={closeMachine}'],
    ['closeServer,', 'onCloseServer={closeServer}'],
    ['openAlerts: () => setAlertsOpen(true),', 'onOpenAlerts={() => setAlertsOpen(true)}'],
    ['openHoot: () => openCopilot(),', 'onOpenCopilot={(focus) => openCopilot(focus)}'],
    ['newSessionIn: (path) => openNewSessionDialog(path),', 'openNewSessionDialog(projectPath)'],
  ]
  const block = APP.slice(APP.indexOf('nativeHandlers.current = {'), APP.indexOf('}', APP.indexOf('nativeHandlers.current = {')))
  for (const [handler, rail] of handed) {
    it(`${handler.split(':')[0].replace(',', '')} is the rail\u2019s own ${rail.split('=')[0]}`, () => {
      expect(block).toContain(handler)
      expect(APP).toContain(rail)
    })
  }

  it('builds the native panel from the very values the rail is handed', () => {
    for (const prop of [
      'panels={railPanels}',
      'active: railCopilotActive,',
      'machines={railMachines}',
      'servers={railServers}',
      'activeTabId={railActiveTabId}',
      'unread={unreadIds}',
      'held={held.rows}',
      'heldRetrying={held.retrying}',
    ]) {
      expect(APP, prop).toContain(prop)
    }
    const input = APP.slice(APP.indexOf('railInput.current = {'), APP.indexOf('nativeHandlers.current = {'))
    for (const field of [
      'panels: railPanels,',
      'active: railCopilotActive',
      'activePanel: panel,',
      'projects,',
      'tabs,',
      'activeTabId: railActiveTabId,',
      'unread: unreadIds,',
      'held: held.rows,',
      'heldRetrying: held.retrying,',
      'machines: railMachines,',
      'servers: railServers,',
    ]) {
      expect(input, field).toContain(field)
    }
  })

  /* And each tab handler, against the prop the web strip is handed. */
  const strip: Array<[string, string]> = [
    ['selectTab,', 'onSelect={selectTab}'],
    ['showInstead,', 'onShowInstead={showInstead}'],
    ['closeWindow: closeTab,', 'onCloseWindow={closeTab}'],
    ['newTerminalTab: () => openNewSessionDialog(),', 'onNewSession={() => openNewSessionDialog()}'],
    ['newBrowserTab: () => newBrowserTab(),', 'onNewBrowserTab={() => newBrowserTab()}'],
    ['setStripOrder,', 'const [stripOrder, setStripOrder] = usePromotedOrder()'],
  ]
  for (const [handler, prop] of strip) {
    it(`${handler.split(':')[0].replace(',', '')} is the strip\u2019s own ${prop.split('=')[0]}`, () => {
      expect(block).toContain(handler)
      expect(APP).toContain(prop)
    })
  }

  it('always offers a way to open a browser in the native window', () => {
    expect(APP.slice(APP.indexOf('stripInput.current = {'))).toContain('canNewBrowser: true,')
  })

  it('builds the native tabs from the very values the strip is handed', () => {
    for (const prop of ['tabs={openTabs}', 'activeTabId={railActiveTabId}', 'covered={showingPanel}']) {
      expect(APP, prop).toContain(prop)
    }
    const input = APP.slice(APP.indexOf('stripInput.current = {'), APP.indexOf('nativeHandlers.current = {'))
    for (const field of ['order: stripOrder,', 'tabs: openTabs,', 'activeTabId: railActiveTabId,', 'covered: showingPanel,', 'unread: unreadIds,']) {
      expect(input, field).toContain(field)
    }
  })

  it('is published by the window', () => {
    expect(APP).toContain('useEffect(() => publishNativeCommands(() => nativeHandlers.current), [])')
  })
})

describe('publishing the commands', () => {
  function host(native: boolean) {
    const posted: unknown[] = []
    const target: NativeHost = {
      document: { documentElement: { dataset: native ? { shell: 'native' } : {} } },
      webkit: { messageHandlers: { [NATIVE_MESSAGE_HANDLER]: { postMessage: (message) => posted.push(message) } } },
    }
    return { target, posted }
  }

  it('does nothing inside Electron', () => {
    const { target, posted } = host(false)
    expect(isNativeShell(target)).toBe(false)
    const cleanup = publishNativeCommands(() => recording().handlers, target)
    expect(target.tdNative).toBeUndefined()
    expect(posted).toEqual([])
    cleanup()
  })

  it('replaces the early stub, says ready once per page, and puts the stub back on unmount', () => {
    const { target, posted } = host(true)
    const stub = { run: () => false }
    target.tdNative = stub
    const { log, handlers } = recording()

    const cleanup = publishNativeCommands(() => handlers, target)
    expect((target.tdNative as { run(name: string, arg?: unknown): boolean }).run('select', 'tasks')).toBe(true)
    expect(log).toEqual(['panel tasks'])
    expect(posted).toEqual([{ type: 'ready' }])

    cleanup()
    expect(target.tdNative).toBe(stub)

    // Strict mode mounts again: the commands come back, the ready does not.
    publishNativeCommands(() => handlers, target)
    expect(target.tdNative).not.toBe(stub)
    expect(posted).toEqual([{ type: 'ready' }])
  })

  it('does not throw when nothing on the native side is listening', () => {
    const target: NativeHost = { document: { documentElement: { dataset: { shell: 'native' } } } }
    expect(() => publishNativeCommands(() => null, target)).not.toThrow()
  })
})

describe('the title', () => {
  it('is the heading, with the project under it', () => {
    expect(nativeTitle('fix login', 'api')).toEqual({ type: 'title', value: 'fix login', subtitle: 'api' })
    expect(nativeTitle('Files', 'api')).toEqual({ type: 'title', value: 'Files', subtitle: 'api' })
  })

  it('never says the same words twice', () => {
    // A session still named after its folder.
    expect(nativeTitle('api', 'api')).toEqual({ type: 'title', value: 'api' })
  })

  it('names the app when the heading has nothing, and leaves out a missing project', () => {
    expect(nativeTitle(null, null)).toEqual({ type: 'title', value: BRAND.name })
    expect(nativeTitle('Store', '')).toEqual({ type: 'title', value: 'Store' })
  })

  it('is posted only when it changes', () => {
    const posted: NativeTitleMessage[] = []
    const publisher = createTitlePublisher((message) => posted.push(message))
    publisher.update(nativeTitle('a', 'api'))
    publisher.update(nativeTitle('a', 'api'))
    publisher.update(nativeTitle('b', 'api'))
    publisher.update(nativeTitle('b', null))
    expect(posted.map((message) => [message.value, message.subtitle ?? null])).toEqual([
      ['a', 'api'],
      ['b', 'api'],
      ['b', null],
    ])
  })

  it('is posted by the window from its own heading', () => {
    expect(APP).toContain('titleInput.current = nativeTitle(')
    expect(APP).toContain('heading.title,')
  })
})

describe('Settings, from the main window', () => {
  it('posts open-settings in native mode instead of opening the sheet, from the one function every path uses', () => {
    const open = APP.slice(APP.indexOf('const openSettings = useCallback('), APP.indexOf('}, [])', APP.indexOf('const openSettings = useCallback(')))
    expect(open).toContain('if (isNativeShell()) {')
    expect(open).toContain('postToNative(\n        openSettingsMessage(\n          section,')
    // Every `setPrefsOpen(true)` is inside `openSettings` — no path around it.
    expect(APP.match(/setPrefsOpen\(true\)/g)).toHaveLength(1)
    expect(open).toContain('setPrefsOpen(true)')
  })

  it('hands the Settings page\u2019s three hand-backs to the same calls the sheet makes', () => {
    expect(APP).toContain("if (message.type === 'changed') applySettings(message.values)")
    expect(APP).toContain("newSession(undefined, false, message.profileId, message.provider)")
    expect(APP).toContain('else setCopilotSetupOpen(true)')
    expect(APP).toContain('onChange={applySettings}')
    expect(APP).toContain('newSession(undefined, false, profileId, provider)')
  })
})

describe('doors between views (lanes A and V)', () => {
  it('open-file opens the Files view on that file', () => {
    const { log, handlers } = recording()
    const run = nativeCommands(() => handlers).run
    expect(run('open-file', 'src/a.ts')).toBe(true)
    expect(run('open-file', '')).toBe(false)
    expect(run('open-file')).toBe(false)
    expect(log).toEqual(['file src/a.ts'])
  })

  it('show-panel opens a view on one part of it, only a view the rail draws', () => {
    const { log, handlers } = recording()
    const run = nativeCommands(() => handlers).run
    expect(run('show-panel', ['git', 'staged'])).toBe(true)
    expect(run('show-panel', ['tasks'])).toBe(true)
    expect(run('show-panel', ['github', 'issues'])).toBe(false) // not on this rail
    expect(run('show-panel', ['nonsense', 'x'])).toBe(false)
    expect(run('show-panel', 'git')).toBe(false)
    expect(log).toEqual(['panel git staged', 'panel tasks'])
  })

  it('open-inspector and show-sessions; show-sessions says when swarm is not there', () => {
    const { log, handlers } = recording()
    expect(nativeCommands(() => handlers).run('open-inspector')).toBe(true)
    expect(nativeCommands(() => handlers).run('show-sessions')).toBe(true)
    expect(log).toEqual(['inspector', 'sessions'])
    const off = recording(false)
    expect(nativeCommands(() => off.handlers).run('show-sessions')).toBe(false)
  })

  it('App hands over the dashboard\'s own doors and publishes what they leave', () => {
    const handlersBlock = APP.slice(APP.indexOf('const nativeDoorHandlers'))
    expect(handlersBlock).toContain('showFile,')
    expect(handlersBlock).toContain('openInspector: () => setInspectorOpen(true)')
    expect(handlersBlock).toContain("if (!features.on('swarm')) return false")
    expect(APP.slice(APP.indexOf('nativeHandlers.current = {'))).toContain('...nativeDoorHandlers,')
    const railBlock = APP.slice(APP.indexOf('railInput.current = {'))
    expect(railBlock).toContain('openFile,')
    expect(railBlock).toContain('focus: panelFocus,')
  })
})

describe('sessions drawn natively (lanes T and V)', () => {
  it('each takes [tabId, value] and reaches its handler', () => {
    const { log, handlers } = recording()
    const run = nativeCommands(() => handlers).run
    expect(run('rename-session', ['s1', 'API work'])).toBe(true)
    expect(run('server-shell-write', ['server:box:1', 'ls\r'])).toBe(true)
    expect(run('server-shell-opened', ['server:box:1', 'sh-7'])).toBe(true)
    expect(run('server-shell-ended', ['server:box:1'])).toBe(true)
    expect(log).toEqual(['rename s1 API work', 'write server:box:1 "ls\\r"', 'opened server:box:1 sh-7', 'ended server:box:1'])
  })

  it('refuses a missing tab id, a missing value or an empty shell id', () => {
    const { log, handlers } = recording()
    const run = nativeCommands(() => handlers).run
    expect(run('rename-session', 's1')).toBe(false)
    expect(run('rename-session', ['', 'x'])).toBe(false)
    expect(run('rename-session', ['s1'])).toBe(false)
    expect(run('server-shell-write', ['server:box:1', 3])).toBe(false)
    expect(run('server-shell-opened', ['server:box:1', ''])).toBe(false)
    expect(log).toEqual([])
  })

  it('passes the page\'s own answer back (no shell open, blank name)', () => {
    const off = recording(false)
    expect(nativeCommands(() => off.handlers).run('server-shell-write', ['server:box:1', 'x'])).toBe(false)
    expect(nativeCommands(() => off.handlers).run('rename-session', ['s1', ' '])).toBe(false)
  })

  it('App renames as the rail does and writes through the tab\'s shell id', () => {
    const block = APP.slice(APP.indexOf('const nativeDoorHandlers'))
    expect(block).toContain('const name = userSessionTitle(typed)')
    expect(block).toContain('setSessionTitle(tabId, name, { fromUser: true })')
    expect(block).toContain('void window.deck.renameSession?.(tabId, name)')
    expect(block).toContain('const shellId = serverShellIds[tabId]')
    expect(block).toContain('void serversBridge.writeToServerShell(shellId, text)')
    const strip = APP.slice(APP.indexOf('stripInput.current = {'))
    expect(strip).toContain('serverSessions,')
    expect(strip).toContain('serverShellIds,')
  })
})

describe('the account chips drawn natively (lane T)', () => {
  it('each reaches the chip\'s own handler, blanks read as none', () => {
    const { log, handlers } = recording()
    const run = nativeCommands(() => handlers).run
    expect(run('new-session-as', ['/work/api', 'acc-1', 'codex'])).toBe(true)
    expect(run('new-session-as', ['', 'acc-1', ''])).toBe(true)
    expect(run('switch-account', ['s1', 'acc-2'])).toBe(true)
    expect(run('open-server-shell', ['box', 'claude'])).toBe(true)
    expect(run('open-server-shell', ['box', ''])).toBe(true)
    expect(run('add-account')).toBe(true)
    expect(run('manage-accounts')).toBe(true)
    expect(log).toEqual([
      'new as /work/api acc-1 codex',
      'new as null acc-1 null',
      'switch s1 acc-2',
      'server shell box claude',
      'server shell box null',
      'add account',
      'accounts',
    ])
  })

  it('refuses a missing account, session or server', () => {
    const { log, handlers } = recording()
    const run = nativeCommands(() => handlers).run
    expect(run('new-session-as', ['/work/api', ''])).toBe(false)
    expect(run('switch-account', ['s1'])).toBe(false)
    expect(run('switch-account', ['s1', 4])).toBe(false)
    expect(run('open-server-shell', [''])).toBe(false)
    expect(run('open-server-shell', 'box')).toBe(false)
    expect(log).toEqual([])
  })

  it('App hands over the chips\' own acts', () => {
    const block = APP.slice(APP.indexOf('const nativeDoorHandlers'))
    expect(block).toContain('newSession(projectPath ?? undefined, false, accountId, runAs)')
    expect(block).toContain('switcher.ask({ sessionId, profileId: accountId })')
    expect(block).toContain('openServerShell(serverId, group.serverName, null, agentId === null ? null : agentCommand(agentId))')
    expect(block).toContain('if (add) askForAddAccount()')
    expect(block).toContain("openSettings('profiles')")
  })
})

describe('split and swarm drawn natively (lane T)', () => {
  it('each reaches the page\'s own act', () => {
    const { log, handlers } = recording()
    const run = nativeCommands(() => handlers).run
    expect(run('set-mode', ['split'])).toBe(true)
    expect(run('set-mode', ['terminal'])).toBe(true)
    expect(run('focus-pane', ['p2'])).toBe(true)
    expect(run('resize-split', ['sp1', '0.35'])).toBe(true)
    expect(run('close-pane', ['p1'])).toBe(true)
    expect(log).toEqual(['mode split', 'mode terminal', 'focus p2', 'resize sp1 0.35', 'close pane p1'])
  })

  it('refuses a mode, ratio or id it cannot use', () => {
    const { log, handlers } = recording()
    const run = nativeCommands(() => handlers).run
    expect(run('set-mode', ['chat'])).toBe(false)
    expect(run('set-mode', 'split')).toBe(false)
    expect(run('resize-split', ['sp1', '1'])).toBe(false)
    expect(run('resize-split', ['sp1', 'wide'])).toBe(false)
    expect(run('resize-split', ['sp1', ''])).toBe(false)
    expect(run('focus-pane', [''])).toBe(false)
    expect(log).toEqual([])
  })

  it('App hands over ModeSwitch\'s and SplitView\'s own acts, and publishes the arrangement', () => {
    const block = APP.slice(APP.indexOf('const nativeDoorHandlers'))
    expect(block).toContain('setLayoutMode: setMode,')
    expect(block).toContain('setPanes((current) => focusPane(current, paneId))')
    expect(block).toContain('setPanes((current) => resizeSplit(current, splitId, ratio))')
    expect(block).toContain('closePaneAt(paneId)')
    const strip = APP.slice(APP.indexOf('stripInput.current = {'))
    expect(strip).toContain("splitOffer: !features.on('split'),")
    expect(strip).toContain('!(headingTab?.isCopilot && copilotMachine !== null) &&')
  })
})

describe('the servers screens drawn natively (lane G)', () => {
  it('opens a terminal on a server, in a folder or not, and passes a rename on', () => {
    const { log, handlers } = recording()
    const run = nativeCommands(() => handlers).run
    expect(run('open-server-session', ['box', 'Box', '/srv/app'])).toBe(true)
    expect(run('open-server-session', ['box', 'Box', ''])).toBe(true)
    expect(run('server-renamed', ['box', 'Big box'])).toBe(true)
    expect(log).toEqual(['server session box Box /srv/app', 'server session box Box null', 'server renamed box Big box'])
  })

  it('refuses a missing server, name, or a non-text part', () => {
    const { log, handlers } = recording()
    const run = nativeCommands(() => handlers).run
    expect(run('open-server-session', ['', 'Box'])).toBe(false)
    expect(run('open-server-session', ['box'])).toBe(false)
    expect(run('server-renamed', ['box', 3])).toBe(false)
    expect(run('server-renamed', 'box')).toBe(false)
    expect(log).toEqual([])
  })

  it('App hands over ServerSessions\' own acts', () => {
    const block = APP.slice(APP.indexOf('const nativeDoorHandlers'))
    expect(block).toContain('serverSessionOpener.open(serverId, serverName, startIn)')
    expect(block).toContain('serverSessionOpener.renamed(serverId, name)')
  })
})
