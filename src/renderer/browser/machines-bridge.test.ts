import { describe, expect, it } from 'vitest'
import {
  asDevPorts,
  destinationFor,
  differentPortNote,
  inTheWay,
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
import { hereName, STATE_LABEL, type MachinesView } from '../machines/types'
import { ThisMachine } from '../platform'

/**
 * The browser's half of *"I should be able to type and reach the devices which
 * are not here on this device"*.
 *
 * Everything the picker does that a person can see is in these functions,
 * deliberately: this project's test run has no DOM, so a rule that lived inside
 * a click handler would be a rule nothing could hold. What is pinned here is the
 * behaviour somebody would notice going away — `localhost` moving to the chosen
 * machine, `example.com` staying where it is, a refusal arriving as a sentence,
 * and a machine that cannot be reached keeping its row and a two-word state
 * rather than the paragraph that used to sit under it.
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
        hostVersion: '',
        hostKind: null,
        retryAt: null,
        ...over,
      },
    ],
    here: '',
    blocked: null,
  }
}

describe('the machines the picker offers', () => {
  it('offers a connected machine that shares its ports, and what it is serving', () => {
    const [machine] = machineChoices(view())
    expect(machine.name).toBe('office-pc')
    expect(machine.noun).toBe('PC')
    expect(machine.unreachable).toBeNull()
    expect(machine.ports.map((port) => port.port)).toEqual([5173, 8080])
  })

  it('keeps a machine that has gone offline, and labels it', () => {
    // Dropped, this would simply be a computer missing from a menu — which is
    // the state somebody goes looking for a machine in.
    const [machine] = machineChoices(view({ state: 'offline' }))
    expect(machine.unreachable).toBe('Not connected')
  })

  /**
   * The rule he repeated more than any other, held here rather than in a review.
   *
   *   > *"here you have a very long description… Remove this full shit. I don't
   *   > want any kind of long descriptions anywhere."*
   *
   * This menu printed three lines under a greyed row. A ceiling on the label is
   * the only thing that stops the next person writing a fourth: a word is a
   * state, and everything past a word is somebody explaining.
   */
  it('never puts a sentence on a row', () => {
    for (const link of [
      { state: 'offline' as const },
      { state: 'connecting' as const },
      { state: 'awaiting-approval' as const },
      { state: 'error' as const, reason: null },
      { capabilities: ['create'] },
    ]) {
      const [machine] = machineChoices(view(link))
      const label = machine.unreachable ?? ''
      expect(label).not.toBe('')
      expect(label.split(' ').length).toBeLessThanOrEqual(4)
      expect(label).not.toContain('.')
      // The name is beside it on the row and in the band, so a label that named
      // the machine would say it twice.
      expect(label).not.toContain('office-pc')
    }
  })

  it('uses the same words for a state that the Machines panel uses', () => {
    // One vocabulary for a machine's condition. A machine reading `Connecting`
    // in the sidebar and something else in a dropdown is two.
    expect(machineChoices(view({ state: 'connecting' }))[0].unreachable).toBe(STATE_LABEL.connecting)
    expect(machineChoices(view({ state: 'awaiting-approval' }))[0].unreachable).toBe(
      STATE_LABEL['awaiting-approval'],
    )
    expect(machineChoices(view({ state: 'error', reason: null }))[0].unreachable).toBe(STATE_LABEL.error)
  })

  it('keeps the far machine’s own words for a failure, out of sight', () => {
    const [machine] = machineChoices(view({ state: 'error', reason: 'The relay refused the credential.' }))
    // A label on the row; the relay's sentence only as the row's `title`.
    expect(machine.unreachable).toBe('Cannot connect')
    expect(machine.detail).toBe('The relay refused the credential.')
  })

  it('adds nothing to a state its label already describes', () => {
    for (const link of [
      { state: 'offline' as const },
      { state: 'connecting' as const },
      { state: 'awaiting-approval' as const },
      { capabilities: ['create'] },
    ]) {
      expect(machineChoices(view(link))[0].detail).toBeNull()
    }
  })

  /**
   * The fifth door, seen from the guest's side — and what is left of it.
   *
   * This used to be the guest case as well as the old-build one, and the row
   * carried three lines saying so. `localhostAllowed` and `grantedPorts` in
   * `src/main/remote/server.ts` fixed the guest half: a guest is now told the
   * capability exists and is offered the ports its own folder grant covers,
   * which is what Asad asked for — *"still as a guest I should be able to open a
   * browser."* A machine that reaches this line is genuinely older than that
   * rule, which is one fact and two words.
   */
  it('labels a machine that does not advertise localhost as an old build', () => {
    const [machine] = machineChoices(view({ capabilities: ['create'] }))
    expect(machine.unreachable).toBe('Older build')
  })

  it('never lists this machine, which has no row to be wrong about', () => {
    expect(machineChoices({ machines: [], links: [], here: '', blocked: null })).toEqual([])
  })
})

/**
 * What this computer is called on a bar that is naming three of them.
 *
 * The picker draws this computer itself — it has no row in `machineChoices` and
 * no id — so until 2026-08-21 it was the one machine on the bar with no name,
 * and the phrase invented for it was on screen three times at once meaning three
 * different things:
 *
 *   > *"So I'm confused now what is the truth, because this machine is Office
 *   > PC, this machine is this machine where I am, and Office PC is the server.
 *   > So it is showing both, selected one and this one. So I don't know what to
 *   > trust."*
 */
describe('what this computer is called', () => {
  it('uses the name the machines view carried', () => {
    expect(hereName({ here: 'Asads-MacBook-Pro' })).toBe('Asads-MacBook-Pro')
  })

  it('falls back to the app’s own phrase rather than inventing a name', () => {
    /*
     * Two builds are in this state and neither may be given a made-up hostname: a
     * preload older than the field, and a computer whose hostname could not be
     * read at all. "This Mac" is what every other surface in the app has always
     * called this computer, so the fallback is that phrase and not a second one.
     */
    expect(hereName({ here: '' })).toBe(ThisMachine())
    expect(hereName(null)).toBe(ThisMachine())
    expect(hereName(undefined)).toBe(ThisMachine())
    // Whitespace is not a name either — a hostname of spaces would otherwise be
    // drawn as an empty chip, which reads as a value that failed to load.
    expect(hereName({ here: '   ' })).toBe(ThisMachine())
    // And it is a phrase about *this* computer in every case, never a machine
    // name this file made up.
    expect(ThisMachine()).toMatch(/^This /)
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

  it('says which number is which, as the arithmetic and not as a paragraph', () => {
    expect(differentPortNote(opened, 'office-pc')).toBe('office-pc:3000 → :53412')
  })

  // The rule he repeated most, pinned where it was broken: this note was two
  // sentences long. Anything that grows it back past the arithmetic fails here.
  it('is not a sentence', () => {
    const note = differentPortNote(opened, 'office-pc')
    expect(note.length).toBeLessThan(40)
    expect(note).not.toMatch(/[.,]/)
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
    unreachable: null,
    folders: null,
    detail: null,
  }

  it('leaves a good selection alone', () => {
    expect(lostMachine([good], 'mach-1')).toBeNull()
  })

  it('leaves this machine alone, which cannot go anywhere', () => {
    expect(lostMachine([], THIS_MACHINE)).toBeNull()
    expect(lostMachine([good], THIS_MACHINE)).toBeNull()
  })

  it('names the machine and its state, and nothing else', () => {
    const gone: MachineChoice = { ...good, unreachable: STATE_LABEL.offline }
    // Not "\u2026 Addresses now open on this machine": the picker has just
    // snapped back in front of them, so that half was narrating the screen.
    expect(lostMachine([gone], 'mach-1')).toBe('office-pc \u2014 Not connected')
  })

  it('still says something when the machine has left the list entirely', () => {
    // Forgotten on this side, or revoked and dropped. There is no row left to
    // borrow a name from, and silence would be a picker resetting itself under
    // somebody's hand.
    expect(lostMachine([], 'mach-1')).toBe('That machine is no longer paired')
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
describe('inTheWay — which tunnel owns the address the next page needs', () => {
  const opened = [
    { machineId: 'm-office', machineName: 'Office PC', port: 3100, localPort: 3100, sameNumber: true },
    { machineId: 'm-office', machineName: 'Office PC', port: 3000, localPort: 53412, sameNumber: false },
  ]

  it('finds the tunnel standing on that number here, whatever it serves over there', () => {
    expect(inTheWay(3100, THIS_MACHINE, opened)).toBe(opened[0])
    // 3000 is the *far* port of the second tunnel; the number this machine has
    // is 53412, and that is the only one that can be in anybody's way.
    expect(inTheWay(3000, THIS_MACHINE, opened)).toBeNull()
    expect(inTheWay(53412, THIS_MACHINE, opened)).toBe(opened[1])
  })

  it('says nothing for an address with no port in it', () => {
    expect(inTheWay(null, THIS_MACHINE, opened)).toBeNull()
    expect(inTheWay(3100, THIS_MACHINE, [])).toBeNull()
  })

  it('never asks a machine to give back the tunnel it is about to be asked for', () => {
    // Re-opening 3100 on the machine already serving it gets the same tunnel
    // back — `open` is idempotent per port — so closing it first would take the
    // page down and rebuild it for nothing.
    expect(inTheWay(3100, 'm-office', opened)).toBeNull()
  })
})

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
      // Nothing of this window's is standing on 3000: the tunnel is on 3001,
      // which is why it had to take a different number in the first place.
      give: null,
    })
  })

  /**
   * The case every test above this line missed, and the one that shipped.
   *
   * The fixture at the top of this block is a tunnel whose local port *differs*
   * from the origin port — `sameNumber: false`, rung 3, the case where this
   * machine was already busy on that number. That is the arrangement in which
   * moving a page home works by navigating, and it was the only one exercised.
   *
   * The ordinary arrangement is the opposite one: nothing here was using 3100,
   * so the tunnel took 3100, and `localhost:3100` on this Mac became the PC's
   * 3100. Moving home then navigated to the tunnel. From the 0.9.0 screenshot —
   * picker `Asads-MacBoo…`, address field `Office PC:3100`, and Paperclip, which
   * runs on the PC, on the page:
   *
   *   > *"when i change the machine it should attempt to browse with that
   *   > machine instead of staying on previous one and showing its running
   *   > there then what is the purpose of us if we change from dropdown"*
   */
  it('names the tunnel that has to be given back before home means home', () => {
    const kept = [
      {
        machineId: 'm-office',
        machineName: 'Office PC',
        port: 3100,
        localPort: 3100,
        sameNumber: true,
      },
    ]
    expect(moveFor(THIS_MACHINE, 'http://localhost:3100/auth?next=%2F', kept)).toEqual({
      kind: 'here',
      url: 'http://localhost:3100/auth?next=%2F',
      // The address is unchanged, which is precisely why the tunnel cannot be:
      // navigating there without closing it is a reload of the same far page.
      give: kept[0],
    })
  })

  it('asks for nothing back when moving to another machine, which needs nothing back', () => {
    const kept = [
      {
        machineId: 'm-office',
        machineName: 'Office PC',
        port: 3100,
        localPort: 3100,
        sameNumber: true,
      },
    ]
    // The new machine opens its own listener and the ladder takes the next rung
    // if this number is busy. Closing the old one first would only take the page
    // down before knowing whether the new machine will answer at all.
    expect(moveFor('m-desktop', 'http://localhost:3100/', kept)).toEqual({
      kind: 'there',
      machineId: 'm-desktop',
      port: 3100,
      url: 'http://localhost:3100/',
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

  it('lets an empty tab simply choose, which is the only way to reach a remote port list', () => {
    /*
     * Found by rendering: on a new browser tab the picker refused every other
     * machine and snapped straight back, because a start page has no address
     * and an address with no port in it was read as "nothing to move". The
     * remote machine's port list is drawn *on that start page*, so the one
     * route to a remote port was closed by the control that exists to open it.
     */
    expect(moveFor('m-desktop', '', opened)).toEqual({ kind: 'choose' })
    expect(moveFor('m-desktop', '   ', opened)).toEqual({ kind: 'choose' })
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

  it('does not treat a start page as a page that refuses to move', () => {
    /*
     * This test used to assert the opposite — `refused` — and asserting it kept
     * a real defect pinned in place. Rendered in `.harness/index.html`, which
     * has a paired machine: on a new browser tab, choosing `office-pc` snapped
     * the picker back to This machine and printed a refusal, every time. The
     * start page draws *the chosen machine's* port list, so refusing there
     * closed the only route to a remote port.
     *
     * See the `choose` case above; this is the same fact from the other side.
     */
    expect(moveFor('m-desktop', '', opened)).not.toMatchObject({ kind: 'refused' })
  })
})
