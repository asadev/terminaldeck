/**
 * The windows a session can be in — the main window, or one of its own.
 *
 * Asad, 2026-10-03, asking for sessions in their own windows on his second
 * monitor; and of the MCP, a day earlier: *"Everything that I can do manually
 * should be able to do through the MCP."* Moving a session into its own window
 * and back is something he does by hand, so it is three tools here — the same
 * three things the rail's ⋯ menu, the palette and the File menu do, through the
 * same registry (`main/popout-windows.ts`), so a tool and a click cannot reach
 * different results.
 *
 * ## Tier
 *
 * `read` for the list. `act` for the two moves: each is visible the moment it
 * happens, undone by the other one, and touches no process — a session moved
 * into its own window is the same pty printing into a different window. Nothing
 * here can end a session; `sessions.stop` is the only tool that does.
 *
 * ## Which sessions
 *
 * Asked through `requireSession`, so a caller only reaches the sessions its own
 * listing shows it — the same scope every session tool keeps.
 */

import { BadArgument, optStr, requireSession, str, type ToolSpec } from './catalogue'
import { Refused } from './surface'

/** One session window, as the registry reports it. Narrowed here; see `PopoutWindowView`. */
export interface WindowToolView {
  windows: ReadonlyArray<{
    sessionId: string
    label: string
    status: string | null
    displayId: number | null
    displayLabel: string
    bounds: { x: number; y: number; width: number; height: number }
    fullScreen: boolean
    minimized: boolean
    focused: boolean
  }>
  displays: ReadonlyArray<{ id: number; label: string; primary: boolean; width: number; height: number }>
}

export interface WindowToolResult {
  ok: boolean
  message: string
  sessionId: string
  display?: string
}

export interface WindowToolDeps {
  view(): WindowToolView
  open(sessionId: string, options: { displayId: number | null }): WindowToolResult
  dock(sessionId: string): WindowToolResult
}

/**
 * A display named by id or by its name, as the list prints them.
 *
 * Both, because a model reads "DELL U2723QE" off `windows.list` and will hand
 * that back, and refusing it for not being a number would be a refusal over
 * spelling. A name matches case-insensitively and must match exactly one.
 */
export function displayIdFrom(raw: unknown, view: WindowToolView): number | null {
  if (raw === undefined || raw === null || raw === '') return null
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    if (view.displays.some((d) => d.id === raw)) return raw
    throw new BadArgument(`there is no display with id ${raw}; windows.list names the ones there are`)
  }
  if (typeof raw === 'string') {
    const asNumber = Number(raw)
    if (raw.trim() !== '' && Number.isFinite(asNumber) && view.displays.some((d) => d.id === asNumber)) return asNumber
    const wanted = raw.trim().toLowerCase()
    if (wanted === 'main' || wanted === 'primary') {
      const primary = view.displays.find((d) => d.primary)
      if (primary) return primary.id
    }
    const matches = view.displays.filter((d) => d.label.toLowerCase() === wanted)
    if (matches.length === 1) return matches[0].id
    throw new BadArgument(
      matches.length === 0
        ? `no display is called “${raw}”; windows.list names the ones there are`
        : `two displays are called “${raw}”; pass its id from windows.list instead`,
    )
  }
  throw new BadArgument('display must be a display id or name from windows.list')
}

export function sessionWindowTools(deps: WindowToolDeps): ToolSpec[] {
  return [
    {
      id: 'windows.list',
      wire: 'windows_list',
      tier: 'read',
      title: 'List session windows and displays',
      description:
        'Which sessions are in a window of their own, and the displays (monitors) connected to this computer. ' +
        'Each window gives its session id, the name the app shows for it, its status, which display it is on ' +
        '(id and name), its position and size in screen points, and whether it is full screen, minimised or in ' +
        'front. A session that is not listed here is in the main window. Call this before windows.pop_out when ' +
        'the person names a monitor, to find its id.',
      index: 'Which sessions are in their own windows, and the monitors connected to this computer.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'List the session windows and displays',
      run: async () => {
        const view = deps.view()
        return { value: view, summary: { windows: view.windows.length, displays: view.displays.length } }
      },
    },

    {
      id: 'windows.pop_out',
      wire: 'windows_pop_out',
      tier: 'act',
      title: 'Move a session into its own window',
      description:
        'Move a session out of the main window into a window of its own — the same live session, not a copy: ' +
        'the same process and the same scrollback, and anything typed there goes to the same agent. Optionally ' +
        'put it on a particular display (monitor), by the id or name windows.list gives, or "main". If the ' +
        'session already has its own window, that window is brought to the front (and moved nowhere). Returns ' +
        'which display it opened on. The copilot cannot be moved out of the main window.',
      index: 'Move a session into its own window, optionally on a named monitor (same live session, not a copy).',
      inputSchema: {
        type: 'object',
        properties: {
          sessionId: { type: 'string', description: 'From sessions.list.' },
          display: {
            type: 'string',
            description: 'Optional. A display id (as text) or name from windows.list, or "main".',
          },
        },
        required: ['sessionId'],
        additionalProperties: false,
      },
      precheck: (args) => {
        str(args, 'sessionId')
      },
      summary: (args) => {
        const display = args.display
        return `Move session ${optStr(args, 'sessionId') ?? '?'} into its own window${
          display === undefined || display === null || display === '' ? '' : ` on ${String(display)}`
        }`
      },
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        const displayId = displayIdFrom(args.display, deps.view())
        const result = deps.open(session.id, { displayId })
        if (!result.ok) throw new Refused('not-permitted', result.message)
        return {
          value: { sessionId: result.sessionId, message: result.message, display: result.display ?? null },
          summary: { sessionId: result.sessionId, display: result.display ?? null },
        }
      },
    },

    {
      id: 'windows.dock',
      wire: 'windows_dock',
      tier: 'act',
      title: 'Move a session back to the main window',
      description:
        'Put a session that is in its own window back into the main window and close that window. The session ' +
        'keeps running, untouched — this never stops anything. Refused, with a sentence, when the session is not ' +
        'in a window of its own (windows.list says which are).',
      index: 'Put a session that is in its own window back into the main window (never stops it).',
      inputSchema: {
        type: 'object',
        properties: { sessionId: { type: 'string', description: 'From windows.list or sessions.list.' } },
        required: ['sessionId'],
        additionalProperties: false,
      },
      precheck: (args) => {
        str(args, 'sessionId')
      },
      summary: (args) => `Move session ${optStr(args, 'sessionId') ?? '?'} back to the main window`,
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        const result = deps.dock(session.id)
        if (!result.ok) throw new Refused('not-permitted', result.message)
        return { value: { sessionId: result.sessionId, message: result.message }, summary: { sessionId: result.sessionId } }
      },
    },
  ]
}
