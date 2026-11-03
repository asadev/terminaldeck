import { useCallback, useEffect, useState } from 'react'
import type { SessionMeta } from '../../shared/types'
import { postToNative } from '../../shared/native-shell'
import { publishNativeAppearance } from '../native-appearance'
import { TerminalView } from '../components/TerminalView'
import { FeaturesProvider, useFeatures } from '../features/FeaturesProvider'
import { nativeTitle } from '../native-commands'
import { useNativeScreens } from '../native-screens'
import { folderName } from '../session-title'
import { openSettingsMessage } from '../settings/native-settings'
import { booleanSetting, numberSetting, stringSetting, type SectionId } from '../settings/settings-schema'
import { useAppSettings } from '../settings/useAppSettings'
import { PanelView } from '../shell/PanelView'
import { panelSpec, type PanelId } from '../shell/panels'
import { tabLabel } from '../shell/workspace-tabs'
import { SESSION_MESSAGES, sessionScreenState, type ScreenRoute } from './screen-route'
import './screens.css'

/**
 * One screen in a window of its own — see `screen-route.ts` for the routes.
 *
 * Built from the same components the main window draws (`PanelView`,
 * `TerminalView`), so a view or a terminal is the same thing in either; what is
 * missing is only what a window of one screen has no use for — the side panel
 * and the tab strip.
 */
export function ScreenPage({ route }: { route: ScreenRoute }) {
  // The app's theme and density, applied to this page as to the main window.
  useAppSettings()
  useEffect(() => postToNative({ type: 'ready' }), [])
  useEffect(() => publishNativeAppearance(), [])
  const drawnNatively = useNativeScreens()
  if (route.kind === 'unknown') return <ScreenMessage text={route.message} />
  // The window draws this screen itself: nothing mounted under it (the title
  // and `ready` above still come from here).
  if (drawnNatively.has(route.kind === 'panel' ? route.id : 'session')) {
    return <div className="native-screen" data-screen={route.kind === 'panel' ? route.id : 'session'} />
  }
  if (route.kind === 'panel') {
    return (
      <FeaturesProvider>
        <PanelScreen panel={route.id} project={route.project} />
      </FeaturesProvider>
    )
  }
  return <SessionScreen sessionId={route.id} />
}

/** The plain sentence a window shows when it has nothing else to. */
export function ScreenMessage({ text }: { text: string }) {
  return (
    <div className="screen-message" role="status">
      <p>{text}</p>
    </div>
  )
}

function postTitle(value: string | null, subtitle: string | null): void {
  postToNative(nativeTitle(value, subtitle))
}

/**
 * One view. It starts on the project it was opened for, or the one opened most
 * recently; moving to another view from inside it (a tile on Overview, a file
 * from Source control) moves this window, as it would move the main one.
 */
function PanelScreen({ panel: first, project }: { panel: PanelId; project: string | null }) {
  const features = useFeatures()
  const [panel, setPanel] = useState<PanelId>(first)
  const [projectPath, setProjectPath] = useState<string | null>(project)
  const [openFile, setOpenFile] = useState<string | null>(null)

  useEffect(() => {
    if (project !== null) return
    void window.deck
      .listProjects()
      .then((list) => {
        const newest = [...list].sort((a, b) => b.lastOpenedAt - a.lastOpenedAt)[0]
        if (newest) setProjectPath((current) => current ?? newest.path)
      })
      .catch(() => undefined)
  }, [project])

  const label = panelSpec(panel).label
  useEffect(() => {
    postTitle(label, projectPath === null ? null : folderName(projectPath))
  }, [label, projectPath])

  const openProject = useCallback(() => {
    void window.deck.pickProjectFolder().then((path) => {
      if (path === null) return
      void window.deck.addProject(path).catch(() => undefined)
      setProjectPath(path)
    })
  }, [])

  if (!features.panelOn(panel)) return <ScreenMessage text={`${label} is not installed.`} />
  return (
    <div className="screen screen-panel">
      <PanelView
        panel={panel}
        projectPath={projectPath}
        onOpenProject={openProject}
        openFile={openFile}
        onOpenFile={(path) => {
          setOpenFile(path)
          setPanel('files')
        }}
        onShowPanel={(id) => setPanel(id)}
        onOpenSettings={(section) => postToNative(openSettingsMessage(section as SectionId))}
      />
    </div>
  )
}

/**
 * One session's terminal, attached by id like any other: it reads the
 * scrollback and then follows the output, so two windows on one session both
 * print everything. A session that is gone or has ended is said, not drawn.
 */
function SessionScreen({ sessionId }: { sessionId: string }) {
  const { values: settings } = useAppSettings()
  const [found, setFound] = useState<SessionMeta | null | undefined>(undefined)
  const [all, setAll] = useState<SessionMeta[]>([])
  const [status, setStatus] = useState<string | null>(null)

  useEffect(() => {
    void window.deck
      .listSessions()
      .then((list) => {
        setAll(list)
        setFound(list.find((entry) => entry.id === sessionId) ?? null)
      })
      .catch(() => setFound(null))
  }, [sessionId])
  useEffect(
    () =>
      window.deck.onSessionStatus((id, next) => {
        if (id === sessionId) setStatus(next)
      }),
    [sessionId],
  )
  useEffect(
    () =>
      window.deck.onSessionExit((id, exitCode) => {
        if (id === sessionId) setFound((current) => (current ? { ...current, exitCode } : current))
      }),
    [sessionId],
  )
  useEffect(
    () =>
      window.deck.onSessionRenamed((id, title) => {
        if (id === sessionId) setFound((current) => (current ? { ...current, title } : current))
      }),
    [sessionId],
  )

  // Named as the rail names it: the title, numbered among its folder's sessions.
  useEffect(() => {
    if (!found) return
    const tabs = all.map((meta) => ({
      id: meta.id,
      kind: 'session' as const,
      label: meta.id === found.id ? found.title : meta.title,
      projectPath: meta.cwd,
      closable: true,
    }))
    const self = tabs.find((tab) => tab.id === found.id)
    postTitle(self ? tabLabel(self, tabs) : found.title, folderName(found.cwd))
  }, [found, all])

  const state = sessionScreenState(found, status)
  if (state !== 'live') return <ScreenMessage text={SESSION_MESSAGES[state]} />
  return (
    <div className="screen screen-session">
      <TerminalView
        key={sessionId}
        sessionId={sessionId}
        visible
        fontSize={numberSetting(settings, 'appearance.terminalFontSize')}
        fontFamily={stringSetting(settings, 'appearance.terminalFontFamily')}
        copyOnSelect={booleanSetting(settings, 'general.copyOnSelect')}
      />
    </div>
  )
}
