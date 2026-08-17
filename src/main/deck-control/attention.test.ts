import { describe, expect, it } from 'vitest'
import { attentionOf, byAttention, statusOf, type AttentionView } from './attention'
import { ActivityTracker, classify } from '../session-activity'
import type { SessionStatus } from '../../shared/types'

/**
 * The derivation, and the one thing it must not become.
 *
 * `attention` is worth having only if it is *not* a rename of `waiting`. The
 * tests that matter here therefore run the app's own classifier over screens
 * captured from real processes and assert what falls out the far end — because
 * the trap is not in the switch statement below, it is in the belief that a
 * session showing a prompt is a session asking for something.
 */

function view(over: Partial<Parameters<typeof attentionOf>[0]> = {}): AttentionView {
  return attentionOf({ status: 'idle', statusSince: 1_000, exitCode: null, now: 61_000, ...over })
}

describe('what each status means for a person', () => {
  it('calls an unanswered question blocked, and nothing else blocked', () => {
    expect(view({ status: 'input' }).attention).toBe('blocked')
    expect(view({ status: 'input' }).attentionReason).toBe('question-unanswered')

    const others: SessionStatus[] = ['idle', 'working', 'waiting', 'completed', 'exited']
    for (const status of others) {
      expect(view({ status, exitCode: status === 'exited' ? 0 : null }).attention).not.toBe('blocked')
    }
  })

  it('calls a session that is still producing output running', () => {
    expect(view({ status: 'working' })).toMatchObject({
      attention: 'running',
      attentionReason: 'output-streaming',
    })
  })

  it('separates the two ways of being quiet', () => {
    // Both are `quiet`, and they are not the same observation: one has a prompt
    // on screen and one has a screen nobody could read anything from.
    expect(view({ status: 'waiting' }).attentionReason).toBe('prompt-ready')
    expect(view({ status: 'idle' }).attentionReason).toBe('no-output')
    expect(view({ status: 'waiting' }).attention).toBe('quiet')
    expect(view({ status: 'idle' }).attention).toBe('quiet')
  })

  it('separates a clean exit from a crash, and calls both done', () => {
    expect(view({ status: 'exited', exitCode: 0 })).toMatchObject({
      attention: 'done',
      attentionReason: 'process-exited',
    })
    expect(view({ status: 'exited', exitCode: 137 })).toMatchObject({
      attention: 'done',
      attentionReason: 'process-failed',
    })
  })

  it('calls a finished turn done without calling the process dead', () => {
    expect(view({ status: 'completed' })).toMatchObject({
      attention: 'done',
      attentionReason: 'turn-finished',
      statusSource: 'screen',
    })
  })
})

describe('attention is not a rename of waiting — checked through the real classifier', () => {
  /**
   * The screen a login shell shows when nobody has touched it. `classify` reads
   * `%` at the end of the line and answers `waiting`, which is correct and means
   * nothing at all about whether a person is needed.
   *
   * This is the assertion the whole field gets wrong (`COPILOT-CAPABILITIES.md`
   * §2.1: blocked, idle and working sharing one badge). If somebody later maps
   * `waiting` to `blocked` because the word sounds like it, this goes red.
   */
  it('does not call a backgrounded shell blocked', () => {
    const status = classify('apple@Mac terminaldeck % ', false)
    expect(status).toBe('waiting')
    expect(view({ status }).attention).toBe('quiet')
  })

  /**
   * Fixture from a real `claude` process — the same one `session-activity.test.ts`
   * captured, including the two things that surprised it: the glyph is ❯ and the
   * prompt is not the last line.
   */
  it('does not call an idle Claude prompt blocked', () => {
    const screen = [
      '╰──────────────────────────────────────────────────────╯',
      '',
      '        ✦ ultracode · xhigh effort + dynamic workflows',
      '─────────────────────────────────────────── ultracode ─',
      '❯ ',
      '───────────────────────────────────────────────────────',
      '',
      '  ⏵⏵ bypass permissions on (shift+tab to cycle)',
    ].join('\n')
    const status = classify(screen, false)
    expect(status).toBe('waiting')
    expect(view({ status }).attention).toBe('quiet')
  })

  /** The real trust-folder prompt. This one genuinely is stopped on a person. */
  it('does call the real trust-folder prompt blocked', () => {
    const screen = [
      'Accessing workspace:',
      '',
      '/Users/apple/Projects/terminaldeck',
      '',
      'Claude Code will be able to read, edit, and execute files here.',
      '',
      '❯ 1. Yes, I trust this folder',
      '  2. No, exit',
      '',
      'Enter to confirm · Esc to cancel',
    ].join('\n')
    const status = classify(screen, false)
    expect(status).toBe('input')
    expect(view({ status }).attention).toBe('blocked')
  })

  /**
   * End to end through the real emulator, not just the pure classifier.
   *
   * `ActivityTracker` is what actually produces the status the copilot sees: it
   * writes the bytes into a headless xterm, waits for them to settle and reads
   * the viewport. Feeding it a repainting TUI — a question drawn, then the
   * screen cleared and a prompt drawn over it — is the case where reading the
   * byte stream and reading the screen give different answers.
   */
  it('follows the screen, not the byte stream, before deciding nobody is blocked', async () => {
    const seen: SessionStatus[] = []
    const tracker = new ActivityTracker('s1', (_id, status) => seen.push(status), 60, 8)

    tracker.push('Do you want to proceed? (y/n)')
    // The agent answers itself and repaints: clear screen, home the cursor,
    // draw a ready prompt. The question is still earlier in the *stream*.
    tracker.push('\x1b[2J\x1b[H❯ \n')

    const status = classify(await tracker.settledText(), false)
    expect(status).toBe('waiting')
    expect(view({ status }).attention).toBe('quiet')
    tracker.dispose()
  })
})

describe('how long, and how we know', () => {
  it('measures from the last status change', () => {
    expect(view({ status: 'input', statusSince: 1_000, now: 61_000 }).attentionForMs).toBe(60_000)
  })

  it('clamps a clock that moved backwards rather than reporting negative time', () => {
    expect(view({ status: 'input', statusSince: 90_000, now: 61_000 }).attentionForMs).toBe(0)
  })

  /**
   * The number that would have been confidently wrong.
   *
   * An exited session has no live-status entry — `onExit` deletes it in the same
   * turn the tracker writes it — so nothing knows when it ended. Falling back to
   * `createdAt` would report a session that died a minute ago as having been
   * finished for however long it ran, which is the kind of number a model
   * repeats in a sentence to somebody.
   */
  it('says null rather than guessing when nothing recorded the moment', () => {
    expect(view({ status: 'exited', exitCode: 0, statusSince: null }).attentionForMs).toBeNull()
    expect(view({ status: 'exited', exitCode: 0, statusSince: null }).attention).toBe('done')
  })

  it('says an exited session is known from its exit code, not from its screen', () => {
    expect(view({ status: 'exited', exitCode: 0 }).statusSource).toBe('exit-code')
    expect(view({ status: 'working' }).statusSource).toBe('screen')
  })

  /**
   * There is no `hook` source, and that is a statement about the app rather
   * than about this file: `hooks.ts` exports `EVENT_STATUS`, nothing imports it,
   * and `registerHookServer` is wired with no `onEvent` listener. Reporting a
   * hook-sourced status today would be a lie about where the answer came from.
   */
  it('reports only the two sources that exist', () => {
    const sources = new Set<string>()
    const statuses: SessionStatus[] = ['idle', 'working', 'waiting', 'input', 'completed', 'exited']
    for (const status of statuses) {
      sources.add(view({ status, exitCode: status === 'exited' ? 0 : null }).statusSource)
    }
    expect([...sources].sort()).toEqual(['exit-code', 'screen'])
  })
})

describe('the status a dead session is reported as', () => {
  it('lets the exit code beat a stale classification', () => {
    // The tracker's last word was `working`; the process has since died. A dead
    // session reading as working is the answer "how is that session doing" must
    // never give.
    expect(statusOf(0, 'working')).toBe('exited')
    expect(statusOf(null, 'working')).toBe('working')
    expect(statusOf(null, null)).toBe('idle')
  })
})

describe('triage order', () => {
  it('puts the blocked first, then the finished, then the quiet, then the busy', () => {
    const running = view({ status: 'working' })
    const quiet = view({ status: 'idle' })
    const done = view({ status: 'exited', exitCode: 1 })
    const blocked = view({ status: 'input' })

    expect([running, quiet, done, blocked].sort(byAttention).map((entry) => entry.attention)).toEqual([
      'blocked',
      'done',
      'quiet',
      'running',
    ])
  })

  it('puts the longest-blocked first inside a bucket', () => {
    const recent = view({ status: 'input', statusSince: 60_000, now: 61_000 })
    const ancient = view({ status: 'input', statusSince: 1_000, now: 61_000 })
    expect([recent, ancient].sort(byAttention)).toEqual([ancient, recent])
  })

  it('sorts an unknown duration last in its bucket, not first', () => {
    // "We do not know how long" is not a claim of urgency. Treating null as a
    // large number would put every exited session above one blocked for an hour.
    const unknown = view({ status: 'exited', exitCode: 0, statusSince: null })
    const known = view({ status: 'exited', exitCode: 0, statusSince: 1_000, now: 61_000 })
    expect([unknown, known].sort(byAttention)).toEqual([known, unknown])
  })
})
