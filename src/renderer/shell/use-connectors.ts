/**
 * Which connectors this session actually has.
 *
 * ## What this is answering
 *
 * Asad, on the `Connectors` chip that used to sit on the bar unconditionally:
 *
 *   > *"Connectors — a dropdown only when some exist. Hide it when empty."*
 *
 * The chip was a door: it opened the MCP servers view and nothing else, and it
 * was on the bar whether or not there was a single server behind it. On a
 * machine with none configured — which is every machine on the first day — it
 * was a permanent invitation to a room with nothing in it, taking a chip's worth
 * of a bar shared with five other controls. That is the most repeated complaint
 * in his whole review, and the fix is the one he stated: know the answer before
 * drawing the control.
 *
 * ## Why the count is asked for rather than assumed
 *
 * There is no cheaper signal. MCP servers live in three scopes — the user's own
 * `~/.claude.json`, a project's `.mcp.json`, and a local override — and which
 * ones apply depends on the directory the session runs in, which is exactly why
 * `mcp:list` takes a project path. So the honest answer for *this* session is
 * the one this asks for with this session's own `cwd`, and a global count would
 * be right for some sessions and wrong for others in the same window.
 *
 * ## Why nothing is drawn until the answer lands
 *
 * A chip that appears a quarter of a second after the bar and pushes the mode
 * switch sideways is a worse bar than one without connectors at all. `loaded`
 * exists so the component can wait rather than guess, and the wait is one IPC
 * round trip against a file the main process has usually already read.
 *
 * The failure case is deliberately silent. A list that cannot be read is not the
 * same as a list that is empty, but the difference cannot be acted on from a
 * toolbar and the review's rule for that is unambiguous: a control nobody can
 * use is removed, not greyed out with an apology. The MCP servers view is still
 * in the sidebar and still says what went wrong, in its own words, with room to
 * say it.
 */

import { useEffect, useState } from 'react'
import { readServers, rowDetail, type McpRow } from '../chat/attach/McpServers'
import { useControlOffer } from '../features/offer'

export interface ConnectorsState {
  /** The servers that apply to this session's directory. Empty until loaded. */
  rows: McpRow[]
  /** False until the first answer lands, whatever that answer turns out to be. */
  loaded: boolean
}

/** The two preload methods this uses, both already on the bridge. */
interface ConnectorsBridge {
  listMcpServers?(projectPath?: string | null): Promise<unknown>
  onMcpState?(cb: (status: unknown) => void): () => void
}

function bridge(): ConnectorsBridge | undefined {
  return (globalThis as unknown as { deck?: ConnectorsBridge }).deck
}

/** What the dropdown prints under a server's name. The composer's own wording. */
export { rowDetail }

export function useConnectors(cwd?: string | null): ConnectorsState {
  const [state, setState] = useState<ConnectorsState>({ rows: [], loaded: false })
  /**
   * Whether MCP servers is installed at all.
   *
   * This moved here on 2026-08-18 and it is worth saying why, because the file
   * it moved *from* no longer exists. The `chat.connectors` control used to be a
   * row inside the composer's Add menu, which is where the registry's question
   * was asked. That row is gone — the window's bar carries the chip now, and a
   * copy of it in the chat box was one of the duplicates he asked to have
   * removed — so the question had to move with the surface or the switch in the
   * store would have stopped doing anything.
   *
   * It is asked here rather than in `SessionControls` because the thing left
   * behind by an uninstalled feature is the *chip*, and this hook is the only
   * thing that decides whether there is a chip. `features-wiring.test.ts` names
   * this file as the host and fails if the question stops being asked.
   *
   * Non-null means "not installed", and the answer is an empty list rather than
   * an offer: the review's rule for a control nobody can use is that it is not
   * there, and the MCP servers row in the sidebar is where somebody would turn
   * the feature back on.
   */
  const offer = useControlOffer('chat.connectors')
  // Not `off`: the effect below already binds that name to its own unsubscribe
  // function, and a `const` in the same block would put this one in its temporal
  // dead zone — a ReferenceError on the first render rather than a type error.
  const uninstalled = offer !== null

  useEffect(() => {
    if (uninstalled) {
      setState({ rows: [], loaded: true })
      return
    }
    const host = bridge()
    const list = host?.listMcpServers
    if (typeof list !== 'function') {
      // No channel in this build. Loaded, and empty — which draws no chip, which
      // is the correct outcome: this build cannot open a connector either.
      setState({ rows: [], loaded: true })
      return
    }

    let mounted = true
    const ask = (): void => {
      void list
        .call(host, cwd == null || cwd === '' ? null : cwd)
        .then((answer) => {
          if (!mounted) return
          // `readServers` returns null for a payload that is not a list at all,
          // which is a different thing from an empty list — but not a difference
          // a chip can express, so both draw nothing. It is the parser the
          // composer's own connector list uses, so the two cannot come to
          // disagree about what a server is.
          setState({ rows: readServers(answer) ?? [], loaded: true })
        })
        .catch(() => {
          if (mounted) setState({ rows: [], loaded: true })
        })
    }

    ask()
    // Adding, removing, enabling or connecting a server pushes `mcp:state`, so
    // the chip appears and disappears with the servers rather than with a
    // reload. Optional because a preload without it is a build this component
    // must still work in — it simply stops updating, and the first answer stands.
    const off = typeof host?.onMcpState === 'function' ? host.onMcpState(ask) : null

    return () => {
      mounted = false
      off?.()
    }
  }, [cwd, uninstalled])

  return state
}
