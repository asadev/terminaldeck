/**
 * The tab strip, described for the native macOS window's top bar.
 *
 * Inside the native window the web strip (`WorkspaceTabStrip.tsx`) is hidden
 * and AppKit draws the tabs in its title bar. It has to be the same strip: the
 * same tabs in the same order, named the same way, the same one selected. So
 * this runs the strip's own functions over the strip's own inputs —
 * `shownTabs` over the persisted order, `tabIdentities` for the names — and
 * `native-tabs.test.ts` renders the real strip beside it and compares.
 *
 * ## The shape (the contract with `macos/`)
 *
 *   { tabs: [{ id, title, symbol, kind, active, unread?, status?, closable }],
 *     canNewTerminal, canNewBrowser }
 *
 * `kind` is `'session' | 'browser'` — the two kinds the strip holds — and
 * `'hoot'` for Hoot's own window, so the native side draws the owl as the web
 * strip does. (`'panel'` is in the contract for a later strip that holds pages;
 * nothing here makes one, because the web strip has none.)
 *
 * ## What a tab's ✕ does
 *
 * Exactly what the web strip's ✕ does, and the two are different on purpose
 * (`WorkspaceTabStrip.tsx` carries the whole argument): a session's tab is
 * taken off the bar and the session keeps running in the side panel — nothing
 * on this bar ends a session — while a browser window is closed, down the same
 * path ⌘W takes. {@link stripClose} is that decision.
 */

import { removeFromStrip, shownTabs } from '../browser/workspace-strip'
import { BROWSER_SYMBOL, HOOT_SYMBOL, SESSION_SYMBOL } from './native-sidebar'
import { tabIdentities, type WorkspaceTab } from './workspace-tabs'
import type { ServerSession } from '../machines/servers/server-sessions'
import { primaryPane, type PaneLayout, type PaneNode } from '../layout/pane-tree'

/**
 * How the window arranges its terminals, so the native window can draw split
 * and swarm itself (lane T). `root` is the pane tree's own JSON — a leaf is
 * `{ type: 'leaf', id, tabId }`, a split `{ type: 'split', id, direction, ratio,
 * children }`. `modeSwitch` is the page's own condition for drawing ModeSwitch,
 * `splitOffer` its `splitOffer` prop (split not installed yet: choosing it
 * installs it), and `swarmSessions` SwarmGrid's rows.
 */
export interface NativeLayoutState {
  mode: 'terminal' | 'split'
  swarm: boolean
  root: PaneNode | null
  focusedPaneId: string | null
  primaryPaneId: string | null
  modeSwitch: boolean
  splitOffer: boolean
  swarmSessions: { id: string; title: string; status: string }[]
}

/**
 * A terminal on a server: what it takes to open its shell — `ServerSessionPane`'s
 * own props — so the native window can draw server shells too (lane T).
 *
 * `shellId` is the far end's id once a shell is open, null before: the page's
 * `serverShellIds`. A native window that opens the shell itself tells the page
 * with `server-shell-opened` / `server-shell-ended`, so the bar, the heading and
 * `server-shell-write` keep addressing the right channel.
 */
export interface NativeServerTab {
  serverId: string
  serverName: string
  shellKey: string
  startIn: string | null
  run: string | null
  shellId: string | null
}

export interface NativeTab {
  id: string
  title: string
  /** An SF Symbol name. */
  symbol: string
  /** `hoot` for Hoot's own window, so the native side draws the owl. */
  kind: 'session' | 'browser' | 'panel' | 'hoot'
  active: boolean
  unread?: boolean
  status?: string
  closable: boolean
  /** Only on a terminal on a server. */
  server?: NativeServerTab
}

/**
 * The "Switching to …" / "Switched to …" note beside the account chip (lane T):
 * which session it is about, whether the switch is still going, and its words.
 */
export interface NativeAccountSwitch {
  sessionId: string
  state: 'working' | 'done'
  text: string
}

export interface NativeTabsState {
  tabs: NativeTab[]
  canNewTerminal: boolean
  /** The account-switch note, or null when there is none. */
  accountSwitch: NativeAccountSwitch | null
  /** Split and swarm — see {@link NativeLayoutState}. */
  layout: NativeLayoutState
  canNewBrowser: boolean
}

/** What `App.tsx` hands the strip. */
export interface NativeTabsInput {
  /** The strip's persisted order — `usePromotedOrder`, the very store the strip reads. */
  order: readonly string[]
  /** `openTabs`. */
  tabs: readonly WorkspaceTab[]
  /** `railActiveTabId`, the strip's `activeTabId`. */
  activeTabId: string | null
  /** The strip's `covered`: a sidebar view fills the window, so no tab is the selected one. */
  covered: boolean
  unread: readonly string[]
  /** Whether a browser window can be opened at all — see `App.tsx`. */
  canNewBrowser: boolean
  /** The server terminals open in this window (`serverSessions`), and their shells' ids by tab id. */
  serverSessions: readonly ServerSession[]
  serverShellIds: Readonly<Record<string, string>>
  /** The window's arrangement: `mode`, `swarm`, the pane tree, and the ModeSwitch facts. */
  mode: 'terminal' | 'split'
  swarm: boolean
  panes: PaneLayout
  modeSwitch: boolean
  splitOffer: boolean
  swarmSessions: readonly { id: string; title: string; status: string }[]
  /** App's `switchingNote` / `accountSwitchNote`, as one field. */
  accountSwitch: NativeAccountSwitch | null
}

export const EMPTY_NATIVE_TABS: NativeTabsInput = {
  order: [],
  tabs: [],
  activeTabId: null,
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

export function buildNativeTabs(input: NativeTabsInput): NativeTabsState {
  const shown = shownTabs(input.order, input.tabs, input.activeTabId)
  const identities = tabIdentities(
    shown.map((entry) => entry.tab),
    input.tabs,
  )
  const selected = input.covered ? null : input.activeTabId
  const unread = new Set(input.unread)
  return {
    tabs: shown.map(({ tab }) => {
      const identity = identities.get(tab.id) ?? { label: tab.label, qualifier: null }
      return {
        id: tab.id,
        // The strip's own spoken name: the label, and what tells it from its twin.
        title: identity.qualifier ? `${identity.label} — ${identity.qualifier}` : identity.label,
        symbol: tab.isCopilot ? HOOT_SYMBOL : tab.kind === 'session' ? SESSION_SYMBOL : BROWSER_SYMBOL,
        kind: tab.isCopilot ? 'hoot' : tab.kind,
        active: tab.id === selected,
        ...(unread.has(tab.id) ? { unread: true } : {}),
        ...(tab.kind === 'session' && tab.status ? { status: tab.status } : {}),
        // The strip draws a ✕ on every tab: off the bar for a session, close for a page.
        closable: true,
        ...serverTab(input, tab.id),
      }
    }),
    canNewTerminal: true,
    accountSwitch: input.accountSwitch === null ? null : { ...input.accountSwitch },
    layout: {
      mode: input.mode,
      swarm: input.swarm,
      root: input.panes.root,
      focusedPaneId: input.panes.focusedPaneId,
      primaryPaneId: primaryPane(input.panes)?.id ?? null,
      modeSwitch: input.modeSwitch,
      splitOffer: input.splitOffer,
      swarmSessions: input.swarmSessions.map((row) => ({ id: row.id, title: row.title, status: row.status })),
    },
    canNewBrowser: input.canNewBrowser,
  }
}

/**
 * What the strip's ✕ on this tab does: take a session off the bar (with the
 * order to keep, and the tab to show instead when it was the one in front), or
 * close a browser window. `null` for a tab the strip is not showing.
 */
function serverTab(input: NativeTabsInput, id: string): { server?: NativeServerTab } {
  const entry = input.serverSessions.find((row) => row.tabId === id)
  if (!entry) return {}
  return {
    server: {
      serverId: entry.serverId,
      serverName: entry.serverName,
      shellKey: entry.shellKey,
      startIn: entry.startIn,
      run: entry.run,
      shellId: input.serverShellIds[id] ?? null,
    },
  }
}

export function stripClose(
  input: NativeTabsInput,
  id: string,
): { kind: 'off-bar'; order: readonly string[]; select?: string | null } | { kind: 'close-window' } | null {
  const shown = shownTabs(input.order, input.tabs, input.activeTabId).find((entry) => entry.tab.id === id)
  if (!shown) return null
  if (shown.tab.kind === 'browser') return { kind: 'close-window' }
  const result = removeFromStrip(input.order, input.tabs, id, input.activeTabId)
  return { kind: 'off-bar', order: result.order, ...(result.select !== undefined ? { select: result.select } : {}) }
}

/** Whether the strip is showing this tab — what `select-tab` may name. */
export function stripHas(input: NativeTabsInput, id: string): boolean {
  return shownTabs(input.order, input.tabs, input.activeTabId).some((entry) => entry.tab.id === id)
}
