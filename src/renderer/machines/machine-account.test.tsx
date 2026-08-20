/**
 * The account chip over a session on another machine — what it reads, and what
 * it draws.
 *
 * Two properties are worth a test and they are the two that have gone wrong on
 * this bar before. **A chip must not invent a fact**: an account row that came
 * back without a name is not a half-row, and a read that could not be made is
 * not an empty account list. And **a chip with nothing behind it is not there**:
 * a machine whose build predates the capability answers nothing, and the answer
 * to that is an absent chip, not a named one with an empty menu — *"a dropdown
 * only when some exist. Hide it when empty."*
 */

import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { readAccount, readAccountState, switchMachineAccount } from './machine-account'
import { MachineAccountChip } from './MachineAccountChip'

const WORK = { id: 'work', name: 'work@example.com', provider: 'claude' as const, color: '--acct-3', system: false }

describe('reading what the far machine said', () => {
  it('keeps a row a menu can draw and drops one it cannot', () => {
    expect(readAccount({ id: 'work', name: 'work@example.com' })).toEqual({
      id: 'work',
      name: 'work@example.com',
      provider: null,
      color: null,
      system: false,
    })
    // An id is what a press sends back and a name is what a person reads. A
    // record missing either is not a row.
    expect(readAccount({ id: 'work' })).toBeNull()
    expect(readAccount({ name: 'work@example.com' })).toBeNull()
    expect(readAccount('work')).toBeNull()
  })

  it('never guesses the agent or the colour', () => {
    /*
     * A mark beside a name says which CLI that login belongs to, and a colour
     * says which account it is. Both invented here would be this app asserting
     * something the other machine never said — the same class of mistake as
     * naming the default account over a session that is on a different one.
     */
    const row = readAccount({ id: 'work', name: 'work@example.com', provider: 42, color: '' })
    expect(row?.provider).toBeNull()
    expect(row?.color).toBeNull()
  })

  it('answers nothing for a payload that is not a state at all', () => {
    // Which is what the hook turns into "keep the account you already had",
    // rather than into an empty menu.
    expect(readAccountState(null)).toBeNull()
    expect(readAccountState('nope')).toBeNull()
    expect(readAccountState({})).toEqual({ current: null, accounts: [] })
  })
})

describe('asking the far machine to move the session', () => {
  it('answers with a sentence when this build has no channel for it', async () => {
    const answer = await switchMachineAccount('m1', 's1', 'work')
    expect(answer.ok).toBe(false)
    // A press that produces nothing at all is indistinguishable from a control
    // that does not work, which is the defect this whole pass exists to remove.
    expect(answer.message).not.toBe('')
    expect(answer.session).toBeNull()
  })
})

describe('the chip itself', () => {
  const html = (props: Partial<Parameters<typeof MachineAccountChip>[0]> = {}): string =>
    renderToStaticMarkup(
      <MachineAccountChip
        current={WORK}
        accounts={[WORK]}
        busy={false}
        onOpen={() => undefined}
        onPick={() => undefined}
        {...props}
      />,
    )

  it('names the login the far session is on', () => {
    expect(html()).toContain('work@example.com')
  })

  it('says “No login” rather than naming this machine’s default', () => {
    // The chip is over a session on somebody else's computer. Falling back to
    // anything at all here would be the wrong-account bug at a distance.
    const view = html({ current: null })
    expect(view).toContain('No login')
    expect(view).not.toContain('work@example.com')
  })

  it('explains nothing on the chip', () => {
    /*
     * The rule he repeated most in the 2026-08-20 review. The chip's tooltip is
     * one clause naming the account and nothing else — no sentence about which
     * computer this is, because the machine's name is already on this bar two
     * chips to the left.
     */
    const view = html()
    expect(view).toContain('title="Account: work@example.com."')
    expect(view).not.toMatch(/title="[^"]{80,}"/)
  })
})
