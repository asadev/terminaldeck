import { describe, expect, it } from 'vitest'
import capture from './cli-screens.capture.json'
import conpty from './agent-controls.conpty.json'
import {
  applyControl,
  discoverModels,
  modelFromSettings,
  readCommandError,
  readControls,
  readFast,
  readFastIndicator,
  readModelFromWelcome,
  type SessionAccess,
} from './agent-controls'

/**
 * The half of `agent-controls.ts` that was established by driving the shipped
 * binary on 2026-08-18, kept in its own file so the screens it reads and the
 * claims it makes sit next to each other.
 *
 * Every screen here came off `claude 2.1.234` through a pty into
 * `@xterm/headless` — the same path the app reads a session with — and is stored
 * verbatim in `cli-screens.capture.json`. Three of the things pinned below were
 * *stated as facts in this repo* before they were measured, and all three were
 * wrong: that fast mode cannot be read except at the moment it changes, that the
 * model list is five aliases, and that a session with nothing on its screen has
 * no model to report.
 */

const FAST_TIMINGS = { poll: 1, echo: 40, command: 120, cycleStep: 40 }

/**
 * A session whose screen is a script: each read advances to the next entry, and
 * the last one repeats for ever.
 *
 * The scripts below all carry the echo step, because `typeCommand` will not send
 * a return until it has *seen* the command sitting on the command line — that is
 * the protocol, not an implementation detail, and a fake that skipped it would
 * be testing a version of this module nobody ships.
 */
function scripted(screens: string[]): SessionAccess & { written: string[] } {
  const written: string[] = []
  let at = 0
  return {
    written,
    screen: async () => screens[Math.min(at++, screens.length - 1)] ?? null,
    write: (_id: string, data: string) => {
      written.push(data)
    },
  }
}

/** The screen a session shows while `command` is typed at its prompt, unsent. */
function echoOf(command: string): string {
  return ['───────────────────────────────────────────────────────────────', `❯ ${command}`].join('\n')
}

describe('fast mode, read off the status rule', () => {
  /*
   * The measurement, in one test. `/fast on` leaves a `↯` in the rule above the
   * command line; `/fast off` takes it away. Nothing was typed to produce
   * `bootFastOn` — it is a brand-new process that inherited the setting — which
   * is what proves the glyph is a *state* and not the echo of a command.
   */
  it('reads on and off from the glyph in the rule above the composer', () => {
    expect(readFastIndicator(capture.shots.fastOn)).toBe('on')
    expect(readFastIndicator(capture.shots.bootFastOn)).toBe('on')
    expect(readFastIndicator(capture.shots.fastOff)).toBe('off')
    expect(readFastIndicator(capture.shots.bootFastOff)).toBe('off')
  })

  it('survives a session that has never once been told about fast mode', () => {
    // The whole complaint, in one assertion: before this the boot screen read
    // "Not reported" for ever, because nothing had announced anything.
    expect(readFast(capture.shots.bootFastOff)).toEqual({ value: 'off', label: 'Off', source: 'screen' })
    expect(readFast(capture.shots.bootFastOn)).toEqual({ value: 'on', label: 'On', source: 'screen' })
  })

  it('claims nothing when it cannot find the rule at all', () => {
    // An older CLI, a half-drawn repaint, or a session that is not Claude Code:
    // all three have to answer null rather than "off", because "off" from an
    // unreadable screen is the confident-and-wrong reading this module exists
    // to avoid.
    expect(readFastIndicator('')).toBeNull()
    expect(readFastIndicator('❯ ')).toBeNull()
    expect(readFastIndicator('$ ls -la\ntotal 8\n')).toBeNull()
  })

  it('does not mistake the rule below the command line for the one above it', () => {
    /*
     * The CLI draws two rules, one on each side of the composer, and only the
     * upper one ever carries the glyph. A reader that searched from the bottom
     * would find the lower one and answer "off" on every screen, including the
     * ones where fast mode is plainly on — which is why the search walks *up*
     * from the composer and stops after three lines.
     */
    const both = capture.shots.fastOn.split('\n')
    expect(both.filter((line) => /^─{10,}.*─$/.test(line)).length).toBeGreaterThan(1)
    expect(readFastIndicator(capture.shots.fastOn)).toBe('on')
  })

  it('keeps a refusal beside an off reading, and drops a stale one beside an on reading', () => {
    const refused = [
      '❯ /fast on',
      '  ⎿  Fast mode unavailable: Fast mode requires usage credits · /usage-credits to',
      '─────────────────────────────────────────────────────────────────────────────────────',
      '❯ ',
    ].join('\n')
    expect(readFast(refused)).toEqual({
      value: 'off',
      label: 'Off',
      source: 'screen',
      unavailableReason: 'Fast mode requires usage credits · /usage-credits to',
    })

    // Same screen, later, after credits were bought and it actually turned on.
    // The refusal is still scrolled up there and must not be shown over a
    // control that is visibly working.
    const laterOn = refused.replace(
      '─────────────────────────────────────────────────────────────────────────────────────',
      '──────────────────────────────────────────────────────────────────── ↯  Update Claude Code ──',
    )
    expect(readFast(laterOn)?.unavailableReason).toBeUndefined()
    expect(readFast(laterOn)?.value).toBe('on')
  })
})

describe('turning fast mode on', () => {
  it('accepts the glyph as the confirmation when the CLI prints nothing', async () => {
    /*
     * `/fast on` at a session that is already on prints nothing at all. The old
     * code waited out its whole timeout and then apologised — "it was either
     * already on or it is mid-turn" — for a state that was exactly what had
     * been asked for.
     */
    const already = capture.shots.bootFastOn
    const access = scripted([already, already, echoOf('/fast on'), already])
    const answer = await applyControl(
      access,
      { sessionId: 's', control: 'fast', value: 'on', provider: 'claude' },
      FAST_TIMINGS,
    )
    expect(answer.ok).toBe(true)
    expect(answer.reading).toEqual({ value: 'on', label: 'On', source: 'screen' })
  })

  it('still sends the command through the echo-then-return protocol', async () => {
    const already = capture.shots.bootFastOn
    const access = scripted([already, already, echoOf('/fast on'), already])
    await applyControl(access, { sessionId: 's', control: 'fast', value: 'on', provider: 'claude' }, FAST_TIMINGS)
    // The command, then the return, in that order and never glued together —
    // the separation is what stops a stray `\r` answering somebody's dialog.
    expect(access.written[0]).toBe('/fast on')
    expect(access.written[1]).toBe('\r')
  })
})

describe('the model, on a session that has said nothing', () => {
  it('reads the model out of the CLI’s welcome panel', () => {
    expect(readModelFromWelcome(capture.shots.bootFastOff)).toBe('Opus 5')
  })

  it('stops at the effort word, because a narrow window truncates it', () => {
    /*
     * From the Windows capture: `Opus 5 (1M context) with xhig… · Claude Max ·`.
     * A reader that took everything before the separator would report a model
     * called "Opus 5 (1M context) with xhig…".
     */
    const narrow = '│   Opus 5 (1M context) with xhig… · Claude Max ·    │ Added opt-in memory cgroup support │'
    expect(readModelFromWelcome(narrow)).toBe('Opus 5 (1M context)')
  })

  it('falls back to what Claude’s own settings say, and names that source', () => {
    expect(modelFromSettings({ model: 'opus' })).toEqual({ value: 'opus', label: 'Opus 5', source: 'settings' })
    expect(modelFromSettings({ model: 'claude-sonnet-4-6' })).toEqual({
      value: 'claude-sonnet-4-6',
      label: 'Sonnet 4.6',
      source: 'settings',
    })
    expect(modelFromSettings({})).toEqual({ value: null, label: null, source: null })
  })

  /*
   * His words: *"Unknown should not be there, it should be already selected."*
   * A model is the one control that always has a value, so this asserts the
   * outcome rather than the mechanism — whatever the sources are, the boot
   * screen of a real session must not read as unknown.
   */
  it('never reports Unknown for a live session’s model', async () => {
    const access = scripted([capture.shots.bootFastOff])
    const readings = await readControls(access, 's', undefined, 'claude')
    expect(readings.model.label).not.toBeNull()
    expect(readings.model.label).toBe('Opus 5')
  })
})

describe('asking the session for its model list', () => {
  it('opens the picker, reads it, and cancels out again', async () => {
    const access = scripted([
      capture.shots.bootFastOff, // the opening read, which finds a free prompt
      capture.shots.bootFastOff, // typeCommand's own check, before it writes
      echoOf('/model'), // the echo it waits for before sending the return
      capture.shots.modelPicker, // the picker, once it has drawn
    ])
    const answer = await discoverModels(access, 's', 'claude', FAST_TIMINGS)
    expect(answer.message).toBeNull()
    expect(answer.models.map((row) => `${row.name} · ${row.model}`)).toEqual([
      'Opus (1M context) · Opus 5 with 1M context',
      'Fable · Fable 5',
      'Sonnet · Sonnet 5',
      'Haiku · Haiku 4.5',
      'Opus · Opus 5',
    ])
    // Typed, submitted, and then escaped. The Esc is the part worth pinning:
    // an app that opens a modal in somebody's terminal and walks away has done
    // the worst thing in this file it is possible to do.
    expect(access.written).toEqual(['/model', '\r', '\x1b'])
  })

  it('escapes the dialog even when it cannot read it', async () => {
    const access = scripted([
      capture.shots.bootFastOff,
      capture.shots.bootFastOff,
      echoOf('/model'),
      'something unfamiliar',
    ])
    const answer = await discoverModels(access, 's', 'claude', FAST_TIMINGS)
    expect(answer.models).toEqual([])
    expect(answer.message).toMatch(/cancelled/)
    expect(access.written).toContain('\x1b')
  })

  it('will not type into a session that is mid-turn, and says why', async () => {
    const busy = ['❯ do the thing', '✽ Flambéing… (6s · ↓ 25 tokens)', '❯ '].join('\n')
    const access = scripted([busy])
    const answer = await discoverModels(access, 's', 'claude', FAST_TIMINGS)
    expect(answer.models).toEqual([])
    expect(answer.message).toMatch(/mid-turn/)
    expect(access.written).toEqual([])
  })

  it('will not type Claude’s commands into a session running another CLI', async () => {
    const access = scripted([capture.shots.bootFastOff])
    const answer = await discoverModels(access, 's', 'gemini', FAST_TIMINGS)
    expect(answer.models).toEqual([])
    expect(access.written).toEqual([])
  })
})

describe('refusals the CLI actually prints', () => {
  /*
   * Driven, not read: `/model claude-mythos-5` on an account without the
   * entitlement answered exactly this. Before it was recognised, choosing that
   * model waited out the whole timeout and reported "the CLI has not answered
   * yet" over a perfectly clear explanation the CLI had already given.
   */
  it('recognises "isn’t available for your account yet"', () => {
    const screen = [
      '❯ /model claude-mythos-5',
      "  ⎿  Mythos 5 isn't available for your account yet. Run /model to pick another model.",
      '─────────────────────────────────────────────────────────────────────────────',
      '❯ ',
    ].join('\n')
    expect(readCommandError(screen)).toBe(
      "Mythos 5 isn't available for your account yet. Run /model to pick another model.",
    )
  })

  it('does not read that sentence out of the middle of an answer', () => {
    const answer = '⏺ It will say that Mythos 5 isn’t available for your account yet. if you try it.'
    expect(readCommandError(answer)).toBeNull()
  })
})

describe('the Windows capture still parses', () => {
  it('reads no fast-mode glyph on a CLI version that does not draw one', () => {
    /*
     * `claude 2.1.233` on Windows drew no `↯` because fast mode was off there,
     * and the point of this test is the *shape* of the answer: an honest "off"
     * where the rule was found, never a null that would make the control give
     * up on a whole platform.
     */
    const environments = conpty.environments as Record<string, { shots: Array<{ screen: string }> }>
    const idle = Object.values(environments)
      .flatMap((environment) => environment.shots)
      .find((shot) => shot.screen.includes('shift+tab to cycle'))
    expect(idle, 'the Windows capture should contain an idle screen').toBeTruthy()
    expect(readFastIndicator(String(idle?.screen))).toBe('off')
  })
})
