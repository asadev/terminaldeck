import { useCallback, useEffect, useMemo, useState } from 'react'
import { detectPlatform, thisMachine } from '../platform'
import { asView, type MachineLinkState, type MachinesView } from '../machines/types'
import { asServers, type Server } from '../machines/servers/types'

/**
 * Which machines' copilots this window can reach — for the switch at the top of
 * the copilot page.
 *
 * ## Why the copilot needed a machine switch at all
 *
 * Asad has two computers paired to each other, and the copilot page had no way
 * to say which one it was about. From his covering message of 2026-08-20: he
 * wants *"the same switch we have for sessions"* at the top of the copilot page,
 * so the copilot can be used against either machine.
 *
 * The sessions' version of that switch is the **Where** step in the New Session
 * dialog — this machine first, then each machine that can be reached — and the
 * one rule worth copying from it is the one about absence: *"a person with no
 * second computer paired should not be offered a machine step at all."* So with
 * nothing paired this answers a single row and the page draws no switch.
 *
 * ## Why a machine can be listed and still not offer a copilot
 *
 * Because the copilot is not a capability of a machine, it is a decision about a
 * device. `remote/copilot-access.ts` carries the whole argument: a device paired
 * as **My device** reaches the copilot automatically, a **guest** never does,
 * and the kind is fixed at the moment of approval. So whether this Mac reaches
 * that PC's copilot depends on what somebody chose at *that* PC's keyboard, and
 * the only way to know is that the far end's `welcome` carried a copilot link
 * for us.
 *
 * That is why {@link CopilotMachine.reach} has three values and not two. A
 * machine that is offline is a machine we have not asked; a machine that is
 * online and sent no copilot link is one that has answered, and the answer is
 * no. Collapsing those into "unavailable" would be the app claiming to know
 * something it has not been told — and the remedy differs: one is *wait*, the
 * other is *pair this machine again as your own*.
 *
 * ## Read, not owned
 *
 * Nothing here connects, pairs or forgets. `useMachines` in `machines/` is the
 * window's full-fat view with a session opener and an output subscription bolted
 * on; this is a list of names and one question about each of them, mounted by
 * one page. Sharing the heavier hook would have meant this page holding a
 * machine-session starter it has no use for.
 */

/** How far this window has got with one machine's copilot. */
export type CopilotReach =
  /** Connected, and its welcome carried a copilot link for this device. */
  | 'ready'
  /** Connected, and it did not. This device is a guest there. */
  | 'refused'
  /** Not connected, so the question has not been asked yet. */
  | 'unreachable'
  /**
   * A server, which has no copilot of its own and never will.
   *
   * Asad, on this switch: *"here icon not still choose the local connected
   * server, by the way, I think. Maybe server is not connected, I don't know."*
   * The switch listed paired devices only, so a server he had signed in to was
   * simply not on it and he could not tell whether that meant *not connected*
   * or *not shown*. It is shown now.
   *
   * It cannot be switched **to**, and that is a fact about servers rather than
   * a control we declined to build. A server does not run this app — see the
   * vocabulary note at the top of `machines/servers/types.ts` — so there is no
   * copilot process there to point at. The copilot that works on a server is
   * the one on this computer, and whether it may act is a per-server grant that
   * `SERVERS-DESIGN.md` §6.2 puts on that server's own page in as many words:
   * *"not in Settings, and not in the copilot's window."*
   */
  | 'server'

export interface CopilotMachine {
  /** Empty for this computer, which is always the first row. */
  id: string
  name: string
  reach: CopilotReach
  /**
   * The link has said `copilot.hello` on the socket it currently holds.
   *
   * Carried because it is the one thing about a reachable machine that changes
   * *after* the page is already looking at it: it is false on every fresh
   * connection and true a round trip later, and false again the moment a laptop
   * sleeps. A pane that attached once on mount and never watched this would sit
   * on "Reaching…" for the rest of the session after one reconnect, which is the
   * shape of defect this project keeps finding — a screen that is right about a
   * moment and wrong about now. Always true for this computer.
   */
  open: boolean
}

interface MachinesReadBridge {
  listMachines(): Promise<unknown>
  onMachinesState(callback: (view: unknown) => void): () => void
  /**
   * The stored servers, and nothing more.
   *
   * Deliberately not `lookAtServer`, which is the call that would tell us
   * whether one is up: it opens an SSH connection. A switch at the top of a page
   * that dialled every server the moment the page was drawn would be this
   * project's own polling complaint with a worse bill attached — *"events, not
   * polling"* — for a row that cannot be pressed either way.
   */
  listServers?(): Promise<unknown>
}

function bridge(): MachinesReadBridge | null {
  const deck = (globalThis as { deck?: Partial<MachinesReadBridge> }).deck
  if (!deck || typeof deck.listMachines !== 'function') return null
  if (typeof deck.onMachinesState !== 'function') return null
  return deck as MachinesReadBridge
}

/**
 * Whether this link's `welcome` said this device reaches that machine's copilot.
 *
 * The order of the two questions is the whole of it. **Offline first**: a
 * machine we have not spoken to has told us nothing, and reading its absent
 * copilot as a refusal would put "pair this again as your own" on a row whose
 * only problem is that it is asleep. Only once it is online does the missing
 * copilot mean what `MachineLinkState.copilot` says it means — no copilot for
 * us, in either of the two ways the far end deliberately does not distinguish.
 *
 * `linked` is checked as well as the object's presence, because a pushed
 * `copilot.grant` can set it false and take the copilot away without a
 * reconnect — the one case nothing else on this link reports.
 */
function reachOf(link: MachineLinkState): CopilotReach {
  if (link.state !== 'online') return 'unreachable'
  return link.copilot?.linked === true ? 'ready' : 'refused'
}

export function useCopilotMachines(): CopilotMachine[] {
  const [view, setView] = useState<MachinesView | null>(null)
  const [servers, setServers] = useState<Server[]>([])

  const read = useCallback((deck: MachinesReadBridge) => {
    void deck
      .listMachines()
      .then((value) => setView(asView(value)))
      .catch(() => {
        // Leave whatever was last true. A failed read is not evidence that the
        // machines have gone, and emptying the switch under somebody who is
        // looking at a remote copilot would take the page out from under them.
      })
  }, [])

  useEffect(() => {
    const deck = bridge()
    if (!deck) return
    read(deck)
    // The servers are read once, on mount. The stored list only changes when
    // somebody adds or forgets one, which is a page away, and re-reading it on
    // a timer would be a poll for a row that cannot be pressed.
    if (typeof deck.listServers === 'function') {
      void deck
        .listServers()
        .then((value) => setServers(asServers(value)))
        .catch(() => {
          // No servers feature in this build. The rows simply do not appear.
        })
    }
    // Every change to any link arrives on this one push — a machine coming up,
    // a copilot grant being revoked at the far keyboard — so there is no timer
    // here and nothing to poll.
    return deck.onMachinesState((value) => setView(asView(value)))
  }, [read])

  return useMemo(() => {
    // This computer, always first and always reachable: its copilot is a process
    // on this disk, and every other row is measured against it.
    const here: CopilotMachine = { id: '', name: thisMachine(detectPlatform()), reach: 'ready', open: true }
    const rest: CopilotMachine[] = []
    if (view) {
      const named = new Map(view.machines.map((machine) => [machine.id, machine.name]))
      for (const link of view.links) {
        const name = named.get(link.id)
        // A link whose machine is not in the list is one this window can say
        // nothing about — forgotten while connected, or the two halves of the
        // view disagree. A row that cannot be named is not a row;
        // `machines-bridge.ts` takes the same line about the same gap.
        if (name === undefined || name === '') continue
        rest.push({ id: link.id, name, reach: reachOf(link), open: link.copilot?.open === true })
      }
    }
    // The servers, last, and never pressable — see `CopilotReach['server']`.
    // Listed because the switch being silent about a machine he had signed in to
    // is what he was looking at when he said he could not tell whether it was
    // connected.
    for (const server of servers) {
      rest.push({ id: `server ${server.id}`, name: server.name, reach: 'server', open: false })
    }
    return [here, ...rest]
  }, [view, servers])
}
