import { describe, expect, it } from 'vitest'
import { NO_TIERS } from '../deck-control/surface'
import { CopilotAccess, FULL_TIERS, remoteCopilotCaller } from './copilot-access'

/**
 * The gate the whole copilot-over-the-wire feature rests on.
 *
 * `copilot-access.ts` calls `granted` *"the only thing standing between a paired
 * phone and a tool that can rewrite this machine"*, and until now it had no test
 * of its own — every case that touched it went through `server.ts`, which is a
 * socket, a handshake and a dispatch table away from the two lines that decide
 * the answer. That is the wrong distance for this particular rule: a change here
 * that opened the copilot to guests would still leave most of those tests green,
 * because most of them are not about guests.
 *
 * So these are direct, they are small, and every one of them is a way the answer
 * could come out *wrong in the dangerous direction*.
 */

/** A store that knows about exactly one device of his. */
const kinds = (mine: readonly string[]) => ({ isMine: (id: string) => mine.includes(id) })

describe('who reaches the copilot', () => {
  it('gives one of his own devices everything', () => {
    // The decision he made, in his words: *"if we are connecting as my device,
    // copilot automatically comes."* There is no second act of authorisation to
    // perform and no state in which a device is paired, trusted and refused.
    const access = new CopilotAccess(kinds(['phone']))
    expect(access.granted('phone')).toEqual(FULL_TIERS)
    expect(access.linked('phone')).toBe(true)
  })

  it('gives a guest nothing, tier by tier', () => {
    // *"If we connect as guest then copilot don't come."* Asserted field by
    // field rather than against `NO_TIERS` by reference, so a future tier added
    // to `deck-control` cannot arrive here defaulted to true.
    const access = new CopilotAccess(kinds(['phone']))
    const granted = access.granted('stranger')
    expect(granted.read).toBe(false)
    expect(granted.act).toBe(false)
    expect(granted.alter).toBe(false)
    expect(access.linked('stranger')).toBe(false)
  })

  it('refuses a device it cannot name at all', () => {
    // An empty id is what an unauthenticated socket has. It must not be able to
    // land on the same branch as a device somebody approved.
    const access = new CopilotAccess({ isMine: () => true })
    expect(access.granted('')).toEqual(NO_TIERS)
    expect(access.linked('')).toBe(false)
  })

  it('treats a store that throws as a guest', () => {
    /*
     * The kind store reads a file, and a file can be missing, truncated or
     * unreadable. A throw crossing this line lands in whichever call site asked
     * — including one deciding whether to dispatch a tool — so the catch is not
     * defensive tidiness, it is the last of the three places this feature fails
     * closed.
     */
    const access = new CopilotAccess({
      isMine: () => {
        throw new Error('remote-device-kinds.json is unreadable')
      },
    })
    expect(access.granted('phone')).toEqual(NO_TIERS)
    expect(access.linked('phone')).toBe(false)
  })

  it('will not let a fourth tier become grantable by existing', () => {
    // `FULL_TIERS` is a frozen literal rather than a spread of `TIERS`, so that
    // a tier added next year is not remotely grantable until somebody comes here
    // and writes it down, having decided a phone may do it.
    expect(Object.isFrozen(FULL_TIERS)).toBe(true)
    expect(Object.keys(FULL_TIERS).sort()).toEqual(['act', 'alter', 'read'])
  })
})

describe('which devices the settings panel lists', () => {
  it('is the roster filtered, and holds no roster of its own', () => {
    // The device list lives in `RemoteAuth`; a second copy here would be a
    // second answer to *which devices exist*, which is the shape this codebase
    // has had to unpick twice.
    const access = new CopilotAccess(kinds(['mac', 'phone']))
    expect(access.list(['phone', 'stranger', 'mac'])).toEqual([
      { deviceId: 'phone', tiers: FULL_TIERS },
      { deviceId: 'mac', tiers: FULL_TIERS },
    ])
  })

  it('is empty when none of them are his', () => {
    expect(new CopilotAccess(kinds([])).list(['a', 'b'])).toEqual([])
  })
})

describe('the caller a run acts as', () => {
  it('reads access at the moment it is built, not when it was registered', () => {
    /*
     * Revoking a device is the only way to take the copilot away, and it has to
     * land on the *next tool call* rather than the next reconnect. That is why
     * every run registers `() => remoteCopilotCaller(access, deviceId)` instead
     * of a snapshot — and this is the case that would go quiet if somebody
     * "optimised" that into a value.
     */
    let mine = true
    const access = new CopilotAccess({ isMine: () => mine })
    expect(remoteCopilotCaller(access, 'phone').tiers).toEqual(FULL_TIERS)
    mine = false
    expect(remoteCopilotCaller(access, 'phone').tiers).toEqual(NO_TIERS)
  })

  it('is marked remote, which is what keeps it off the servers', () => {
    // `servers/grants.ts` refuses every server to a caller that is not `local`,
    // deliberately: a copilot run driven from a phone may not take control of an
    // SSH server, however fully its device is trusted. That property is carried
    // by this one field.
    expect(remoteCopilotCaller(new CopilotAccess(kinds(['phone'])), 'phone').kind).toBe('remote')
  })
})
