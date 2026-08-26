/**
 * The account chip over a terminal on a server — what it draws, what it types,
 * and what it says about itself.
 *
 * The slot it replaced was a `<span>`, pinned by a test that said "a word and
 * not a control". Asad, inside this exact bar: *"when I am inside the server, I
 * cannot even change the accounts."* What is pinned now is the corrected model:
 * the same four sentences on the chip, a menu whose rows are the two verbs a
 * server really has, and a note — the `fixedAccountNote` pattern — that says
 * what a press does *before* one is pressed. A menu row must never promise a
 * switch this app cannot perform, and must never be a dead end either.
 */

import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { signInLine, type ServerSignIn } from './server-signin'
import {
  agentCommand,
  menuStateLine,
  SERVER_ACCOUNT_NOTE,
  ServerAccountChip,
} from './ServerAccountChip'

const TWO_LOGINS: ServerSignIn = {
  known: 'yes',
  agents: 2,
  logins: [
    { agentId: 'claude', account: 'asad@example.com' },
    { agentId: 'codex', account: null },
  ],
}

const html = (signIn: ServerSignIn): string =>
  renderToStaticMarkup(
    <ServerAccountChip
      signIn={signIn}
      serverName="Office PC"
      onStartAgent={() => undefined}
      onManage={() => undefined}
    />,
  )

describe('the chip itself', () => {
  it('keeps the sign-in line as its label — the words do not change, only the shape', () => {
    const drawn = html(TWO_LOGINS)
    expect(drawn).toContain(signInLine(TWO_LOGINS, 'Office PC').line)
    // And it is a control now: a real button that opens a menu, not a span.
    expect(drawn).toContain('aria-haspopup="menu"')
    expect(drawn).toContain('account-chip-button')
  })

  it('keeps the tooltip that says whose fact this is', () => {
    // "…a fact about that account rather than about this session" — the part
    // that stops the chip reading as this session's login.
    expect(html(TWO_LOGINS)).toContain('fact about that account')
  })

  it('is never blank: even a server that would not answer still draws the state', () => {
    const drawn = html({ known: 'cannot', why: 'This server did not answer.' })
    expect(drawn).toContain('Coding logins unknown')
  })
})

describe('what a picked row types', () => {
  it('uses the agent’s own command from the catalogue', () => {
    expect(agentCommand('claude')).toBe('claude')
    expect(agentCommand('codex')).toBe('codex')
    expect(agentCommand('gemini')).toBe('gemini')
  })

  it('types an unknown agent id as it arrived, the same fallback the label makes', () => {
    // The far probe can be newer than this build; `grok` at a prompt is more
    // useful than a refusal to try, and `command not found` is the honest
    // outcome where it really is not there.
    expect(agentCommand('grok')).toBe('grok')
  })
})

describe('the menu says which mode it is, before a row is read', () => {
  it('states the whole model in one note: no switch here, a new terminal instead', () => {
    // The `fixedAccountNote` pattern, for the server case: why this terminal
    // keeps its login, what a press really does, where logins change.
    expect(SERVER_ACCOUNT_NOTE).toContain('did not start')
    expect(SERVER_ACCOUNT_NOTE).toContain('opens a new terminal on this server')
    expect(SERVER_ACCOUNT_NOTE).toContain('this one keeps what it has')
    expect(SERVER_ACCOUNT_NOTE).toContain('signing in')
  })

  it('has a sentence for every state that draws no login rows', () => {
    expect(menuStateLine({ known: 'cannot', why: 'This server did not answer.' }, 'Office PC')).toBe(
      'This server did not answer.',
    )
    expect(menuStateLine({ known: 'yes', agents: 0, logins: [] }, 'Office PC')).toBe(
      'No coding agent is installed on Office PC.',
    )
    expect(menuStateLine({ known: 'yes', agents: 0, logins: [] }, '')).toContain('this server')
    expect(menuStateLine({ known: 'yes', agents: 2, logins: [] }, 'Office PC')).toBe(
      'A coding agent is installed there and none of them has a login.',
    )
  })

  it('has no sentence when there are rows — the rows are the answer', () => {
    expect(menuStateLine(TWO_LOGINS, 'Office PC')).toBeNull()
  })
})
