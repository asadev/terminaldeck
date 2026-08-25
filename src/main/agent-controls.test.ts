import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import {
  encodeProjectPath,
  installDeviceHomes,
  resetDeviceHomes,
} from './transcript'
import { classify } from './session-activity'
import {
  applyControl,
  effortFromSettings,
  fastFromSettings,
  labelModelId,
  PERMISSION_MODES,
  countCommandErrors,
  readCarry,
  readCommandError,
  readComposer,
  readControls,
  readEffortConfirmation,
  readEffortFromScreen,
  readFastFromScreen,
  readModelConfirmation,
  readModelFromScreen,
  readModelFromTranscript,
  readSwitchDialog,
  readAgentFromScreen,
  readPermissionMode,
  readPermissionDefault,
  refuseByProvider,
  NO_AGENT,
  type ApplyTimings,
  type SessionAccess,
} from './agent-controls'

/**
 * Every fixture below is a transcription of a screen this app's own headless
 * terminal rendered while driving the real `claude` binary in a pty. They keep
 * the wrapping, the box-drawing rules and the `⎿` gutter, because all three
 * broke an earlier draft of these patterns: the model confirmation wraps mid
 * sentence, and the effort confirmation puts the level immediately before a
 * parenthesis on a line that also ends mid-word.
 */

/** The bottom of the screen. The footer is the last line; the notice above it is real too. */
function footer(mode: string): string {
  return [
    '──────────────────────────────────────────────────────────── ultracode ─',
    '❯',
    '────────────────────────────────────────────────────────────────────────',
    '  ⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · res…',
    `  ${mode}`,
  ].join('\n')
}

const BYPASS = footer('⏵⏵ bypass permissions on (shift+tab to cycle)')
const AUTO = footer('⏵⏵ auto mode on (shift+tab to cycle)')
const MANUAL = footer('⏸ manual mode on · ? for shortcuts')
const ACCEPT_EDITS = footer('⏵⏵ accept edits on (shift+tab to cycle)')
const PLAN = footer('⏸ plan mode on (shift+tab to cycle)')

describe('permission mode from the footer', () => {
  it('reads every mode the real cycle produced', () => {
    expect(readPermissionMode(BYPASS)).toBe('bypass')
    expect(readPermissionMode(AUTO)).toBe('auto')
    expect(readPermissionMode(ACCEPT_EDITS)).toBe('acceptEdits')
    expect(readPermissionMode(PLAN)).toBe('plan')
  })

  it('reads manual, whose footer ends "? for shortcuts" and not "shift+tab to cycle"', () => {
    expect(readPermissionMode(MANUAL)).toBe('manual')
  })

  it('is unknown rather than guessing when no footer is on screen', () => {
    expect(readPermissionMode('❯ nothing here\n────────')).toBeNull()
  })

  it('ignores the auto-mode explainer that stays on screen after entering auto', () => {
    // Verbatim from the real screen: entering auto prints this paragraph, and
    // it then sits mid-screen for the rest of the session while the footer
    // moves on. Scanning the whole viewport would pin the reading to it.
    const explained = [
      '⏺ Auto mode lets Claude handle permission prompts automatically — Claude',
      '  checks each tool call for risky actions and prompt injection before',
      '  executing. Ideal for long-running tasks. Shift+Tab to change mode.',
      MANUAL,
    ].join('\n')
    expect(readPermissionMode(explained)).toBe('manual')
  })

  it('has no mode the cycle never showed', () => {
    // `--permission-mode` also accepts dontAsk, but it never appeared in the
    // cycle, so it must not be offered as something a running session can reach.
    expect(PERMISSION_MODES.map((mode) => mode.id)).toEqual([
      'auto',
      'manual',
      'acceptEdits',
      'plan',
      'bypass',
    ])
  })
})

describe('model from the CLI confirmation', () => {
  it('reads a single-line confirmation', () => {
    const screen = ['❯ /model sonnet', '  ⎿  Set model to Sonnet 5 and saved as your default for new sessions'].join('\n')
    expect(readModelFromScreen(screen)).toBe('Sonnet 5')
  })

  it('keeps the parenthesised context tag and survives the wrap', () => {
    const screen = [
      '❯ /model default',
      '  ⎿  Set model to Opus 5 (1M context) (default) and saved as your default for',
      '     new sessions',
    ].join('\n')
    expect(readModelFromScreen(screen)).toBe('Opus 5 (1M context) (default)')
  })

  it('reads the cancelled-picker wording, which has no "and saved" clause', () => {
    expect(readModelFromScreen('  ⎿  Kept model as Opus 5 (1M context) (default)')).toBe(
      'Opus 5 (1M context) (default)',
    )
  })

  it('takes the most recent confirmation when several are on screen', () => {
    const screen = [
      '  ⎿  Set model to Sonnet 5 and saved as your default for new sessions',
      '  ⎿  Set model to Haiku 4.5 and saved as your default for new sessions',
    ].join('\n')
    expect(readModelFromScreen(screen)).toBe('Haiku 4.5')
  })

  it('is null when nothing on screen says what the model is', () => {
    expect(readModelFromScreen(BYPASS)).toBeNull()
  })

  it('stops at the session-only clause instead of putting it on the button', () => {
    // The binary builds this line as `Set model to X` + one of two clauses.
    // Matching only the "and saved" arm left the other one glued to the name,
    // so the control read "Sonnet 5 for this session only" as if that were a
    // model.
    const screen = '  ⎿  Set model to Sonnet 5 for this session only'
    expect(readModelFromScreen(screen)).toBe('Sonnet 5')
    expect(readModelConfirmation(screen)?.scope).toBe('session')
  })

  it('reads the scope the CLI chose, both ways', () => {
    expect(readModelConfirmation('  ⎿  Set model to Sonnet 5 and saved as your default for new sessions')?.scope).toBe(
      'default',
    )
    expect(readModelConfirmation('  ⎿  Kept model as Opus 5')?.scope).toBeNull()
  })

  it('still reads the scope when the terminal wrapped it mid-phrase', () => {
    // What an 80-column screen actually holds: the clause is cut after "for".
    const wrapped = [
      '  ⎿  Set model to Opus 5 (1M context) (default) and saved as your default for',
      '     new sessions',
    ].join('\n')
    expect(readModelConfirmation(wrapped)).toEqual({ name: 'Opus 5 (1M context) (default)', scope: 'default' })
  })
})

describe('effort from the CLI confirmation', () => {
  it('reads the level out of a wrapped confirmation', () => {
    const screen = [
      '❯ /effort xhigh',
      '  ⎿  Set effort level to xhigh (saved as your default for new sessions): Deeper',
      '     reasoning than high, just below maximum (Fable 5, Opus 4.7+, Sonnet 5)',
    ].join('\n')
    expect(readEffortFromScreen(screen)).toBe('xhigh')
  })

  it('is null when the session has not been told anything about effort', () => {
    expect(readEffortFromScreen(BYPASS)).toBeNull()
  })

  it('reads /effort auto, whose reply puts the words in the other order', () => {
    // `Effort level set to auto`, not `Set effort level to auto`. A pattern
    // built from the first wording alone never confirmed Auto, so picking it
    // timed out and reported a failure on a change that had been made.
    const screen = ['❯ /effort auto', '  ⎿  Effort level set to auto (this session only)'].join('\n')
    expect(readEffortFromScreen(screen)).toBe('auto')
    expect(readEffortConfirmation(screen)?.scope).toBe('session')
  })

  it('reads ultracode as session-only, which is the only thing it can be', () => {
    const screen = '  ⎿  Set effort level to ultracode (this session only): xhigh + dynamic workflow orchestration'
    expect(readEffortConfirmation(screen)).toEqual({ level: 'ultracode', scope: 'session' })
  })

  it('reads the saved-as-default arm when the CLI takes it', () => {
    const screen = '  ⎿  Set effort level to high (saved as your default for new sessions): Comprehensive'
    expect(readEffortConfirmation(screen)?.scope).toBe('default')
  })
})

describe('effort and fast mode from the settings the CLI itself writes', () => {
  it('treats ultracode as its own level, not as xhigh', () => {
    // This machine's real settings.json: { effortLevel: 'xhigh', ultracode: true }.
    expect(effortFromSettings({ effortLevel: 'xhigh', ultracode: true })).toEqual({
      value: 'ultracode',
      label: 'Ultracode',
      source: 'settings',
    })
  })

  it('reads a plain level', () => {
    expect(effortFromSettings({ effortLevel: 'medium' })).toEqual({
      value: 'medium',
      label: 'Medium',
      source: 'settings',
    })
  })

  it('is unknown when the file says nothing, rather than assuming a level', () => {
    expect(effortFromSettings({})).toEqual({ value: null, label: null, source: null })
  })

  it('will not call a missing fastMode key "off, from Claude settings"', () => {
    // `readClaudeSettings` returns {} for a missing file, an unreadable one and
    // a malformed one alike, and the shipped CLI does not write `fastMode`
    // here at all — so treating absence as "off" invented a value and then
    // credited it to a file. Unknown is the true answer.
    expect(fastFromSettings({})).toEqual({ value: null, label: null, source: null })
    expect(fastFromSettings({ fastMode: false })).toEqual({ value: 'off', label: 'Off', source: 'settings' })
    expect(fastFromSettings({ fastMode: true }).value).toBe('on')
  })
})

describe('fast mode from the screen', () => {
  it('keeps the CLI refusal instead of reporting a plain off', () => {
    const screen = [
      '❯ /fast on',
      '  ⎿  Fast mode unavailable: Fast mode requires usage credits · /usage-credits to',
      '     turn them on',
    ].join('\n')
    const reading = readFastFromScreen(screen)
    expect(reading?.value).toBe('off')
    expect(reading?.unavailableReason).toContain('requires usage credits')
  })

  it('is null when fast mode has never been mentioned', () => {
    expect(readFastFromScreen(BYPASS)).toBeNull()
  })
})

describe('command failures are surfaced verbatim', () => {
  it('reads the model rejection', () => {
    expect(readCommandError("  ⎿  Model 'nosuchmodel' not found")).toBe("Model 'nosuchmodel' not found")
  })

  it('reads the effort rejection, which lists the valid levels', () => {
    const screen = '  ⎿  Invalid argument: nosuchlevel. Valid options are: low, medium, high, xhigh,'
    expect(readCommandError(screen)).toContain('Valid options are: low, medium, high, xhigh')
  })

  it('reads the other three ways a model can be turned down', () => {
    // All three are in the shipped binary. Recognising only "not found" meant
    // the other refusals ran out the six-second timeout and were reported as
    // "the CLI has not answered yet", which is not what happened.
    expect(readCommandError("  ⎿  Model 'opus' is not in the list of available models")).toContain(
      'not in the list of available models',
    )
    expect(
      readCommandError("  ⎿  Model 'opus' is restricted by your organization's settings. Run /model to choose"),
    ).toContain('restricted by your organization')
    expect(readCommandError('  ⎿  Failed to validate model: network error')).toContain('Failed to validate model')
  })

  it('treats an effort change the environment overrides as a failure, not a success', () => {
    const screen =
      '  ⎿  Cleared effort from settings, but CLAUDE_CODE_EFFORT_LEVEL=max still controls this session'
    expect(readCommandError(screen)).toContain('still controls this session')
  })

  it('reads the organisation effort cap', () => {
    const screen = "  ⎿  Effort 'max' exceeds your organization's limit for claude-opus-5; set to 'high' instead"
    expect(readCommandError(screen)).toContain("exceeds your organization's limit")
  })

  it('reads the newest refusal on the screen, not the first pattern in the list', () => {
    // A session accumulates its refusals: the fast-mode one stays on screen for
    // the rest of the session. Ordering by the pattern list rather than by
    // position meant the oldest one kept being reported as the answer to
    // whatever was pressed last.
    const screen = [
      '  ⎿  Fast mode unavailable: Fast mode requires usage credits',
      '❯ /model nosuchmodel',
      "  ⎿  Model 'nosuchmodel' not found",
    ].join('\n')
    expect(readCommandError(screen)).toBe("Model 'nosuchmodel' not found")
  })

  it('counts them, so a control can tell its own refusal from a leftover', () => {
    const stale = '  ⎿  Fast mode unavailable: Fast mode requires usage credits'
    expect(countCommandErrors(stale)).toBe(1)
    expect(countCommandErrors(`${stale}\n  ⎿  Model 'nope' not found`)).toBe(2)
    expect(countCommandErrors('  ⎿  Set model to Sonnet 5')).toBe(0)
  })
})

describe('a refusal left on the screen is not blamed on the next control', () => {
  /**
   * Caught in the running app, in the window's own toolbar, in this order:
   * press Fast mode → On, be told "Fast mode requires usage credits" (correct,
   * and that line stays on the session's screen); then press Effort → Ultracode
   * and be told **"Fast mode unavailable: Fast mode requires usage credits"** by
   * the effort control, while the effort change had in fact gone through.
   *
   * The success side of this was already solved by counting confirmations. The
   * failure side was not, and it is the more damaging of the two: one refusal
   * poisoned every later change in that session, and the message named a
   * control the user had not touched.
   */
  it('reports the effort change rather than the old fast-mode refusal', async () => {
    const session = fakeClaude({
      history: ['❯ /fast on', '  ⎿  Fast mode unavailable: Fast mode requires usage credits'],
      respond: (line, cli) => {
        if (line === '/effort ultracode') {
          cli.print('  ⎿  Set effort level to ultracode (this session only): xhigh + dynamic workflows')
        }
      },
    })
    const result = await applyControl(
      session,
      { ...CLAUDE, sessionId: 's', control: 'effort', value: 'ultracode' },
      QUICK,
    )
    expect(result.ok).toBe(true)
    expect(result.message).not.toMatch(/fast/i)
    expect(result.message).toContain('Ultracode')
  })

  it('still reports a refusal this command actually caused', async () => {
    // The counting must not swallow a real one. `haiku` is a genuine alias, so
    // the request gets past the argument check and the fake refuses it the way
    // an account without access would.
    const refusing = fakeClaude({
      history: ['❯ /fast on', '  ⎿  Fast mode unavailable: Fast mode requires usage credits'],
      respond: (line, cli) => {
        if (line === '/model haiku') cli.print("  ⎿  Model 'haiku' not found")
      },
    })
    const result = await applyControl(refusing, { ...CLAUDE, sessionId: 's', control: 'model', value: 'haiku' }, QUICK)
    expect(result.ok).toBe(false)
    expect(result.message).toContain("Model 'haiku' not found")
  })
})

describe('model id labels', () => {
  it('keeps the 1M tag, which normalizeModelId strips', () => {
    expect(labelModelId('claude-opus-5[1m]')).toBe('Opus 5 · 1M')
  })

  it('reads a dated snapshot', () => {
    expect(labelModelId('claude-haiku-4-5-20251001')).toBe('Haiku 4.5')
  })

  it('passes an unrecognised id through rather than inventing a name', () => {
    expect(labelModelId('some-other-model')).toBe('some-other-model')
  })
})

/* -------------------------------------------------------------------------- */
/* Applying                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * A stand-in for the running CLI, modelled on how the real one behaved when it
 * was driven in a pty for this change.
 *
 * The previous version of this helper answered every `screen()` with a fixed
 * string and treated `'/plan\r'` as an atomic write. That is a model in which
 * the two bugs this file now pins **cannot happen**: it has no line editor, so
 * a draft cannot be appended to, and no dialog, so a return cannot be
 * swallowed by one. A test double that cannot express the failure is not a
 * weaker test, it is a test of something else.
 *
 * So this one has the three parts the real thing has and the old one did not:
 *
 *  - a **composer**, which printable writes append to and `\r` submits, exactly
 *    as a pty write reaches a line editor;
 *  - **ctrl+u**, which empties it, because that is the rollback the code uses;
 *  - a **modal dialog**, which draws over the composer and whose `\r` answers
 *    the dialog rather than running anything.
 *
 * The screen it renders is the shape the real one rendered: history above, a
 * rule, the `❯` composer, a rule, and the permission footer at the bottom.
 */
interface FakeClaude extends SessionAccess {
  typed: string[]
  submitted: string[]
  composer: string
  mode: string
  print(...lines: string[]): void
  ask(lines: string[], answer: () => void): void
}

const FOOTER_TEXT: Record<string, string> = {
  auto: '⏵⏵ auto mode on (shift+tab to cycle) · ← for agents',
  manual: '⏸ manual mode on · ? for shortcuts',
  acceptEdits: '⏵⏵ accept edits on (shift+tab to cycle) · ← for agents',
  plan: '⏸ plan mode on (shift+tab to cycle) · ← for agents',
  bypass: '⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents',
}

interface FakeOptions {
  mode?: string
  ring?: string[]
  /** Lines already in the scroll area, e.g. an exchange that has happened. */
  history?: string[]
  /** What the CLI does when a line is submitted. */
  respond?(line: string, session: FakeClaude): void
}

function fakeClaude(options: FakeOptions = {}): FakeClaude {
  const ring = options.ring ?? ['auto', 'manual', 'acceptEdits', 'plan', 'bypass']
  const history: string[] = [...(options.history ?? [])]
  let dialog: { lines: string[]; answer: () => void } | null = null

  const session: FakeClaude = {
    typed: [],
    submitted: [],
    composer: '',
    mode: options.mode ?? 'bypass',
    print(...lines: string[]): void {
      history.push(...lines)
    },
    ask(lines: string[], answer: () => void): void {
      dialog = { lines, answer }
    },
    write(_id: string, data: string): void {
      session.typed.push(data)
      if (data === '\x1b[Z') {
        const at = ring.indexOf(session.mode)
        session.mode = ring[(at + 1) % ring.length]
        return
      }
      if (data === '\x15') {
        session.composer = ''
        return
      }
      if (data === '\r') {
        // A dialog owns the keyboard. This is the behaviour that mattered: on
        // the real CLI a return arriving here picked the highlighted option,
        // and the command that "sent" it never ran at all.
        if (dialog !== null) {
          const open = dialog
          dialog = null
          open.answer()
          return
        }
        const line = session.composer
        session.composer = ''
        if (line === '') return
        session.submitted.push(line)
        history.push(`❯ ${line}`)
        options.respond?.(line, session)
        return
      }
      // Printable input. Swallowed while a dialog is up — which is what the
      // real one did, and why typing at a dialog is silent rather than loud.
      if (dialog !== null) return
      session.composer += data
    },
    async screen(): Promise<string | null> {
      if (dialog !== null) return [...history, ...dialog.lines].join('\n')
      return [
        ...history,
        '─────────────────────── Update Claude Code terminal to new version ──',
        `❯ ${session.composer}`,
        '──────────────────────────────────────────────────────────────────────',
        '',
        `  ${FOOTER_TEXT[session.mode]}`,
      ].join('\n')
    },
  }
  return session
}

/** The dialog the real CLI raised, transcribed off the screen it drew it on. */
function switchModelDialog(to: string): string[] {
  return [
    '▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔',
    '   Switch model?',
    '   Your next response will be slower and use more tokens',
    '',
    `   This conversation is cached for the current model. Switching to ${to} means the full`,
    '   history gets re-read on your next message.',
    '',
    `   ❯ 1. Yes, switch to ${to}`,
    '     2. No, go back',
  ]
}

/**
 * The same thing for effort, and it is a separate transcription rather than the
 * one above with a word swapped, because the assumption that effort was the
 * simple case is exactly what let this ship broken once. Driven at the real CLI
 * with `/effort ultracode` from `low`, verbatim.
 */
function changeEffortDialog(to: string): string[] {
  return [
    '▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔',
    '   Change effort level?',
    '   Your next response will be slower and use more tokens',
    '',
    `   This conversation is cached for the current effort level. Switching to ${to} means the full`,
    '   history gets re-read on your next message.',
    '',
    `   ❯ 1. Yes, switch to ${to}`,
    '     2. No, go back',
  ]
}

/** One exchange in the scroll area, so the session is not a fresh one. */
const USED = ['❯ say ok', '', '⏺ OK', '', '✻ Cooked for 1s']

const CLAUDE = { provider: 'claude' as const }

/**
 * Deadlines short enough that the give-up branches can be tested at all.
 *
 * The paths worth pinning hardest here are the ones that refuse — the CLI never
 * answered, the echo never arrived, the footer would not move — and each of
 * those sits out a full deadline in real time. At the shipped six seconds three
 * of these tests exceeded the default test timeout and the rest of the file
 * spent twenty seconds asleep. The numbers are policy, not behaviour, so they
 * are handed in; `applyControl` uses `SHIPPED_TIMINGS` when nobody does, which
 * is what the IPC handler relies on.
 */
const QUICK: ApplyTimings = { poll: 5, echo: 120, command: 400, cycleStep: 120 }

/* -------------------------------------------------- reading the composer -- */

/**
 * Who owns the keyboard, read off the real screens.
 *
 * Every fixture in this block is a transcription of a screen `claude 2.1.233`
 * drew in a pty on this machine while this was being written — including the
 * two that the old write path had no way of seeing, and walked straight into.
 */
describe('what the session is doing with its keyboard', () => {
  it('calls an empty prompt ready', () => {
    expect(readComposer(BYPASS)).toEqual({ kind: 'ready' })
  })

  it('sees a draft the user has not sent, which is the thing that must not be typed over', () => {
    // Verbatim: typing this at the real CLI and dumping the screen produced
    // exactly `❯ remind me to buy milk` between the two rules. A write of
    // `/model sonnet` here does not replace it — it appends to it.
    const screen = ['─────── Update Claude Code terminal to new version ──', '❯ remind me to buy milk', '──────', '', '  ⏵⏵ bypass permissions on (shift+tab to cycle)'].join('\n')
    expect(readComposer(screen)).toEqual({ kind: 'typing', text: 'remind me to buy milk' })
  })

  it('sees a modal choice, whose selected row wears the same glyph as the prompt', () => {
    const state = readComposer(switchModelDialog('Sonnet 5').join('\n'))
    expect(state.kind).toBe('choosing')
    // Not `typing` with the text "1. Yes, switch to Sonnet 5", which is what a
    // reader that only knew about `❯` would have said.
    if (state.kind === 'choosing') expect(state.asking).toContain('Yes, switch to Sonnet 5')
  })

  it('sees the trust prompt, which is the same shape and is up before anything else', () => {
    const trust = ['   ❯ 1. Yes, I trust this folder', '     2. No, exit', '', ' Enter to confirm · Esc to cancel'].join('\n')
    expect(readComposer(trust).kind).toBe('choosing')
  })

  it('sees a turn in flight from the counter the fullscreen TUI draws', () => {
    /*
     * The reason this is not `classify` from session-activity.ts.
     *
     * With `"tui": "fullscreen"` — what this machine runs — the in-flight line
     * is `✶ Dilly-dallying… (5s · ↓ 90 tokens)` and the string
     * `esc to interrupt` appears nowhere on the screen, while the composer sits
     * below it empty. `classify` reads that empty `❯` and answers `waiting`,
     * which was true of the prompt and false of the session.
     */
    const working = [
      '⏺ Sleeping for 25 seconds',
      '  ⎿  $ sleep 25',
      '',
      '✶ Dilly-dallying… (5s · ↓ 90 tokens)',
      '',
      '─────── Update Claude Code terminal to new version ──',
      '❯ ',
      '──────',
      '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents',
    ].join('\n')
    expect(readComposer(working).kind).toBe('working')
    expect(classify(working, false)).toBe('waiting')
  })

  it('sees the first frames of a turn, before the counter appears', () => {
    // `✶ Galloping… ` with nothing after it: the counter is only added a few
    // seconds in, so a reader built from the counter alone is blind for the
    // first stretch of every turn.
    const opening = ['⏺', '✶ Galloping… ', '  ⎿  Tip: Use /permissions to pre-approve', '❯ '].join('\n')
    expect(readComposer(opening).kind).toBe('working')
  })

  it('does not read the line a finished turn leaves behind as a running one', () => {
    /*
     * `✻ Baked for 6s · 1 shell still running` wears the same rotating glyph as
     * the in-flight line and stays on screen for the rest of the session. If it
     * counted as working, these controls would refuse for good the first time
     * the agent answered anything — a dead control produced by being careful.
     */
    for (const line of ['✻ Baked for 6s · 1 shell still running', '✻ Cogitated for 11s', '✻ Cooked for 1s']) {
      expect(readComposer([line, '❯ '].join('\n')), line).toEqual({ kind: 'ready' })
    }
  })

  it('does not read an ordinary bullet with an ellipsis in it as a running turn', () => {
    // `⏺` lines are the agent's own output and outlive the turn that wrote them.
    const bullet = ['⏺ Started sleep 20 in the background; I will report when it finishes…', '❯ '].join('\n')
    expect(readComposer(bullet)).toEqual({ kind: 'ready' })
  })

  it('still sees a turn in flight from the marker the default TUI draws', () => {
    const working = ['⏺ Reading agent-controls.ts…', '  ⎿  (esc to interrupt · 12s)', '❯ '].join('\n')
    expect(readComposer(working).kind).toBe('working')
  })

  it('does not mistake the finished-timing line for a turn still running', () => {
    // `✻ Cooked for 1s` is what the CLI leaves behind once it has answered, and
    // it stays on screen. Reading it as "working" would jam the controls shut
    // for the rest of the session.
    expect(readComposer([...USED, '❯ '].join('\n'))).toEqual({ kind: 'ready' })
  })

  it('reads the prompt at the bottom, not the first echo of a sent message', () => {
    // Every message already sent is echoed behind its own `❯` in the scroll
    // area. Taking the first one would report the oldest thing the user ever
    // typed as the text they are typing now.
    expect(readComposer([...USED, '❯ '].join('\n')).kind).toBe('ready')
  })

  it('says unknown rather than ready when there is no prompt at all', () => {
    expect(readComposer('apple@host tdprobe % ').kind).toBe('unknown')
  })
})

describe('the Switch model? dialog', () => {
  it('reads the model it is offering', () => {
    expect(readSwitchDialog(switchModelDialog('Sonnet 5').join('\n'))?.kind).toBe('model')
    expect(readSwitchDialog(switchModelDialog('Sonnet 5').join('\n'))?.target).toBe('Sonnet 5')
  })

  it('reads effort’s own version of it, which has a different heading', () => {
    // Found by driving it, after a first pass had assumed only the model could
    // raise one. Same shape, heading `Change effort level?`.
    const dialog = readSwitchDialog(changeEffortDialog('xhigh').join('\n'))
    expect(dialog?.kind).toBe('effort')
    expect(dialog?.target).toBe('xhigh')
  })

  it('is null when the cursor is on "No", because moving it would be a guess', () => {
    const onNo = switchModelDialog('Sonnet 5').map((line) =>
      line.includes('1. Yes') ? line.replace('❯ 1.', '  1.') : line.replace('     2.', '   ❯ 2.'),
    )
    expect(readSwitchDialog(onNo.join('\n'))).toBeNull()
  })

  it('is null for any other numbered dialog, however similar', () => {
    const permission = ['   Allow this command?', '   ❯ 1. Yes, allow', '     2. No'].join('\n')
    expect(readSwitchDialog(permission)).toBeNull()
  })
})

/* --------------------------------------------------------- typing safely -- */

describe('nothing is typed into a session that is not ready for it', () => {
  /*
   * **This used to assert that nothing was typed, and that is no longer the
   * rule.** A draft at the prompt was a refusal: the sheet opened onto a
   * paragraph saying *"clear the prompt and pick again"* instead of onto the
   * models. He rejected that:
   *
   * > *"they are also not control they are just descriptions which i dont want
   * > always"*
   *
   * So the draft is now lifted, the command is sent, and the draft is put back
   * — see `carryDraft`. What has not changed, and is the reason this test is
   * here at all, is the second assertion: **his sentence is exactly as he left
   * it**. It goes back unsent, never with a return, because a line read off a
   * screen can never be known to be byte-exact — `switch-later.ts` spends a
   * whole state on that same distinction.
   */
  it('lifts a draft out of the way, sends the command, and puts it back', async () => {
    const session = fakeClaude()
    session.composer = 'remind me to buy milk'
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)
    // The point of the whole exercise: their sentence is exactly as they left it.
    expect(session.composer).toBe('remind me to buy milk')
    // Kill the line, the command, the return, the line back — in that order.
    expect(session.typed).toEqual(['\x15', '/model sonnet', '\r', 'remind me to buy milk'])
    // And whatever became of the command, the message says what became of the
    // draft — the one thing he would otherwise have to go and look for.
    expect(result.message).toContain('Your draft is back at the prompt, unsent.')
  })

  it('will not press return at a session that is asking a question', async () => {
    // The failure that was found by driving it: a `\r` sent while a dialog is
    // up answers the dialog. Here that would mean silently accepting whatever
    // the agent was asking permission for.
    const session = fakeClaude()
    let answered = false
    session.ask(['   Allow this command?', '   ❯ 1. Yes, allow', '     2. No'], () => {
      answered = true
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'effort', value: 'low' }, QUICK)
    expect(result.ok).toBe(false)
    expect(answered).toBe(false)
    expect(session.typed).toEqual([])
  })

  it('will not fire into a turn that is still running', async () => {
    const session = fakeClaude({ history: ['✶ Dilly-dallying… (5s · ↓ 90 tokens)'] })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/mid-turn/i)
    expect(session.typed).toEqual([])
  })

  it('never sends the return until it has read its own command back off the screen', async () => {
    const session = fakeClaude({
      respond: (_line, cli) => cli.print('  ⎿  Set effort level to low (this session only): Quick'),
    })
    await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'effort', value: 'low' }, QUICK)
    // Two writes, in this order, and the second only after the first was seen.
    expect(session.typed).toEqual(['/effort low', '\r'])
    expect(session.submitted).toEqual(['/effort low'])
  })

  it('takes its own keystrokes back out when they do not appear', async () => {
    /*
     * A session that accepts writes but never shows them — a screen this app
     * cannot read is a screen it must not commit a return into. The rollback is
     * safe here and only here: the composer was checked empty first, so ctrl+u
     * can only be removing this app's own typing.
     */
    const deaf: SessionAccess = { write: () => {}, screen: async () => BYPASS }
    const written: string[] = []
    const session: SessionAccess = { write: (_id, data) => written.push(data), screen: deaf.screen }
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'effort', value: 'low' }, QUICK)
    expect(result.ok).toBe(false)
    expect(written).toEqual(['/effort low', '\x15'])
    expect(written).not.toContain('\r')
  })
})

/* ------------------------------------------------- which CLIs this speaks -- */

describe('a session this build cannot drive is not given controls that pretend', () => {
  it('refuses a shell outright', async () => {
    const session = fakeClaude()
    const result = await applyControl(session, { sessionId: 's', provider: 'shell', control: 'model', value: 'sonnet' }, QUICK)
    expect(result.ok).toBe(false)
    expect(session.typed).toEqual([])
  })

  it('refuses Codex and Gemini rather than typing Claude’s commands at them', async () => {
    for (const provider of ['codex', 'gemini']) {
      const session = fakeClaude()
      const result = await applyControl(session, { sessionId: 's', provider, control: 'model', value: 'sonnet' }, QUICK)
      expect(result.ok, provider).toBe(false)
      expect(session.typed, provider).toEqual([])
      expect(result.message.toLowerCase()).toContain(provider === 'codex' ? 'codex' : 'gemini')
    }
  })

  it('reports nothing about a Codex session rather than reading Claude’s settings at it', async () => {
    // The same class of bug one provider along: every fallback in `readControls`
    // is a Claude Code file, and they all answer confidently for a session that
    // has nothing to do with Claude.
    const session = fakeClaude()
    const reading = await readControls(session, 's', undefined, 'codex')
    for (const control of ['model', 'effort', 'fast', 'permission'] as const) {
      expect(reading[control].value, control).toBeNull()
      expect(reading[control].unavailableReason, control).toBeTruthy()
    }
  })

  it('lets an unnamed provider through only when the screen says Claude Code is there', async () => {
    // A session started as a shell that somebody has run `claude` inside. The
    // app never saw which CLI it was; the banner and the footer did.
    const running = fakeClaude()
    expect(refuseByProvider(undefined, { running: true, evidence: 'screen', saw: '╭─── Claude Code v2.1.233 ─╮' })).toBeNull()
    expect(refuseByProvider(undefined, NO_AGENT)).toBeTruthy()
    const result = await applyControl(running, { sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)
    // `fakeClaude`'s footer is Claude Code's, so the screen identifies it.
    expect(result.message).not.toMatch(/Claude Code is running/i)
  })
})

/* ------------------------------------------------ carrying a draft over -- */

/**
 * A draft that wrapped onto a second row.
 *
 * The CLI draws its command line between two rules, so a sentence longer than
 * the terminal is wide leaves a row underneath the pointer that carries no
 * pointer of its own — and `readComposer`, which reads exactly one row, would
 * report the first half of it as though it were the whole. Lifting that half
 * means ctrl+u destroying a half nobody read, which is the one outcome the
 * carrying path exists to make impossible. Hence `readCarry` looks under the
 * composer before it touches anything.
 */
const WRAPPED_DRAFT = [
  '─────────────────────────────────────────────────────────── ultracode ─',
  '❯ a sentence long enough that the terminal ran out of room and put the',
  'rest of it on the row underneath',
  '───────────────────────────────────────────────────────────────────────',
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
].join('\n')

/**
 * The composer with something in it that the *CLI* drew, not the person.
 *
 * There is no reading that tells these apart on sight — a hint, a placeholder,
 * the echo under a completion popup all look exactly like a draft to a screen
 * reader. What tells them apart is ctrl+u: a real draft goes, and this does not.
 * That is why `carryDraft` waits for the line to read back empty before it types
 * anything, and why this fixture is worth its own test.
 */
const CLI_DREW_IT = [
  '─────────────────────────────────────────────────────────── ultracode ─',
  '❯ Try "edit <filepath>"',
  '───────────────────────────────────────────────────────────────────────',
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
].join('\n')

describe('what this app may do with the far session’s command line', () => {
  it('is free to type when the prompt is empty', async () => {
    expect(readCarry((await fakeClaude().screen('s')) ?? '')).toEqual({ kind: 'clear' })
  })

  it('carries a draft it can read whole', async () => {
    const session = fakeClaude()
    session.composer = 'switch it to english'
    const screen = (await session.screen('s')) ?? ''
    expect(readCarry(screen)).toEqual({ kind: 'carry', draft: 'switch it to english' })
  })

  it('refuses a draft that runs past the row the pointer is on', () => {
    expect(readCarry(WRAPPED_DRAFT)).toEqual({
      kind: 'refuse',
      reason: 'A multi-line draft is sitting at this prompt.',
    })
  })

  it('refuses the three states where the keyboard belongs to something else', async () => {
    const busy = fakeClaude({ history: ['✶ Dilly-dallying… (5s · ↓ 90 tokens)'] })
    expect(readCarry((await busy.screen('s')) ?? '')).toEqual({
      kind: 'refuse',
      reason: 'This session is mid-turn.',
    })
    const asking = fakeClaude({ history: ['❯ 1. Yes, switch to Sonnet 5', '  2. No, go back'] })
    expect(readCarry((await asking.screen('s')) ?? '')).toEqual({
      kind: 'refuse',
      reason: 'This session is waiting on an answer on screen.',
    })
    expect(readCarry('nothing here looks like a command line')).toEqual({
      kind: 'refuse',
      reason: 'This session’s prompt is not on screen.',
    })
  })
})

/**
 * The whole of T9, driven end to end.
 *
 * His words, on tapping **Model** and getting a paragraph about unsent text
 * where the list of models should have been:
 *
 *   > *"they are also not control they are just descriptions which i dont want
 *   > always"*
 *
 * So the draft is the app's obstacle to move, not his. Each test below pins one
 * half of "move it and give it back": the command really ran, and the sentence
 * he typed is at the prompt afterwards, unsent, character for character.
 */
describe('a draft at the prompt is carried across the change', () => {
  it('lifts it, runs the command, and types it back unsent', async () => {
    const session = fakeClaude({
      respond: (line, cli) => {
        if (line === '/model sonnet') cli.print('  ⎿  Set model to Sonnet 5 for this session only')
      },
    })
    session.composer = 'switch it to english'

    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)

    expect(result.ok).toBe(true)
    expect(result.reading.label).toBe('Sonnet 5')
    // The command ran, and it ran alone: the draft was never part of the line.
    expect(session.submitted).toEqual(['/model sonnet'])
    // And it is back where he left it.
    expect(session.composer).toBe('switch it to english')
    expect(result.message).toContain('Your draft is back at the prompt, unsent.')
    // ctrl+u, the command, the return that commits it, the draft. No second
    // return: this copy of the line came off a screen, so it is never submitted.
    expect(session.typed).toEqual(['\x15', '/model sonnet', '\r', 'switch it to english'])
  })

  it('never presses return on the line it put back, even on a used session with a dialog', async () => {
    const session = fakeClaude({
      history: USED,
      respond: (line, cli) => {
        if (line !== '/model sonnet') return
        cli.ask(switchModelDialog('Sonnet 5'), () => cli.print('  ⎿  Set model to Sonnet 5 for this session only'))
      },
    })
    session.composer = 'switch it to english'

    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)

    expect(result.ok).toBe(true)
    expect(session.typed).toEqual(['\x15', '/model sonnet', '\r', '\r', 'switch it to english'])
    expect(session.submitted).toEqual(['/model sonnet'])
    expect(session.composer).toBe('switch it to english')
  })

  it('adds nothing of its own to the line — not even the space a submitted replay needs', async () => {
    /*
     * `replayWrites` puts a trailing space on a line containing an `@` so the
     * CLI's file-completion popup cannot eat the Enter. No Enter is coming here,
     * so that space would be a character he did not type sitting on the end of a
     * line he is being asked to check. Called with `submit` false for exactly
     * that reason, and this is the assertion that keeps it false.
     */
    const session = fakeClaude({
      respond: (line, cli) => {
        if (line === '/effort low') cli.print('  ⎿  Set effort level to low (this session only): Quick')
      },
    })
    session.composer = 'look at @src/main/agent-controls.ts'

    await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'effort', value: 'low' }, QUICK)

    expect(session.composer).toBe('look at @src/main/agent-controls.ts')
    expect(session.typed[session.typed.length - 1]).toBe('look at @src/main/agent-controls.ts')
  })

  it('carries one over the fast switch too, which is reached from the same sheet', async () => {
    /*
     * Off rather than on, and the reason is the fake rather than the feature:
     * `readFast` settles from the `↯` in the status rule above the composer, and
     * this fake draws that rule without one — so it can be driven to a truthful
     * "off" and never to a truthful "on". The draft is what this test is about
     * and it travels the same either way.
     */
    const session = fakeClaude({
      respond: (line, cli) => {
        if (line === '/fast off') cli.print('  ⎿  Fast mode OFF')
      },
    })
    session.composer = 'switch it to english'

    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'fast', value: 'off' }, QUICK)

    expect(result.ok).toBe(true)
    expect(session.submitted).toEqual(['/fast off'])
    expect(session.composer).toBe('switch it to english')
    expect(result.message).toContain('Your draft is back at the prompt, unsent.')
  })

  it('types nothing at all when the line will not clear, because it was never his', async () => {
    /*
     * The hazard the clear-confirmation exists for. A hint the CLI drew itself
     * reads as a draft to every screen reader in this file; ctrl+u does not
     * remove it; and without the wait, the next step would type the CLI's own
     * placeholder into his prompt as though he had written it.
     */
    const typed: string[] = []
    const stuck: SessionAccess = { write: (_id, data) => typed.push(data), screen: async () => CLI_DREW_IT }

    const result = await applyControl(stuck, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)

    expect(result.ok).toBe(false)
    expect(result.message).toContain('would not clear')
    // One harmless kill at a line that was already empty, and nothing else.
    expect(typed).toEqual(['\x15'])
  })

  it('still refuses a draft it cannot read whole, in the long words, having typed nothing', async () => {
    const typed: string[] = []
    const wrapped: SessionAccess = { write: (_id, data) => typed.push(data), screen: async () => WRAPPED_DRAFT }

    const result = await applyControl(wrapped, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)

    expect(result.ok).toBe(false)
    // `refuseToType`'s register, not `readCarry`'s: this is after a press, so
    // there is room to quote the draft and say what to do about it.
    expect(result.message).toContain('unsent text')
    expect(typed).toEqual([])
  })
})

/* ------------------------------------------- the gate, before the click -- */

/**
 * `readControls` says whether a control *could* be applied, and why not.
 *
 * The reason this is worth its own block: the same refusals were already
 * correct at write time, and the controls that consume them have moved into the
 * window's own chrome and onto a phone, where a picker that looks live and then
 * apologises is exactly the dead control this repository is audited for.
 *
 * Two properties are pinned here rather than one, and the second is new. The
 * gate must **open** on a draft, because `carryDraft` lifts it — that is T9, and
 * the test below is the one that fails if anybody puts the refusal back. And
 * every reason that does close it has to be one short line, because the sheet
 * draws it above a live control instead of in place of one; the long-form
 * wording still exists and is still `refuseToType`'s, but it is shown after a
 * press rather than before one.
 */
describe('whether a control could be applied at this session right now', () => {
  it('opens the gate on an empty prompt', async () => {
    const reading = await readControls(fakeClaude(), 's', undefined, 'claude')
    expect(reading.gate).toEqual({ canType: true, reason: null })
  })

  it('opens it on a draft too, because the draft gets carried', async () => {
    const session = fakeClaude()
    session.composer = 'switch it to english'
    const reading = await readControls(session, 's', undefined, 'claude')
    expect(reading.gate).toEqual({ canType: true, reason: null })
  })

  it('closes it mid-turn', async () => {
    const session = fakeClaude({ history: ['✶ Dilly-dallying… (5s · ↓ 90 tokens)'] })
    const reading = await readControls(session, 's', undefined, 'claude')
    expect(reading.gate.canType).toBe(false)
    expect(reading.gate.reason).toBe('This session is mid-turn.')
  })

  it('closes it while a numbered dialog owns the keyboard', async () => {
    const session = fakeClaude({ history: ['❯ 1. Yes, switch to Sonnet 5', '  2. No, go back'] })
    const reading = await readControls(session, 's', undefined, 'claude')
    expect(reading.gate.canType).toBe(false)
    expect(reading.gate.reason).toBe('This session is waiting on an answer on screen.')
  })

  it('closes it on a draft that runs past the row the pointer is on', async () => {
    const wrapped: SessionAccess = { write: () => {}, screen: async () => WRAPPED_DRAFT }
    const reading = await readControls(wrapped, 's', undefined, 'claude')
    expect(reading.gate.canType).toBe(false)
    expect(reading.gate.reason).toBe('A multi-line draft is sitting at this prompt.')
  })

  it('keeps every reason to one line, because the sheet draws it beside the rows', async () => {
    const screens: SessionAccess[] = [
      { write: () => {}, screen: async () => WRAPPED_DRAFT },
      fakeClaude({ history: ['✶ Dilly-dallying… (5s · ↓ 90 tokens)'] }),
      fakeClaude({ history: ['❯ 1. Yes, switch to Sonnet 5', '  2. No, go back'] }),
      { write: () => {}, screen: async () => 'nothing that looks like a prompt' },
    ]
    for (const access of screens) {
      const reason = (await readControls(access, 's', undefined, 'claude')).gate.reason
      expect(reason).not.toBeNull()
      // One sentence, no quoted draft, no instruction to go and do it by hand.
      expect((reason ?? '').length).toBeLessThanOrEqual(64)
      expect(reason).not.toContain('\n')
    }
  })

  it('says the session is gone rather than that it is busy, when there is no screen', async () => {
    const deaf: SessionAccess = { write: () => {}, screen: async () => null }
    const reading = await readControls(deaf, 's', undefined, 'claude')
    expect(reading.live).toBe(false)
    expect(reading.gate).toEqual({ canType: false, reason: 'That session is no longer running.' })
  })

  it('still reports the gate for a CLI this build cannot drive', async () => {
    // The provider refusal and the keyboard gate answer different questions, and
    // a renderer that draws one of them must not be handed `undefined` for the
    // other — an absent gate reads as "typing is fine" in every `?.` that
    // touches it.
    const reading = await readControls(fakeClaude(), 's', undefined, 'codex')
    expect(reading.gate.canType).toBe(true)
    expect(reading.model.unavailableReason).toBeTruthy()
  })
})

/* ---------------------------------------------------------------- model -- */

describe('changing the model', () => {
  it('types the slash command and reports the name the CLI confirmed', async () => {
    const session = fakeClaude({
      respond: (line, cli) => {
        if (line === '/model sonnet') cli.print('  ⎿  Set model to Sonnet 5 and saved as your default for new sessions')
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)
    expect(result.ok).toBe(true)
    expect(result.reading.label).toBe('Sonnet 5')
    expect(result.reading.source).toBe('screen')
  })

  it('answers the Switch model? dialog, which is what a used session actually does', async () => {
    /*
     * The defect this change exists for.
     *
     * On a session with any history, `/model sonnet` prints nothing and raises
     * this dialog. The old code waited six seconds for a confirmation that was
     * never coming, reported "the CLI has not answered yet — it may be
     * mid-turn", and left the dialog sitting on the user's terminal for their
     * next keystroke to answer.
     */
    const session = fakeClaude({
      history: USED,
      respond: (line, cli) => {
        if (line !== '/model sonnet') return
        cli.ask(switchModelDialog('Sonnet 5'), () =>
          cli.print('  ⎿  Set model to Sonnet 5 and saved as your default for new sessions'),
        )
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)
    expect(result.ok).toBe(true)
    expect(result.reading.label).toBe('Sonnet 5')
    // Typed the command, then the return that submitted it, then the return
    // that answered the dialog. Nothing else.
    expect(session.typed).toEqual(['/model sonnet', '\r', '\r'])
  })

  it('leaves a dialog it cannot read alone instead of pressing return at it', async () => {
    // Cursor on "No". Moving a selection this app can only partly see would be
    // guessing twice, so it stops and says the session is still asking.
    const session = fakeClaude({
      history: USED,
      respond: (line, cli) => {
        if (line !== '/model sonnet') return
        cli.ask(
          switchModelDialog('Sonnet 5').map((row) =>
            row.includes('1. Yes') ? row.replace('❯ 1.', '  1.') : row.replace('     2.', '   ❯ 2.'),
          ),
          () => cli.print('  ⎿  Set model to Sonnet 5 and saved as your default for new sessions'),
        )
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)
    expect(result.ok).toBe(false)
    expect(session.typed).toEqual(['/model sonnet', '\r'])
  })

  it('confirms a change to the model it is already on, instead of timing out', async () => {
    /*
     * Counting rather than comparing. The screen already holds
     * `Set model to Sonnet 5 …` from an earlier pick, so "has the name
     * changed?" is false for a command that did exactly what was asked.
     */
    const session = fakeClaude({
      history: ['  ⎿  Set model to Sonnet 5 and saved as your default for new sessions'],
      respond: (line, cli) => {
        if (line === '/model sonnet') cli.print('  ⎿  Set model to Sonnet 5 and saved as your default for new sessions')
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)
    expect(result.ok).toBe(true)
    expect(result.reading.label).toBe('Sonnet 5')
  })

  it('surfaces the CLI rejection rather than claiming success', async () => {
    const session = fakeClaude({
      respond: (_line, cli) => cli.print("  ⎿  Model 'sonnet' not found"),
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value: 'sonnet' }, QUICK)
    expect(result.ok).toBe(false)
    expect(result.message).toBe("Model 'sonnet' not found")
  })

  /*
   * This test used to assert the opposite, and the reversal is the point.
   *
   * It pinned a hand-written allow-list of five aliases: anything else was
   * refused here, before the CLI ever saw it, with a message blaming the model
   * rather than the list. That is exactly the staleness Asad found in the menu
   * the list was feeding — *"they are just very few, not all of them… there are
   * more models"* — and it is worse than a stale menu, because it means a model
   * released tomorrow is unreachable even by a user who knows its name.
   *
   * So the guard is now on the *shape* (`isTypeableModelValue`), and a name this
   * build has never heard of is sent and the CLI's own answer is shown. Driving
   * the real binary is what settled that this is safe rather than merely
   * permissive: `/model claude-opus-4-8` answered `Set model to Opus 4.8`,
   * `/model sonnet46` answered `Model 'sonnet46' not found`, and
   * `/model claude-mythos-5` answered `Mythos 5 isn't available for your account
   * yet` — three different real answers this app can print, where before it
   * printed one invented one.
   */
  it('sends a name it has never heard of and lets the CLI be the judge', async () => {
    const session = fakeClaude({
      respond: (line, cli) => {
        if (line === '/model claude-opus-4-8') cli.print('  ⎿  Set model to Opus 4.8 and saved as your default for new sessions')
      },
    })
    const result = await applyControl(
      session,
      { ...CLAUDE, sessionId: 's', control: 'model', value: 'claude-opus-4-8' },
      QUICK,
    )
    expect(result.ok).toBe(true)
    expect(result.reading.label).toBe('Opus 4.8')
  })

  /*
   * What the guard is actually for. This string is about to be typed into
   * somebody's terminal, so a value that would become a second argument, or
   * submit a line nobody wrote, must not reach the pty at all — and the check
   * has to happen before any byte is written, not after.
   */
  it('refuses a value that would not be a single argument, and types nothing', async () => {
    for (const value of ['sonnet 5', 'sonnet\rrm -rf ~', '/model sonnet']) {
      const session = fakeClaude()
      const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value }, QUICK)
      expect(result.ok, value).toBe(false)
      expect(session.typed, value).toEqual([])
    }
  })

  it('does not claim the change was saved when the CLI said session-only', async () => {
    const session = fakeClaude({
      respond: (line, cli) => {
        if (line === '/model haiku') cli.print('  ⎿  Set model to Haiku 4.5 for this session only')
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'model', value: 'haiku' }, QUICK)
    expect(result.ok).toBe(true)
    expect(result.reading.label).toBe('Haiku 4.5')
    expect(result.message).toMatch(/this session only/i)
    expect(result.message).not.toMatch(/default for new sessions/i)
  })
})

describe('changing effort', () => {
  it('confirms from the CLI reply and says the change also becomes the default', async () => {
    const session = fakeClaude({
      respond: (line, cli) => {
        if (line === '/effort medium') {
          cli.print('  ⎿  Set effort level to medium (saved as your default for new sessions): Balanced')
        }
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'effort', value: 'medium' }, QUICK)
    expect(result.ok).toBe(true)
    expect(result.reading.value).toBe('medium')
    expect(result.message).toMatch(/default for new sessions/i)
  })

  it('does not report a success off a confirmation that was already on screen', async () => {
    // Pick Low, then pick Low again. Without counting, the second pick is
    // satisfied by the first pick's line before the command has been parsed —
    // a success message for a keystroke that never reached the CLI.
    const session = fakeClaude({
      history: ['  ⎿  Set effort level to low (saved as your default for new sessions): Quick'],
      respond: () => {
        /* the CLI says nothing this time */
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'effort', value: 'low' }, QUICK)
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/has not answered/i)
  })

  it('answers the Change effort level? dialog, which /effort raises too', async () => {
    /*
     * The second half of the same defect. A first pass here handled the model's
     * dialog and left `/effort` on the old path, on the strength of one run in
     * which it had applied straight away. Driven against a live session it
     * raised its own — `Change effort level?` — and the picker reported "the
     * CLI has not answered yet" while leaving the dialog up.
     *
     * Note the name in the reply: `/effort ultracode` is confirmed as `xhigh`,
     * because ultracode is xhigh plus workflows. The dialog's target is
     * therefore reported, never matched against the request.
     */
    const session = fakeClaude({
      history: USED,
      respond: (line, cli) => {
        if (line !== '/effort ultracode') return
        cli.ask(changeEffortDialog('xhigh'), () =>
          cli.print('  ⎿  Set effort level to ultracode (this session only): xhigh + dynamic workflow orchestration'),
        )
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'effort', value: 'ultracode' }, QUICK)
    expect(result.ok).toBe(true)
    expect(result.reading.value).toBe('ultracode')
    expect(session.typed).toEqual(['/effort ultracode', '\r', '\r'])
  })

  it('will not answer the model dialog on behalf of an effort command', async () => {
    // The kind is checked, not just the shape. A dialog that is not the one
    // this command could have raised is somebody else's question.
    const session = fakeClaude({
      history: USED,
      respond: (line, cli) => {
        if (line === '/effort low') cli.ask(switchModelDialog('Sonnet 5'), () => cli.print('switched'))
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'effort', value: 'low' }, QUICK)
    expect(result.ok).toBe(false)
    expect(session.typed).toEqual(['/effort low', '\r'])
  })

  it('will not send a level the CLI does not accept', async () => {
    const session = fakeClaude()
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'effort', value: 'insane' }, QUICK)
    expect(result.ok).toBe(false)
    expect(session.typed).toEqual([])
  })

  it('confirms Auto, whose reply is worded backwards from every other level', async () => {
    const session = fakeClaude({
      respond: (line, cli) => {
        if (line === '/effort auto') cli.print('  ⎿  Effort level set to auto (this session only)')
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'effort', value: 'auto' }, QUICK)
    expect(result.ok).toBe(true)
    expect(result.reading.value).toBe('auto')
    expect(result.message).toMatch(/this session only/i)
    expect(result.message).not.toMatch(/default for new sessions/i)
  })
})

describe('changing fast mode', () => {
  it('reports the account restriction the CLI answered with', async () => {
    const session = fakeClaude({
      respond: (_line, cli) =>
        cli.print('  ⎿  Fast mode unavailable: Fast mode requires usage credits · /usage-credits to'),
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'fast', value: 'on' }, QUICK)
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/usage credits/i)
    expect(result.reading.unavailableReason).toBeTruthy()
  })
})

describe('changing the permission mode', () => {
  it('cycles to the requested mode and confirms it landed', async () => {
    const session = fakeClaude({ mode: 'bypass' })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'permission', value: 'acceptEdits' }, QUICK)
    expect(result.ok).toBe(true)
    expect(result.reading.value).toBe('acceptEdits')
    // bypass → auto → manual → acceptEdits: three presses, no more.
    expect(session.typed.filter((keys) => keys === '\x1b[Z')).toHaveLength(3)
  })

  it('uses /plan rather than cycling, because the CLI has a direct command for it', async () => {
    const session = fakeClaude({
      mode: 'bypass',
      respond: (line, cli) => {
        if (line === '/plan') cli.mode = 'plan'
      },
    })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'permission', value: 'plan' }, QUICK)
    expect(result.ok).toBe(true)
    expect(session.typed).toEqual(['/plan', '\r'])
  })

  it('does nothing when already in the requested mode', async () => {
    const session = fakeClaude({ mode: 'plan' })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'permission', value: 'plan' }, QUICK)
    expect(result.ok).toBe(true)
    expect(session.typed).toEqual([])
  })

  it('cycles even with a draft in the composer, and leaves the draft alone', async () => {
    /*
     * Measured, not assumed. Driven at the real CLI with
     * `a draft the user is still writing` unsent in the composer, one shift+tab
     * moved the footer from bypass to auto and left the draft character for
     * character. A chord never reaches the line editor, so refusing here would
     * withdraw a working control for a hazard that does not exist.
     *
     * The second half of this used to read "while `/plan`, which types, is
     * refused in the same state", and that is no longer true: `/plan` carries
     * the draft the way every other typed command now does. The two paths reach
     * the same place by different routes — the cycle never has to move the line,
     * and `/plan` lifts it and puts it back — so this asserts the outcome they
     * share, which is that his sentence is still at the prompt afterwards.
     */
    const session = fakeClaude({ mode: 'bypass' })
    session.composer = 'a draft the user is still writing'
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'permission', value: 'auto' }, QUICK)
    expect(result.ok).toBe(true)
    expect(session.composer).toBe('a draft the user is still writing')
    // Chords only: nothing was lifted because nothing was typed.
    expect(session.typed).not.toContain('\x15')

    const typedPlan = fakeClaude({
      mode: 'bypass',
      respond: (line, cli) => {
        if (line === '/plan') cli.mode = 'plan'
      },
    })
    typedPlan.composer = 'a draft the user is still writing'
    const planned = await applyControl(typedPlan, { ...CLAUDE, sessionId: 's', control: 'permission', value: 'plan' }, QUICK)
    expect(planned.ok).toBe(true)
    expect(typedPlan.submitted).toEqual(['/plan'])
    expect(typedPlan.composer).toBe('a draft the user is still writing')
    expect(planned.message).toContain('Your draft is back at the prompt, unsent.')
  })

  it('will not cycle while a dialog owns the keyboard', async () => {
    const session = fakeClaude({ mode: 'bypass' })
    session.ask(['   Allow this command?', '   ❯ 1. Yes, allow', '     2. No'], () => {})
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'permission', value: 'auto' }, QUICK)
    expect(result.ok).toBe(false)
    expect(session.typed).toEqual([])
  })

  it('refuses to press at all when the current mode cannot be read', async () => {
    const blind: SessionAccess = { write: () => {}, screen: async () => '❯ \n╭─── Claude Code v2.1.233 ─╮' }
    const result = await applyControl(blind, { ...CLAUDE, sessionId: 's', control: 'permission', value: 'auto' }, QUICK)
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/unknown/i)
    expect(result.reading.value).toBeNull()
  })

  it('still reaches plan when the footer is unreadable, because /plan names its destination', async () => {
    let screen = '╭─── Claude Code v2.1.233 ─╮\n❯ '
    const session: SessionAccess = {
      write: (_id, data) => {
        if (data === '/plan') screen = '╭─── Claude Code v2.1.233 ─╮\n❯ /plan'
        if (data === '\r') screen = PLAN
      },
      screen: async () => screen,
    }
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'permission', value: 'plan' }, QUICK)
    expect(result.ok).toBe(true)
    expect(result.reading.value).toBe('plan')
  })

  it('stops and says so when the ring does not contain the mode', async () => {
    // Policy can disable bypass; the stop then simply is not in the cycle.
    const session = fakeClaude({ mode: 'auto', ring: ['auto', 'manual', 'acceptEdits', 'plan'] })
    const result = await applyControl(session, { ...CLAUDE, sessionId: 's', control: 'permission', value: 'bypass' }, QUICK)
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/not available/i)
  })

  it('reports a dead session instead of writing into nothing', async () => {
    const gone: SessionAccess = { write: () => {}, screen: async () => null }
    const result = await applyControl(gone, { ...CLAUDE, sessionId: 's', control: 'permission', value: 'auto' }, QUICK)
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/no longer running/i)
  })
})

/* --------------------------------------------- where the model is read from -- */

/**
 * The model shown on the controls is read off the newest assistant line of the
 * project's live transcript, which is the strongest statement available: not a
 * setting or an intention, but the model that served the last reply.
 *
 * A session started from a paired device runs confined, with a `HOME` of its
 * own, so the CLI writes that transcript under the device's home rather than
 * under `~/.claude`. Reading only the profile's store answered "no model" for a
 * session that was answering — a control that does not know what it is
 * controlling.
 */
describe('reading the model from a confined session transcript', () => {
  const made: string[] = []

  afterAll(() => {
    for (const dir of made) rmSync(dir, { recursive: true, force: true })
  })

  function scratch(prefix: string): string {
    const dir = mkdtempSync(join(tmpdir(), prefix))
    made.push(dir)
    return dir
  }

  function assistant(model: string): string {
    return `${JSON.stringify({
      type: 'assistant',
      sessionId: 'sess-phone',
      timestamp: '2026-08-15T09:00:00.000Z',
      message: { role: 'assistant', model, usage: { input_tokens: 1, output_tokens: 1 } },
    })}\n`
  }

  const CWD = '/Users/apple/Projects/agent-controls-fixture'

  it('finds it in the device store the session actually wrote to', async () => {
    const homes = scratch('deck-controls-homes-')
    installDeviceHomes(homes)
    try {
      const store = join(homes, 'dev-a', '.claude', 'projects', encodeProjectPath(CWD))
      mkdirSync(store, { recursive: true })
      writeFileSync(join(store, 'sess-phone.jsonl'), assistant('claude-opus-5'))
      expect(await readModelFromTranscript(CWD)).toBe('claude-opus-5')
    } finally {
      resetDeviceHomes()
    }
  })

  it('answers null when no store holds anything for the project', async () => {
    resetDeviceHomes()
    expect(await readModelFromTranscript('/nowhere/at/all')).toBeNull()
  })

  it('steps over the CLI’s own <synthetic> lines to the model that served a reply', async () => {
    /*
     * Found in the audit of 2026-08-20, after an account switch that resumed a
     * conversation: the toolbar's Model chip read the placeholder itself where
     * the same session had read *Opus 5 · 1M* a moment before.
     *
     * Claude Code writes assistant lines of its own — interrupts, API errors and
     * the notices around a resume — stamped `"model": "<synthetic>"`. `cost.ts`
     * has known that since it was written; this reader did not, and returned
     * whichever assistant line happened to be newest.
     */
    const homes = scratch('deck-controls-synthetic-')
    installDeviceHomes(homes)
    try {
      const store = join(homes, 'dev-a', '.claude', 'projects', encodeProjectPath(CWD))
      mkdirSync(store, { recursive: true })
      writeFileSync(
        join(store, 'sess-phone.jsonl'),
        assistant('claude-opus-5[1m]') + assistant('<synthetic>') + assistant('<synthetic>'),
      )
      expect(await readModelFromTranscript(CWD)).toBe('claude-opus-5[1m]')
    } finally {
      resetDeviceHomes()
    }
  })

  it('answers null for a transcript that is nothing but synthetic lines', async () => {
    // Not a failure: the chain in `readControls` goes on to the CLI's welcome
    // panel and then to `settings.json`, both of which name a real model. A
    // placeholder returned here would be printed on the bar.
    const homes = scratch('deck-controls-synthetic-only-')
    installDeviceHomes(homes)
    try {
      const store = join(homes, 'dev-a', '.claude', 'projects', encodeProjectPath(CWD))
      mkdirSync(store, { recursive: true })
      writeFileSync(join(store, 'sess-phone.jsonl'), assistant('<synthetic>'))
      expect(await readModelFromTranscript(CWD)).toBeNull()
    } finally {
      resetDeviceHomes()
    }
  })
})

/**
 * Item 1 of NEXT-UPDATE.md: a session with no Claude in it must not wear
 * Claude's controls.
 *
 * The fixtures are transcriptions of screens this app's own headless terminal
 * produced while a real `claude 2.1.233` was driven inside a `/bin/zsh -l` pty
 * on this machine — the same route the app's session emulator takes. The one
 * that matters most is the last: the CLI had exited and the shell was back, and
 * *that* is the case a "did the user type claude?" test would get wrong.
 */
describe('is an agent in front of this session', () => {
  const SHELL_IDLE = 'apple@Asads-MacBook-Pro-21 tdprobe % '

  /** Straight off the capture, wrapping and all. */
  const CLAUDE_IDLE = [
    'apple@Asads-MacBook-Pro-21 tdprobe % claude',
    '╭─── Claude Code v2.1.233 ─────────────────────────────────────────────╮',
    '│                 Welcome back Asad!                                   │',
    '╰──────────────────────────────────────────────────────────────────────╯',
    '❯ ',
    '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
  ].join('\n')

  it('says nothing about a plain shell sitting at its prompt', () => {
    expect(readAgentFromScreen(SHELL_IDLE)).toBeNull()
  })

  it('sees the CLI on a screen it has drawn', () => {
    expect(readAgentFromScreen(CLAUDE_IDLE)).toContain('Claude Code v2.1.233')
  })

  it('still sees it once the banner has scrolled away', () => {
    // The banner is drawn once; the footer is redrawn continuously. A signal
    // that only knew the banner would answer "no agent" for every session more
    // than a screenful old.
    const footerOnly = ['❯ ', '  ⏵⏵ bypass permissions on (shift+tab to cycle)'].join('\n')
    expect(readAgentFromScreen(footerOnly)).toContain('bypass permissions on')
  })

  it('sees it while it is working, when the footer says so instead', () => {
    const working = ['⏺ Reading agent-controls.ts…', '  ⎿  (esc to interrupt · 12s)'].join('\n')
    expect(readAgentFromScreen(working)).toContain('esc to interrupt')
  })

  it('stops seeing it the moment the CLI exits and leaves the shell behind', () => {
    /*
     * The whole point. Claude Code clears the screen on a clean `/exit` —
     * captured, not assumed: the dump immediately after typing it held these
     * two lines and nothing else, with the session still very much alive. A
     * control row keyed off "the user typed claude" would still be showing an
     * account picker here.
     */
    const after = ['apple@Asads-MacBook-Pro-21 tdprobe % claude', 'apple@Asads-MacBook-Pro-21 tdprobe % '].join('\n')
    expect(readAgentFromScreen(after)).toBeNull()
  })

  it('is not fooled by the word claude in a shell prompt or a command', () => {
    // A pattern loose enough to match this would put an agent's controls on
    // every terminal that has ever mentioned one.
    const talking = [
      'apple@host ~/Projects/claude % git commit -m "run claude in plan mode"',
      '❯ claude --help | head',
    ].join('\n')
    expect(readAgentFromScreen(talking)).toBeNull()
  })

  it('needs the whole footer, not just the mode phrase', () => {
    // `readPermissionMode` matches `plan mode on` alone, which is right for
    // reading a mode off a screen already known to be the CLI's and far too
    // loose for deciding whether it is the CLI's at all.
    expect(readPermissionMode('plan mode on')).toBe('plan')
    expect(readAgentFromScreen('plan mode on')).toBeNull()
  })

  it('reports no evidence rather than "no agent" when there is no session', () => {
    // Null and false are different answers and the caller has to be able to
    // tell them apart — one is "there is no agent", the other is "nothing was
    // read", and only the second is fixed by looking again.
    expect(NO_AGENT).toEqual({ running: false, evidence: null, saw: null })
  })
})


/* --------------------------------------------- the mode the footer never says -- */

/**
 * The control that never resolved.
 *
 * Every other reading here has two sources. Permission had one — the footer —
 * and the footer only announces a mode at the moment it *changes*, because the
 * lines `readPermissionMode` matches are the confirmations the CLI prints on
 * entering one. So a session nobody had pressed shift+tab in had nothing on
 * screen to read, and the composer said `Unknown` for its entire life. Asad:
 * the model "eventually resolves", permission "never does".
 *
 * The names below are not invented and not taken from documentation. They are
 * what the shipped binary itself lists for `--permission-mode`:
 *
 *     (choices: "acceptEdits", "auto", "bypassPermissions", "manual",
 *      "dontAsk", "plan")
 *
 * and `permissions.defaultMode` on this machine is `bypassPermissions`, which
 * is one of them exactly.
 */
describe('readPermissionDefault', () => {
  const dirs: string[] = []

  function project(settings: unknown, local?: unknown): string {
    const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-perm-'))
    dirs.push(dir)
    mkdirSync(join(dir, '.claude'), { recursive: true })
    if (settings !== undefined) {
      writeFileSync(join(dir, '.claude', 'settings.json'), JSON.stringify(settings))
    }
    if (local !== undefined) {
      writeFileSync(join(dir, '.claude', 'settings.local.json'), JSON.stringify(local))
    }
    return dir
  }

  /**
   * The user's own `~/.claude/settings.json` is the last file in the chain, so
   * without isolating it every case below would fall through to whatever this
   * machine happens to have set — and on the machine this was written on that
   * is `bypassPermissions`, which quietly made two of these pass for the wrong
   * reason. `CLAUDE_CONFIG_DIR` is the same lever profiles use.
   */
  const realConfigDir = process.env.CLAUDE_CONFIG_DIR
  function withoutUserSettings(): string {
    const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-perm-home-'))
    dirs.push(dir)
    process.env.CLAUDE_CONFIG_DIR = dir
    return dir
  }

  afterAll(() => {
    if (realConfigDir === undefined) delete process.env.CLAUDE_CONFIG_DIR
    else process.env.CLAUDE_CONFIG_DIR = realConfigDir
    for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
  })

  it('reads every mode name the CLI itself accepts', async () => {
    withoutUserSettings()
    const expected: Array<[string, string]> = [
      ['acceptEdits', 'acceptEdits'],
      ['auto', 'auto'],
      ['bypassPermissions', 'bypass'],
      ['manual', 'manual'],
      ['plan', 'plan'],
    ]
    for (const [written, id] of expected) {
      const cwd = project({ permissions: { defaultMode: written } })
      const reading = await readPermissionDefault(cwd)
      expect(reading.value).toBe(id)
      // Named the way the picker names it, so the value on the button and the
      // ticked row in the menu are the same words.
      expect(reading.label).toBe(PERMISSION_MODES.find((mode) => mode.id === id)?.label)
      // And marked as an assumption from settings rather than a live read.
      expect(reading.source).toBe('settings')
    }
  })

  it('refuses to name a mode the app cannot also reach', async () => {
    withoutUserSettings()
    // `dontAsk` is accepted by the flag and never appears in the shift+tab
    // cycle, so it has no row in the picker. A value with no option to match it
    // is a control that cannot express what it is showing.
    const reading = await readPermissionDefault(project({ permissions: { defaultMode: 'dontAsk' } }))
    expect(reading.value).toBeNull()
  })

  it('refuses to guess at a name this build does not know', async () => {
    withoutUserSettings()
    const reading = await readPermissionDefault(
      project({ permissions: { defaultMode: 'somethingNew' } }),
    )
    expect(reading.value).toBeNull()
  })

  it('lets the local file win over the project one', async () => {
    withoutUserSettings()
    // Claude reads local over project over user, and stops at the first that
    // names a mode. A project default of plan is replaced, not merged.
    const cwd = project(
      { permissions: { defaultMode: 'plan' } },
      { permissions: { defaultMode: 'acceptEdits' } },
    )
    expect((await readPermissionDefault(cwd)).value).toBe('acceptEdits')
  })

  it('answers nothing when no file names a default', async () => {
    withoutUserSettings()
    const reading = await readPermissionDefault(project({ permissions: { allow: [] } }))
    // Which is the case `unreadLabel` prints "Not reported" for — not the CLI's
    // built-in default, because this app has not been told what that is and a
    // wrong permission mode on screen is the worst thing this panel could say.
    expect(reading.value).toBeNull()
    expect(reading.label).toBeNull()
  })

  it('falls back to the user’s own Claude settings when the project sets none', async () => {
    // The ordinary case on a real machine, and the one that turns "Unknown
    // forever" into an answer: this file is where `permissions.defaultMode`
    // normally lives.
    const home = withoutUserSettings()
    writeFileSync(
      join(home, 'settings.json'),
      JSON.stringify({ permissions: { defaultMode: 'bypassPermissions' } }),
    )
    const reading = await readPermissionDefault(project({}))
    expect(reading.value).toBe('bypass')
    expect(reading.source).toBe('settings')
  })
})

/**
 * The control cluster follows the session's own account, not the app's.
 *
 * ## The defect
 *
 * `readControls` reached `readClaudeSettings()` and `readPermissionDefault()`
 * with their default arguments, and both of those default to
 * `claudeConfigDir()` — the **app process's** `CLAUDE_CONFIG_DIR`, or
 * `~/.claude`. So on a machine with two logins the model, effort, fast-mode and
 * permission-mode fallbacks all described whichever account this app happened
 * to resolve, for every session alike, however many accounts were running. That
 * is the fifth surface in the set Asad listed beside the account chip, the usage
 * bar and the session's own limit notice:
 *
 *   > *"all of them are not about one logged in account, they should be all
 *   > aligned."*
 *
 * ## What is pinned
 *
 * Two real config directories on disk holding *different* settings, and one
 * `SessionAccess` that names one of them. Every assertion below is the reading
 * that comes back from the real `readControls`, so it fails if any one of the
 * four fallbacks is re-pointed at the process's own store — including a fifth
 * added later that forgets to ask, which is the shape of the original bug.
 */
describe('the controls read the account the session is running as', () => {
  const made: string[] = []
  const realConfigDir = process.env.CLAUDE_CONFIG_DIR

  function store(settings: Record<string, unknown>): string {
    const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-controls-store-'))
    made.push(dir)
    writeFileSync(join(dir, 'settings.json'), JSON.stringify(settings))
    return dir
  }

  afterAll(() => {
    if (realConfigDir === undefined) delete process.env.CLAUDE_CONFIG_DIR
    else process.env.CLAUDE_CONFIG_DIR = realConfigDir
    for (const dir of made) rmSync(dir, { recursive: true, force: true })
    resetDeviceHomes()
  })

  /**
   * A screen with an agent on it and nothing announced, so every fallback runs.
   *
   * Deliberately without the status rule above the composer. That rule is what
   * `readFastIndicator` reads fast mode off, and it answers from *any* rule it
   * finds — so with one here the fast row is settled by the screen and never
   * reaches the settings fallback these cases are about. No rule is a real
   * screen state (an older CLI, a mid-repaint frame) and it is the one in which
   * the file is the only source there is.
   */
  const QUIET = ['⏺ Claude Code', '❯'].join('\n')

  function access(configDir: string | null): SessionAccess {
    return {
      write: () => undefined,
      screen: () => Promise.resolve(QUIET),
      configDir: () => configDir,
    }
  }

  it('reads effort, fast mode and the permission default out of that account’s settings.json', async () => {
    resetDeviceHomes()
    // The app's own store says one thing…
    process.env.CLAUDE_CONFIG_DIR = store({
      effortLevel: 'low',
      fastMode: false,
      permissions: { defaultMode: 'plan' },
    })
    // …and the account this session is actually running as says another.
    const session = store({
      effortLevel: 'high',
      fastMode: true,
      permissions: { defaultMode: 'acceptEdits' },
    })

    const reading = await readControls(access(session), 's', undefined, 'claude')
    expect(reading.effort.value).toBe('high')
    expect(reading.effort.source).toBe('settings')
    expect(reading.fast.value).toBe('on')
    expect(reading.permission.value).toBe('acceptEdits')
  })

  it('falls back to the app’s own store when no account has been established', async () => {
    /*
     * The rule that keeps this from trading one wrong answer for another: an
     * account this app cannot name is *unknown*, and an unknown account must
     * keep the behaviour that shipped rather than be turned into a different
     * account. `establishedConfigDir` answers null while its probe is still
     * running, which is every first read of every session.
     */
    resetDeviceHomes()
    process.env.CLAUDE_CONFIG_DIR = store({ effortLevel: 'low', permissions: { defaultMode: 'plan' } })
    const reading = await readControls(access(null), 's', undefined, 'claude')
    expect(reading.effort.value).toBe('low')
    expect(reading.permission.value).toBe('plan')
  })

  it('is the same answer for a SessionAccess that cannot be asked at all', async () => {
    // `servers/ipc.ts` builds one over an SSH channel and its tests build one
    // by hand; neither can answer this, and `configDir` is optional for them.
    resetDeviceHomes()
    process.env.CLAUDE_CONFIG_DIR = store({ effortLevel: 'medium' })
    const bare: SessionAccess = { write: () => undefined, screen: () => Promise.resolve(QUIET) }
    expect((await readControls(bare, 's', undefined, 'claude')).effort.value).toBe('medium')
  })

  it('reads the model out of that account’s transcripts rather than the app’s', async () => {
    /*
     * The same fault one rung up the model chain. `transcriptDirs` puts the
     * *primary* store first and a session's own store is the primary one for
     * it — two accounts with the same project open each keep their own
     * conversation, so reading the app's store answers with the model of the
     * login you are not on.
     */
    resetDeviceHomes()
    const cwd = '/Users/apple/Projects/agent-controls-account-fixture'
    const mine = store({})
    const theirs = store({})
    process.env.CLAUDE_CONFIG_DIR = theirs
    for (const [dir, model] of [
      [mine, 'claude-sonnet-5'],
      [theirs, 'claude-opus-5'],
    ] as const) {
      const projects = join(dir, 'projects', encodeProjectPath(cwd))
      mkdirSync(projects, { recursive: true })
      writeFileSync(
        join(projects, 'sess.jsonl'),
        `${JSON.stringify({
          type: 'assistant',
          sessionId: 'sess',
          message: { role: 'assistant', model, usage: { input_tokens: 1, output_tokens: 1 } },
        })}\n`,
      )
    }

    expect(await readModelFromTranscript(cwd, mine)).toBe('claude-sonnet-5')
    expect((await readControls(access(mine), 's', cwd, 'claude')).model.value).toBe('claude-sonnet-5')
    // And unchanged for a caller that names no store.
    expect(await readModelFromTranscript(cwd)).toBe('claude-opus-5')
  })

  it('reports the failure reading from that account’s settings too', async () => {
    /*
     * `applyControl` re-reads after a change it could not confirm, and that
     * re-read is a file read. Answering it from another account's file is the
     * same wrong claim as the read path's, in the one place a person is already
     * being told something went wrong.
     */
    resetDeviceHomes()
    process.env.CLAUDE_CONFIG_DIR = store({ effortLevel: 'low' })
    const session = store({ effortLevel: 'xhigh' })
    const deaf: SessionAccess = {
      write: () => undefined,
      // An agent that is mid-turn: the composer is there, so the command is
      // typed, and nothing is ever printed back.
      screen: () => Promise.resolve(QUIET),
      configDir: () => session,
    }
    const result = await applyControl(
      deaf,
      { ...CLAUDE, sessionId: 's', control: 'effort', value: 'medium' },
      QUICK,
    )
    expect(result.ok).toBe(false)
    expect(result.reading.value).toBe('xhigh')
  })

  it('reads nothing at all for a session on another computer, whatever it says its store is', async () => {
    /*
     * `ControlScope` is checked *before* this — a shell on a server reads its
     * own files through that machine's copy of this module, and every path in
     * here describes this laptop. A store name arriving alongside
     * `onThisMachine: false` must not re-open the door that flag closes.
     */
    resetDeviceHomes()
    process.env.CLAUDE_CONFIG_DIR = store({ effortLevel: 'low' })
    const session = store({ effortLevel: 'xhigh', permissions: { defaultMode: 'plan' } })
    const reading = await readControls(access(session), 's', undefined, 'claude', {
      onThisMachine: false,
    })
    expect(reading.effort.value).toBeNull()
    expect(reading.permission.value).toBeNull()
  })
})
