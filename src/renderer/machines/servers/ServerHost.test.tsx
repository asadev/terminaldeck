import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  ADDRESS_HOW,
  SERVER_COPILOT,
  PairingCode,
  ServerAddress,
  awayLine,
  hostControls,
  linkedLine,
  noAddressLine,
} from './ServerHost'
import { formatServerAddress } from '../../../shared/server-address'
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

/**
 * A real address, not a placeholder.
 *
 * Built by the shared formatter rather than typed out, so that a change to the
 * format shows up here as a changed fixture instead of as a screen displaying a
 * string no client would accept.
 */
const ADDRESS = formatServerAddress({
  url: 'wss://relay.terminaldeck.dev',
  hostId: 'A2B3C4D5E6F7G8H9JKLMNPQSTU',
  hostKey: Buffer.alloc(32, 7).toString('base64url'),
}) as string

const NOW_OFFER = {
  host: {
    command: '/home/me/.local/bin/terminaldeck',
    version: '0.9.1',
    running: 'yes',
    status: 'Terminal Deck host 0.9.1 — running, idle',
    address: ADDRESS,
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
  linkedButNotConnected: false,
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
    host: {
      ...NOW_OFFER.host,
      command: '',
      version: '',
      running: 'unknown',
      status: '',
      address: '',
      unit: '',
    },
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
   * The state that had no sentence and no button, and had both of the wrong
   * ones. Measured on his office PC: the host up two hours, on the relay, a
   * device of his approved in its own list — and zero channels open. The panel
   * said *"This computer is linked to it … sessions, folders and the terminal
   * work there the way they do for any other machine"*, which was false in every
   * clause, and offered nothing to press.
   */
  it('says nothing is reaching a host it has a row for, and offers the press', () => {
    const controls = hostControls(offer({ linkedAs: 'office-pc', linkedButNotConnected: true }), false)
    expect(controls.away).toBe(true)
    expect(controls.linkedAs).toBe('office-pc')
    // The button is back, because a row with nothing behind it is not "already
    // linked" and a fresh pairing is the one press that fixes it.
    expect(controls.link).toBe(true)
    const said = awayLine('office-pc')
    expect(said).toContain('office-pc')
    expect(said).toContain('nothing is reaching it')
    // Named, not described. The label on the button directly above it.
    expect(said).toContain('Link this computer')
    // And it must not be the other sentence, whose every clause is a claim
    // about a machine this one can talk to.
    expect(said).not.toContain('any other machine')
  })

  /*
   * And it stays quiet about a link that is working, which is the ordinary case:
   * a second sentence and a second button on every healthy panel would train
   * somebody to ignore both.
   */
  it('says nothing about reaching a host that is reached', () => {
    const controls = hostControls(offer({ linkedAs: 'office-pc' }), false)
    expect(controls.away).toBe(false)
    expect(controls.link).toBe(false)
  })

  /*
   * A main process older than the field says nothing about it, and an absent
   * field must not put a warning and a second button on a healthy panel. This is
   * the one field here read in the quiet direction, and this is the claim.
   */
  it('reads a missing answer as connected rather than as trouble', () => {
    const read = asHostOffer({ ...NOW_OFFER, linkedAs: 'office-pc', linkedButNotConnected: undefined })
    expect(read?.linkedButNotConnected).toBe(false)
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

describe('the address for a phone', () => {
  /*
   * The screen that was missing, and the reason the whole feature was
   * unreachable in the shipped build. `enroll` and its whole wire were there;
   * nothing printed the one string a phone that has never met this machine can
   * act on, because a host id and a fingerprint are both one-way hashes.
   */
  it('shows the address, in full, without anything to press first', () => {
    const html = renderToStaticMarkup(<ServerAddress address={ADDRESS} running="yes" />)
    expect(html).toContain(ADDRESS)
    expect(html).toContain('Address for a phone')
  })

  it('says what to do with it, in the steps of the app rather than as a concept', () => {
    const html = renderToStaticMarkup(<ServerAddress address={ADDRESS} running="yes" />)
    expect(html).toContain('Add a server')
    expect(html).toContain('sign in')
  })

  it('says it is not a secret, because it will be treated as one otherwise', () => {
    const html = renderToStaticMarkup(<ServerAddress address={ADDRESS} running="yes" />)
    expect(html).toContain('not a secret')
    expect(html).toContain('the login is the gate')
  })

  it('offers exactly one control, and it copies', () => {
    const html = renderToStaticMarkup(<ServerAddress address={ADDRESS} running="yes" />)
    expect(html.match(/<button/g)?.length).toBe(1)
    expect(html).toContain('Copy')
  })

  /*
   * Never a blank where a control would be. A missing address on a panel that
   * otherwise looks finished reads as this app failing rather than as that
   * machine having nothing to say — and the three states have three remedies.
   */
  it('draws no address and no button when that server has none, and says why', () => {
    const html = renderToStaticMarkup(<ServerAddress address="" running="yes" />)
    expect(html).not.toContain('<button')
    expect(html).not.toContain('srv1.')
    expect(html).toContain('not on a relay')
  })

  it('names the remedy that matches the state the host is in', () => {
    expect(noAddressLine('no')).toContain('not running')
    expect(noAddressLine('unknown')).toContain('did not say')
    // The one that catches a host older than this feature, which prints no
    // address block at all and would otherwise look like a relay problem.
    expect(noAddressLine('yes')).toContain('upgrading')
  })

  it('keeps the instructions with the address rather than in this test', () => {
    expect(ADDRESS_HOW).toContain('Add a server')
  })
})

describe('what the copilot on a server gives a device, and what it withholds', () => {
  /*
   * The truth after `headless/host.ts` began running a full copilot and
   * advertising it to the owner's own devices: one of your own devices does get
   * the copilot on a server now, driven from the app. Said in this pane's words
   * because on the wire a guest's withheld copilot and a host that has none
   * arrive as the same absence.
   */
  it('says an owner device gets the copilot, and a guest does not', () => {
    expect(SERVER_COPILOT).toContain('copilot')
    // The two facts that flipped and the one that did not: your own device gets
    // it, driven from here; a guest still never does.
    expect(SERVER_COPILOT).toMatch(/your own/)
    expect(SERVER_COPILOT).toMatch(/guest never gets it/)
    // And it must no longer claim the old falsehood that a server has none.
    expect(SERVER_COPILOT).not.toContain('no copilot on a server')
  })
})
