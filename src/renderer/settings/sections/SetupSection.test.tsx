import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SettingsPanel } from '../SettingsWindow'
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
    // second half stops "3 of 5 installed" reading as a contradiction of the
    // "Installed, but …" sentence directly beneath it.
    expect(
      hookSummary(
        block({
          state: 'partial',
          installedEvents: ['SessionStart', 'PreToolUse', 'PostToolUse'],
          staleEvents: ['Stop', 'SessionEnd'],
          missingEvents: [],
        }),
      ),
    ).toBe('3 of 5 installed · 2 out of date')
  })

  it('names the all-stale case instead of counting it to zero', () => {
    // The state this machine is in every time the app restarts, and the one the
    // count could not describe: "0 of 5 installed · 5 out of date" asks the
    // reader where the five came from if none is installed, and it sat directly
    // above "Installed, but 5 events still point at a previous run of the app".
    // Nothing here is allowed to print a zero beside a non-zero drawn from the
    // same five entries.
    const summary = hookSummary(
      block({ state: 'stale', staleEvents: block().events, missingEvents: [] }),
    )
    expect(summary).toBe('All hooks out of date')
    expect(summary).not.toMatch(/\b0 of\b/)
  })

  it('still counts the stale ones when some events are missing outright', () => {
    // Two of five are ours-but-stale and three were never written, so "all" is
    // untrue and the total is what tells the reader the rest are simply absent.
    expect(
      hookSummary(
        block({
          state: 'partial',
          staleEvents: ['SessionStart', 'Stop'],
          missingEvents: ['PreToolUse', 'PostToolUse', 'SessionEnd'],
        }),
      ),
    ).toBe('2 of 5 out of date')
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
      endpoint: { running: true, address: '/tmp/terminaldeck/hook.sock' },
    })
    expect(snapshot?.tools).toHaveLength(1)
    expect(snapshot?.tools[0].state).toBe('unknown')
    expect(snapshot?.hooks[0].events).toEqual(['SessionStart'])
    expect(snapshot?.endpoint).toEqual({ running: true, address: '/tmp/terminaldeck/hook.sock' })
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

describe('the Other tools disclosure', () => {
  /**
   * Asad, 2026-08-21, at the foot of Coding AI:
   *
   *   > *"If there is no tool, why we have this button, you know?"*
   *
   * The disclosure was meant to hold git and the GitHub CLI, but the probe
   * behind the pane answers only for the agents and Copilot — all of which this
   * pane subtracts — so the list was empty on every machine, and the only thing
   * a person ever saw was the pending branch flashing on each visit. It is gone
   * whole, pending branch included, and this pins that it stays gone: a control
   * that cannot ever hold a row has no honest moment to be drawn in.
   */
  it('is gone, pending branch included', () => {
    // `renderToStaticMarkup` runs no effects, so this render is exactly the
    // probe-still-out paint — the one the old code drew the flashing button on.
    const html = renderToStaticMarkup(<SettingsPanel bridge={{}} initialSection="setup" />)
    expect(html).not.toContain('Other tools')
    expect(html).not.toContain('settings-tool-ghost')
  })
})

describe('setup, now that it is part of Agents', () => {
  /**
   * `setup` is no longer a pane; it is two groups inside Agents. The id still
   * has to resolve, though, because `App.tsx` opens Settings at it from the
   * application menu — a menu item that lands on General because its section
   * was merged away is a menu item that appears to do nothing.
   */
  it('opens the Agents pane when the old section id is asked for', () => {
    const html = renderToStaticMarkup(<SettingsPanel bridge={{}} initialSection="setup" />)
    expect(html).toContain('data-section="agents" class="settings-nav-item" aria-selected="true"')
  })

  it('explains itself instead of rendering an empty page', () => {
    const html = renderToStaticMarkup(<SettingsPanel bridge={{}} initialSection="setup" />)
    expect(html).toContain('not available in this build yet')
  })
})
