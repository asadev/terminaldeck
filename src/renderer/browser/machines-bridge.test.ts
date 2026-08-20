import { describe, expect, it } from 'vitest'
import {
  asDevPorts,
  destinationFor,
  differentPortNote,
  loopbackPort,
  lostMachine,
  machineChoices,
  moveFor,
  reachedAddress,
  readReach,
  resolveMachinesApi,
  servedBy,
  THIS_MACHINE,
  type MachineChoice,
  type ReachOpened,
} from './machines-bridge'
import type { MachinesView } from '../machines/types'

/**
 * The browser's half of *"I should be able to type and reach the devices which
 * are not here on this device"*.
 *
 * Everything the picker does that a person can see is in these functions,
 * deliberately: this project's test run has no DOM, so a rule that lived inside
 * a click handler would be a rule nothing could hold. What is pinned here is the
 * behaviour somebody would notice going away — `localhost` moving to the chosen
 * machine, `example.com` staying where it is, a refusal arriving as a sentence,
 * and a machine that cannot be reached keeping its row and its reason.
 */

function view(over: Partial<MachinesView['links'][number]> = {}): MachinesView {
  return {
    machines: [
      {
        id: 'mach-1',
        name: 'office-pc',
        hostId: 'HOST',
        fingerprint: 'AAAA-BBBB',
        platform: 'win32',
        pairedAt: 0,
        lastConnectedAt: null,
      },
    ],
    links: [
      {
        id: 'mach-1',
        state: 'online',
        reason: null,
        sessions: [],
        folders: null,
        capabilities: ['create', 'localhost'],
        ports: [
          { port: 5173, process: 'node', guessed: false },
          { port: 8080, process: '', guessed: true },
        ],
        copilot: null,
        hostPlatform: 'win32',
        retryAt: null,
        ...over,
      },
    ],
    blocked: null,
  }
}

describe('the machines the picker offers', () => {
  it('offers a connected machine that shares its ports, and what it is serving', () => {
    const [machine] = machineChoices(view())
    expect(machine.name).toBe('office-pc')
    expect(machine.noun).toBe('PC')
    expect(machine.refusal).toBeNull()
    expect(machine.ports.map((port) => port.port)).toEqual([5173, 8080])
  })

  it('keeps a machine that has gone offline, and says so under its row', () => {
    // Dropped, this would simply be a computer missing from a menu — which is
    // the state somebody goes looking for a machine in.
    const [machine] = machineChoices(view({ state: 'offline' }))
    expect(machine.refusal).toBe('This desktop is not connected to office-pc right now.')
  })

  it('names the machine in every refusal, because the sentence is read twice', () => {
    // Once under the row in the picker, and once in the notice band when a
    // machine that was chosen goes away underneath somebody. A sentence that
    // only worked under its own row would be a mystery in the band.
    for (const link of [
      { state: 'connecting' as const },
      { state: 'awaiting-approval' as const },
      { state: 'error' as const, reason: null },
    ]) {
      const [machine] = machineChoices(view(link))
      expect(machine.refusal).toContain('office-pc')
    }
  })

  it('prefers the far machine’s own words when it said why it failed', () => {
    const [machine] = machineChoices(view({ state: 'error', reason: 'The relay refused the credential.' }))
    expect(machine.refusal).toBe('The relay refused the credential.')
  })

  /**
   * The fifth door, seen from the guest's side.
   *
   * `localhostAllowed` in `src/main/remote/server.ts` decides this on the far
   * machine: the port list and every tunnel are for a device of its owner's own,
   * and a guest gets neither — because a port cannot be attributed to a folder,
   * so a folder grant has nothing to check it against. A guest never hears the
   * capability at all, which is what arrives here as its absence.
   *
   * The window's job is to say that in a sentence rather than to draw a picker
   * entry that refuses on every press.
   */
  it('refuses a machine that does not advertise localhost, and says both reasons', () => {
    const [machine] = machineChoices(view({ capabilities: ['create'] }))
    expect(machine.refusal).toContain('office-pc is not sharing what it is serving')
    expect(machine.refusal).toContain('older version')
    expect(machine.refusal).toContain('guest')
  })

  it('never lists this machine, which has no row to be wrong about', () => {
    expect(machineChoices({ machines: [], links: [], blocked: null })).toEqual([])
  })
})

describe('the far machine’s ports, in the start page’s shape', () => {
  it('marks none of them as ours, because the far end already removed its own', () => {
    // `reserved` in `src/main/remote/tunnel.ts` is fed from `own-ports.ts`, so
    // nothing the far machine sends is a listener belonging to the app running
    // over there. The fold that hides this app's own ports is therefore empty
    // and never drawn for a remote machine.
    expect(asDevPorts([{ port: 3000, process: 'node', guessed: false }])).toEqual([
      { port: 3000, process: 'node', guessed: false, ours: false },
    ])
  })

  it('puts the ports nobody could name last, exactly as the local scan does', () => {
    const sorted = asDevPorts([
      { port: 9000, process: '', guessed: true },
      { port: 5173, process: 'node', guessed: false },
      { port: 3000, process: 'node', guessed: false },
    ])
    expect(sorted.map((port) => port.port)).toEqual([3000, 5173, 9000])
  })
})

describe('which machine an address is for', () => {
  it('sends localhost to the chosen machine', () => {
    expect(destinationFor('mach-1', 'http://localhost:3000/')).toEqual({
      kind: 'there',
      machineId: 'mach-1',
      port: 3000,
      url: 'http://localhost:3000/',
    })
  })

  it('leaves every other address exactly where it was', () => {
    // The rule the picker actually implements: choosing a machine changes what
    // `localhost` means and nothing else. `example.com` is the same site from
    // either computer, so tunnelling it would cost the page its real origin to
    // solve a problem nobody has.
    expect(destinationFor('mach-1', 'https://example.com/docs')).toEqual({
      kind: 'here',
      url: 'https://example.com/docs',
    })
  })

  it('sends nothing anywhere while the picker says this machine', () => {
    expect(destinationFor(THIS_MACHINE, 'http://localhost:3000/')).toEqual({
      kind: 'here',
      url: 'http://localhost:3000/',
    })
  })

  it('knows the four spellings of this computer, and no others', () => {
    expect(loopbackPort('http://localhost:5173/')).toBe(5173)
    expect(loopbackPort('http://127.0.0.1:8080/')).toBe(8080)
    expect(loopbackPort('http://[::1]:4000/')).toBe(4000)
    expect(loopbackPort('http://0.0.0.0:9000/')).toBe(9000)
    expect(loopbackPort('http://localhost/')).toBe(80)
    expect(loopbackPort('https://localhost/')).toBe(443)
    expect(loopbackPort('https://example.com/')).toBeNull()
    expect(loopbackPort('about:blank')).toBeNull()
    expect(loopbackPort('nonsense')).toBeNull()
  })

  it('leaves a named localhost host alone, because the tunnel cannot carry it', () => {
    // Chromium resolves `app.localhost` to the loopback, but a byte pipe sends
    // `Host: 127.0.0.1:<port>` — a server routing by virtual host would answer
    // with the wrong site. A page that loads the wrong thing is worse than one
    // that loads nothing.
    expect(loopbackPort('http://app.localhost:3000/')).toBeNull()
  })
})

describe('the address that comes back', () => {
  it('keeps the path, the query and the fragment that were typed', () => {
    expect(
      reachedAddress('http://localhost:3000/orders?page=2#top', 'http://127.0.0.1:53412/'),
    ).toBe('http://127.0.0.1:53412/orders?page=2#top')
  })

  it('opens the front page when that is what was asked for', () => {
    expect(reachedAddress('http://localhost:3000', 'http://127.0.0.1:3000/')).toBe(
      'http://127.0.0.1:3000/',
    )
  })

  it('falls back to the tunnel’s own address rather than losing the navigation', () => {
    expect(reachedAddress('not a url', 'http://127.0.0.1:3000/')).toBe('http://127.0.0.1:3000/')
  })
})

describe('reading the answer to a reach', () => {
  it('takes the URL, the two ports and whether they match', () => {
    expect(
      readReach({ ok: true, url: 'http://127.0.0.1:3000/', port: 3000, localPort: 3000, sameNumber: true }),
    ).toEqual({ ok: true, url: 'http://127.0.0.1:3000/', port: 3000, localPort: 3000, sameNumber: true })
  })

  it('carries a refusal through as the sentence it was written as', () => {
    // The whole instruction for this feature: a refusal is a sentence somebody
    // reads, not a false to be swallowed.
    expect(readReach({ ok: false, message: 'That machine is not connected right now.' })).toEqual({
      ok: false,
      message: 'That machine is not connected right now.',
    })
  })

  it('turns anything unreadable into a sentence rather than a silence', () => {
    expect(readReach(null).ok).toBe(false)
    expect(readReach(undefined).ok).toBe(false)
    expect(readReach({ ok: true }).ok).toBe(false)
    expect(readReach({ ok: false }).ok).toBe(false)
    for (const value of [null, undefined, { ok: true }, { ok: false }, 7]) {
      const answer = readReach(value)
      expect(answer.ok === false && answer.message.length > 0).toBe(true)
    }
  })

  it('reads a missing sameNumber as “they may differ”, so the window still says so', () => {
    // An older main process sends no such field. The answer that makes the
    // window speak is the safe one; the answer that makes it stay quiet is a
    // promise it has not been given.
    const answer = readReach({ ok: true, url: 'http://127.0.0.1:1/', port: 3000, localPort: 1 })
    expect(answer.ok === true && answer.sameNumber).toBe(false)
  })
})

describe('the badge that names where a page came from', () => {
  const opened = [
    { machineId: 'mach-1', machineName: 'office-pc', port: 3000, localPort: 53412, sameNumber: false },
  ]

  it('reads the machine back off the address, so a link inside the site keeps it', () => {
    expect(servedBy('http://127.0.0.1:53412/orders', opened)?.machineName).toBe('office-pc')
  })

  it('says nothing about a page that is genuinely on this machine', () => {
    expect(servedBy('http://localhost:3000/', opened)).toBeNull()
    expect(servedBy('https://example.com/', opened)).toBeNull()
    expect(servedBy('', opened)).toBeNull()
  })
})

describe('the caveat when the port numbers could not match', () => {
  const opened: ReachOpened = {
    ok: true,
    url: 'http://127.0.0.1:53412/',
    port: 3000,
    localPort: 53412,
    sameNumber: false,
  }

  it('says which number is which, and what will go wrong because of it', () => {
    const note = differentPortNote(opened, 'office-pc')
    expect(note).toContain('3000')
    expect(note).toContain('53412')
    expect(note).toContain('office-pc')
  })

  it('says nothing at all when the number was kept', () => {
    expect(differentPortNote({ ...opened, localPort: 3000, sameNumber: true }, 'office-pc')).toBe('')
  })
})

describe('the bridge this panel needs', () => {
  const whole = {
    listMachines: async () => null,
    onMachinesState: () => () => undefined,
    refreshMachinePorts: async () => true,
    reachOnMachine: async () => null,
  }

  it('resolves when all four channels are there', () => {
    expect(resolveMachinesApi(whole)).not.toBeNull()
  })

  it('is null on a preload that predates remote localhost', () => {
    // 0.4.0 shipped `machines:reach` in the main process with nothing in the
    // renderer calling it, so a window running against an older preload is a
    // thing that exists on somebody's disk. The picker is absent then, never
    // drawn and refusing.
    const { reachOnMachine: _dropped, ...older } = whole
    expect(resolveMachinesApi(older)).toBeNull()
  })

  it('asks for only what it calls, not for the settings panel’s eighteen methods', () => {
    // `MachinesBridge` in `renderer/machines/types.ts` resolves to null without
    // `renameMachine`, which is right for a screen that renames machines and
    // wrong here: a preload missing it would cost the browser its port list for
    // no reason at all.
    expect(resolveMachinesApi({ ...whole, renameMachine: undefined })).not.toBeNull()
  })

  it('is null when there is no bridge at all', () => {
    expect(resolveMachinesApi(null)).toBeNull()
    expect(resolveMachinesApi(7)).toBeNull()
  })
})

/**
 * What happens when the machine somebody was typing at goes away.
 *
 * Watched on a real pair of desktops: revoking the guest over there left the
 * picker still naming it, every localhost address refusing, and a caveat about
 * one of its ports sitting above a tab that had stopped answering. The rule is
 * here so that a test can hold it — the effect that calls it is in a panel, and
 * this project's test run has no DOM.
 */
describe('when the chosen machine goes', () => {
  const good: MachineChoice = {
    kind: 'device',
    id: 'mach-1',
    name: 'office-pc',
    noun: 'PC',
    ports: [],
    refusal: null,
  }

  it('leaves a good selection alone', () => {
    expect(lostMachine([good], 'mach-1')).toBeNull()
  })

  it('leaves this machine alone, which cannot go anywhere', () => {
    expect(lostMachine([], THIS_MACHINE)).toBeNull()
    expect(lostMachine([good], THIS_MACHINE)).toBeNull()
  })

  it('gives the machine\u2019s own reason, and says what happens next', () => {
    const gone: MachineChoice = { ...good, refusal: 'That machine closed the connection.' }
    expect(lostMachine([gone], 'mach-1')).toBe(
      'That machine closed the connection. Addresses now open on this machine.',
    )
  })

  it('still says something when the machine has left the list entirely', () => {
    // Forgotten on this side, or revoked and dropped. There is no row left to
    // borrow a sentence from, and silence would be a picker resetting itself
    // under somebody's hand.
    expect(lostMachine([], 'mach-1')).toBe(
      'That machine is no longer paired with this one. Addresses now open on this machine.',
    )
  })
})

/**
 * Moving the page that is open, rather than only the next one typed.
 *
 * > *"if I move it to this machine, it's keeping on the same browser, same
 * > machine. It's not moving to this machine. Same link should be again tried on
 * > the new machine… or it should be unsuccessful here also, because we always
 * > need a truth."*
 *
 * The refusal case is asserted as loudly as the success ones. A picker that
 * silently keeps a machine's name over a page that never went there is the
 * untruth this function exists to prevent, and it is the failure that would
 * survive every render test.
 */
describe('moveFor — the page follows the picker, or the picker goes back', () => {
  /** One tunnel: the PC's 3000 is reachable on this machine's 3001. */
  const opened = [
    {
      machineId: 'm-desktop',
      machineName: 'DESKTOP',
      port: 3000,
      localPort: 3001,
      sameNumber: false,
    },
  ]

  it('sends a tunnelled page home on its ORIGIN port, keeping the path', () => {
    expect(moveFor(THIS_MACHINE, 'http://localhost:3001/orders?page=2', opened)).toEqual({
      kind: 'here',
      // 3000, not the 3001 in the address bar. The tunnel had to pick a
      // different local number because this Mac was already using 3000 — asking
      // this machine for 3001 would open a different service entirely.
      url: 'http://localhost:3000/orders?page=2',
    })
  })

  it('sends a local page to the far machine on the port it is really on', () => {
    expect(moveFor('m-desktop', 'http://localhost:5173/app#top', [])).toEqual({
      kind: 'there',
      machineId: 'm-desktop',
      port: 5173,
      url: 'http://localhost:5173/app#top',
    })
  })

  it('does nothing when the page is already there', () => {
    expect(moveFor('m-desktop', 'http://localhost:3001/orders', opened)).toEqual({ kind: 'already' })
    expect(moveFor(THIS_MACHINE, 'http://localhost:5173/', [])).toEqual({ kind: 'already' })
  })

  it('refuses a page that belongs to nobody in this room, and says where it is', () => {
    // Stripe's website is not on a computer here. There is nothing to move, and
    // the picker has to go back rather than claim it moved.
    expect(moveFor('m-desktop', 'https://dashboard.stripe.com/payments', opened)).toEqual({
      kind: 'refused',
      at: THIS_MACHINE,
    })
    // Switching *back* to this computer is not a refusal, because a public page
    // is already being fetched by this computer's own Chromium. There is nothing
    // to move and nothing to correct, which is a different answer from "that
    // cannot be done" and has to stay one.
    expect(moveFor(THIS_MACHINE, 'https://example.com/', opened)).toEqual({ kind: 'already' })
  })

  it('refuses a start page rather than opening a machine at nothing', () => {
    expect(moveFor('m-desktop', '', opened)).toEqual({ kind: 'refused', at: THIS_MACHINE })
  })
})
