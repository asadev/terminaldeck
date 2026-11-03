import { describe, expect, it } from 'vitest'
import { readNode } from './session'
import { readRound } from './round'

describe('a round from the window', () => {
  it('is rebuilt field by field, clamped, cut and renumbered', () => {
    const round = readRound({
      id: 'r1',
      createdAt: 5,
      where: { kind: 'device', place: 'iOS Simulator', name: 'x'.repeat(500), deviceId: 'ios:1', evil: 'dropped' },
      frame: { width: 1206.4, height: -3 },
      note: 'Make #1 bold.',
      annotations: [
        // A per-marker note from an older window is dropped: a round has one note.
        { id: 'a', n: 9, rect: { x: -1, y: 2, width: 0.5, height: 0.5 }, note: 'one', element: { role: 'button', script: 'x' } },
        { id: 'b', rect: {}, element: 'not an object' },
      ],
    })
    expect(round.where).toEqual({ kind: 'device', place: 'iOS Simulator', name: 'x'.repeat(200), deviceId: 'ios:1' })
    expect(round.frame).toEqual({ width: 1206, height: 0 })
    expect(round.annotations.map((a) => a.n)).toEqual([1, 2])
    expect(round.annotations[0].rect).toEqual({ x: 0, y: 1, width: 0.5, height: 0.5 })
    expect(round.annotations[0].element).toEqual({ role: 'button' })
    expect(round.note).toBe('Make #1 bold.')
    expect('note' in round.annotations[0]).toBe(false)
    expect(round.annotations[1].element).toBeNull()
  })

  it('makes up an id for a round that came without one, rather than failing', () => {
    expect(readRound(null).id).toMatch(/^round-/)
    expect(readRound(null).note).toBe('')
  })
})

describe('a tree node from the engine', () => {
  it('keeps only the fields this app reads', () => {
    const node = readNode({
      ref: 'ax:1',
      role: 'AXButton',
      label: 'Pay',
      actions: ['AXPress'],
      visibleFraction: 1,
      frame: { normalized: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 }, points: { x: 1, y: 2, width: 3, height: 4 } },
    })
    expect(node).toEqual({ ref: 'ax:1', role: 'AXButton', label: 'Pay', frame: { normalized: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 } } })
  })

  it('never carries a redacted value', () => {
    expect(readNode({ ref: 'p', role: 'AXSecureTextField', value: '••••', valueRedacted: true })).toEqual({
      ref: 'p',
      role: 'AXSecureTextField',
      valueRedacted: true,
    })
  })

  it('keeps a React Native source location', () => {
    expect(readNode({ ref: 'rn:1', component: 'PayButton', sourceLocation: { file: 'src/Pay.tsx', line: 12 } })?.sourceLocation).toEqual({
      file: 'src/Pay.tsx',
      line: 12,
    })
  })
})
