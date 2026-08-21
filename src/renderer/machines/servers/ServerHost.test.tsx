import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { NO_COPILOT, PairingCode, hostControls } from './ServerHost'
import { asHostOffer } from './types'
import type { HostOffer } from './types'

/**
 * The section that puts a host on a server, tested where it would look fine on
 * screen and be wrong.
 *
 * One rule shapes all of it, and it is the one that has gone wrong before:
 * **never a control that looks like it works and does not.** So every test here
 * is about a button that must not be drawn — on a machine that cannot take a
 * host, on a build that carries no package, and on a window whose preload has no
 * machine channels to redeem a pairing code with.
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
   * There is one terminal, so while it is in use the only control is the one
   * that stops what is using it. Anything else would take the terminal from the
   * run that is in the middle of an install on somebody's server.
   */
  it('offers nothing but Stop while the terminal is in use', () => {
    const controls = hostControls(offer(), true)
    expect(controls.stop).toBe(true)
    expect(controls.install || controls.pair || controls.remove).toBe(false)
    expect(controls.why).toBeNull()
    expect(controls.reach).toBeNull()
  })
})

describe('the pairing code', () => {
  it('prints the code exactly as the host printed it', () => {
    const html = renderToStaticMarkup(
      <PairingCode code="904021" linked={false} canLink onLink={() => undefined} />,
    )
    expect(html).toContain('904021')
    expect(html).toContain('Link it to this computer')
  })

  /*
   * A window whose preload has no machine channels cannot redeem a code, so it
   * draws no button — and says where the code goes instead. A greyed button
   * with nothing to say for itself is what §4.1 forbids.
   */
  it('draws no Link button when nothing here could redeem it', () => {
    const html = renderToStaticMarkup(
      <PairingCode code="904021" linked={false} canLink={false} onLink={() => undefined} />,
    )
    expect(html).not.toContain('Link it to this computer')
    expect(html).toContain('904021')
    expect(html).toContain('Machines on another computer')
  })

  /*
   * After the link, the person still has one thing to do, and it is the one
   * thing this app must not do for them.
   */
  it('sends the person to the fingerprint rather than answering it', () => {
    const html = renderToStaticMarkup(
      <PairingCode code="904021" linked canLink onLink={() => undefined} />,
    )
    expect(html).toContain('fingerprint')
    expect(html).not.toContain('Link it to this computer')
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
