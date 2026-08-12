import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SettingsPanel } from '../SettingsWindow'
import { TOOL_MARK } from './SetupSection'
import {
  eventState,
  foreignNote,
  hookActions,
  hookSummary,
  toHookWriteOutcome,
  toSetupSnapshot,
  type SetupHookBlock,
} from '../setup-status'

/**
 * There is no DOM in this project's test setup, so the panel is rendered to
 * static markup and everything that decides a word is a pure function tested
 * directly — the same split the rest of the settings tests use.
 */

function block(over: Partial<SetupHookBlock> = {}): SetupHookBlock {
  return {
    id: 'claude',
    label: 'Claude Code',
    state: 'none',
    unsupportedReason: null,
    events: ['SessionStart', 'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd'],
    installedEvents: [],
    staleEvents: [],
    missingEvents: ['SessionStart', 'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd'],
    file: '/Users/apple/.claude/settings.json',
    fileExists: true,
    foreignHooks: 0,
    foreignOwners: [],
    message: 'No hooks from this app in this file yet.',
    requirement: null,
    ...over,
  }
}

describe('the hook summary', () => {
  it('says all of them when all of them are there', () => {
    const events = block().events
    expect(hookSummary(block({ state: 'complete', installedEvents: events, missingEvents: [] }))).toBe(
      'All hooks installed',
    )
  })

  it('counts the partial case', () => {
    expect(
      hookSummary(
        block({
          state: 'partial',
          installedEvents: ['SessionStart', 'Stop', 'SessionEnd'],
          missingEvents: ['PreToolUse', 'PostToolUse'],
        }),
      ),
    ).toBe('3 of 5 installed')
  })

  it('does not count a stale hook as installed, and says why the count is low', () => {
    // A stale entry is tagged as ours and sitting in the file, but it points at
    // a previous run's port and token — so it reports nothing, and calling it
    // installed would put "All hooks installed" over a silent provider. The
    // second half stops "0 of 5 installed" reading as a contradiction of the
    // "Installed, but …" sentence directly beneath it.
    expect(hookSummary(block({ state: 'stale', staleEvents: block().events, missingEvents: [] }))).toBe(
      '0 of 5 installed · 5 out of date',
    )
  })

  it('separates nothing installed from nothing installable', () => {
    expect(hookSummary(block())).toBe('Not installed')
    expect(hookSummary(block({ state: 'unsupported', events: [] }))).toBe('Not supported')
    expect(hookSummary(block({ state: 'error' }))).toBe('Could not be read')
  })
})

describe('one event in a block', () => {
  it('reads its state off the arrays rather than guessing from the total', () => {
    const partial = block({ installedEvents: ['SessionStart'], staleEvents: ['Stop'] })
    expect(eventState(partial, 'SessionStart')).toBe('installed')
    expect(eventState(partial, 'Stop')).toBe('stale')
    expect(eventState(partial, 'PreToolUse')).toBe('missing')
  })
})

describe('the buttons', () => {
  it('offers Install only when there is nothing of ours there yet', () => {
    expect(hookActions(block(), true)).toEqual({ install: true, repair: false, remove: false })
  })

  it('offers Repair and Remove once something of ours is', () => {
    const installed = block({ state: 'complete', installedEvents: block().events, missingEvents: [] })
    expect(hookActions(installed, true)).toEqual({ install: false, repair: true, remove: true })
  })

  it('offers nothing that can only fail', () => {
    // No endpoint: `installHooks` refuses, because there is no address to write.
    expect(hookActions(block(), false).install).toBe(false)
    // A settings file we could not parse is one `hooks.ts` will not rewrite.
    expect(hookActions(block({ state: 'error' }), true)).toEqual({
      install: false,
      repair: false,
      remove: false,
    })
    expect(hookActions(block({ state: 'unsupported', events: [] }), true).install).toBe(false)
  })

  it('can still remove an install that only left events we no longer manage', () => {
    expect(hookActions(block({ state: 'partial' }), true).remove).toBe(true)
  })
})

describe('somebody else’s hooks in the same file', () => {
  it('names the owner and promises not to touch them', () => {
    const note = foreignNote(block({ foreignHooks: 26, foreignOwners: ['vibeyard'] }))
    expect(note).toBe('26 hooks from vibeyard also live in this file. Nothing here ever touches them.')
  })

  it('says nothing when there are none', () => {
    expect(foreignNote(block())).toBeNull()
  })

  it('still explains an unmarked hook it cannot attribute', () => {
    expect(foreignNote(block({ foreignHooks: 1 }))).toContain('1 hook from another app')
  })
})

describe('a snapshot off the wire', () => {
  it('keeps only what it recognises, and never throws on junk', () => {
    expect(toSetupSnapshot(null)).toBeNull()
    expect(toSetupSnapshot({ tools: 'lots' })).toBeNull()
    const snapshot = toSetupSnapshot({
      tools: [{ id: 'claude', state: 'nonsense' }, { label: 'no id' }],
      hooks: [{ id: 'claude', state: 'complete', events: ['SessionStart', 7] }],
      endpoint: { running: true, port: 51234 },
    })
    expect(snapshot?.tools).toHaveLength(1)
    expect(snapshot?.tools[0].state).toBe('unknown')
    expect(snapshot?.hooks[0].events).toEqual(['SessionStart'])
    expect(snapshot?.endpoint).toEqual({ running: true, port: 51234 })
  })
})

describe('a write result off the wire', () => {
  it('treats anything that is not an explicit ok as a failure', () => {
    // `hooks.ts` reports a refusal as `ok: false` with the reason, and a silent
    // success would otherwise congratulate the user on a write that never landed.
    expect(toHookWriteOutcome({ ok: true, message: 'Installed 10 hooks.' })).toEqual({
      ok: true,
      message: 'Installed 10 hooks.',
    })
    expect(toHookWriteOutcome(undefined).ok).toBe(false)
    expect(toHookWriteOutcome({}).message).toContain('nothing was reported back')
  })
})

describe('the glyph on a tool row', () => {
  it('does not give an installed tool the same mark as a missing one', () => {
    // The row for a signed-out CLI says "Sign in needed" and the CSS tints it
    // amber, but a `✕` shared with "Not found" made an installed tool look
    // absent at a glance — and left colour as the only difference between them.
    expect(TOOL_MARK['installed-not-authed']).not.toBe(TOOL_MARK.missing)
    expect(new Set(Object.values(TOOL_MARK)).size).toBe(Object.keys(TOOL_MARK).length)
    expect(TOOL_MARK.ready).toBe('✓')
  })
})

describe('the section with nothing wired', () => {
  it('explains itself instead of rendering an empty page', () => {
    const html = renderToStaticMarkup(<SettingsPanel bridge={{}} initialSection="setup" />)
    expect(html).toContain('Setup')
    expect(html).toContain('not available in this build yet')
  })
})
