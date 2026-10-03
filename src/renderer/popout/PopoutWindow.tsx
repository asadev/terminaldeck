import { useCallback, useEffect, useState } from 'react'
import type { SessionMeta, SessionStatus } from '@shared/types'
import '../shell/shell.css'
import './popout.css'
import { TerminalView } from '../components/TerminalView'
import { StatusDot } from '../components/StatusDot'
import { SwitchAccountConfirm } from '../components/SwitchAccountConfirm'
import { useKnownSignIns } from '../accounts'
import { switchNames, useSwitchAccount } from '../session-switch'
import { WindowToolbar } from '../shell/WindowToolbar'
import { FolderTitle } from '../shell/FolderChip'
import { AccountChip } from '../shell/AccountChip'
import { SessionControls } from '../shell/SessionControls'
import { endOfLocalSession } from '../shell/session-end'
import { useAppSettings } from '../settings/useAppSettings'
import { booleanSetting, numberSetting, stringSetting } from '../settings/settings-schema'
import { sessionWindowsBridge, useSessionWindows } from './session-windows'

/**
 * A session in a window of its own.
 *
 * Asad, 2026-10-03: *"Session two I want to move in my another screen in my
 * another monitor."* So this is one session and nothing else — no rail, no tab
 * strip — with the same bar over it the main window draws for a session: its
 * name (double-click renames it, everywhere), its folder, the account it runs
 * as with the same switch, its model and effort chips, and the terminal.
 *
 * ## The same terminal, attached the same way
 *
 * `TerminalView` is mounted here exactly as the main window mounts it: it asks
 * the main process for the scrollback and listens to `session:data` for one id,
 * and what is typed goes to `writeToSession` for that id. There is no second
 * process and no copy — the main window has stopped drawing this session (it
 * shows "open in its own window" instead), so this is the one terminal on the
 * pty, and it sizes it.
 *
 * ## What is not here, and where it went
 *
 * The chat and split views are the main window's; this window is the terminal.
 * The connectors chip and "Manage accounts…" open pages that live in the main
 * window, so they bring the main window forward and open them there.
 */

const DOCK_GLYPH = 'M15 4h5v5M20 4l-7 7M10 6H6.5A2.5 2.5 0 0 0 4 8.5v9A2.5 2.5 0 0 0 6.5 20h9a2.5 2.5 0 0 0 2.5-2.5V14'

const STATUSES: readonly SessionStatus[] = ['idle', 'working', 'waiting', 'input', 'completed', 'exited']

function asStatus(value: unknown): SessionStatus | null {
  return typeof value === 'string' && (STATUSES as readonly string[]).includes(value) ? (value as SessionStatus) : null
}

interface Props {
  /** The session this window was opened for — off its address, before the list arrives. */
  sessionId: string
}

export function PopoutWindow({ sessionId: initialId }: Props) {
  const { values: settings } = useAppSettings()
  const windows = useSessionWindows()
  const knownSignIns = useKnownSignIns()
  const switcher = useSwitchAccount()

  /*
   * Which session this window holds: the list's answer for this window, by
   * window id, once it has one. An account switch that restarts the agent
   * gives the session a new id, and the window follows it rather than going
   * blank — see `popout:rekey`.
   */
  const row = windows.view.self === null ? null : windows.view.windows.find((w) => w.windowId === windows.view.self) ?? null
  const sessionId = row?.sessionId ?? initialId

  const [meta, setMeta] = useState<SessionMeta | null>(null)
  const [status, setStatus] = useState<SessionStatus>('idle')
  const [note, setNote] = useState<string | null>(null)

  const reload = useCallback(() => {
    void window.deck
      .listSessions()
      .then((list) => setMeta(list.find((entry) => entry.id === sessionId) ?? null))
      .catch(() => undefined)
  }, [sessionId])

  useEffect(() => {
    reload()
  }, [reload])

  // The status the main process had when this window opened, then every change.
  useEffect(() => {
    const first = asStatus(row?.status)
    if (first) setStatus(first)
  }, [row?.status])
  useEffect(
    () =>
      window.deck.onSessionStatus((id, next) => {
        const read = asStatus(next)
        if (id === sessionId && read) setStatus(read)
      }),
    [sessionId],
  )
  useEffect(
    () =>
      window.deck.onSessionExit((id, exitCode) => {
        if (id !== sessionId) return
        setStatus('exited')
        setMeta((current) => (current ? { ...current, exitCode } : current))
      }),
    [sessionId],
  )
  useEffect(
    () =>
      window.deck.onSessionRenamed((id, title) => {
        if (id === sessionId) setMeta((current) => (current ? { ...current, title } : current))
      }),
    [sessionId],
  )
  // A switch made anywhere — in place, or armed for the next message — changes
  // the account this bar names. Re-read rather than patched: the main process's
  // record is the truth about which login a session runs as.
  useEffect(() => window.deck.onSessionSwitched?.(() => reload()), [reload])

  // A switch made from this window's own chip, in place: same session, other login.
  useEffect(() => {
    const done = switcher.done
    if (done === null) return
    setMeta(done.meta)
    const to = done.to === null ? (done.meta.profileName ?? 'the other account') : switchNames({ from: null, to: done.to }, knownSignIns).to
    setNote(`Switched to ${to}`)
    switcher.dismissDone()
  }, [knownSignIns, switcher])
  useEffect(() => {
    if (note === null) return
    const timer = setTimeout(() => setNote(null), 4000)
    return () => clearTimeout(timer)
  }, [note])

  const label = row?.label || meta?.title || 'Session'
  useEffect(() => {
    document.title = label
  }, [label])

  const confirmSwitch = useCallback(() => {
    const previous = switcher.asking?.sessionId
    if (!previous) return
    void switcher.confirm().then((next) => {
      // A switch that restarted the agent made a new session. The window
      // follows it, and the main window is told so its rail does too.
      if (next && next.id !== previous) void sessionWindowsBridge()?.followSessionSwitch?.(previous, next.id)
    })
  }, [switcher])

  const end = endOfLocalSession(meta?.exitCode ?? null)
  const switchingNote =
    switcher.working !== null && switcher.asking === null
      ? `Switching to ${
          switcher.working.to === null
            ? 'the other account'
            : switchNames({ from: null, to: switcher.working.to }, knownSignIns).to
        }…`
      : null

  return (
    <div className="popout" data-session={sessionId}>
      <WindowToolbar
        title={label}
        sessionId={sessionId}
        titleMark={<StatusDot status={status} />}
        sidebarHidden={false}
        onRevealSidebar={() => undefined}
        onEdgeEnter={() => undefined}
        meta={
          meta ? (
            <div className="toolbar-chips">
              <FolderTitle path={meta.cwd} />
              <span className="toolbar-chip-sep" aria-hidden="true" />
              <AccountChip
                current={
                  meta.profileId && meta.profileName
                    ? { id: meta.profileId, name: meta.profileName, provider: meta.provider }
                    : null
                }
                justSwitched={note !== null}
                projectPath={meta.cwd}
                session={{
                  id: meta.id,
                  provider: meta.provider,
                  exited: meta.exitCode !== null,
                  ...(meta.homeProfileId !== undefined ? { switchedInPlace: true } : {}),
                }}
                onSwitchAccount={(id, accountId) => switcher.ask({ sessionId: id, profileId: accountId })}
                // A new session and the accounts page are the main window's.
                onPick={() => sessionWindowsBridge()?.showMainWindow?.('session.newDialog')}
                onManage={() => sessionWindowsBridge()?.showMainWindow?.('app.preferences')}
              />
              {switchingNote === null && note === null ? null : (
                <span className="machine-switch-host">
                  <span className="account-switch-note" role="status" data-state={switchingNote !== null ? 'working' : 'done'}>
                    {switchingNote ?? note}
                  </span>
                </span>
              )}
            </div>
          ) : null
        }
      >
        {meta ? (
          <SessionControls
            sessionId={sessionId}
            cwd={meta.cwd}
            provider={meta.provider}
            exited={meta.exitCode !== null}
            end={end}
            onOpenConnectors={() => sessionWindowsBridge()?.showMainWindow?.('view.mcp')}
          />
        ) : null}
        <button
          type="button"
          className="toolbar-btn popout-dock"
          onClick={() => windows.dock(sessionId)}
          aria-label="Move back to main window"
          title="Move back to main window"
        >
          <svg
            width="17"
            height="17"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
            style={{ transform: 'rotate(180deg)' }}
          >
            <path d={DOCK_GLYPH} />
          </svg>
        </button>
      </WindowToolbar>

      <div className="popout-body">
        <TerminalView
          key={sessionId}
          sessionId={sessionId}
          visible
          fontSize={numberSetting(settings, 'appearance.terminalFontSize')}
          fontFamily={stringSetting(settings, 'appearance.terminalFontFamily')}
          copyOnSelect={booleanSetting(settings, 'general.copyOnSelect')}
          end={end}
          onReopen={() => sessionWindowsBridge()?.showMainWindow?.('session.newDialog')}
        />
      </div>

      <SwitchAccountConfirm
        open={switcher.asking !== null}
        title={switcher.asking === null ? '' : label}
        names={switchNames(switcher.plan ?? { from: null, to: null }, knownSignIns)}
        plan={switcher.plan}
        busy={switcher.busy}
        problem={switcher.problem}
        onCancel={switcher.cancel}
        onConfirm={confirmSwitch}
        canDefer={switcher.canDefer}
        onDefer={() => void switcher.defer()}
      />
    </div>
  )
}

/** The glyph for "move into its own window", shared with the main window's controls. */
export const POP_OUT_GLYPH = DOCK_GLYPH
