import { describe, expect, it } from 'vitest'
import { machineIsClosed, type ClosedMachine } from './machine-groups'

/**
 * What Close on a machine's heading does to its group, pinned against the bug
 * that shipped in the first version of it.
 *
 * ## The bug, because it is the whole reason this rule has a shape
 *
 * The first spelling was a list of machine ids, hidden while the id was in the
 * list, with an effect that took the id out again "once nothing is running
 * there". It typechecked, it read correctly, and it did nothing: the sessions
 * end **on the other computer**, so at the moment Close is pressed they are all
 * still listed, and the effect removed the id in the same render that added it.
 * Pressing Close visibly did nothing at all.
 *
 * It was found by driving the running app and watching the group stay put — not
 * by reading the code, where every line is right. That is worth writing down
 * because the failure mode is generic: any rule of the form "hide until the
 * thing you asked for has happened" is a race with the round trip unless it is
 * expressed against what was true at the moment of the press.
 *
 * ## So the rule is stated in ids
 *
 * An entry remembers what was running when Close was pressed, and the group is
 * hidden while every session on that machine is one of those. Each case below is
 * a state a person can actually be in.
 */

const CLOSED: ClosedMachine[] = [{ id: 'm1', sessions: ['a', 'b'] }]

describe('a machine group folded away by Close', () => {
  it('is hidden the instant it is pressed, with the sessions still listed', () => {
    // The case the first version got wrong. The far machine has not answered
    // yet; both sessions are still on the wire's list.
    expect(machineIsClosed(CLOSED, 'm1', [{ id: 'a' }, { id: 'b' }])).toBe(true)
  })

  it('stays hidden as they drain away one at a time', () => {
    expect(machineIsClosed(CLOSED, 'm1', [{ id: 'b' }])).toBe(true)
    expect(machineIsClosed(CLOSED, 'm1', [])).toBe(true)
  })

  it('comes back the moment a session nobody here closed appears', () => {
    /*
     * *"whenever you want to start, you can start as a new session and you can
     * start from that device."* New session → that machine puts a session on it
     * → its id is not one of the closed ones → the group is drawn again. Nothing
     * un-hides it by hand, which is why there is no control anywhere for doing
     * so and why a machine somebody *else* started work on also reappears.
     */
    expect(machineIsClosed(CLOSED, 'm1', [{ id: 'c' }])).toBe(false)
    // Even beside one of the closed ones that has not died yet — a fresh session
    // is a reason to show the group whatever else is on the list.
    expect(machineIsClosed(CLOSED, 'm1', [{ id: 'a' }, { id: 'c' }])).toBe(false)
  })

  it('says nothing about a machine nobody closed', () => {
    // A connected machine with no sessions is an ordinary state and the rail
    // says so — "Nothing running there." — so an empty list must not be mistaken
    // for a closed group.
    expect(machineIsClosed(CLOSED, 'm2', [])).toBe(false)
    expect(machineIsClosed([], 'm1', [])).toBe(false)
  })
})
