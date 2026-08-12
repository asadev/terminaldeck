import { describe, expect, it } from 'vitest'
import {
  applyControl,
  effortFromSettings,
  fastFromSettings,
  labelModelId,
  PERMISSION_MODES,
  readCommandError,
  readEffortConfirmation,
  readEffortFromScreen,
  readFastFromScreen,
  readModelConfirmation,
  readModelFromScreen,
  readPermissionMode,
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
 * A session that behaves like the real one: shift+tab advances the footer
 * through the ring that was actually observed, and anything else is ignored.
 */
function fakeSession(start: string, ring = ['auto', 'manual', 'acceptEdits', 'plan', 'bypass']): SessionAccess & {
  typed: string[]
  mode: string
} {
  const byId: Record<string, string> = {
    auto: AUTO,
    manual: MANUAL,
    acceptEdits: ACCEPT_EDITS,
    plan: PLAN,
    bypass: BYPASS,
  }
  const state = {
    typed: [] as string[],
    mode: start,
    write(_id: string, data: string): void {
      state.typed.push(data)
      if (data === '\x1b[Z') {
        const at = ring.indexOf(state.mode)
        state.mode = ring[(at + 1) % ring.length]
      } else if (data === '/plan\r') {
        state.mode = 'plan'
      }
    },
    async screen(): Promise<string | null> {
      return byId[state.mode]
    },
  }
  return state
}

describe('changing the permission mode', () => {
  it('cycles to the requested mode and confirms it landed', async () => {
    const session = fakeSession('bypass')
    const result = await applyControl(session, { sessionId: 's', control: 'permission', value: 'acceptEdits' })
    expect(result.ok).toBe(true)
    expect(result.reading.value).toBe('acceptEdits')
    // bypass → auto → manual → acceptEdits: three presses, no more.
    expect(session.typed.filter((keys) => keys === '\x1b[Z')).toHaveLength(3)
  })

  it('uses /plan rather than cycling, because the CLI has a direct command for it', async () => {
    const session = fakeSession('bypass')
    const result = await applyControl(session, { sessionId: 's', control: 'permission', value: 'plan' })
    expect(result.ok).toBe(true)
    expect(session.typed).toEqual(['/plan\r'])
  })

  it('does nothing when already in the requested mode', async () => {
    const session = fakeSession('plan')
    const result = await applyControl(session, { sessionId: 's', control: 'permission', value: 'plan' })
    expect(result.ok).toBe(true)
    expect(session.typed).toEqual([])
  })

  it('refuses to press at all when the current mode cannot be read', async () => {
    const blind: SessionAccess = { write: () => {}, screen: async () => '❯ nothing to go on' }
    const result = await applyControl(blind, { sessionId: 's', control: 'permission', value: 'auto' })
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/unknown/i)
    expect(result.reading.value).toBeNull()
  })

  it('still reaches plan when the footer is unreadable, because /plan names its destination', async () => {
    let screen = '❯ nothing to go on'
    const session: SessionAccess = {
      write: (_id, data) => {
        if (data === '/plan\r') screen = PLAN
      },
      screen: async () => screen,
    }
    const result = await applyControl(session, { sessionId: 's', control: 'permission', value: 'plan' })
    expect(result.ok).toBe(true)
    expect(result.reading.value).toBe('plan')
  })

  it('stops and says so when the ring does not contain the mode', async () => {
    // Policy can disable bypass; the stop then simply is not in the cycle.
    const session = fakeSession('auto', ['auto', 'manual', 'acceptEdits', 'plan'])
    const result = await applyControl(session, { sessionId: 's', control: 'permission', value: 'bypass' })
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/not available/i)
  })

  it('reports a dead session instead of writing into nothing', async () => {
    const gone: SessionAccess = { write: () => {}, screen: async () => null }
    const result = await applyControl(gone, { sessionId: 's', control: 'permission', value: 'auto' })
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/no longer running/i)
  })
})

describe('changing the model', () => {
  it('types the slash command and reports the name the CLI confirmed', async () => {
    let screen = BYPASS
    const session: SessionAccess = {
      write: (_id, data) => {
        if (data === '/model sonnet\r') {
          screen = `${BYPASS}\n  ⎿  Set model to Sonnet 5 and saved as your default for new sessions`
        }
      },
      screen: async () => screen,
    }
    const result = await applyControl(session, { sessionId: 's', control: 'model', value: 'sonnet' })
    expect(result.ok).toBe(true)
    expect(result.reading.label).toBe('Sonnet 5')
    expect(result.reading.source).toBe('screen')
  })

  it('surfaces the CLI rejection rather than claiming success', async () => {
    let screen = BYPASS
    const session: SessionAccess = {
      write: () => {
        screen = `${BYPASS}\n  ⎿  Model 'sonnet' not found`
      },
      screen: async () => screen,
    }
    const result = await applyControl(session, { sessionId: 's', control: 'model', value: 'sonnet' })
    expect(result.ok).toBe(false)
    expect(result.message).toBe("Model 'sonnet' not found")
  })

  it('will not send an alias the CLI does not accept', async () => {
    const session = fakeSession('bypass')
    const result = await applyControl(session, { sessionId: 's', control: 'model', value: 'gpt-5' })
    expect(result.ok).toBe(false)
    expect(session.typed).toEqual([])
  })

  it('does not claim the change was saved when the CLI said session-only', async () => {
    let screen = BYPASS
    const session: SessionAccess = {
      write: (_id, data) => {
        if (data === '/model haiku\r') screen = `${BYPASS}\n  ⎿  Set model to Haiku 4.5 for this session only`
      },
      screen: async () => screen,
    }
    const result = await applyControl(session, { sessionId: 's', control: 'model', value: 'haiku' })
    expect(result.ok).toBe(true)
    expect(result.reading.label).toBe('Haiku 4.5')
    expect(result.message).toMatch(/this session only/i)
    expect(result.message).not.toMatch(/default for new sessions/i)
  })
})

describe('changing effort', () => {
  it('confirms from the CLI reply and says the change also becomes the default', async () => {
    let screen = BYPASS
    const session: SessionAccess = {
      write: (_id, data) => {
        if (data === '/effort medium\r') {
          screen = `${BYPASS}\n  ⎿  Set effort level to medium (saved as your default for new sessions): Balanced`
        }
      },
      screen: async () => screen,
    }
    const result = await applyControl(session, { sessionId: 's', control: 'effort', value: 'medium' })
    expect(result.ok).toBe(true)
    expect(result.reading.value).toBe('medium')
    expect(result.message).toMatch(/default for new sessions/i)
  })

  it('will not send a level the CLI does not accept', async () => {
    const session = fakeSession('bypass')
    const result = await applyControl(session, { sessionId: 's', control: 'effort', value: 'insane' })
    expect(result.ok).toBe(false)
    expect(session.typed).toEqual([])
  })

  it('confirms Auto, whose reply is worded backwards from every other level', async () => {
    let screen = BYPASS
    const session: SessionAccess = {
      write: (_id, data) => {
        if (data === '/effort auto\r') screen = `${BYPASS}\n  ⎿  Effort level set to auto (this session only)`
      },
      screen: async () => screen,
    }
    const result = await applyControl(session, { sessionId: 's', control: 'effort', value: 'auto' })
    expect(result.ok).toBe(true)
    expect(result.reading.value).toBe('auto')
    expect(result.message).toMatch(/this session only/i)
    expect(result.message).not.toMatch(/default for new sessions/i)
  })
})

describe('changing fast mode', () => {
  it('reports the account restriction the CLI answered with', async () => {
    let screen = BYPASS
    const session: SessionAccess = {
      write: () => {
        screen = `${BYPASS}\n  ⎿  Fast mode unavailable: Fast mode requires usage credits · /usage-credits to`
      },
      screen: async () => screen,
    }
    const result = await applyControl(session, { sessionId: 's', control: 'fast', value: 'on' })
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/usage credits/i)
    expect(result.reading.unavailableReason).toBeTruthy()
  })
})
