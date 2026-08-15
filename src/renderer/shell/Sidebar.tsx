import { useState, type MouseEvent, type ReactNode } from 'react'
import { StatusDot } from '../components/StatusDot'
import type { Project } from '../state/store'
import { tip } from '../keymap'
import { PANEL_GROUPS, PANELS, type PanelId, type PanelSpec } from './panels'
import { accountsWorthShowing, KIND_ICON, sessionLabel, type WorkspaceTab } from './workspace-tabs'

interface Props {
  width: number
  projects: Project[]
  tabs: WorkspaceTab[]
  /** The open session or page, whether or not a view is covering it. */
  activeTabId: string | null
  /** The view covering the window, or null when a session/page is on screen. */
  activePanel: PanelId | null
  /**
   * The views to list, which is every view whose feature is installed.
   *
   * A prop rather than a read of the feature state, because this component is
   * the window's inventory of what you have open and the decision about what
   * exists belongs one level up, with the rest of the gating. It defaults to all
   * of them so that rendering a `Sidebar` on its own — a test, a harness — shows
   * the app rather than a fresh install's subset of it.
   */
  panels?: readonly PanelSpec[]
  /**
   * Whether the browser feature is installed and on, i.e. whether the globe
   * beside New session opens a pane or offers one.
   *
   * It used to decide whether the button was drawn at all, and the result was
   * the failure a feature store actually causes: uninstalling the browser pane
   * deleted the globe with nothing in its place, so the app looked like one
   * that had never had a browser. The button stays either way — see
   * `browserOffer`.
   */
  browser?: boolean
  /**
   * The hover label for the globe when the feature is *not* on, from
   * `useControlOffer`. Null when it is on and the globe is an ordinary control.
   *
   * A string rather than a feature id for the same reason `panels` is a list
   * rather than a lookup: this component is the window's inventory of what you
   * have open, and every decision about what exists is made one level up.
   */
  browserOffer?: string | null
  /** Session ids with output nobody has looked at yet. */
  unread?: readonly string[]
  badges?: Partial<Record<PanelId, number>>
  /**
   * Showing because the pointer is near the edge, rather than because it is
   * pinned. It floats over the content in that state instead of taking room
   * from it, and the arrow in its gutter offers to keep it.
   */
  peeking?: boolean
  /**
   * The update notice, rendered above Settings.
   *
   * Passed in rather than imported so it stays mounted from `App.tsx`, which is
   * where the wiring test can see it and where its bridge subscription belongs.
   * It sits here because an update is the same category of thing as Alerts and
   * Settings — the app talking to you about itself — and none of the three has
   * anything to do with the work in the middle of the window.
   */
  update?: ReactNode
  onSelectTab(id: string): void
  onCloseTab(id: string): void
  onSelectPanel(id: PanelId): void
  onNewSession(projectPath?: string, resume?: boolean): void
  onNewBrowserTab(): void
  onOpenProject(): void
  onCloseProject(path: string): void
  onOpenSettings(): void
  /** Keep it open (peeking) or put it away (pinned). */
  onToggleCollapsed(): void
  onPeekStart(): void
  onPeekEnd(): void
  onStartResize(event: MouseEvent): void
}

function Glyph({
  path,
  size = 17,
  className,
}: {
  path: string
  size?: number
  className?: string
}) {
  return (
    <svg
      className={className ? `sb-glyph ${className}` : 'sb-glyph'}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={path} />
    </svg>
  )
}

const PLUS = 'M12 5.5v13M5.5 12h13'
const DISCLOSURE = 'M9.5 6.5l5.5 5.5-5.5 5.5'
/**
 * The arrow in the gutter, and the only control that opens or closes the rail.
 *
 * It points the way the *content's* left edge is about to move, which is the
 * only reading that stays true in both directions: pinned, the arrow points
 * left and the content grows leftwards when you press it; peeked, it points
 * right and pressing it pushes the content over to make permanent room.
 */
const CHEVRON_LEFT = 'M14.5 6.5 9 12l5.5 5.5'
const CHEVRON_RIGHT = 'M9.5 6.5 15 12l-5.5 5.5'
const RESUME = 'M4 12a8 8 0 1 0 2.7-6M4 4.5v4h4'
const CLOSE = 'M6.5 6.5l11 11M17.5 6.5l-11 11'
const GEAR =
  'M12 15.1a3.1 3.1 0 1 0 0-6.2 3.1 3.1 0 0 0 0 6.2zM19.3 14.6a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5v.2a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1.1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1h-.2a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1.1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5v-.2a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1h.2a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z'

/**
 * The sidebar. One of them.
 *
 * What used to be here was a 48px icon rail, a 300px drawer with its own
 * header and collapse button, a tab strip in the window title bar and a
 * segmented control in a bar of its own — four pieces of chrome answering the
 * same question. This is that question asked once: what do you have open, and
 * what would you like to look at.
 *
 * The rows are quiet on purpose. Nothing here is boxed, nothing is separated by
 * a line, and the only colour is the status dot next to a session that is
 * actually doing something.
 */
export function Sidebar({
  width,
  projects,
  tabs,
  activeTabId,
  activePanel,
  panels = PANELS,
  browser = true,
  browserOffer = null,
  unread = [],
  badges,
  peeking = false,
  update,
  onSelectTab,
  onCloseTab,
  onSelectPanel,
  onNewSession,
  onNewBrowserTab,
  onOpenProject,
  onCloseProject,
  onOpenSettings,
  onToggleCollapsed,
  onPeekStart,
  onPeekEnd,
  onStartResize,
}: Props) {
  /** Folded projects, by path. Local: it is a view state, not a preference. */
  const [folded, setFolded] = useState<ReadonlySet<string>>(new Set())
  const toggleFold = (path: string) =>
    setFolded((current) => {
      const next = new Set(current)
      if (!next.delete(path)) next.add(path)
      return next
    })

  const browserTabs = tabs.filter((tab) => tab.kind === 'browser')
  const sessionsIn = (path: string) =>
    tabs.filter((tab) => tab.kind === 'session' && tab.projectPath === path)
  /** Sessions whose project has been closed out from under them. */
  const orphaned = tabs.filter(
    (tab) =>
      tab.kind === 'session' && !projects.some((project) => project.path === tab.projectPath),
  )

  const labelFor = (tab: WorkspaceTab, index: number, projectName?: string): string =>
    tab.kind === 'session' ? sessionLabel(tab.label, index, projectName) : tab.label

  /**
   * Whether the rows have to name the account each session belongs to.
   *
   * Only once more than one is in play — see `accountsWorthShowing`. Two
   * sessions in the same folder under two logins are otherwise the same row
   * twice, which is the thing this app must never make someone guess about.
   */
  const showAccounts = accountsWorthShowing(tabs)

  const tabRow = (tab: WorkspaceTab, label: string) => (
    <li key={tab.id}>
      <div
        className={`sb-row sb-open${!activePanel && tab.id === activeTabId ? ' active' : ''}${
          unread.includes(tab.id) ? ' unread' : ''
        }`}
      >
        <button
          type="button"
          className="sb-row-main"
          title={
            showAccounts && tab.account ? `${label} — signed in as ${tab.account.name}` : label
          }
          aria-current={!activePanel && tab.id === activeTabId}
          onClick={() => onSelectTab(tab.id)}
        >
          {tab.kind === 'session' ? (
            <StatusDot status={tab.status ?? 'idle'} />
          ) : (
            <Glyph path={KIND_ICON.browser} size={15} />
          )}
          <span className="sb-label">{label}</span>
          {showAccounts && tab.account && (
            <span className="sb-account">{tab.account.name}</span>
          )}
        </button>
        {/* Mail's idiom: a dot for a row with something new in it. It hides
            under the close button on hover, because at that point the pointer
            is on its way somewhere else. */}
        {unread.includes(tab.id) && <span className="sb-unread" aria-label="Unread output" />}
        {tab.closable && (
          <button
            type="button"
            className="sb-row-action sb-close"
            aria-label={`Close ${label}`}
            title={`Close ${label}`}
            onClick={() => onCloseTab(tab.id)}
          >
            <Glyph path={CLOSE} size={13} />
          </button>
        )}
      </div>
    </li>
  )

  /** Views that live at the foot rather than in a labelled run. */
  const footPanels = panels.filter((panel) => panel.group === 'foot')

  return (
    <aside
      className="sidebar"
      style={{ width }}
      data-peek={peeking || undefined}
      aria-label="Sidebar"
      // The pointer arriving anywhere on the rail keeps a peek alive; the
      // pointer leaving starts the grace period. Both are no-ops while the rail
      // is pinned, because `beginPeek`/`endPeek` only move a state the pinned
      // sidebar does not read.
      onPointerEnter={onPeekStart}
      onPointerLeave={onPeekEnd}
    >
      {/* The traffic lights live over this, and now so does the one control
          that opens and closes the rail — which is what "next to the window
          buttons" means. It used to sit in the toolbar, on the far side of the
          window's own divider from the thing it acts on. */}
      <div className="sidebar-gutter">
        <button
          type="button"
          className="sidebar-arrow"
          onClick={onToggleCollapsed}
          aria-label={peeking ? 'Keep the sidebar open' : 'Hide the sidebar'}
          aria-expanded={!peeking}
          title={
            peeking
              ? tip('Keep the sidebar open', 'view.sidebar')
              : tip('Hide the sidebar', 'view.sidebar')
          }
        >
          <Glyph path={peeking ? CHEVRON_RIGHT : CHEVRON_LEFT} size={16} />
        </button>
      </div>

      <div className="sidebar-actions">
        <button
          type="button"
          className="sb-new"
          onClick={() => onNewSession()}
          title={tip('New session', 'session.new')}
        >
          <Glyph path={PLUS} size={16} />
          <span>New session</span>
        </button>
        {/*
          Drawn whether or not the feature is installed, and it does the right
          thing either way: with the browser pane on it opens a tab, without it
          the same press installs the pane and opens one. What changes is the
          hover label and the offer dot — the shared mark in app.css — so the
          button reads as "there is something here" rather than as a control
          that is greyed out or, as it was, as nothing at all.
        */}
        {(browser || browserOffer !== null) && (
          <button
            type="button"
            className="sb-new-alt"
            data-offer={browserOffer !== null || undefined}
            onClick={onNewBrowserTab}
            aria-label={browserOffer ?? 'New browser tab'}
            title={browserOffer ?? 'New browser tab'}
          >
            <Glyph path={KIND_ICON.browser} size={16} />
          </button>
        )}
      </div>

      <div className="sidebar-scroll">
        {PANEL_GROUPS.map((group) => {
          const inGroup = panels.filter((panel) => panel.group === group.id)
          // A heading over nothing. Uninstalling every integration used to leave
          // the word "Integrations" sitting above a gap, which reads as a list
          // that failed to load rather than one that is empty on purpose.
          if (inGroup.length === 0) return null
          return (
            <section key={group.id} className="sb-group">
              <h2 className="sb-group-label">{group.label}</h2>
              <ul className="sb-list">
                {inGroup.map((panel) => {
                  const count = badges?.[panel.id] ?? 0
                  return (
                    <li key={panel.id}>
                      <button
                        type="button"
                        className={`sb-row sb-nav${activePanel === panel.id ? ' active' : ''}`}
                        aria-current={activePanel === panel.id}
                        // Read out of the keymap for this platform, never typed
                        // here: the rail used to carry its own ⌘1/⌘2/⌘3 tooltips
                        // and every one of them was wrong.
                        title={panel.command ? tip(panel.label, panel.command) : panel.label}
                        onClick={() => onSelectPanel(panel.id)}
                      >
                        <Glyph path={panel.icon} />
                        <span className="sb-label">{panel.label}</span>
                        {count > 0 && <span className="sb-badge">{count > 99 ? '99+' : count}</span>}
                      </button>
                    </li>
                  )
                })}
              </ul>
            </section>
          )
        })}

        <section className="sb-group">
          <div className="sb-group-head">
            <h2 className="sb-group-label">Open</h2>
            <button
              type="button"
              className="sb-group-action"
              onClick={onOpenProject}
              aria-label="Open a project"
              title={tip('Open a project', 'project.open')}
            >
              <Glyph path={PLUS} size={14} />
            </button>
          </div>

          {/* A statement, not a third way to do the same thing. The ＋ beside
              the heading opens a project, and the page filling the window says
              so with a button of its own — this line only has to explain why
              the list under it is empty. */}
          {projects.length === 0 && browserTabs.length === 0 && (
            <p className="sb-empty">Nothing open yet.</p>
          )}

          {projects.map((project) => (
            <div key={project.path} className="sb-project">
              <div className="sb-row sb-project-head">
                {/* A disclosure, the way a macOS sidebar folds a group. It used
                    to start a session, which is what the ＋ beside it does — one
                    affordance, one meaning. */}
                <button
                  type="button"
                  className="sb-row-main"
                  title={project.path}
                  aria-expanded={!folded.has(project.path)}
                  onClick={() => toggleFold(project.path)}
                >
                  <Glyph
                    path={DISCLOSURE}
                    size={12}
                    className={`sb-disclosure${folded.has(project.path) ? '' : ' open'}`}
                  />
                  <span className="sb-project-name">{project.name}</span>
                </button>
                <button
                  type="button"
                  className="sb-row-action"
                  onClick={() => onNewSession(project.path, true)}
                  aria-label={`Continue the last session in ${project.name}`}
                  title={tip('Continue last session', 'session.resume')}
                >
                  <Glyph path={RESUME} size={13} />
                </button>
                <button
                  type="button"
                  className="sb-row-action"
                  onClick={() => onNewSession(project.path)}
                  aria-label={`New session in ${project.name}`}
                  title={tip('New session', 'session.new')}
                >
                  <Glyph path={PLUS} size={13} />
                </button>
                <button
                  type="button"
                  className="sb-row-action"
                  onClick={() => onCloseProject(project.path)}
                  aria-label={`Close ${project.name}`}
                  title="Close project"
                >
                  <Glyph path={CLOSE} size={13} />
                </button>
              </div>
              {!folded.has(project.path) && (
                <ul className="sb-list sb-sessions">
                  {sessionsIn(project.path).map((tab, index) =>
                    tabRow(tab, labelFor(tab, index, project.name)),
                  )}
                </ul>
              )}
            </div>
          ))}

          {orphaned.length > 0 && (
            <ul className="sb-list">
              {orphaned.map((tab, index) => tabRow(tab, labelFor(tab, index)))}
            </ul>
          )}
          {browserTabs.length > 0 && (
            <ul className="sb-list">{browserTabs.map((tab) => tabRow(tab, tab.label))}</ul>
          )}
        </section>
      </div>

      {/*
        The foot: the app talking about itself, in the order you would want to
        hear it. An update is news and goes on top; Alerts is a standing list
        and goes under it; Settings is where you go when you have decided to
        change something, and stays at the bottom-left where every app of this
        shape puts it.

        All three used to be somewhere else — the update strip across the top of
        the work, Alerts in the toolbar's right-hand corner competing with the
        controls you use while working — which put three unrelated interruptions
        in the two places your eye is trying to read.
      */}
      <div className="sidebar-foot">
        {update && <div className="sidebar-update">{update}</div>}

        {footPanels.map((panel) => {
          const count = badges?.[panel.id] ?? 0
          return (
            <button
              key={panel.id}
              type="button"
              className={`sb-row sb-nav${activePanel === panel.id ? ' active' : ''}`}
              aria-current={activePanel === panel.id}
              title={panel.command ? tip(panel.label, panel.command) : panel.label}
              onClick={() => onSelectPanel(panel.id)}
            >
              <Glyph path={panel.icon} />
              <span className="sb-label">{panel.label}</span>
              {count > 0 && <span className="sb-badge">{count > 99 ? '99+' : count}</span>}
            </button>
          )
        })}

        <button
          type="button"
          className="sb-row sb-settings"
          onClick={onOpenSettings}
          title={tip('Settings', 'app.preferences')}
        >
          <Glyph path={GEAR} />
          <span className="sb-label">Settings</span>
        </button>
      </div>

      <div
        className="sidebar-resize"
        onMouseDown={onStartResize}
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize sidebar"
      />
    </aside>
  )
}
