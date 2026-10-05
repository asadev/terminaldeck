import { describe, expect, it } from 'vitest'
import { layoutGraph } from './graph-layout'

const box = { width: 800, height: 480, margin: 32 }

function distance(a: { x: number; y: number } | undefined, b: { x: number; y: number } | undefined): number {
  if (a === undefined || b === undefined) throw new Error('missing point')
  return Math.hypot(a.x - b.x, a.y - b.y)
}

describe('placing the notes', () => {
  it('places every node, and only the nodes it was given, inside the frame', () => {
    const nodes = ['a', 'b', 'c', 'd', 'e']
    const at = layoutGraph(nodes, [{ from: 'a', to: 'b' }, { from: 'a', to: 'ghost' }], box)
    expect([...at.keys()]).toEqual(nodes)
    for (const point of at.values()) {
      expect(point.x).toBeGreaterThanOrEqual(32)
      expect(point.x).toBeLessThanOrEqual(768)
      expect(point.y).toBeGreaterThanOrEqual(32)
      expect(point.y).toBeLessThanOrEqual(448)
    }
  })

  it('is the same picture every time for the same notes', () => {
    const nodes = ['MEMORY.md', 'a.md', 'b.md', 'c.md']
    const edges = [
      { from: 'MEMORY.md', to: 'a.md' },
      { from: 'MEMORY.md', to: 'b.md' },
    ]
    expect([...layoutGraph(nodes, edges, box)]).toEqual([...layoutGraph(nodes, edges, box)])
  })

  it('pulls linked notes closer together than notes with nothing between them', () => {
    const nodes = ['hub', 'a', 'b', 'c', 'lonely-1', 'lonely-2']
    const edges = [
      { from: 'hub', to: 'a' },
      { from: 'hub', to: 'b' },
      { from: 'hub', to: 'c' },
    ]
    const at = layoutGraph(nodes, edges, box)
    const linked = (distance(at.get('hub'), at.get('a')) + distance(at.get('hub'), at.get('b')) + distance(at.get('hub'), at.get('c'))) / 3
    const apart = distance(at.get('lonely-1'), at.get('lonely-2'))
    expect(linked).toBeLessThan(apart)
  })

  it('handles nothing and one note', () => {
    expect(layoutGraph([], [], box).size).toBe(0)
    expect(layoutGraph(['only'], [], box).get('only')).toEqual({ x: 400, y: 240 })
  })

  it('stays quick for a large memory', () => {
    const nodes = Array.from({ length: 600 }, (_, i) => `n${i}.md`)
    const edges = nodes.slice(1).map((node, i) => ({ from: nodes[i], to: node }))
    const started = Date.now()
    expect(layoutGraph(nodes, edges, box).size).toBe(600)
    expect(Date.now() - started).toBeLessThan(3_000)
  })
})
