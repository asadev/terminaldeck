/**
 * The loopback ports this app is itself serving on, so a phone is never offered
 * one.
 *
 * ## The hole this closes
 *
 * `remote/tunnel.ts` lets a paired phone tap a port on this machine's loopback
 * and reach it from the phone's browser. That is the feature, and it is a good
 * one — the whole point is to open the dev server you are working on. It has
 * always refused one port: the remote server's own, with the reasoning stated
 * where it is passed, *"tunnelling to our own listener would let a phone reach
 * the desktop's static file server through the connection it is already
 * holding."*
 *
 * The principle was right and the list was one entry long. This app grew two
 * more loopback listeners, and both were control planes rather than content:
 *
 *  - **`deck-control`** — the copilot's MCP server. Every tool in
 *    `catalogue.ts`: start a session, type into one, stop one, write settings.
 *  - **`hook-server`** — where the agent CLIs report their lifecycle events.
 *
 * Neither is filtered by `dev-ports.ts`, which keeps this app's own ports in the
 * list on purpose (*"a port this app is holding is worth saying so about"*), so
 * both were listed to a phone and both were dialable. A bearer token stands in
 * front of each, so this was not an open door — but it was the *wrong* door
 * being present at all, and it made a per-device copilot grant defeatable by a
 * client that had a token, with the calls landing in the action log marked
 * `local`. `COPILOT-CAPABILITIES.md` item 5 is about deciding what a phone may
 * ask the copilot; a path that reaches the same tools without passing the
 * decision would make that decision decorative.
 *
 * ## The hook endpoint left this list, and that is the better fix
 *
 * `hook-server.ts` no longer binds a port at all. It serves a unix socket inside
 * the app's own data directory, for reasons that were about hook staleness
 * rather than about tunnels — but the consequence belongs here: a control plane
 * with no port cannot appear in a port list, cannot be tunnelled by accident,
 * and cannot be reached by anything holding only a network address. Keeping a
 * door off a list is a rule somebody can forget to apply; not having the door is
 * not. `deck-control` still needs this registry, because an MCP server has to
 * speak HTTP to clients this app does not write.
 *
 * ## Why a registry rather than an argument
 *
 * Because the alternative is the wiring site knowing every port, and the wiring
 * site is `src/main/index.ts` and `src/headless/host.ts` — two shells that would
 * both have to be told, and a third that will be written later and will not be.
 * A listener that knows its own port says so, once, where it binds it. That is
 * the same argument `configPaths()` makes for locations.
 *
 * Read live rather than snapshotted: the hub for a phone is built when that
 * phone connects, which is long after everything here has claimed its port, but
 * ordering between two startup paths is exactly the thing that gets rearranged
 * by a later change and never noticed. Asking at connect time cannot go stale.
 */

/** Ports this process is listening on for its own purposes. */
const claimed = new Set<number>()

/**
 * Say that this app is serving on a port.
 *
 * Called by the listener itself, immediately after it knows its port. Ports are
 * ephemeral by default here (both servers bind port 0), so a claim only means
 * anything for the life of the process that made it.
 */
export function claimOwnPort(port: number): void {
  if (Number.isInteger(port) && port > 0) claimed.add(port)
}

/**
 * Give a port back, when a listener stops.
 *
 * Worth doing rather than leaving the set to grow: a stopped server's port goes
 * back to the operating system, and a stale claim would refuse a phone a tunnel
 * to somebody's dev server that happened to be handed the same number.
 */
export function releaseOwnPort(port: number): void {
  claimed.delete(port)
}

/** Every port this app is serving on right now. */
export function ownPorts(): number[] {
  return [...claimed]
}

/** Test seam. Not used by the app. */
export function resetOwnPortsForTests(): void {
  claimed.clear()
}
