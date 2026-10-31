import { beforeEach, describe, expect, it, vi } from 'vitest'
import { isMeaningfulOutput, UnreadTracker, type UnreadSnapshot } from './unread'

describe('isMeaningfulOutput', () => {
  it('accepts ordinary text', () => {
    expect(isMeaningfulOutput('Done. 3 files changed.\n')).toBe(true)
  })

  it('rejects an empty chunk', () => {
    expect(isMeaningfulOutput('')).toBe(false)
  })

  it('rejects whitespace, including the carriage returns TUIs repaint with', () => {
    expect(isMeaningfulOutput('  \r\n\t ')).toBe(false)
  })

  it('rejects a chunk that is only cursor movement and colour', () => {
    expect(isMeaningfulOutput('\x1b[2K\x1b[1G\x1b[32m\x1b[0m')).toBe(false)
  })

  it('rejects a bare spinner frame', () => {
    // Agent CLIs redraw these several times a second; counting them would
    // leave every running session permanently badged.
    expect(isMeaningfulOutput('\x1b[2K\r⠹ ')).toBe(false)
    expect(isMeaningfulOutput('⠋⠙⠹⠸')).toBe(false)
  })

  it('accepts a spinner frame that carries text with it', () => {
    expect(isMeaningfulOutput('⠹ Thinking about the parser')).toBe(true)
  })

  it('accepts the prompt glyph, which is a real change of state', () => {
    expect(isMeaningfulOutput('\x1b[32m❯ \x1b[0m')).toBe(true)
  })

  // REGRESSION: a control byte is not something a human reads, but only the
  // ones inside a *complete* escape sequence were being dropped, so each of
  // these lit the badge on its own.
  it('rejects a chunk of bare control bytes', () => {
    expect(isMeaningfulOutput('\x07')).toBe(false) // BEL: a failed completion
    expect(isMeaningfulOutput('\b\b\b')).toBe(false) // a TUI walking its cursor back
    expect(isMeaningfulOutput('\x1b')).toBe(false) // a lone escape
    expect(isMeaningfulOutput('\x00\x01\x02')).toBe(false)
  })

  // REGRESSION: a PTY read ends wherever the kernel buffer did, so one spinner
  // repaint arrives often enough as '\x1b[2' + 'K\r⠸ '. `stripAnsi` only
  // removes complete sequences, so the first half read as the printable text
  // '[2' and badged a tab that had produced nothing.
  it('rejects a chunk cut off mid-escape-sequence', () => {
    expect(isMeaningfulOutput('\x1b[2')).toBe(false)
    expect(isMeaningfulOutput('\x1b[38;5;')).toBe(false)
    expect(isMeaningfulOutput('\x1b]0;claude')).toBe(false)
  })

  it('still sees the text in a chunk that merely ends mid-escape', () => {
    // Only the dangling tail is dropped — everything before it is real output.
    expect(isMeaningfulOutput('Done. 3 files changed.\n\x1b[2')).toBe(true)
  })
})

describe('UnreadTracker', () => {
  let clock: number
  let tracker: UnreadTracker

  beforeEach(() => {
    clock = 1_000
    tracker = new UnreadTracker({
      now: () => clock,
      viewing: { activeSessionId: 'a', windowFocused: true },
    })
  })

  it('marks a background session that produces output', () => {
    expect(tracker.recordOutput('b', 'compiled ok\n')).toBe(true)
    expect(tracker.isUnread('b')).toBe(true)
    expect(tracker.count()).toBe(1)
  })

  it('does not mark the session the user is watching', () => {
    expect(tracker.recordOutput('a', 'compiled ok\n')).toBe(false)
    expect(tracker.isUnread('a')).toBe(false)
  })

  it('marks the active session when the window is not focused', () => {
    tracker.setViewing({ activeSessionId: 'a', windowFocused: false })
    expect(tracker.recordOutput('a', 'compiled ok\n')).toBe(true)
  })

  it('ignores repaint noise', () => {
    expect(tracker.recordOutput('b', '\x1b[2K\r⠸ ')).toBe(false)
    expect(tracker.isUnread('b')).toBe(false)
  })

  it('ignores a repaint that the chunk boundary split in half', () => {
    // The leading half of '\x1b[2K\r⠸ ', which used to badge the tab.
    expect(tracker.recordOutput('b', '\x1b[2')).toBe(false)
    expect(tracker.isUnread('b')).toBe(false)
  })

  it('skips the noise filter when the caller has no bytes to offer', () => {
    expect(tracker.recordOutput('b')).toBe(true)
  })

  it('reports only the first mark as a change', () => {
    expect(tracker.recordOutput('b', 'one')).toBe(true)
    expect(tracker.recordOutput('b', 'two')).toBe(false)
    expect(tracker.count()).toBe(1)
  })

  it('clears when the user switches to the session', () => {
    tracker.recordOutput('b', 'output')
    tracker.setViewing({ activeSessionId: 'b', windowFocused: true })
    expect(tracker.isUnread('b')).toBe(false)
  })

  it('clears the session already on screen when the window regains focus', () => {
    tracker.setViewing({ activeSessionId: 'a', windowFocused: false })
    tracker.recordOutput('a', 'output while away')
    expect(tracker.isUnread('a')).toBe(true)

    tracker.setViewing({ activeSessionId: 'a', windowFocused: true })
    expect(tracker.isUnread('a')).toBe(false)
  })

  it('clears nothing when the window merely loses focus', () => {
    tracker.recordOutput('b', 'output')
    tracker.setViewing({ activeSessionId: 'a', windowFocused: false })
    expect(tracker.isUnread('b')).toBe(true)
  })

  it('clears nothing when there is no active session at all', () => {
    tracker.recordOutput('b', 'output')
    tracker.setViewing({ activeSessionId: null, windowFocused: true })
    expect(tracker.isUnread('b')).toBe(true)
  })

  it('marks a session again after it has been read', () => {
    tracker.recordOutput('b', 'first')
    tracker.setViewing({ activeSessionId: 'b', windowFocused: true })
    tracker.setViewing({ activeSessionId: 'a', windowFocused: true })

    expect(tracker.recordOutput('b', 'second')).toBe(true)
    expect(tracker.isUnread('b')).toBe(true)
  })

  it('keeps ids in the order they were marked', () => {
    tracker.recordOutput('c', 'x')
    tracker.recordOutput('b', 'x')
    tracker.recordOutput('d', 'x')
    expect(tracker.ids()).toEqual(['c', 'b', 'd'])
  })

  it('records when a session was marked, and forgets on read', () => {
    clock = 5_000
    tracker.recordOutput('b', 'x')
    expect(tracker.markedAt('b')).toBe(5_000)

    tracker.markRead('b')
    expect(tracker.markedAt('b')).toBeNull()
  })

  it('rolls up across a project', () => {
    tracker.recordOutput('b', 'x')
    expect(tracker.hasAnyOf(['a', 'b'])).toBe(true)
    expect(tracker.hasAnyOf(['a', 'z'])).toBe(false)
    expect(tracker.hasAnyOf([])).toBe(false)
  })

  it('drops a closed session', () => {
    tracker.recordOutput('b', 'x')
    tracker.forget('b')
    expect(tracker.isUnread('b')).toBe(false)
    expect(tracker.count()).toBe(0)
  })

  it('reports markRead honestly', () => {
    expect(tracker.markRead('b')).toBe(false)
    tracker.recordOutput('b', 'x')
    expect(tracker.markRead('b')).toBe(true)
  })

  describe('subscribers', () => {
    it('are notified with a snapshot on every real change', () => {
      const seen: UnreadSnapshot[] = []
      tracker.subscribe((snapshot) => seen.push(snapshot))

      tracker.recordOutput('b', 'x')
      tracker.recordOutput('c', 'x')
      tracker.markRead('b')

      expect(seen.map((s) => s.count)).toEqual([1, 2, 1])
      expect(seen[2].ids).toEqual(['c'])
    })

    it('are not woken by output on an already-unread session', () => {
      const listener = vi.fn()
      tracker.recordOutput('b', 'first')
      tracker.subscribe(listener)

      tracker.recordOutput('b', 'second')
      tracker.recordOutput('b', 'third')

      expect(listener).not.toHaveBeenCalled()
    })

    it('are not woken by noise', () => {
      const listener = vi.fn()
      tracker.subscribe(listener)
      tracker.recordOutput('b', '\x1b[2K\r⠋ ')
      expect(listener).not.toHaveBeenCalled()
    })

    it('are not woken by a clear that cleared nothing', () => {
      const listener = vi.fn()
      tracker.subscribe(listener)
      tracker.setViewing({ activeSessionId: 'b', windowFocused: true })
      expect(listener).not.toHaveBeenCalled()
    })

    it('stop being called after unsubscribing', () => {
      const listener = vi.fn()
      const off = tracker.subscribe(listener)

      tracker.recordOutput('b', 'x')
      off()
      tracker.recordOutput('c', 'x')

      expect(listener).toHaveBeenCalledTimes(1)
    })

    it('may unsubscribe themselves from inside the callback', () => {
      const other = vi.fn()
      const off = tracker.subscribe(() => off())
      tracker.subscribe(other)

      expect(() => tracker.recordOutput('b', 'x')).not.toThrow()
      expect(other).toHaveBeenCalledTimes(1)
    })

    it('hand out a snapshot that later changes cannot mutate', () => {
      const captured: UnreadSnapshot[] = []
      tracker.subscribe((snapshot) => captured.push(snapshot))

      tracker.recordOutput('b', 'x')
      tracker.recordOutput('c', 'x')

      // The first snapshot still describes the world as it was when it was handed out.
      expect(captured[0].ids).toEqual(['b'])
      expect(captured[1].ids).toEqual(['b', 'c'])
    })
  })

  it('defaults to a focused window with nothing selected', () => {
    const fresh = new UnreadTracker()
    expect(fresh.recordOutput('anything', 'x')).toBe(true)
    expect(fresh.snapshot()).toEqual({ ids: ['anything'], count: 1 })
  })
})
