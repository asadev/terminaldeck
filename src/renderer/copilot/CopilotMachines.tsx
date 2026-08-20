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
 * ## Every row can be pressed, including the ones that will not answer
 *
 * Asad, looking at this switch on 2026-08-20: *"here icon not still choose the
 * local connected server, by the way, I think. Maybe server is not connected, I
 * don't know."* Two things are in that sentence and both matter. He could not
 * **choose** the machine, and he could not tell whether it was **connected**.
 *
 * A round of this answered him by drawing the unready machines greyed out with
 * the reason on hover, which meets a man saying he cannot pick a machine by
 * removing the pick and writing him a sentence about it. So there is no
 * `disabled` here any more. Press any row and the page goes to that machine;
 * `RemoteCopilot` is what reports what it found — offline, a guest, no run yet,
 * or the conversation. The state belongs where somebody is looking after the
 * press, not in a tooltip on a button that refuses it.
 *
 * The row still *shows* its condition without being hovered: `data-reach` dims
 * the ones that are not ready, exactly as the rail dims a machine that is
 * asleep. A mark, not a sentence — *"don't put any single statement in
 * anywhere… Let the smart people use it."*
 *
 * ## No servers on it
 *
 * A server has no copilot to switch to; {@link useCopilotMachines} carries the
 * measurement. Every server row this switch ever had was a disabled row, which
 * is the dead control rather than the truth.
 */

interface Props {
  machines: readonly CopilotMachine[]
  /** Empty is this computer. */
  chosen: string
  onChoose(machineId: string): void
}

export function CopilotMachines({ machines, chosen, onChoose }: Props) {
  if (machines.length < 2) return null
  return (
    <div className="cp-machines" role="radiogroup" aria-label="Which machine's copilot">
      {machines.map((machine) => (
        <button
          key={machine.id || 'here'}
          type="button"
          role="radio"
          className="cp-machine"
          aria-checked={machine.id === chosen}
          data-chosen={machine.id === chosen || undefined}
          data-reach={machine.reach}
          title={`${machine.name} — its copilot`}
          onClick={() => onChoose(machine.id)}
        >
          {machine.name}
        </button>
      ))}
    </div>
  )
}
