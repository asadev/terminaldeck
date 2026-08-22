import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ServerDrivesWindows } from './ServerAdvanced'
import type { Server } from './types'

/**
 * The one control on a server's page that hands something *out* rather than
 * reaching in.
 *
 * Everything else under Advanced lets this machine act on that one. This lets an
 * agent on that machine act on the browser here — and since T30 it is the
 * **off**-switch: a server the person added drives by default, because the
 * connection is the authorization. What is worth pinning: that it draws what the
 * main process resolved rather than a default of its own, that it is absent
 * rather than dead when the press would land nowhere, and that its words name
 * what is actually handed out — opening windows here, and the ones the person
 * attaches.
 */

const SERVER: Server = { id: 's1', name: 'Office PC', address: 'example.com', username: 'admin' }

function html(server: Server, onChange?: (allowed: boolean) => void): string {
  return renderToStaticMarkup(
    <ServerDrivesWindows
      server={server}
      disabled={false}
      {...(onChange === undefined ? {} : { onChange })}
    />,
  )
}

describe('letting a server’s terminals act on browser windows here', () => {
  it('draws the resolved answer, and ticked means the default the person was told about', () => {
    // The main process resolves the default — a server the person added drives
    // unless they unticked it — and always sends the boolean, so a ticked box
    // here is a stored fact rather than this side guessing a permission.
    expect(html({ ...SERVER, drivesWindows: true }, () => {})).toContain('checked=""')
    expect(html({ ...SERVER, drivesWindows: false }, () => {})).not.toContain('checked=""')
  })

  it('draws unticked when an older main process never said', () => {
    /*
     * `drivesWindows` absent from the wire means a build older than the field.
     * Rendered unticked, not merely defaulted unticked in a store somewhere:
     * the one side that may not invent the open default is the one that did
     * not resolve it.
     */
    const drawn = html(SERVER, () => {})
    expect(drawn).toContain('browser windows here')
    expect(drawn).not.toContain('checked=""')
  })

  it('is not drawn at all when the press would land nowhere', () => {
    // The channel is off `BRIDGE_METHODS` — that list is an all-or-nothing gate
    // and a switch added this round must not be able to blank a screen that
    // works — so the control is absent rather than dead when it is missing.
    expect(html(SERVER)).toBe('')
  })

  it('names the feature and the default, and does not overstate the reach', () => {
    const drawn = html({ ...SERVER, drivesWindows: true }, () => {})
    // The heading names what is handed out — the audit found the old words
    // never mentioned opening or driving a browser at all.
    expect(drawn).toContain('open and drive browser windows here')
    // The default is said in words, with the reason it is on.
    expect(drawn).toContain('On, because you added this server yourself')
    // The off direction is a sentence, because the switch is the off-switch.
    expect(drawn).toContain('Untick it')
    // What it hands out is bounded by the opening and the attaching.
    expect(drawn).toContain('you</em> attach')
    // And it names the one agent this can reach, rather than implying all three.
    expect(drawn).toContain('Claude Code')
    expect(drawn).toContain('Codex and Gemini')
  })

  it('does not go on saying "On" over a box somebody unticked', () => {
    /*
     * Both paragraphs used to be written for the default and printed whatever
     * the tick said. Walked in the packaged app on 2026-08-22 against a stored
     * server at `drivesWindows: false`: the screen read *"On, because you added
     * this server yourself"* over an empty box, and told the reader to *"Untick
     * it"* — a screen arguing with its own control, which is the same defect as
     * a control that does not do what it says, one layer up.
     *
     * Asserted in both directions and against each other's words, because the
     * failure this catches is not a missing sentence, it is the wrong one being
     * present.
     */
    const off = html({ ...SERVER, drivesWindows: false }, () => {})
    expect(off).toContain('Off, because you turned it off')
    expect(off).toContain('Tick it')
    expect(off).not.toContain('On, because you added this server yourself')
    expect(off).not.toContain('Untick it')

    const on = html({ ...SERVER, drivesWindows: true }, () => {})
    expect(on).not.toContain('Off, because you turned it off')
    // `Untick it` contains `Tick it`, so the on direction is checked by the
    // sentence that only the on copy has.
    expect(on).toContain('Untick it')
  })

  it('names the server, so two of them in a list are two switches', () => {
    expect(html(SERVER, () => {})).toContain('Office PC')
  })
})
