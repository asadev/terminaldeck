import type { CopilotMachine } from './useCopilotMachines'
import './copilot.css'

/**
 * The switch at the top of the copilot page: which machine's copilot is this.
 *
 * ## What was asked for
 *
 * Asad, 2026-08-20, having paired two computers to each other and found the
 * copilot page silent about which one it meant: *"the same switch we have for
 * sessions"*, at the top, so the copilot can be used against either machine.
 *
 * ## Why it is not drawn at all with one machine
 *
 * A switch with one position is not a switch, it is a label — and a label naming
 * the computer you are sitting at is a standing sentence that tells nobody
 * anything. The New Session dialog draws no Where step for a person with no
 * second computer; this draws no row of buttons for the same reason and at the
 * same moment. {@link useCopilotMachines} answers one entry for an unpaired
 * desktop, so the condition is `length < 2` and nothing else.
 *
 * ## Why a machine it cannot reach is drawn and disabled rather than dropped
 *
 * *"We always need a truth."* A paired machine that is offline, or one that
 * paired this device as a guest, is a machine he can see in the rail two inches
 * away; leaving it out of this row would be the picker quietly showing a subset,
 * which is the failure this project keeps finding. So every paired machine is
 * here, and the ones that cannot answer are disabled with the reason on hover.
 *
 * ## Why servers are on it, and why they cannot be pressed
 *
 * Asad, looking at this switch: *"here icon not still choose the local connected
 * server, by the way, I think. Maybe server is not connected, I don't know."*
 * The switch listed paired devices only, so a server he had signed into was not
 * on it at all — and the sentence says exactly what that costs: he could not
 * tell *not connected* from *not shown*, and had to guess about his own machine.
 *
 * They are drawn and not pressable, which is the same treatment an unreachable
 * device gets and for a harder reason: a server does not run this app, so there
 * is no copilot over there to switch to. The copilot that works on a server is
 * this one, and whether it may act is a grant that lives on that server's page
 * — `SERVERS-DESIGN.md` §6.2, in as many words: *"not in Settings, and not in
 * the copilot's window."* Building the grant here would have put the largest
 * permission in the product on the screen the design forbids it on.
 *
 * The reason is on hover and not on the page, deliberately, and that is his
 * standing rule rather than a judgement made here: *"don't put any single
 * statement in anywhere… We want simplicity. Let the smart people use it."* A
 * sentence under a row of buttons, explaining a state most people will never be
 * in, is exactly the thing being removed everywhere else this week.
 */

interface Props {
  machines: readonly CopilotMachine[]
  /** Empty is this computer. */
  chosen: string
  onChoose(machineId: string): void
}

/** Why a row cannot be pressed, for the hover label. Empty when it can. */
function why(machine: CopilotMachine): string {
  switch (machine.reach) {
    case 'ready':
      return ''
    case 'unreachable':
      return `${machine.name} is not connected.`
    case 'refused':
      // The remedy, not the mechanism. A person reading this has to *do*
      // something at the other keyboard, and "guest devices do not get the
      // copilot" tells them a rule without telling them the move.
      return `${machine.name} paired this computer as a guest. Pair it again as your own to use its copilot.`
    case 'server':
      // Also the remedy rather than the mechanism, and the move is on a
      // different page on purpose — `SERVERS-DESIGN.md` §6.2: the grant is asked
      // for on that server's own page, *"not in Settings, and not in the
      // copilot's window."*
      return `${machine.name} is a server. This copilot works on it — allow that on the server's page.`
  }
}

export function CopilotMachines({ machines, chosen, onChoose }: Props) {
  if (machines.length < 2) return null
  return (
    <div className="cp-machines" role="radiogroup" aria-label="Which machine's copilot">
      {machines.map((machine) => {
        const blocked = machine.reach !== 'ready'
        const label = why(machine)
        return (
          <button
            key={machine.id || 'here'}
            type="button"
            role="radio"
            className="cp-machine"
            aria-checked={machine.id === chosen}
            data-chosen={machine.id === chosen || undefined}
            disabled={blocked}
            title={label || `${machine.name} — its copilot`}
            onClick={() => onChoose(machine.id)}
          >
            {machine.name}
          </button>
        )
      })}
    </div>
  )
}
