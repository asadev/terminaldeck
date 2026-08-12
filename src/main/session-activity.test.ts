import { describe, expect, it, vi } from 'vitest'
import { ActivityTracker, classify, stripAnsi } from './session-activity'

describe('stripAnsi', () => {
  it('removes colour codes', () => {
    expect(stripAnsi('\x1b[31mred\x1b[0m')).toBe('red')
  })

  it('removes OSC title sequences', () => {
    expect(stripAnsi('\x1b]0;my title\x07text')).toBe('text')
  })
})

describe('classify', () => {
  it('detects an agent actively working', () => {
    expect(classify('\x1b[2m✻ Thinking… (12s · esc to interrupt)\x1b[0m', false)).toBe('working')
  })

  it('detects an idle prompt box as waiting', () => {
    expect(classify('╭────────────╮\n│ >          │\n╰────────────╯', false)).toBe('waiting')
  })

  it('detects a yes/no question as needing input', () => {
    expect(classify('Do you want to proceed? (y/n)', false)).toBe('input')
  })

  it('detects a numbered choice as needing input', () => {
    expect(classify('Select an option:\n❯ 1. Yes\n  2. No', false)).toBe('input')
  })

  it('treats a shell prompt as waiting', () => {
    expect(classify('apple@Mac ~ % ', false)).toBe('waiting')
  })

  it('reports plain output as idle', () => {
    expect(classify('some build output here\ndone.', false)).toBe('idle')
  })

  it('lets exit override everything', () => {
    expect(classify('anything at all', true)).toBe('exited')
  })

  it('prefers a live spinner over a stale prompt box above it', () => {
    expect(classify('│ > │\n✻ Thinking… (3s · esc to interrupt)', false)).toBe('working')
  })

  /**
   * Regression: scanning the whole buffer left a session pinned to "needs
   * input" forever once any question had ever been asked. Caught against a
   * real PTY, where a completed command left the tab permanently blocked.
   */
  it('returns to waiting once an answered question scrolls above the prompt', () => {
    const tail = [
      '% echo "Do you want to continue? (y/n)"',
      'Do you want to continue? (y/n)',
      'apple@Mac ~ % ',
    ].join('\n')
    expect(classify(tail, false)).toBe('waiting')
  })

  it('still blocks when the question is the last thing on screen', () => {
    expect(classify('Writing files…\nDo you want to proceed? (y/n)', false)).toBe('input')
  })

  /**
   * Fixture captured from a real `claude` process rendered through a headless
   * terminal. Two assumptions failed against it: the prompt glyph is ❯ (U+276F),
   * not >, and a rule plus a permissions hint are drawn BELOW the prompt, so it
   * is never the last line on screen.
   */
  it('recognises a real idle Claude Code prompt as waiting', () => {
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
    expect(classify(screen, false)).toBe('waiting')
  })

  it('recognises the real trust-folder prompt as needing input', () => {
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
    expect(classify(screen, false)).toBe('input')
  })
})

describe('ActivityTracker', () => {
  /**
   * Regression: agent CLIs repaint via cursor positioning, so the end of the
   * byte stream is not the bottom of the screen. Scanning the raw stream left
   * Claude's visible "1. Yes / 2. No" prompt classified as idle in the real
   * app. The tracker feeds a headless terminal and reads its viewport instead.
   */
  it('classifies from the rendered screen, not the raw stream order', async () => {
    vi.useFakeTimers()
    const seen: string[] = []
    const tracker = new ActivityTracker('t', (_id, s) => seen.push(s), 80, 24)

    // Draw the prompt, then jump the cursor back to the top and overwrite a
    // line — so the question is on screen but is NOT at the end of the stream.
    tracker.push('\x1b[2J\x1b[H') // clear + home
    tracker.push('Accessing workspace:\r\n\r\n')
    tracker.push('\x1b[32m❯ 1. Yes, I trust this folder\x1b[0m\r\n')
    tracker.push('  2. No, exit\r\n')
    tracker.push('\x1b[1;1H\x1b[KAccessing workspace:') // repaint line 1 last

    await vi.advanceTimersByTimeAsync(1000)
    vi.useRealTimers()

    expect(seen.at(-1)).toBe('input')
    tracker.dispose()
  })

  it('reports exit as terminal state', () => {
    const seen: string[] = []
    const tracker = new ActivityTracker('t', (_id, s) => seen.push(s))
    tracker.push('hello')
    tracker.markExited()
    expect(seen.at(-1)).toBe('exited')
    tracker.dispose()
  })
})
