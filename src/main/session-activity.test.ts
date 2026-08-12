import { describe, expect, it } from 'vitest'
import { classify, stripAnsi } from './session-activity'

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
})
