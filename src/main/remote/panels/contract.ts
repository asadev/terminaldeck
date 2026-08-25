/**
 * What a panel is, on the phone's side of the wire.
 *
 * ## Why this file exists
 *
 * > *"these pages are not just to view the information — exactly all actions
 * > that we have in desktop application, they should be inside each option of
 * > them."*
 *
 * Four panels — Artifacts, Store, AI readiness, MCP servers — became four
 * read-only lists in a hurry, and the hurry showed: each was *"the shortest
 * honest answer the existing module can give"*, which is a fair thing to ship
 * once and a poor thing to leave. Store was worse than thin — it read the
 * desktop's preferences file, which is not what the desktop calls a Store at
 * all, and on a headless host that read threw and the screen said *"This machine
 * could not answer that panel."*
 *
 * The rewrite needed a shape the four could share, because the alternative was
 * four families of wire frame — `mcp.add`, `mcp.edit`, `mcp.remove`,
 * `mcp.connect`, `readiness.fix`, `store.install`, `store.remove` — each written
 * once in TypeScript, once in Swift, once in a codec and once in a screen.
 *
 * So the host declares what a panel can do **in the same answer as its rows**,
 * and the phone draws whatever it was handed. A panel that grows an action next
 * month is a change to one file in this folder: no wire change, no codec change,
 * no screen change. The phone can only ever send back an action it was offered,
 * which is also what makes the open `action` string on `panel.act` safe — see
 * the note on `WINDOW_ACTIONS` in `protocol.ts` for the case where that argument
 * does *not* hold and the list is closed instead.
 *
 * ## The rule every implementation follows
 *
 * **An action answers with the panel.** Not with an outcome, not with an ack:
 * `act` returns the same `PanelPayload` that `read` would return afterwards, so
 * the screen redrawing is the confirmation. A person who removed an MCP server
 * sees it gone, and there is no second state for a client to get wrong.
 *
 * `notice` is the one exception, and it is a line rather than a state: *"Added
 * context7."* It rides on the redraw and it is never the only thing that
 * changed.
 */

import type { PanelAction, PanelRow, PanelScope } from '../protocol'

/** Everything a panel answers with, whether it was read or acted on. */
export interface PanelPayload {
  /** Where this was answered for. Echoed so the screen can caption itself. */
  path: string
  /** Why the list is empty, when it is. Not an error — an explanation. */
  note?: string
  /** What just happened. Only ever set by an action. */
  notice?: string
  scopes?: PanelScope[]
  /** What can be done to the panel itself. */
  actions?: PanelAction[]
  rows: PanelRow[]
}

/** What a panel was asked for. */
export interface PanelRequest {
  /** The folder in view. Always resolved before it gets here. */
  path: string
  scope?: string
  query?: string
}

/** What an action was asked to do. */
export interface PanelActionRequest extends PanelRequest {
  action: string
  /** The row it names, when it names one. */
  id?: string
  fields: Record<string, string>
}

/**
 * One panel.
 *
 * `act` is optional: a panel with nothing to do is a legitimate panel, and
 * making it implement a method that refuses everything would be worse than the
 * absence. `server.ts` answers `panel.act` for one of those with the panel
 * unchanged and a notice saying so.
 */
export interface Panel {
  read(request: PanelRequest): Promise<PanelPayload>
  act?(request: PanelActionRequest): Promise<PanelPayload>
}
