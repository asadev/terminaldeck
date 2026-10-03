import { describe, expect, it } from 'vitest'
import { MomentTracker, pillLabel, needsYou, readSnapshot, restingLine, type HootSessionView } from './hoot-panel-model'

const s = (id: string, label: string, status: HootSessionView['status']): HootSessionView => ({ id, label, status })

describe('the line in the panel’s header', () => {
  it('says nothing when all is quiet', () => {
    expect(restingLine([s('a', 'Session 1', 'idle'), s('b', 'Session 2', 'waiting')])).toBeNull()
    expect(restingLine([])).toBeNull()
  })

  it('counts the sessions working', () => {
    expect(restingLine([s('a', 'Session 1', 'working'), s('b', 'Session 2', 'working')])).toEqual({
      text: '2 working',
      attention: false,
    })
  })

  it('names the one session that needs you, over any number working', () => {
    expect(restingLine([s('a', 'Session 1', 'working'), s('b', 'Session 2', 'input')])).toEqual({
      text: 'Session 2 needs you',
      attention: true,
    })
    expect(restingLine([s('a', 'Session 1', 'input'), s('b', 'Session 2', 'input')])).toEqual({
      text: '2 need you',
      attention: true,
    })
    expect(needsYou([s('a', 'Session 1', 'working'), s('b', 'Session 2', 'input')]).map((x) => x.id)).toEqual(['b'])
  })
})

describe('what the resting pill says', () => {
  it('is the assistant’s name when nothing is open', () => {
    expect(pillLabel(null, [])).toEqual({ text: 'Hoot', attention: false })
    expect(pillLabel(null, [s('a', 'Session 1', 'exited')])).toEqual({ text: 'Hoot', attention: false })
  })

  it('gives the basic state at a glance: open, working, waiting — leaving out what is zero', () => {
    expect(pillLabel(null, [s('a', 'Session 1', 'idle')])).toEqual({ text: '1 open', attention: false })
    expect(pillLabel(null, [s('a', 'Session 1', 'working'), s('b', 'Session 2', 'working')])).toEqual({
      text: '2 open · 2 working',
      attention: false,
    })
    expect(
      pillLabel(null, [
        s('a', 'Session 1', 'working'),
        s('b', 'Session 2', 'input'),
        s('c', 'Session 3', 'working'),
        s('d', 'Session 4', 'idle'),
        s('e', 'Session 5', 'exited'),
      ]),
    ).toEqual({ text: '4 open · 2 working · 1 waiting', attention: true })
  })

  it('says the moment while it lasts, cut short so it never crowds the menu bar', () => {
    expect(pillLabel({ sessionId: 'a', text: 'Session 2 finished', attention: false }, [])).toEqual({
      text: 'Session 2 finished',
      attention: false,
    })
    const long = pillLabel(
      { sessionId: 'a', text: 'Fix the parser in the reader and the writer needs you', attention: true },
      [],
    )
    expect(long.text.length).toBeLessThanOrEqual(34)
    expect(long.text.endsWith('…')).toBe(true)
  })
})

describe('a moment', () => {
  it('fires once when a session starts waiting on you, or finishes, and never on first sight', () => {
    const tracker = new MomentTracker()
    expect(tracker.next([s('a', 'Session 2', 'input')], 1000)).toBeNull()
    expect(tracker.next([s('a', 'Session 2', 'working')], 2000)).toBeNull()
    expect(tracker.next([s('a', 'Session 2', 'input')], 10_000)).toEqual({
      sessionId: 'a',
      text: 'Session 2 needs you',
      attention: true,
    })
    expect(tracker.next([s('a', 'Session 2', 'input')], 10_100)).toBeNull()
    expect(tracker.next([s('a', 'Session 2', 'completed')], 20_000)).toEqual({
      sessionId: 'a',
      text: 'Session 2 finished',
      attention: false,
    })
  })

  it('swallows a status that flickers, with the same cooldown the banners use', () => {
    const tracker = new MomentTracker()
    tracker.next([s('a', 'Session 1', 'working')], 0)
    expect(tracker.next([s('a', 'Session 1', 'input')], 100)).not.toBeNull()
    tracker.next([s('a', 'Session 1', 'working')], 200)
    expect(tracker.next([s('a', 'Session 1', 'input')], 300)).toBeNull()
  })
})

describe('the snapshot off the wire', () => {
  it('keeps what it knows and drops the rest', () => {
    const view = readSnapshot({
      assistant: 'Hoot',
      hoot: { status: 'running', problem: null },
      sessions: [{ id: 'a', label: 'Session 1', status: 'input' }, { id: 'b', status: 'exploded' }, 'nonsense'],
      messages: [
        { id: 'm1', role: 'agent', text: 'Done.' },
        { id: 'm2', role: 'system', text: 'hidden' },
        { id: 'm3', role: 'you', text: '   ' },
      ],
    })
    expect(view.sessions).toEqual([
      { id: 'a', label: 'Session 1', status: 'input' },
      { id: 'b', label: 'Session', status: 'idle' },
    ])
    expect(view.messages.map((m) => m.id)).toEqual(['m1'])
    expect(readSnapshot(null).hoot.status).toBe('stopped')
  })

  it('reads the island’s state — its words, grown or not, and the display’s notch — and defaults what is missing', () => {
    const view = readSnapshot({
      appearance: 'light',
      label: { text: 'Needs you', attention: true },
      expanded: true,
      geometry: { barHeight: 32, displayWidth: 1512, notch: { left: 656, width: 200, height: 32 } },
    })
    expect(view.label).toEqual({ text: 'Needs you', attention: true })
    expect(view.appearance).toBe('light')
    expect(view.expanded).toBe(true)
    expect(view.geometry).toEqual({ barHeight: 32, displayWidth: 1512, notch: { left: 656, width: 200, height: 32 } })
    const bare = readSnapshot({ assistant: 'Hoot', geometry: { barHeight: -3, notch: { width: 0, height: 32 } } })
    expect(bare.label).toEqual({ text: 'Hoot', attention: false })
    expect(bare.expanded).toBe(false)
    expect(bare.appearance).toBe('dark')
    expect(bare.geometry.barHeight).toBe(24)
    expect(bare.geometry.notch).toBeNull()
  })
})
