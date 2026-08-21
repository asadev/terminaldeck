import { describe, expect, it } from 'vitest'
import {
  afterHandBack,
  readHeld,
  readHolds,
  readReleased,
  resolveReachApi,
  strandedNote,
  type ReachHold,
} from './reach-ledger'
import { inTheWay, servedBy, type ReachedPort } from './machines-bridge'

/**
 * The window's end of the one tunnel list.
 *
 * These used to be assertions about the *text* of `BrowserWorkspace.tsx` —
 * `expect(reach).toContain('void handBack(displaced)')` and three like it —
 * because the decisions lived inside a component and this project's test run
 * has no DOM. That is the worst kind of test: it fails when the code is moved
 * and passes when the behaviour is wrong. The decisions are functions now, so
 * they are checked by running them.
 */

const HOLD = {
  machineId: 'pc',
  machineName: 'Office PC',
  kind: 'device',
  port: 3100,
  localPort: 3100,
  sameNumber: true,
  holders: 1,
  stranded: false,
}

describe('resolveReachApi', () => {
  const whole = {
    listReach: () => Promise.resolve([]),
    onReachState: () => () => undefined,
    holdReach: () => Promise.resolve(null),
    releaseReach: () => Promise.resolve(null),
  }

  it('takes a preload that exposes all four', () => {
    expect(resolveReachApi(whole)).not.toBeNull()
  })

  it('refuses one that is missing any single method, not a sample of them', () => {
    for (const drop of Object.keys(whole)) {
      const partial: Record<string, unknown> = { ...whole }
      delete partial[drop]
      expect(resolveReachApi(partial), `${drop} was allowed to be absent`).toBeNull()
    }
  })

  it('is null with no preload at all, which is what draws no machine picker', () => {
    expect(resolveReachApi(null)).toBeNull()
    expect(resolveReachApi({})).toBeNull()
  })
})

describe('readHolds', () => {
  it('reads the list main pushes', () => {
    expect(readHolds([HOLD])).toEqual([HOLD])
  })

  it('drops a row it cannot read rather than inventing one', () => {
    // A badge is a claim about which computer a page came from. Half a row is
    // not a claim anybody should be shown.
    expect(readHolds([{ machineId: 'pc' }, null, 7, { port: 3100, localPort: 3100 }])).toEqual([])
    expect(readHolds(null)).toEqual([])
    expect(readHolds({ machineId: 'pc' })).toEqual([])
  })

  it('reads a missing sameNumber as true and a missing stranded as false', () => {
    // Both defaults point at "nothing unusual", so a main process that predates
    // a field cannot make a window print a caveat that is not true.
    const [row] = readHolds([{ machineId: 'pc', port: 3100, localPort: 3100 }])
    expect(row).toMatchObject({ sameNumber: true, stranded: false, holders: 0, kind: 'device' })
  })

  it('keeps a server row a server, because that is which bridge holds it', () => {
    const [row] = readHolds([{ ...HOLD, kind: 'server' }])
    expect(row?.kind).toBe('server')
  })
})

describe('the rows main sends are the rows every rule already takes', () => {
  /*
   * `servedBy`, `inTheWay` and `moveFor` were written over the window's own
   * array and are unchanged. This is the seam: what arrives from the ledger has
   * to satisfy them, or the badge silently stops naming anything.
   */
  const holds = readHolds([HOLD])

  it('names the machine behind a loopback address', () => {
    expect(servedBy('http://localhost:3100/orders', holds)?.machineName).toBe('Office PC')
    expect(servedBy('https://stripe.com/', holds)).toBeNull()
  })

  it('finds the tunnel standing on a number this computer is being asked for', () => {
    expect(inTheWay(3100, '', holds)?.machineId).toBe('pc')
    // Never the machine being moved *to*: asking it again gets the same tunnel.
    expect(inTheWay(3100, 'pc', holds)).toBeNull()
  })
})

describe('readHeld', () => {
  const opened = {
    ok: true,
    url: 'http://localhost:3100/',
    port: 3100,
    localPort: 3100,
    sameNumber: true,
  }

  it('narrows the answer with the same rule the direct verb used', () => {
    expect(readHeld({ answer: opened, stranded: null }).answer).toEqual(opened)
  })

  it('carries a displaced listener that would not close', () => {
    const held = readHeld({ answer: opened, stranded: { ...HOLD, holders: 0, stranded: true } })
    expect(held.stranded?.machineName).toBe('Office PC')
    expect(held.stranded?.stranded).toBe(true)
  })

  it('turns an answer it cannot read into a refusal with a sentence', () => {
    // A refusal is a sentence; show it. Silence here would be a click that did
    // nothing, which is the one outcome this whole feature refuses.
    expect(readHeld(null).answer.ok).toBe(false)
    expect(readHeld({}).answer.ok).toBe(false)
    const said = readHeld({ answer: { ok: false, message: 'That machine is not connected.' } })
    expect(said.answer.ok === false && said.answer.message).toBe('That machine is not connected.')
  })
})

describe('readReleased', () => {
  it('reads a port that really came back', () => {
    expect(readReleased({ gone: true, holders: 0, message: '' })).toEqual({
      gone: true,
      holders: 0,
      message: '',
    })
  })

  it('keeps the reason a port did not come back', () => {
    expect(
      readReleased({
        gone: false,
        holders: 1,
        message: 'Another browser window is still reading Office PC:3100 here.',
      }).message,
    ).toBe('Another browser window is still reading Office PC:3100 here.')
  })

  it('reads anything it cannot understand as "it did not go"', () => {
    /*
     * The direction of that default is the point. Reading an unreadable answer
     * as `gone` would let the picker take this computer's name over a page
     * still served from the machine it is leaving — the 0.9.0 defect, with a
     * narrowing bug in place of the missing verb.
     */
    expect(readReleased(null).gone).toBe(false)
    expect(readReleased({}).gone).toBe(false)
    expect(readReleased({ gone: 'yes' }).gone).toBe(false)
  })
})

describe('afterHandBack', () => {
  const held: ReachedPort = {
    machineId: 'pc',
    machineName: 'Office PC',
    port: 3100,
    localPort: 3100,
    sameNumber: true,
  }

  it('lets the page go home once the port really came back', () => {
    expect(afterHandBack({ gone: true, holders: 0, message: '' }, held)).toEqual({ go: true })
  })

  it('puts the picker back on the machine still serving the page', () => {
    const outcome = afterHandBack(
      { gone: false, holders: 1, message: 'Another browser window is still reading Office PC:3100 here.' },
      held,
    )
    // The untruth this whole change is about is a picker naming a machine the
    // page is not on. A hand-back that did not happen is one more way to get it.
    expect(outcome).toEqual({
      go: false,
      machineId: 'pc',
      notice: 'Another browser window is still reading Office PC:3100 here.',
    })
  })

  it('writes the reason itself when main did not send one', () => {
    expect(afterHandBack({ gone: false, holders: 0, message: '' }, held)).toEqual({
      go: false,
      machineId: 'pc',
      notice: 'Office PC is still serving port 3100 here.',
    })
  })
})

describe('strandedNote', () => {
  it('names the machine still answering on the number the new page took', () => {
    const hold: ReachHold = { ...HOLD, holders: 0, stranded: true, kind: 'device' }
    expect(strandedNote(hold)).toBe('Office PC is still serving port 3100 here.')
  })
})
