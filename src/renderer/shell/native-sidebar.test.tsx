import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { BRAND } from '../../shared/brand'
import type { HeldSessionView } from '../held-sessions'
import {
  BROWSER_SYMBOL,
  EMPTY_NATIVE_RAIL,
  HELD_SYMBOL,
  HOOT_STARTED_GROUP,
  HOOT_SYMBOL,
  OTHER_GROUP,
  PANEL_SYMBOLS,
  SESSION_SYMBOL,
  SIDEBAR_PUBLISH_MS,
  buildNativeSidebar,
  createSidebarPublisher,
  type NativeSidebarInput,
  type NativeSidebarState,
} from './native-sidebar'
import { PANELS } from './panels'
import { Sidebar, type SidebarMachine, type SidebarServer } from './Sidebar'
import type { WorkspaceTab } from './workspace-tabs'

/**
 * The native side panel is the web rail, described.
 *
 * Unit checks on the shape, and then the one that matters most: the real
 * `Sidebar` is rendered from the same input and every name it prints — views,
 * group headings, project and machine headings, session rows, held rows — must
 * come out of the builder in the same order. A rail change the builder does not
 * follow fails here rather than as a native panel that quietly disagrees with
 * the web one.
 */

const tab = (id: string, extra: Partial<WorkspaceTab> = {}): WorkspaceTab => ({
  id,
  kind: 'session',
  label: 'Session',
  status: 'idle',
  projectPath: '/work/api',
  closable: true,
  ...extra,
})

const HELD: HeldSessionView[] = [
  { key: 'k1', cwd: '/work/api', provider: 'claude', reason: 'the folder is gone', pick: false, at: 0 },
  { key: 'k2', cwd: '/tmp/loose', provider: 'codex', reason: 'gone', pick: false, at: 0 },
]

const MACHINES: SidebarMachine[] = [
  {
    machineId: 'pc',
    name: 'Office PC',
    sessions: [tab('machine:pc:r1', { label: 'build', projectPath: 'C:/code/site', machine: { id: 'pc', name: 'Office PC' } })],
    canClose: true,
  },
]

const SERVERS: SidebarServer[] = [
  { serverId: 'box', name: 'box', sessions: [tab('server:box:1', { label: 'shell', projectPath: undefined })] },
]

const INPUT: NativeSidebarInput = {
  hoot: { name: 'Hoot', stage: 'ready', active: false },
  panels: PANELS.filter((panel) => panel.id !== 'github'),
  activePanel: null,
  projects: [
    { path: '/work/api', name: 'api' },
    { path: '/work/web', name: 'web' },
  ],
  tabs: [
    tab('s1', { label: 'fix login' }),
    tab('s2', { label: 'fix login', status: 'working' }),
    tab('s3', { label: 'Session', projectPath: '/work/web' }),
    tab('b1', { kind: 'browser', label: 'Docs', projectPath: undefined }),
    tab('lost', { label: 'stray', projectPath: '/somewhere/else' }),
    tab('h1', { label: 'research', origin: 'copilot', projectPath: '/work/api' }),
    tab('a1', { label: 'triage', origin: 'app', originApp: 'ChatGPT', projectPath: '/work/web' }),
    tab('hoot-own', { label: 'Hoot', isCopilot: true }),
  ],
  activeTabId: 's2',
  unread: ['s3'],
  held: HELD,
  heldRetrying: ['k2'],
  machines: MACHINES,
  servers: SERVERS,
  folded: new Set(['/work/web']),
  alerts: { shown: false, count: 0 },
  project: '/work/api',
}

describe('the state', () => {
  const state = buildNativeSidebar(INPUT)

  it('starts with Hoot, then the Project and Integrations runs of the installed views', () => {
    expect(state.groups.map((group) => [group.id, group.title])).toEqual([
      ['hoot', null],
      ['project', 'Project'],
      ['integrations', 'Integrations'],
    ])
    expect(state.groups[0].items).toEqual([{ id: 'hoot', title: 'Hoot', symbol: HOOT_SYMBOL, kind: 'hoot', status: 'idle' }])
    const views = state.groups.slice(1).flatMap((group) => group.items)
    expect(views.map((item) => item.id)).toEqual(INPUT.panels.map((panel) => panel.id))
    expect(views.every((item) => item.kind === 'panel' && item.symbol === PANEL_SYMBOLS[item.id as keyof typeof PANEL_SYMBOLS])).toBe(true)
    // Not installed, no row — as on the rail.
    expect(views.some((item) => item.id === 'github')).toBe(false)
  })

  it('lists every open project with its sessions, then every other run the rail draws, in its order', () => {
    expect(state.projects.map((entry) => [entry.id, entry.title, entry.expanded])).toEqual([
      ['/work/api', 'api', true],
      ['/work/web', 'web', false],
      [OTHER_GROUP, 'Open', true],
      [HOOT_STARTED_GROUP, `Started by ${BRAND.assistant}`, true],
      ['app:ChatGPT', 'From ChatGPT', true],
      ['machine:pc', 'Office PC', true],
      ['server:box', 'box', true],
    ])
  })

  it('names rows as the rail does, and tells two same-named rows apart', () => {
    const api = state.projects[0]
    expect(api.sessions.map((item) => item.id)).toEqual(['s1', 's2', 'held:k1'])
    expect(api.sessions[0].title).toBe('fix login')
    expect(api.sessions[0].subtitle).toBeDefined()
    expect(api.sessions[0].subtitle).not.toBe(api.sessions[1].subtitle)
    expect(api.sessions[1]).toMatchObject({ kind: 'session', symbol: SESSION_SYMBOL, status: 'working' })
    expect(api.sessions[2]).toMatchObject({ title: 'Claude Code', symbol: HELD_SYMBOL, status: 'held', subtitle: 'Not reopened' })
  })

  it('marks unread rows, and a held row that is already opening', () => {
    expect(state.projects[1].sessions[0]).toMatchObject({ id: 's3', unread: true })
    expect(state.projects[0].sessions[0].unread).toBeUndefined()
    const loose = state.projects.find((entry) => entry.id === OTHER_GROUP)
    expect(loose?.sessions.map((item) => [item.id, item.subtitle ?? null])).toEqual([
      ['lost', null],
      ['held:k2', 'Opening…'],
    ])
  })

  it('leaves out browser pages and Hoot\u2019s own window, which the rail does not list as rows', () => {
    const ids = state.projects.flatMap((entry) => entry.sessions.map((item) => item.id))
    expect(ids).not.toContain('b1')
    expect(ids).not.toContain('hoot-own')
    expect(ids).toContain('h1')
    expect(ids).toContain('a1')
  })

  it('names the project the page considers current, so native screens need not guess it', () => {
    expect(state.project).toBe('/work/api')
    expect(buildNativeSidebar({ ...INPUT, project: null }).project).toBeNull()
    expect(buildNativeSidebar(EMPTY_NATIVE_RAIL).project).toBeNull()
  })

  it('selects what the rail draws as current', () => {
    expect(state.selectedId).toBe('s2')
    expect(buildNativeSidebar({ ...INPUT, activePanel: 'files' }).selectedId).toBe('files')
    expect(buildNativeSidebar({ ...INPUT, hoot: { ...INPUT.hoot, active: true } }).selectedId).toBe('hoot')
  })

  it('has a symbol for every view, and a browser page or a stopped Hoot is drawn honestly', () => {
    for (const panel of PANELS) expect(PANEL_SYMBOLS[panel.id], panel.id).toMatch(/^[a-z0-9.]+$/)
    const withPage = buildNativeSidebar({
      ...INPUT,
      tabs: [tab('p1', { kind: 'browser', label: 'Docs', origin: 'copilot' })],
      hoot: { name: 'Hoot', stage: 'stopped', active: false },
    })
    expect(withPage.projects.find((entry) => entry.id === HOOT_STARTED_GROUP)).toBeUndefined()
    expect(withPage.groups[0].items[0].status).toBeUndefined()
    expect(BROWSER_SYMBOL).toBe('globe')
  })

  it('is plain data the native side can decode: no undefined fields, nothing but JSON', () => {
    const text = JSON.stringify(state)
    expect(JSON.parse(text)).toEqual(state)
    expect(text).not.toContain('undefined')
  })

  it('puts the bell beside Settings in the foot, with its count, where the install has one', () => {
    const withBell = buildNativeSidebar({ ...INPUT, alerts: { shown: true, count: 3 } })
    expect(withBell.groups.at(-1)).toEqual({
      id: 'foot',
      title: null,
      items: [{ id: 'alerts', title: 'Alerts', symbol: 'bell', kind: 'panel', unread: true, subtitle: '3 new' }],
    })
    const quiet = buildNativeSidebar({ ...INPUT, alerts: { shown: true, count: 0 } })
    expect(quiet.groups.at(-1)?.items).toEqual([{ id: 'alerts', title: 'Alerts', symbol: 'bell', kind: 'panel' }])
    expect(state.groups.some((group) => group.id === 'foot')).toBe(false)
  })

  it('is just Hoot before the window has drawn anything', () => {
    const empty = buildNativeSidebar(EMPTY_NATIVE_RAIL)
    expect(empty.groups.map((group) => group.id)).toEqual(['hoot'])
    expect(empty.projects).toEqual([])
    expect(empty.selectedId).toBeNull()
  })
})

describe('the same rail the web draws', () => {
  /** Every name the rail prints, in document order. */
  function railNames(input: NativeSidebarInput): string[] {
    const html = renderToStaticMarkup(
      <Sidebar
        width={280}
        projects={[...input.projects]}
        tabs={[...input.tabs]}
        activeTabId={input.activeTabId}
        activePanel={input.activePanel}
        panels={input.panels}
        browser={false}
        browserOffer={null}
        machines={input.machines}
        servers={input.servers}
        alerts={false}
        alertCount={0}
        unread={input.unread}
        held={input.held}
        heldRetrying={input.heldRetrying}
        onRetryHeld={() => {}}
        onForgetHeld={() => {}}
        peeking={false}
        update={null}
        copilot={{ stage: input.hoot.stage ?? 'stopped', state: null, active: input.hoot.active, name: input.hoot.name }}
        onSelectTab={() => {}}
        onCloseTab={() => {}}
        onSelectPanel={() => {}}
        onNewSession={() => {}}
        onNewBrowserTab={() => {}}
        onOpenProject={() => {}}
        onCloseProject={() => {}}
        onOpenSettings={() => {}}
        onOpenAlerts={() => {}}
        onToggleCollapsed={() => {}}
        onPeekStart={() => {}}
        onPeekEnd={() => {}}
        onStartResize={() => {}}
        storage={null}
      />,
    )
    const names = [
      ...html.matchAll(/<(?:span|h2)[^>]*class="(?:sb-label|sb-project-name|sb-group-label)"[^>]*>([^<]*)</g),
    ].map((match) => match[1].replace(/&#x27;/g, "'"))
    // The foot's Settings line is the native toolbar's now, not the panel's.
    expect(names.at(-1)).toBe('Settings')
    return names.slice(0, -1)
  }

  /** The same names, read off the native state in the order the rail prints them. */
  function nativeNames(state: NativeSidebarState): string[] {
    const [hoot, ...runs] = state.groups
    return [
      ...hoot.items.map((item) => item.title),
      ...runs.flatMap((group) => [...(group.title === null ? [] : [group.title]), ...group.items.map((item) => item.title)]),
      'Open',
      ...state.projects.flatMap((entry) => [
        // Sessions outside any open project sit under "Open" with no heading of their own.
        ...(entry.id === OTHER_GROUP ? [] : [entry.title]),
        ...(entry.expanded ? entry.sessions.map((item) => item.title) : []),
      ]),
    ]
  }

  it('prints the same names in the same order, folds and all', () => {
    // The web rail's folds are its own; open everything on both sides to compare.
    const open = { ...INPUT, folded: new Set<string>() }
    const rail = railNames(open)
    // Not vacuous: views, headings, sessions, held rows, machines and servers.
    expect(rail.length).toBeGreaterThan(25)
    expect(rail).toEqual(expect.arrayContaining(['Hoot', 'Files', 'fix login', 'Claude Code', 'Office PC', 'shell']))
    expect(nativeNames(buildNativeSidebar(open))).toEqual(rail)
  })

  it('agrees on a bare window too', () => {
    const bare = { ...EMPTY_NATIVE_RAIL, hoot: { name: 'Hoot', stage: null, active: false }, panels: PANELS }
    expect(nativeNames(buildNativeSidebar(bare))).toEqual(railNames(bare))
  })
})

describe('publishing', () => {
  function clock() {
    const timers: Array<{ run: () => void; ms: number }> = []
    return {
      timers,
      schedule: (run: () => void, ms: number) => timers.push({ run, ms }),
      fire: () => timers.shift()?.run(),
    }
  }

  it('gathers a burst of changes into one post, sent with what is current when the wait ends', () => {
    const posted: NativeSidebarState[] = []
    const time = clock()
    const publisher = createSidebarPublisher((message) => posted.push(message.state), time.schedule)
    publisher.update(() => buildNativeSidebar({ ...INPUT, activeTabId: 's1' }))
    publisher.update(() => buildNativeSidebar({ ...INPUT, activeTabId: 's2' }))
    publisher.update(() => buildNativeSidebar({ ...INPUT, activeTabId: 's3' }))
    expect(time.timers).toHaveLength(1)
    expect(time.timers[0].ms).toBe(SIDEBAR_PUBLISH_MS)
    expect(posted).toEqual([])
    time.fire()
    expect(posted.map((state) => state.selectedId)).toEqual(['s3'])
  })

  it('posts nothing when nothing the panel draws has changed', () => {
    const posted: NativeSidebarState[] = []
    const time = clock()
    const publisher = createSidebarPublisher((message) => posted.push(message.state), time.schedule)
    publisher.update(() => buildNativeSidebar(INPUT))
    time.fire()
    publisher.update(() => buildNativeSidebar(INPUT))
    time.fire()
    publisher.update(() => buildNativeSidebar({ ...INPUT, unread: [] }))
    time.fire()
    expect(posted).toHaveLength(2)
  })

  it('posts the contract\u2019s message: {type: "sidebar", state}', () => {
    const messages: unknown[] = []
    const time = clock()
    createSidebarPublisher((message) => messages.push(message), time.schedule).update(() => buildNativeSidebar(EMPTY_NATIVE_RAIL))
    time.fire()
    expect(messages).toEqual([{ type: 'sidebar', state: buildNativeSidebar(EMPTY_NATIVE_RAIL) }])
  })
})
