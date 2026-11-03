/**
 * The separate windows of the native macOS window: one screen each.
 *
 *   /?screen=panel&id=<panelId>       one sidebar view — Files, Tasks, Memory…
 *   /?screen=panel&id=<panelId>&project=<path>   …about that project
 *   /?screen=session&id=<sessionId>   one session's terminal
 *
 * Same origin and the same bridge as the main window, with no side panel and no
 * tab strip. Each posts `ready` and its title, as the main window does. What a
 * window cannot show — a view that does not exist, a session that has ended or
 * was never there — is said in a plain sentence, never a blank window.
 */

import { isPanelId, type PanelId } from '../shell/panels'

export type ScreenRoute =
  | { kind: 'panel'; id: PanelId; project: string | null }
  | { kind: 'session'; id: string }
  | { kind: 'unknown'; message: string }

/** The screen this page load asks for, or null when it is not a screen at all. */
export function screenRoute(search: string): ScreenRoute | null {
  const query = new URLSearchParams(search)
  const screen = query.get('screen')
  if (screen === null) return null
  const id = query.get('id') ?? ''
  if (screen === 'panel') {
    if (isPanelId(id)) {
      const project = query.get('project')
      return { kind: 'panel', id, project: project === null || project === '' ? null : project }
    }
    return { kind: 'unknown', message: id === '' ? 'No page was named.' : `There is no page called “${id}”.` }
  }
  if (screen === 'session') {
    return id === '' ? { kind: 'unknown', message: 'No session was named.' } : { kind: 'session', id }
  }
  return { kind: 'unknown', message: 'This window has nothing to show.' }
}

/** The URL of a screen, for whatever opens one. */
export function screenUrl(route: { kind: 'panel'; id: PanelId; project?: string | null } | { kind: 'session'; id: string }): string {
  const query = new URLSearchParams({ screen: route.kind, id: route.id })
  if (route.kind === 'panel' && route.project) query.set('project', route.project)
  return `/?${query.toString()}`
}

/** What a session's window says instead of a terminal, when there is no running session to attach. */
export const SESSION_MESSAGES = {
  connecting: 'Connecting to the session…',
  missing: 'This session is not open any more.',
  ended: 'This session has ended.',
} as const

/**
 * Which of those applies: a session not in the list is gone (or never was), one
 * with an exit code or an exited status has ended, and otherwise there is a
 * terminal to show.
 */
export function sessionScreenState(
  found: { exitCode: number | null } | null | undefined,
  status: string | null,
): 'connecting' | 'missing' | 'ended' | 'live' {
  if (found === undefined) return 'connecting'
  if (found === null) return 'missing'
  if (found.exitCode !== null || status === 'exited') return 'ended'
  return 'live'
}

/**
 * What the main window posts in place of opening a window of its own — every
 * pop-out in the app, in the native window: the session bar's "Move to new
 * window", the palette's and the menu's. The native side opens the window, on
 * the route {@link screenUrl} writes for the same kind and id.
 */
export function openWindowMessage(
  kind: 'session' | 'panel',
  id: string,
  title: string,
): { type: 'open-window'; kind: 'session' | 'panel'; id: string; title: string } {
  return { type: 'open-window', kind, id, title }
}
