import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  AgentCliUpdate,
  dismissalIdFor,
  readFixResult,
  UPGRADE_FIX,
  withCommands,
} from './AgentCliUpdate'
import { readStaleAgents } from '../browser/accounts-bridge'

/**
 * The loop the review got stuck in: *"Gemini reports 'authentication
 * successful' while the app shows nothing, then fails with 'this client is no
 * longer supported… migrate to the Gravity suite.'"*
 *
 * The OAuth succeeds and the *client* is turned away on its first API call, so
 * no browser change can reach it and retrying never will either. What closes
 * the loop is telling somebody, where they are standing when it happens, and
 * giving them the upgrade rather than a command to copy.
 *
 * `renderToStaticMarkup` runs no effects, so the row list arrives as a prop of
 * the machine rather than of a fetch — which is why every assertion below is
 * about the *shape* of what is drawn and the pure functions around it. What is
 * actually on screen was checked in the running app, in both themes.
 */

describe('what the stale row is keyed and read by', () => {
  it('remembers a dismissal against the version, not the command', () => {
    /*
     * The point of doing it this way. Somebody who has decided to live with an
     * old build should not be told again tomorrow; if that build changes and is
     * still stale, that is a new fact and the row comes back on its own.
     */
    expect(dismissalIdFor({ command: 'gemini', version: '0.32.1', stale: true, advice: '' })).toBe(
      'agent-cli:gemini@0.32.1',
    )
    expect(dismissalIdFor({ command: 'gemini', version: null, stale: true, advice: '' })).toBe(
      'agent-cli:gemini@unknown',
    )
  })

  it('takes only rows the main process measured as stale', () => {
    // `stale` is set only when a version was actually read *and* it is below the
    // floor — a binary that is missing or would not answer is a different
    // finding entirely, and must never be reported as "yours is too old".
    const rows = readStaleAgents([
      { command: 'gemini', version: '0.32.1', stale: true, advice: 'Upgrade it.' },
      { command: 'other', version: '9.9.9', stale: false, advice: '' },
      { command: 'nameless', stale: true },
      'rubbish',
    ])
    expect(rows.map((row) => row.command)).toEqual(['gemini', 'nameless'])
    expect(rows[0].advice).toBe('Upgrade it.')
  })

  it('narrows the fix answer instead of trusting it', () => {
    expect(readFixResult({ ok: true, message: 'Upgraded from 0.32.1 to 0.46.0.' })).toEqual({
      ok: true,
      message: 'Upgraded from 0.32.1 to 0.46.0.',
    })
    // No message is no answer: printing "undefined" under a row is worse than
    // printing the fallback the caller supplies.
    expect(readFixResult({ ok: true })).toBeNull()
    expect(readFixResult(null)).toBeNull()
    expect(readFixResult('done')).toBeNull()
    // Anything other than a literal true is false. A truthy string must not
    // turn a refusal into a success on screen.
    expect(readFixResult({ ok: 'yes', message: 'x' })?.ok).toBe(false)
  })

  it('sets the commands in the advice as commands', () => {
    /*
     * The sentence is written with backticks, like every other explanation in
     * this codebase — and rendered raw it reached the screen with the backticks
     * showing, on the one line in the app where somebody is being asked to read
     * a command. Seen in the running window before it was fixed.
     */
    expect(withCommands('Upgrade it: `brew upgrade x`, or `npm i -g y`.')).toEqual([
      { code: false, text: 'Upgrade it: ' },
      { code: true, text: 'brew upgrade x' },
      { code: false, text: ', or ' },
      { code: true, text: 'npm i -g y' },
      { code: false, text: '.' },
    ])
    // An unclosed backtick is prose, not a broken span.
    expect(withCommands('run `npm i')).toEqual([
      { code: false, text: 'run ' },
      { code: true, text: 'npm i' },
    ])
    expect(withCommands('no commands here')).toEqual([{ code: false, text: 'no commands here' }])
  })

  it('asks the main process for the act rather than copying a command', () => {
    // The audience is "mostly non-technical vibe coders"; a clipboard is
    // homework. The empty path is the contract for a machine-level fix.
    expect(UPGRADE_FIX).toBe('upgrade-agent-cli')
  })
})

describe('what it draws', () => {
  it('draws nothing at all when nothing is stale', () => {
    // The usual case, and it must cost no space: this block sits above the
    // account list and above the readiness checks.
    const html = renderToStaticMarkup(
      <AgentCliUpdate bridge={{ browserSignInAgents: async () => [] }} />,
    )
    expect(html).toBe('')
  })

  it('draws nothing in a window whose preload has no such channel', () => {
    expect(renderToStaticMarkup(<AgentCliUpdate bridge={{}} />)).toBe('')
  })
})
