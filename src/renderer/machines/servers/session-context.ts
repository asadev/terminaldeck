import { createContext, useContext } from 'react'

/**
 * The one way a screen inside the Machines panel asks the window to open a
 * shell on a server.
 *
 * ## Why a context and not a prop
 *
 * The thing that has to be reached is four components up and on the other side
 * of a switch statement: the window owns the list of what is open, and the
 * control that opens one is on a server's page, which is rendered by
 * `PanelView` from a `PanelId` with no props threaded through it. Passing a
 * callback down would mean widening `PanelView`'s signature for one panel, which
 * is the shared file every parallel change is told not to touch, and would put a
 * server-shaped argument on the component that draws all ten views.
 *
 * ## Why the default is null and not a no-op
 *
 * Because a control that cannot act must be **absent**, and a no-op default is
 * exactly how one comes to be drawn. `null` is a fact the consumer can act on:
 * the harness, a unit test rendering the panel on its own, and any future tree
 * that mounts this panel outside the window all get a page with no *open a
 * terminal* control rather than one that swallows the press. `ServerPage`
 * reads it and says what it can do instead — it moved there on 2026-08-19 when
 * *open a terminal* was promoted out of Advanced, because a server he had just
 * connected offered no visible way to open anything on it.
 */
export interface ServerSessionOpener {
  /**
   * Open one, and put the window on it.
   *
   * The name travels with the id because the window has no route to the servers
   * list — the list lives inside this panel, which is usually not the thing on
   * screen — and the rail heading, the pill's tooltip, the window bar and the
   * close confirmation all print it.
   *
   * `startIn` is the folder on the server the terminal should open in, added on
   * 2026-08-19 with `ServerFolderPicker`. Left off — which every caller did
   * until that day — means wherever the account's own sign-in lands, which is
   * what SSH gives you and what this app did for the whole life of the feature.
   */
  open(serverId: string, serverName: string, startIn?: string | null): void
  /** How many are already open on that one, so a page can say so. */
  openOn(serverId: string): number
  /**
   * A server has been renamed, so the rows that carry its old name can catch up.
   *
   * Pushed at the moment it happens rather than re-read on a timer, because that
   * is the standing rule this whole area obeys — *"events, not polling"* — and
   * because the alternative is worse than a tick: the window's copy of the name
   * is only ever wrong for as long as nobody tells it, and the one moment it can
   * become wrong is a press somebody made two components away.
   *
   * Without it the rail heading, the pill's tooltip and the close confirmation
   * keep the old name until the last terminal on that server is closed, which is
   * the app disagreeing with itself about what a machine is called.
   */
  renamed(serverId: string, name: string): void
}

export const ServerSessions = createContext<ServerSessionOpener | null>(null)

/** The opener, or null in a tree that has no window around it. */
export function useServerSessionOpener(): ServerSessionOpener | null {
  return useContext(ServerSessions)
}
