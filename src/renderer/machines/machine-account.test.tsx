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
import { profileLoginLabel } from '../accounts'
import {
  readAccount,
  readAccountState,
  signInOf,
  switchMachineAccount,
  type MachineAccount,
} from './machine-account'
import { MachineAccountChip } from './MachineAccountChip'

const WORK: MachineAccount = {
  id: 'work',
  name: 'work@example.com',
  provider: 'claude',
  color: '--acct-3',
  system: false,
  signIn: null,
}

/**
 * The machine's own install, which is where the word he condemned came from.
 *
 * `Default` is the key `systemProfileId` generates for it — not a name anybody
 * gave that login — and `system: true` is the far machine's own statement that
 * this is a generated one.
 */
const OWN_INSTALL: MachineAccount = {
  id: 'system',
  name: 'Default',
  provider: 'claude',
  color: null,
  system: true,
  signIn: null,
}

/** What the far machine's `claude auth status --json` actually printed. */
const SIGNED_IN = {
  state: 'signed-in',
  account: 'sherzod.davlatov@gmail.com',
  plan: 'max',
  detail: 'Signed in as sherzod.davlatov@gmail.com on the max plan.',
  command: 'claude auth status --json',
} as const

describe('reading what the far machine said', () => {
  it('keeps a row a menu can draw and drops one it cannot', () => {
    expect(readAccount({ id: 'work', name: 'work@example.com' })).toEqual({
      id: 'work',
      name: 'work@example.com',
      provider: null,
      color: null,
      system: false,
      // Null, not a composed state: a machine whose build predates the field
      // never answers this question, which is a different fact from a machine
      // that answered "could not tell".
      signIn: null,
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

  /**
   * The word he condemned by name, on the one control whose job is this fact.
   *
   * f_0070, 2026-08-21: the chip over the session on DESKTOP-DDGMNCV read
   * *"AAAA · on DESKTOP-DDGMNCV · ● ☀ Default ⌄"* while the Claude Code banner
   * three lines below it in the same pane read *"Welcome back Sherzod
   * Davlatov!"* and *"sherzod.davlatov@gmail.com's Organization"*. The chip and
   * the terminal underneath it disagreed, and the chip was the one that was
   * wrong.
   *
   *   > *"It is saying default, so never default. Whatever is actual account
   *   > should be visible here, never default."*
   */
  it('names the address the far machine’s CLI printed, never the profile key', () => {
    const signedIn: MachineAccount = { ...OWN_INSTALL, signIn: { ...SIGNED_IN } }
    const view = html({ current: signedIn, accounts: [signedIn] })
    expect(view).toContain('sherzod.davlatov@gmail.com')
    expect(view).toContain('title="Account: sherzod.davlatov@gmail.com."')
    // Not on the chip and not in the menu it opens.
    expect(view).not.toContain('Default')
  })

  it('says what it does not know rather than printing a word that means nothing', () => {
    /*
     * Two absences, and neither may fall back to the name. A machine whose build
     * predates `AccountWire.signIn` says nothing at all; a machine that ran the
     * probe and could not tell says so. Both are facts about a login; "Default"
     * is a fact about a JSON key.
     */
    const view = html({ current: OWN_INSTALL, accounts: [OWN_INSTALL] })
    expect(view).not.toContain('Default')
    expect(view).toContain('Account unknown')
    // And the hover says the state as a state. "Account: Account unknown."
    // reads as a login somebody gave that name.
    expect(view).toContain('title="Account unknown."')

    const signedOut: MachineAccount = {
      ...OWN_INSTALL,
      signIn: { state: 'signed-out', account: null, plan: null, detail: 'Not signed in.', command: '' },
    }
    const out = html({ current: signedOut, accounts: [signedOut] })
    expect(out).toContain('Not signed in')
    expect(out).not.toContain('Default')
  })

  it('names a login a person chose by that name, because that is an identity', () => {
    // The rung between the address and the state. "Work" is a word somebody
    // typed about their own account; "Default (Codex CLI)" is a string this app
    // generated, and only the first tells two logins apart.
    const named: MachineAccount = { ...WORK, name: 'Work' }
    expect(html({ current: named, accounts: [named] })).toContain('Work')
  })

  /**
   * And the rows of the menu it opens, which no render in this project reaches.
   *
   * `useChipMenu` opens on a click into a portal, and there is no DOM here — so
   * the rows are held at the function the component passes each account through,
   * with the three accounts a fresh machine actually has. f_0074 caught all
   * three of them: *"Default"*, *"Default (Codex CLI)"*, *"Default (Gemini
   * CLI)"* — one generated key each, in a list you pick a login from.
   */
  it('labels every row the way the chip is labelled, key included', () => {
    const rows: MachineAccount[] = [
      OWN_INSTALL,
      { ...OWN_INSTALL, id: 'system:codex', name: 'Default (Codex CLI)', provider: 'codex' },
      { ...OWN_INSTALL, id: 'system:gemini', name: 'Default (Gemini CLI)', provider: 'gemini' },
    ]
    const labels = rows.map((row) => profileLoginLabel(row, signInOf(row)))
    for (const label of labels) expect(label).not.toContain('Default')
    // And still three different rows: a list whose options read the same twice
    // has stopped being a picker, which is why the rows use this rung and the
    // chip above them uses the state rung.
    expect(new Set(labels).size).toBe(3)
    // The address wins over all of it the moment the far machine reports one.
    expect(profileLoginLabel(OWN_INSTALL, SIGNED_IN)).toBe('sherzod.davlatov@gmail.com')
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
