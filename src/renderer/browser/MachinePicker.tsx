import { useRef, useState } from 'react'
import { AnchoredPopup } from './AnchoredPopup'
import { THIS_MACHINE, type MachineChoice } from './machines-bridge'
import type { Box } from './popup-anchor'

interface Props {
  /** Every machine this desktop is paired to, refusals included. */
  machines: readonly MachineChoice[]
  /**
   * What to call the computer this window is on — its own name, normally.
   *
   * Handed in rather than composed here, because the same string has to appear
   * on the chip, in the first row of the menu and on the mark inside the address
   * field, and three components deciding it separately is how one bar came to
   * carry three different phrases for three different computers. `hereName` in
   * `machines/types.ts` is where it is decided; see the note there.
   */
  here: string
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
 * Because a machine that was there this morning and is not now would otherwise
 * simply be missing from a menu, and somebody would go looking for a computer.
 * The row is disabled — never selectable, never a click that does nothing — and
 * carries its state at the end of it, in the two or three words the Machines
 * panel uses for the same state. Not a sentence: this menu printed three lines
 * under a greyed row until tonight, explaining a refusal that has since been
 * fixed rather than reworded — see `grantedPorts` in
 * `src/main/remote/server.ts`.
 *
 * ## Why it is absent rather than empty
 *
 * With no machine paired there is nothing to choose between, so the control is
 * not drawn and the browser is exactly the browser it was. The panel decides
 * that — this component is only ever mounted with somewhere to go.
 */
export function MachinePicker({ machines, here, selected, onSelect }: Props) {
  const buttonRef = useRef<HTMLButtonElement | null>(null)
  const [anchor, setAnchor] = useState<Box | null>(null)

  const current = machines.find((machine) => machine.id === selected) ?? null
  /*
   * This computer's own name, exactly as every other row carries its own.
   *
   * It read "This machine" until 2026-08-21, and that was the whole complaint:
   * with a machine chosen, the bar said "Office PC" here and "This machine" a
   * centimetre away in the address field, and the menu below said "This machine"
   * again about a third computer — *"I don't know what to trust."* A name is
   * resolvable by reading it; a phrase meaning "wherever you are" is not.
   */
  const label = current === null ? here : current.name

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
        /*
         * The menu's own heading, and nothing more.
         *
         * It used to be two sentences of explanation — *"localhost in the
         * address bar means Office PC. Its ports are opened here, in this
         * window."* — on a bar where he had just had every other hover cut to
         * its name: *"when I hover, it should show the title, like shade,
         * inspect, record. Instead of this line, show only the name."* Four
         * words say which question this control answers, and the person who
         * needs the rest opens it and reads the heading over the list.
         */
        title={`Open localhost on ${label}`}
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
                  {/* The same name the chip above is wearing, and the same one
                      the rows below wear for their machines. One vocabulary. */}
                  <span className="bw-menu-machine">{here}</span>
                </button>
              </li>

              {machines.map((machine) => (
                <li
                  key={machine.id}
                  className="bw-menu-row"
                  /* On the row rather than on the button, because Chromium does
                     not raise a tooltip over a disabled control — and a
                     disabled row is the only kind that has anything to add. */
                  title={machine.detail ?? undefined}
                >
                  <button
                    type="button"
                    className="bw-menu-choice"
                    aria-pressed={machine.id === selected}
                    data-on={machine.id === selected || undefined}
                    disabled={machine.unreachable !== null}
                    onClick={() => {
                      onSelect(machine.id)
                      setAnchor(null)
                    }}
                  >
                    <span className="bw-menu-tick" aria-hidden="true">
                      {machine.id === selected ? '✓' : ''}
                    </span>
                    <span className="bw-menu-machine">{machine.name}</span>
                    {/* One slot at the end of the row, and only ever one thing
                        in it: what it is offering, or why it is not offering
                        anything. Both are the same kind of fact about the same
                        machine and neither is a sentence. */}
                    {machine.unreachable !== null ? (
                      <span className="bw-menu-count">{machine.unreachable}</span>
                    ) : (
                      machine.ports.length > 0 && (
                        <span className="bw-menu-count">
                          {machine.ports.length} {machine.ports.length === 1 ? 'port' : 'ports'}
                        </span>
                      )
                    )}
                  </button>
                </li>
              ))}
            </ul>

            {/*
              There was a note here, and deleting it fixed two things at once.

              It read *"Only localhost moves. Every other address opens the same
              way from either machine."* — a two-sentence statement standing at
              the bottom of a menu, which is the shape of thing he spent this
              recording deleting: *"I don't want any kind of long descriptions
              anywhere."*

              And its second sentence was not true. `example.com` resolves the
              same from either machine; a name on the other machine's LAN, its
              VPN or its hosts file does not, and that is precisely the case a
              machine switcher exists for. The heading three lines up — **Open
              localhost on** — states the scope in three words and states it
              accurately, which is all the note was for. What happens when a page
              cannot move is said by the page not moving, and by the one line the
              panel puts in the notice bar at the moment it refuses.
            */}
          </div>
        </AnchoredPopup>
      )}
    </>
  )
}
