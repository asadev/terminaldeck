import { createContext, useContext } from 'react'

/**
 * The one way the Machines page asks the window to start a session on another
 * computer.
 *
 * ## What this closes
 *
 * The recorded review of 2026-08-17: *"the sidebar + opens [an agent] directly
 * instead of asking session type. Everywhere should ask the same thing."* Every
 * control in the rail, the strip, the palette and the menu was moved onto
 * `openNewSessionDialog` in that pass — and one was missed, because it is not in
 * the window's chrome at all. The paired-machine card on the Machines page draws
 * its own **New session**, and until this file existed its handler called
 * `bridge.createMachineSession(machine.id, link.folders?.[0] ?? '')`: no
 * question about which agent, no question about which login, and a folder that
 * was whichever one happened to be first in the list that machine advertised
 * rather than one anybody chose. That is the quick window he asked to have taken
 * away, wearing a different frame — and on a *far* machine, where getting it
 * wrong costs more than it does here.
 *
 * ## Why a context and not a prop
 *
 * The same argument `machines/servers/session-context.ts` makes for the same
 * shape of problem one subject over, and it is worth restating rather than
 * cross-referencing, because the two are easy to mistake for one: that one opens
 * a *shell on a server*, this one opens the *new-session dialog pointed at a
 * paired machine*. They are different destinations reached from the same page.
 *
 * The thing that has to be reached is five components up and on the far side of
 * a switch statement. `openNewSessionDialog` lives in `App.tsx`, because the
 * dialog's open flag and its two answers are the window's state; the button that
 * needs it is on a machine's card inside `MachineLinks`, which is drawn by
 * `RemoteSection`, which is drawn by `MachinesPanel`, which `PanelView` renders
 * from a `PanelId` with no per-view props threaded through it. Prop-drilling
 * would mean widening `PanelView`'s signature for one panel — putting a
 * machine-shaped argument on the component that draws all ten views — and then
 * carrying it through two more components that have no use for it themselves.
 * Four files edited to move one callback, three of which only pass it along.
 *
 * A context is one file to declare it, one line to provide it, one line to read
 * it, and nothing in between has to know it exists.
 *
 * ## Why the default is null and not a no-op
 *
 * Because a control that cannot act must be **absent**, and a no-op default is
 * exactly how one comes to be drawn. `null` is a fact the consumer can act on:
 * the harness, a unit test rendering the page on its own, and any future tree
 * that mounts this panel outside the window all get a machine card with no *New
 * session* button rather than one that swallows the press. `MachineLinks` reads
 * it and says what it can do instead, the way `ServerAdvanced` already does.
 */
export interface MachineSessionOpener {
  /**
   * Open the new-session dialog, already pointed at that machine.
   *
   * One argument, and it is the same one the rail's machine heading passes:
   * `openNewSessionDialog(null, machineId)` — null folder, machine named. The
   * press has answered *which computer* and nothing else, so the dialog opens on
   * the next question rather than the first. That is the difference between a
   * shortcut and a second flow, and it is why this interface deliberately cannot
   * express anything more: a method that also took a folder or an agent would be
   * a door back to the spawn this file exists to remove.
   *
   * The name does not travel with the id, which is where this parts company with
   * the server opener beside it. That one carries a name because the window has
   * no route to the servers list; this one needs none, because nothing the
   * window does with a machine id prints a name the window does not already
   * hold — the dialog's machine step reads the paired list for itself.
   */
  open(machineId: string): void
}

export const MachineSessions = createContext<MachineSessionOpener | null>(null)

/** The opener, or null in a tree that has no window around it. */
export function useMachineSessionOpener(): MachineSessionOpener | null {
  return useContext(MachineSessions)
}
