import { createContext, useContext } from 'react'

/**
 * The one way the Machines page says "show me that session" — and the reason
 * this file exists at all is that it used to answer the question itself.
 *
 * ## The drift this closes
 *
 * Asad, 2026-08-21, for what he counted as the thousandth time:
 *
 *   > *"every time I tell you I want exactly same identical view of every type
 *   > of session inside, including remote session, including local session"*
 *
 * `shell/session-view-parity.test.ts` is the file that answered him: one bar,
 * one mode switch, one set of controls, whichever computer the session is
 * running on. What it could not reach was a *second* in-session view that had
 * been sitting inside the Remote panel since before any of that — a machine's
 * card listed the sessions on it, and pressing one drew that session's terminal
 * **in the panel**, under a head with a title, a folder and a Close. No
 * controls, no model, no usage, no mode switch, no account. Two doors marked
 * with the same session, and the one that opened onto less was the one a person
 * reaches by looking at the machine it belongs to.
 *
 * There is now one view, and this is how the press gets to it: the card asks
 * the window, the window calls `selectTab(machineTabId(machineId, sessionId))`
 * — the same call the rail, the strip, ⌘1–9 and the command palette all make —
 * and the session arrives in the window's own pane with the bar above it.
 *
 * ## Why this is not `new-session-context.ts`
 *
 * They are one directory apart and one word apart, so the difference is worth
 * stating rather than inferring: that one **starts** a session on a far machine
 * (by opening the new-session dialog with the machine already answered), and
 * this one **shows** one that is already running. `shell/new-session-route.ts`
 * pins the machine opener at exactly one method carrying exactly one argument,
 * on purpose — a second method on it would be a second thing a press on that
 * page can mean, which is how the spawn-without-asking defect got in the first
 * time. So this is its own context with its own name.
 *
 * ## Why a context and not a prop
 *
 * The same argument `machines/servers/session-context.ts` makes for the server
 * shell opener, one directory over. The thing to be reached is `App.tsx`, five
 * components up and on the far side of a switch: the press is on a machine's
 * card in `MachineLinks`, drawn by `RemoteSection`, drawn by `MachinesPanel`,
 * which `PanelView` renders from a `PanelId` with no per-view props threaded
 * through it. Prop-drilling means widening `PanelView`'s signature — the shared
 * file every parallel change is told not to touch — for one panel, and then
 * carrying the argument through two components that have no use for it.
 *
 * ## Why the default is null and not a no-op
 *
 * Because a control that cannot act must be **absent**, and a no-op default is
 * exactly how one comes to be drawn. `null` is a fact the consumer acts on:
 * `MachineLinks` leaves `MachineActions.open` off entirely, and a session row
 * with nothing to open it draws its title, its folder and its status as plain
 * text rather than as a button that eats the press. That is what a unit test
 * rendering the page on its own gets, and what any future tree that mounts this
 * panel outside a window would get.
 */
export interface MachineSessionView {
  /**
   * Put that session in front, in the window's one session view.
   *
   * Both handles travel because the window routes by the single id the two are
   * joined into — `machineTabId(machineId, sessionId)` — and `App.tsx` is the
   * only place that knows how they join. A method that took the joined id
   * instead would make this page the second place that knows, which is the one
   * kind of duplication `readMachineTabId` exists to prevent.
   *
   * It says nothing about *where* in the window the session lands, and must
   * not: unsplit it fills the frame, split it fills the pane you are looking
   * at, and that decision belongs to `selectTab` because the rail and the strip
   * make it there too. A page that asked for the whole frame would be the list
   * undoing somebody's layout.
   */
  show(machineId: string, sessionId: string): void
}

export const MachineSessionViews = createContext<MachineSessionView | null>(null)

/** The window's session view, or null in a tree that has no window around it. */
export function useMachineSessionView(): MachineSessionView | null {
  return useContext(MachineSessionViews)
}
