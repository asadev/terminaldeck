/**
 * `ui.list` and `ui.do` — the window's own clicks, for a caller who is not in
 * front of it.
 *
 * ## The bridge
 *
 * `renderer/driving/ui-bridge.ts` leaves two functions on the app window, the
 * same way `where.ts` leaves `app.where`'s reader: `list()` and `do(request)`.
 * This file calls them through `executeJavaScript` in the page's main world, on
 * the app's own window and no other — never a browser tab, whose page is a
 * separate `WebContentsView` with globals of its own. Everything `do` runs goes
 * through `App.tsx`'s own dispatcher, so a command run from here is the command a
 * person's chord runs. See that file for the argument.
 *
 * ## What is refused, and why it is refused here
 *
 * {@link UI_REFUSED} is the list of commands that open a dialog or a native
 * panel and then wait for a person to type or pick: New session, Open project,
 * quick open, the palette. Run from another computer they would leave a sheet on
 * a screen nobody is at — the dead end this app keeps removing — and each has a
 * tool that does the job directly, which the refusal names. Decided in the main
 * process rather than in the window, because the window is the thing being
 * driven and a rule about what may drive it does not belong to it.
 *
 * Installing a feature is a configuration change and is raised to `alter`, so a
 * person confirms it; everything else here is visible and undone by clicking
 * back, which is `act`.
 *
 * ## Not while a tour plays
 *
 * A tour moves the screen on its own, and a person watching one has suspended
 * their model of cause and effect — the argument `control.ts` makes for
 * `NOT_WHILE_DRIVING`. A view switched underneath a tour is a change nobody can
 * attribute, so `ui.do` is on that list.
 */

import { BadArgument, optStr, str, type ToolSpec } from './catalogue'
import { Refused } from './surface'

/** The global the renderer publishes. Spelled once here and once in `ui-bridge.ts`. */
export const UI_GLOBAL = '__terminaldeckUi'

export const UI_LIST_CALL = `globalThis.${UI_GLOBAL}?.list() ?? null`

/**
 * The expression that runs one request in the window.
 *
 * The request is serialised with `JSON.stringify`, which produces a JavaScript
 * literal, so nothing a caller sends can become code: a target containing a
 * quote or a `)` is a string with a quote in it. The two line separators that
 * JSON leaves raw are escaped as well, so the literal is valid in any engine.
 */
export function uiDoCall(request: { kind: string; target: string }): string {
  const literal = JSON.stringify(request).replace(/\u2028/gu, '\\u2028').replace(/\u2029/gu, '\\u2029')
  return `globalThis.${UI_GLOBAL}?.do(${literal}) ?? null`
}

/**
 * Commands `ui.do` will not run, and the tool that does the job instead.
 *
 * Every one opens something that waits for a person — a dialog to type into, a
 * native panel to pick from, a palette with a cursor in it. `actions/ui.ts`
 * points each of these ids at the tool named here, and `ui.test.ts` checks the
 * two agree.
 */
export const UI_REFUSED: Readonly<Record<string, string | null>> = Object.freeze({
  'session.new': 'sessions.start',
  'session.newDialog': 'sessions.start',
  'session.resume': 'sessions.start',
  'session.close': 'sessions.stop',
  'project.open': 'projects.browse',
  'palette.quickOpen': 'files.find',
  'app.quickOpen': 'files.find',
  'view.search': 'sessions.search',
  'panel.search': 'sessions.search',
  'palette.commands': 'ui.list',
  'app.palette': 'ui.list',
  // Null: there is no tool, because there is nothing behind the dialog yet.
  'app.join': null,
})

const INSTALL_PREFIX = 'features.install.'

export interface UiToolDeps {
  /** Evaluate in the app window, or null when there is no window. See `where-tool.ts`. */
  evaluate(code: string): Promise<unknown>
}

type UiKind = 'run' | 'focus' | 'settings'

function kindOf(args: Record<string, unknown>): UiKind {
  const kind = str(args, 'action')
  if (kind === 'run' || kind === 'focus' || kind === 'settings') return kind
  throw new BadArgument('action must be "run", "focus" or "settings"')
}

function refuseDialogs(args: Record<string, unknown>): void {
  if (kindOf(args) !== 'run') return
  const target = str(args, 'target')
  if (!(target in UI_REFUSED)) return
  const instead = UI_REFUSED[target]
  throw new Refused(
    'not-permitted',
    `${target} opens something that waits for a person to type or pick, and nobody may be at this screen. ` +
      (instead === null ? 'There is nothing behind that dialog yet.' : `Use ${instead} instead.`),
  )
}

/** Whatever the window answered, narrowed. */
function answerOf(raw: unknown): { ok: boolean; text: string } | null {
  if (typeof raw !== 'object' || raw === null) return null
  const answer = raw as { ok?: unknown; did?: unknown; why?: unknown }
  if (answer.ok === true && typeof answer.did === 'string') return { ok: true, text: answer.did }
  if (answer.ok === false && typeof answer.why === 'string') return { ok: false, text: answer.why }
  return null
}

const NO_WINDOW =
  'There is no app window open to act on, so nothing on screen changed. Sessions, files and everything else ' +
  'still work through their own tools.'

export function uiTools(deps: UiToolDeps): ToolSpec[] {
  return [
    {
      id: 'ui.list',
      wire: 'ui_list',
      tier: 'read',
      title: 'What can be done in the window',
      index: 'The app window’s commands, the sessions it can bring to the front, and its Settings sections — for ui.do.',
      description:
        'What the app window can be told to do with ui.do right now: every command in its palette (views like ' +
        'Files, Source control, Overview; split or swarm the window; show or hide the sidebar; open Settings, ' +
        'Help, the session inspector), the sessions it can bring to the front, and the Settings sections it can ' +
        'open. `refused` lists the commands ui.do will not run because they wait for typing, and the tool to use ' +
        'for each. Use app.where to see what is on screen now.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'List what can be done in the window',
      run: async () => {
        const listing = await deps.evaluate(UI_LIST_CALL).catch(() => null)
        if (typeof listing !== 'object' || listing === null) {
          return { value: { window: null, note: NO_WINDOW }, summary: { window: 'none' } }
        }
        const view = listing as { commands?: Array<{ id?: unknown }> }
        const commands = Array.isArray(view.commands)
          ? view.commands.filter((command) => typeof command.id === 'string' && !(command.id in UI_REFUSED))
          : []
        return {
          value: { ...listing, commands, refused: UI_REFUSED },
          summary: { commands: commands.length },
        }
      },
    },

    {
      id: 'ui.do',
      wire: 'ui_do',
      tier: 'act',
      title: 'Do something in the window',
      index: 'Do what a click does in the app window: open a view, bring a session to the front, open Settings.',
      description:
        'Do in the app window what a person does by clicking: `action: "run"` runs a palette command by id ' +
        '(ui.list has them — e.g. "view.files", "pane.split", "view.sidebar"); "focus" brings a session to the ' +
        'front, by id; "settings" opens Settings at a section ("general", "agents", "copilot", …). Installing a ' +
        'feature ("features.install.<id>") is confirmed. Commands that open a dialog waiting for typing are ' +
        'refused with the tool that does the job. Not while a tour is playing.',
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['run', 'focus', 'settings'] },
          target: { type: 'string', description: 'A command id, a session id, or a Settings section.' },
        },
        required: ['action', 'target'],
        additionalProperties: false,
      },
      escalate: (args) => {
        const target = optStr(args, 'target') ?? ''
        return optStr(args, 'action') === 'run' && target.startsWith(INSTALL_PREFIX) ? 'alter' : 'act'
      },
      precheck: (args) => {
        refuseDialogs(args)
      },
      summary: (args) => {
        const target = optStr(args, 'target') ?? '?'
        switch (optStr(args, 'action')) {
          case 'focus':
            return `Bring session ${target} to the front`
          case 'settings':
            return `Open Settings at ${target}`
          default:
            return target.startsWith(INSTALL_PREFIX)
              ? `Install the ${target.slice(INSTALL_PREFIX.length)} feature`
              : `Run ${target} in the window`
        }
      },
      run: async (args) => {
        refuseDialogs(args)
        const kind = kindOf(args)
        const target = str(args, 'target')
        const raw = await deps.evaluate(uiDoCall({ kind, target })).catch(() => null)
        const answer = answerOf(raw)
        if (answer === null) return { value: { done: false, note: NO_WINDOW }, summary: { window: 'none' } }
        if (!answer.ok) throw new BadArgument(`${answer.text} ui.list shows what is there.`)
        return { value: { done: true, did: answer.text }, summary: { action: kind, target } }
      },
    },
  ]
}
