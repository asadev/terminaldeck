import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { NO_COPILOT, PairingCode, hostControls, linkedLine } from './ServerHost'
import { asHostOffer } from './types'
import type { HostOffer } from './types'

/**
 * The section that puts a host on a server, tested where it would look fine on
 * screen and be wrong.
 *
 * One rule shapes all of it, and it is the one that has gone wrong before:
 * **never a control that looks like it works and does not.** So every test here
 * is about a button that must not be drawn — on a machine that cannot take a
 * host, on a build that carries no package, on a host this computer is already
 * linked to, and beside a pairing code, which nothing on this screen can spend.
 *
 * That last one is not hypothetical. The button that used to sit there said
 * **Link it to this computer**, the code beside it had expired during the
 * install that printed it, and pressing it answered *"No machine is showing that
 * code. Check the digits"* to somebody who had never typed a digit.
 */

const NOW_OFFER = {
  host: {
    command: '/home/me/.local/bin/terminaldeck',
    version: '0.9.1',
    running: 'yes',
    status: 'Terminal Deck host 0.9.1 — running, idle',
    unit: 'active',
    linger: true,
    data: true,
    dataDir: '/home/me/.local/share/terminaldeck',
  },
  room: { os: 'linux', arch: 'x86_64', node: 'v22.23.2', npm: '/usr/bin/npm', systemdUser: true },
  canInstall: false,
  why: null,
  line: 'The host 0.9.1 is here and running.',
  reach: 'It starts with this server and keeps running when you log out.',
  consequence: 'This puts the host into your own home folder.',
  removes: { keepData: 'What it stored stays.', withData: 'It all goes.' },
  canLink: true,
  linkedAs: null,
  state: { serverId: 's1', step: 'idle', line: '', detail: '', done: [], code: null, weInstalled: false },
}

function offer(over: Record<string, unknown> = {}): HostOffer {
  const read = asHostOffer({ ...NOW_OFFER, ...over })
  if (read === null) throw new Error('fixture did not parse')
  return read
}

/** A server with nothing on it, which is where the Install button lives. */
function empty(over: Record<string, unknown> = {}): HostOffer {
  return offer({
    host: { ...NOW_OFFER.host, command: '', version: '', running: 'unknown', status: '', unit: '' },
    canInstall: true,
    why: null,
    ...over,
  })
}

describe('which controls are drawn', () => {
  it('offers Install on a bare server that can take one', () => {
    const controls = hostControls(empty(), false)
    expect(controls.install).toBe(true)
    expect(controls.pair).toBe(false)
    expect(controls.remove).toBe(false)
  })

  /*
   * The one that matters. A machine with no compiler cannot take a host, and
   * what it gets is the reason and no button — never a button that would upload
   * a package and then print the installer's refusal.
   */
  it('draws no Install at all when the server cannot take one, and says why', () => {
    const controls = hostControls(
      empty({ canInstall: false, why: 'This server is missing make, gcc, g++.' }),
      false,
    )
    expect(controls.install).toBe(false)
    expect(controls.why).toContain('make, gcc, g++')
  })

  it('draws no Install when this build carries no package', () => {
    const controls = hostControls(
      empty({ canInstall: false, why: 'This copy of the app does not carry the host package.' }),
      false,
    )
    expect(controls.install).toBe(false)
    expect(controls.why).toContain('does not carry the host package')
  })

  it('offers Pair and Remove once there is one, and says whether it survives a logout', () => {
    const controls = hostControls(offer(), false)
    expect(controls.pair).toBe(true)
    expect(controls.remove).toBe(true)
    expect(controls.install).toBe(false)
    expect(controls.reach).toContain('keeps running when you log out')
  })

  /*
   * An install ends linked, so the ordinary path never draws this. It is here
   * for the host somebody put on that server another way — and the alternative
   * to having it is telling that person to uninstall and install again.
   */
  it('offers Link this computer for a host it is not linked to', () => {
    const controls = hostControls(offer(), false)
    expect(controls.link).toBe(true)
    expect(controls.linkedAs).toBeNull()
  })

  /*
   * The pair that must never both be true. A panel that offered to link a
   * machine it had just said it was linked to would be describing two different
   * worlds one line apart.
   */
  /*
   * A build with no Machines list answers a Link press by showing a pairing
   * code, so a button promising to link would be promising what it cannot do.
   */
  it('draws no Link button on a build that could only show a code', () => {
    expect(hostControls(offer({ canLink: false }), false).link).toBe(false)
  })

  it('says it is already linked instead of offering to link again', () => {
    const controls = hostControls(offer({ linkedAs: 'office-pc' }), false)
    expect(controls.link).toBe(false)
    expect(controls.linkedAs).toBe('office-pc')
    expect(linkedLine('office-pc')).toContain('office-pc')
    // And the promise the whole change was asked for: after linking it is a
    // machine like any other.
    expect(linkedLine('office-pc')).toContain('any other machine')
  })

  /*
   * There is one terminal, so while it is in use the only control is the one
   * that stops what is using it. Anything else would take the terminal from the
   * run that is in the middle of an install on somebody's server.
   */
  it('offers nothing but Stop while the terminal is in use', () => {
    const controls = hostControls(offer(), true)
    expect(controls.stop).toBe(true)
    expect(controls.install || controls.pair || controls.remove || controls.link).toBe(false)
    expect(controls.why).toBeNull()
    expect(controls.reach).toBeNull()
    expect(controls.linkedAs).toBeNull()
  })
})

describe('the pairing code', () => {
  it('prints the code exactly as the host printed it', () => {
    const html = renderToStaticMarkup(<PairingCode code="904021" />)
    expect(html).toContain('904021')
    expect(html).toContain('Machines on another computer')
  })

  /*
   * The regression this whole change is about. The only thing this app could
   * spend a code on is the computer it is running on, and that one is linked by
   * installing — so a button here could only ever be the control that looks like
   * it works and does not. There must be no button of any wording beside a code.
   */
  it('draws no button at all beside a code', () => {
    const html = renderToStaticMarkup(<PairingCode code="904021" />)
    expect(html).not.toContain('<button')
    expect(html).not.toContain('Link it to this computer')
  })

  /*
   * For a phone this app has never met, the fingerprint is the only part of
   * pairing anybody can actually check — so the sentence sends the person to it
   * rather than answering it.
   */
  it('sends the person to the fingerprint rather than answering it', () => {
    const html = renderToStaticMarkup(<PairingCode code="904021" />)
    expect(html).toContain('fingerprint')
    expect(html).toContain('about a minute')
  })
})

describe('what a server cannot give a device', () => {
  /*
   * Said here rather than discovered on a phone: on the wire "this host has no
   * copilot" and "you were approved as a guest" arrive as the same absence.
   */
  it('says there is no copilot on a server', () => {
    expect(NO_COPILOT).toContain('no copilot')
    expect(NO_COPILOT).toContain('desktop app')
  })
})
