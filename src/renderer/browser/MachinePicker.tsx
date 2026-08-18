import { useRef, useState } from 'react'
import { AnchoredPopup } from './AnchoredPopup'
import { THIS_MACHINE, type MachineChoice } from './machines-bridge'
import type { Box } from './popup-anchor'

interface Props {
  /** Every machine this desktop is paired to, refusals included. */
  machines: readonly MachineChoice[]
  /** `THIS_MACHINE`, or the id of one of the above. */
  selected: string
  onSelect(id: string): void
}

/**
 * Which machine the address bar is talking to.
 *
 * ## He asked for it in these words
 *
 *   > *"Maybe give a drop down next to somewhere here with the bar, to choose
 *   > which device we are talking to right now."*
 *
 * ## What it changes, and what it deliberately does not
 *
 * It changes **what `localhost` means** and nothing else. `example.com` is the
 * same site from either computer, so it is left alone — `destinationFor` in
 * `machines-bridge.ts` is that rule, in one function, tested. A picker that
 * silently pushed every address through a tunnel would cost every page its real
 * origin to solve a problem nobody has.
 *
 * The rest of the browser does not move. Same window, same tab strip, same
 * toolbar, same start page, same history:
 *
 *   > *"Shape of the application should not be changing for local and remote
 *   > devices."*
 *
 * ## Why a machine that cannot be reached still gets a row
 *
 * Because its sentence is the most useful thing this control can say. A machine
 * that was there this morning and is not now would otherwise simply be missing
 * from a menu, and somebody would go looking for a computer. The row is
 * disabled — never selectable, never a click that does nothing — and carries
 * the reason underneath it, which is either a thing to do (connect it, approve
 * this desktop over there) or a thing to know (it treats this desktop as a
 * guest, so it shares no ports at all).
 *
 * ## Why it is absent rather than empty
 *
 * With no machine paired there is nothing to choose between, so the control is
 * not drawn and the browser is exactly the browser it was. The panel decides
 * that — this component is only ever mounted with somewhere to go.
 */
export function MachinePicker({ machines, selected, onSelect }: Props) {
  const buttonRef = useRef<HTMLButtonElement | null>(null)
  const [anchor, setAnchor] = useState<Box | null>(null)

  const current = machines.find((machine) => machine.id === selected) ?? null
  const label = current === null ? 'This machine' : current.name

  /*
   * Measured at the moment of opening, exactly as the toolbar's own popups are.
   *
   * A rectangle kept in state and refreshed on resize is a popup pointing at
   * where a button used to be — this bar moves whenever the panel becomes half
   * of a split or a band appears above it.
   */
  const open = (): void => {
    const node = buttonRef.current
    if (node) {
      const box = node.getBoundingClientRect()
      setAnchor({ x: box.x, y: box.y, width: box.width, height: box.height })
    } else {
      // No layout to measure — a static render, or a test. The popup still has
      // to be reachable, so it opens against the origin and `anchorPopup` slides
      // it into the window from there.
      setAnchor({ x: 0, y: 0, width: 0, height: 0 })
    }
  }

  return (
    <>
      <button
        ref={buttonRef}
        type="button"
        className="bw-machine"
        aria-haspopup="menu"
        aria-expanded={anchor !== null}
        aria-label={`Addresses open on ${label}. Choose a machine.`}
        title={
          current === null
            ? 'localhost in the address bar means this machine. Choose another to reach its ports instead.'
            : `localhost in the address bar means ${current.name}. Its ports are opened here, in this window.`
        }
        data-on={current !== null || undefined}
        onClick={() => (anchor === null ? open() : setAnchor(null))}
      >
        {/*
          A display, not a globe or a cloud. Nothing here goes to the internet:
          this reaches one computer that belongs to the same person, and the
          sidebar names a machine with the same glyph — one idea, one shape.
        */}
        <svg
          width="12"
          height="12"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <rect x="3" y="4" width="18" height="12" rx="2" />
          <path d="M9 20h6M12 16v4" />
        </svg>
        <span className="bw-machine-name">{label}</span>
        <svg
          className="bw-machine-caret"
          width="10"
          height="10"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2.4"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d="M5 9l7 7 7-7" />
        </svg>
      </button>

      {anchor !== null && (
        <AnchoredPopup anchor={anchor} label="Machine for this address bar" onClose={() => setAnchor(null)}>
          <div className="bw-menu">
            <p className="bw-menu-title">Open localhost on</p>
            <ul className="bw-menu-list">
              <li className="bw-menu-row">
                <button
                  type="button"
                  className="bw-menu-choice"
                  aria-pressed={selected === THIS_MACHINE}
                  data-on={selected === THIS_MACHINE || undefined}
                  onClick={() => {
                    onSelect(THIS_MACHINE)
                    setAnchor(null)
                  }}
                >
                  <span className="bw-menu-tick" aria-hidden="true">
                    {selected === THIS_MACHINE ? '✓' : ''}
                  </span>
                  This machine
                </button>
              </li>

              {machines.map((machine) => (
                <li key={machine.id} className="bw-menu-row bw-menu-row-stacked">
                  <button
                    type="button"
                    className="bw-menu-choice"
                    aria-pressed={machine.id === selected}
                    data-on={machine.id === selected || undefined}
                    disabled={machine.refusal !== null}
                    onClick={() => {
                      onSelect(machine.id)
                      setAnchor(null)
                    }}
                  >
                    <span className="bw-menu-tick" aria-hidden="true">
                      {machine.id === selected ? '✓' : ''}
                    </span>
                    {machine.name}
                    {machine.refusal === null && machine.ports.length > 0 && (
                      <span className="bw-menu-count">
                        {machine.ports.length} {machine.ports.length === 1 ? 'port' : 'ports'}
                      </span>
                    )}
                  </button>
                  {/* Under the row it is about, not in a tooltip. A greyed row
                      whose reason is only revealed by hovering is the control
                      this app keeps deleting — and on a machine that has gone
                      offline mid-session this sentence is the whole message. */}
                  {machine.refusal !== null && <p className="bw-menu-note">{machine.refusal}</p>}
                </li>
              ))}
            </ul>

            <p className="bw-menu-note">
              Only localhost moves. Every other address opens the same way from either machine.
            </p>
          </div>
        </AnchoredPopup>
      )}
    </>
  )
}
