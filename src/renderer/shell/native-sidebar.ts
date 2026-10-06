/**
 * The side panel, described for the native macOS window to draw.
 *
 * Inside the native window the web rail (`Sidebar.tsx`) is hidden and AppKit
 * draws the side panel instead. It has to be *the same* panel: the same rows,
 * in the same order, named the same way, with the same one selected. So this is
 * built from exactly what `App.tsx` hands the rail, through the same functions
 * the rail uses to name and partition its rows — `partitionByOrigin`,
 * `sameFolder`, `sessionLabel`, `tabQualifiers`, `heldAgentName`, `folderName`
 * — and `native-sidebar.test.ts` renders the real rail beside it and compares
 * the two, so a rail change that this does not follow fails there.
 *
 * ## The shape (the contract with `macos/`)
 *
 *   { groups:   [{ id, title|null, items: [Item] }],
 *     projects: [{ id, title, expanded, sessions: [Item] }],
 *     selectedId: string|null,
 *     project: string|null,        the project the page's views are about
 *     openFile: string|null,       the file the Files view has open (`showFile`)
 *     focus: string|null }         the part of a view it was opened on (`panelFocus`:
 *                                  a Git group, GitHub's 'issues', 'task:<id>@<time>')
 *   Item = { id, title, symbol, kind: 'hoot'|'panel'|'session', unread?, status?, subtitle? }
 *
 * `groups` is the top of the rail: Hoot, then the Project and Integrations
 * runs. `projects` is everything under "Open", in the rail's order: each open
 * project (id = its path) with its sessions, then — only when they have rows,
 * as on the rail — sessions in no open project (`other`), the ones Hoot started
 * (`hoot-started`), each outside AI app's (`app:<name>`), each paired machine
 * (`machine:<id>`) and each server (`server:<id>`). Those ids are not paths, so
 * nothing that expects a folder can be handed one by mistake.
 */

import { BRAND } from '../../shared/brand'
import { entryDot, type CopilotStage } from '../copilot/copilot-model'
import { partitionByOrigin, turnOf } from '../copilot/session-origin'
import { MAX_PROMOTED } from '../browser/workspace-strip'
import { heldAgentName, type HeldSessionView } from '../held-sessions'
import { folderName, sameFolder } from '../session-title'
import { PANEL_GROUPS, type PanelId, type PanelSpec } from './panels'
import type { SidebarMachine, SidebarServer } from './Sidebar'
import { sessionLabel, tabQualifiers, type WorkspaceTab } from './workspace-tabs'

/* --------------------------------------------------------------- shape -- */

export interface NativeSidebarItem {
  id: string
  title: string
  /** An SF Symbol name. */
  symbol: string
  kind: 'hoot' | 'panel' | 'session'
  unread?: boolean
  status?: string
  subtitle?: string
  /** The row's whole tooltip, when it says more than the title (a held session's reason). */
  help?: string
  /** The row menu (session-row-menu.ts): the copilot turn that started it, */
  turn?: string
  /** whether it is in the top strip, */
  promoted?: boolean
  /** and why it cannot go there (the strip is full). */
  promoteBlocked?: string
}

export interface NativeSidebarGroup {
  id: string
  title: string | null
  items: NativeSidebarItem[]
}

export interface NativeSidebarProject {
  id: string
  title: string
  expanded: boolean
  sessions: NativeSidebarItem[]
}

export interface NativeSidebarState {
  groups: NativeSidebarGroup[]
  projects: NativeSidebarProject[]
  selectedId: string | null
  /** The project the page considers current — what the web Artifacts, Files and Overview pages are about. */
  project: string | null
  /** The Files view's open file (relative path), as `showFile` / `open-file` set it. */
  openFile: string | null
  /** `panelFocus`: what the view was opened on — a Git group, GitHub's first tab, a task. */
  focus: string | null
}

/* ------------------------------------------------------------- symbols -- */

/**
 * Each view's SF Symbol, chosen to match the line glyph the rail draws for it
 * (`panels.ts`). A `Record` over every `PanelId`, so a view added there without
 * a symbol here is a type error rather than a blank row.
 */
export const PANEL_SYMBOLS: Readonly<Record<PanelId, string>> = {
  overview: 'square.grid.2x2', // four squares
  files: 'doc', // a page with a folded corner
  artifacts: 'doc.text', // a page with lines on it
  git: 'arrow.triangle.branch', // a branch
  simulators: 'iphone', // a phone
  tasks: 'checklist', // ticks beside lines
  memory: 'brain.head.profile', // the agents' memory
  staysfixed: 'checkmark.shield', // a shield with a tick
  store: 'bag', // a shopping bag
  github: 'chevron.left.forwardslash.chevron.right', // no GitHub mark in SF Symbols; code
  readiness: 'checklist.checked', // lines with ticks after them
  mcp: 'server.rack', // two stacked server units
  remote: 'desktopcomputer', // two screens
  hooks: 'paperclip', // the hook-shaped glyph
}

/** The owl's row. */
export const HOOT_SYMBOL = 'bird'
/** A session row (the rail draws its status dot; `status` carries that). */
export const SESSION_SYMBOL = 'terminal'
/** A browser page, where one appears in a run that can hold them. */
export const BROWSER_SYMBOL = 'globe'
/** A session that did not come back after a restart. */
export const HELD_SYMBOL = 'pause.circle'
/** The bell on the rail's Settings line: the Alerts sheet, which is a pop-up rather than a view. */
export const ALERTS_ID = 'alerts'
export const ALERTS_SYMBOL = 'bell'

/* -------------------------------------------------------------- groups -- */

/** The ids of the runs under "Open" that are not a project folder. */
export const OTHER_GROUP = 'other'
export const HOOT_STARTED_GROUP = 'hoot-started'
export const appGroupId = (app: string): string => `app:${app}`
export const machineGroupId = (machineId: string): string => `machine:${machineId}`
export const serverGroupId = (serverId: string): string => `server:${serverId}`
/** A held session's row id: its key, marked so it can never collide with a tab id. */
export const heldItemId = (key: string): string => `held:${key}`

/** What `App.tsx` hands the rail, plus the native panel's own folds. */
export interface NativeSidebarInput {
  hoot: { name: string; stage: CopilotStage | null; active: boolean }
  /** Already filtered to the installed views, exactly as the rail's `panels` prop. */
  panels: readonly PanelSpec[]
  activePanel: PanelId | null
  projects: readonly { path: string; name: string }[]
  tabs: readonly WorkspaceTab[]
  activeTabId: string | null
  unread: readonly string[]
  held: readonly HeldSessionView[]
  heldRetrying: readonly string[]
  machines: readonly SidebarMachine[]
  servers: readonly SidebarServer[]
  /** Group ids the native panel has folded. */
  folded: ReadonlySet<string>
  /** The bell: whether this install has it, and how many alerts it has not shown. */
  alerts: { shown: boolean; count: number }
  /** `activeProjectPath` — the project the window's views are about. */
  project: string | null
  /** `openFile`, the Files view's selection. */
  openFile: string | null
  /** `panelFocus`. */
  focus: string | null
  /** The top strip's order (`usePromotedOrder`), for the row menu's Show at the top. */
  promoted?: readonly string[]
}

/** Before the window's first full render: nothing open, nothing selected. */
export const EMPTY_NATIVE_RAIL: NativeSidebarInput = {
  hoot: { name: BRAND.assistant, stage: null, active: false },
  panels: [],
  activePanel: null,
  projects: [],
  tabs: [],
  activeTabId: null,
  unread: [],
  held: [],
  heldRetrying: [],
  machines: [],
  servers: [],
  folded: new Set(),
  alerts: { shown: false, count: 0 },
  project: null,
  openFile: null,
  focus: null,
}

export function buildNativeSidebar(input: NativeSidebarInput): NativeSidebarState {
  const unread = new Set(input.unread)

  const hootStatus = input.hoot.stage === null ? null : entryDot(input.hoot.stage)
  const groups: NativeSidebarGroup[] = [
    {
      id: 'hoot',
      title: null,
      items: [
        {
          id: 'hoot',
          title: input.hoot.name,
          symbol: HOOT_SYMBOL,
          kind: 'hoot',
          ...(hootStatus === null ? {} : { status: hootStatus }),
        },
      ],
    },
  ]
  const panelItem = (panel: PanelSpec): NativeSidebarItem => ({
    id: panel.id,
    title: panel.label,
    symbol: PANEL_SYMBOLS[panel.id],
    kind: 'panel',
  })
  for (const group of PANEL_GROUPS) {
    const inGroup = input.panels.filter((panel) => panel.group === group.id)
    if (inGroup.length > 0) groups.push({ id: group.id, title: group.label, items: inGroup.map(panelItem) })
  }
  // The rail's foot: any view placed there (none today), and the bell beside
  // Settings — Settings itself is the native toolbar's. The bell is a row here
  // because the native panel is the only place left to put it; without it the
  // Alerts sheet and its count would be out of reach.
  const foot = input.panels.filter((panel) => panel.group === 'foot').map(panelItem)
  if (input.alerts.shown) {
    foot.push({
      id: ALERTS_ID,
      title: 'Alerts',
      symbol: ALERTS_SYMBOL,
      kind: 'panel',
      ...(input.alerts.count > 0 ? { unread: true, subtitle: `${input.alerts.count} new` } : {}),
    })
  }
  if (foot.length > 0) groups.push({ id: 'foot', title: null, items: foot })

  /* What the row menu needs that the row does not show (Sidebar.tsx's showSessionRowMenu request). */
  const strip = input.promoted ?? []
  const rowMenuFacts = (tab: WorkspaceTab): Partial<NativeSidebarItem> => {
    const turn = turnOf(tab)
    const promoted = strip.includes(tab.id)
    return {
      ...(turn !== null ? { turn } : {}),
      ...(promoted ? { promoted: true } : {}),
      ...(!promoted && strip.length >= MAX_PROMOTED ? { promoteBlocked: `The top strip is full (${MAX_PROMOTED})` } : {}),
    }
  }

  /* The rail's `rowsFor`: the same label and the same qualifier per row. */
  const rows = (
    run: readonly WorkspaceTab[],
    projectName?: string | ((tab: WorkspaceTab) => string | undefined),
    options: { nameFolder?: boolean } = {},
  ): NativeSidebarItem[] => {
    const nameOf = typeof projectName === 'function' ? projectName : () => projectName
    const labels = run.map((tab, index) =>
      tab.kind === 'session' ? sessionLabel(tab.label, index, nameOf(tab)) : tab.label,
    )
    const qualifiers = tabQualifiers(run, labels, { accountsShown: false, nameFolder: options.nameFolder })
    return run.map((tab, index) => {
      const qualifier = qualifiers[index]
      return {
        id: tab.id,
        title: labels[index],
        symbol: tab.kind === 'session' ? SESSION_SYMBOL : BROWSER_SYMBOL,
        kind: 'session',
        ...(unread.has(tab.id) ? { unread: true } : {}),
        ...(tab.kind === 'session' ? { status: tab.status ?? 'idle' } : {}),
        ...(qualifier ? { subtitle: qualifier } : {}),
        ...rowMenuFacts(tab),
      }
    })
  }

  /* The rail's `heldRow`. */
  const heldRow = (row: HeldSessionView, nameFolder: boolean): NativeSidebarItem => {
    const agent = heldAgentName(row.provider)
    return {
      id: heldItemId(row.key),
      title: nameFolder ? `${folderName(row.cwd)} · ${agent}` : agent,
      symbol: HELD_SYMBOL,
      kind: 'session',
      status: 'held',
      subtitle: input.heldRetrying.includes(row.key) ? 'Opening…' : 'Not reopened',
      /* The rail's own tooltip, word for word (Sidebar.tsx heldRow). */
      help: `${nameFolder ? `${folderName(row.cwd)} · ${agent}` : agent} — ${
        input.heldRetrying.includes(row.key)
          ? 'Opening…'
          : row.pick
            ? 'Not reopened — open it to choose the conversation'
            : `Not reopened: ${row.reason}`
      }`,
    }
  }

  const listed = input.tabs.filter((tab) => !tab.isCopilot)
  const { mine, copilot, apps } = partitionByOrigin(listed)
  const projects: NativeSidebarProject[] = []
  const add = (id: string, title: string, sessions: NativeSidebarItem[]): void => {
    projects.push({ id, title, expanded: !input.folded.has(id), sessions })
  }

  for (const project of input.projects) {
    add(project.path, project.name, [
      ...rows(
        mine.filter((tab) => tab.kind === 'session' && sameFolder(tab.projectPath, project.path)),
        project.name,
      ),
      ...input.held.filter((row) => sameFolder(row.cwd, project.path)).map((row) => heldRow(row, false)),
    ])
  }

  const inNoProject = (path: string | undefined): boolean =>
    !input.projects.some((project) => sameFolder(project.path, path))
  const orphaned = mine.filter((tab) => tab.kind === 'session' && inNoProject(tab.projectPath))
  const heldLoose = input.held.filter((row) => inNoProject(row.cwd))
  if (orphaned.length > 0 || heldLoose.length > 0) {
    // Under the rail's "Open" heading with no heading of their own; named by it.
    add(OTHER_GROUP, 'Open', [...rows(orphaned), ...heldLoose.map((row) => heldRow(row, true))])
  }

  const folderOf = (tab: WorkspaceTab): string | undefined =>
    tab.projectPath ? folderName(tab.projectPath) : undefined
  if (copilot.length > 0) add(HOOT_STARTED_GROUP, `Started by ${BRAND.assistant}`, rows(copilot, folderOf))
  for (const group of apps) add(appGroupId(group.app), `From ${group.app}`, rows(group.tabs, folderOf))
  for (const group of input.machines) {
    add(machineGroupId(group.machineId), group.name, rows(group.sessions, folderOf, { nameFolder: true }))
  }
  for (const group of input.servers) add(serverGroupId(group.serverId), group.name, rows(group.sessions))

  // The rail's rule for what is drawn as current: a view when one fills the
  // window, Hoot when its window does, and otherwise the session in front.
  const selectedId = input.activePanel ?? (input.hoot.active ? 'hoot' : input.activeTabId)
  return { groups, projects, selectedId, project: input.project, openFile: input.openFile, focus: input.focus }
}

/** Every session row's tab id, held rows aside — what `select` and `close-session` may name. */
export function railTabIds(input: NativeSidebarInput): Set<string> {
  return new Set([
    ...input.tabs.filter((tab) => !tab.isCopilot).map((tab) => tab.id),
    ...input.machines.flatMap((group) => group.sessions.map((tab) => tab.id)),
    ...input.servers.flatMap((group) => group.sessions.map((tab) => tab.id)),
  ])
}

/* ------------------------------------------------------------ publishing -- */

/** How long a burst of changes is gathered before one state goes out. */
export const SIDEBAR_PUBLISH_MS = 50

/**
 * Coalesces changes into at most one post per {@link SIDEBAR_PUBLISH_MS}, and
 * none at all when nothing the native side draws has changed. Shared by every
 * state the main page publishes — the side panel, the tabs, the island.
 *
 * Not a reset-on-every-change debounce: the window re-renders on every status
 * change of every session, and a timer pushed back by each of them could hold
 * the native side stale for as long as an agent is busy. The first change
 * starts the clock; whatever is current when it runs out is what is sent.
 */
export function createCoalescedPublisher<S>(
  post: (state: S) => void,
  schedule: (callback: () => void, ms: number) => unknown = (callback, ms) => setTimeout(callback, ms),
): { update(build: () => S): void } {
  let pending = false
  let latest: (() => S) | null = null
  let last = ''
  return {
    update(build) {
      latest = build
      if (pending) return
      pending = true
      schedule(() => {
        pending = false
        if (latest === null) return
        const state = latest()
        const text = JSON.stringify(state)
        if (text === last) return
        last = text
        post(state)
      }, SIDEBAR_PUBLISH_MS)
    },
  }
}

/** The side panel's publisher: `{type: 'sidebar', state}`. */
export function createSidebarPublisher(
  post: (message: { type: 'sidebar'; state: NativeSidebarState }) => void,
  schedule?: (callback: () => void, ms: number) => unknown,
): { update(build: () => NativeSidebarState): void } {
  return createCoalescedPublisher((state: NativeSidebarState) => post({ type: 'sidebar', state }), schedule)
}
