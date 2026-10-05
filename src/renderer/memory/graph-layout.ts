/**
 * Where each note sits in the Memory page's graph — a small force layout,
 * written here rather than pulled in, because the job is a few dozen to a few
 * hundred dots and a library for it would be the largest thing on the page.
 *
 * Fruchterman–Reingold: every pair of notes pushes apart, every link pulls its
 * two ends together, a weak pull toward the middle keeps islands on the page,
 * and a temperature that cools each round limits how far anything may move, so
 * the picture settles instead of shaking. Deterministic — the start is a circle
 * in the notes' own order, not a random scatter — so the same memory draws the
 * same picture every time it is opened, and a test can hold it still.
 *
 * Edges are only ever the ones handed in. The page hands in resolved links
 * only; a link that reached nothing has no second end to draw, and is listed
 * instead.
 */

export interface LayoutPoint {
  x: number
  y: number
}

export interface LayoutOptions {
  width: number
  height: number
  /** Rounds of the simulation. Fewer for a large graph, where each round costs n². */
  iterations?: number
  /** Kept clear at the edge, so a dot and its label stay inside the frame. */
  margin?: number
}

/** Rounds, scaled down as the pairwise cost grows. */
function roundsFor(count: number): number {
  if (count <= 80) return 300
  if (count <= 250) return 150
  if (count <= 600) return 60
  return 25
}

export function layoutGraph(
  nodes: readonly string[],
  edges: ReadonlyArray<{ from: string; to: string }>,
  options: LayoutOptions,
): Map<string, LayoutPoint> {
  const { width, height } = options
  const margin = options.margin ?? 24
  const count = nodes.length
  const out = new Map<string, LayoutPoint>()
  if (count === 0) return out
  const cx = width / 2
  const cy = height / 2
  if (count === 1) {
    out.set(nodes[0], { x: cx, y: cy })
    return out
  }

  const index = new Map(nodes.map((node, at) => [node, at]))
  const x = new Float64Array(count)
  const y = new Float64Array(count)
  const radius = Math.min(width, height) / 2 - margin
  for (let i = 0; i < count; i += 1) {
    const angle = (2 * Math.PI * i) / count
    x[i] = cx + radius * Math.cos(angle)
    y[i] = cy + radius * Math.sin(angle)
  }
  const links = edges
    .map((edge) => [index.get(edge.from), index.get(edge.to)] as const)
    .filter((pair): pair is readonly [number, number] => pair[0] !== undefined && pair[1] !== undefined && pair[0] !== pair[1])

  const area = (width - 2 * margin) * (height - 2 * margin)
  const k = Math.sqrt(area / count)
  const rounds = options.iterations ?? roundsFor(count)
  let temperature = Math.min(width, height) / 8
  const cooling = temperature / (rounds + 1)
  const dx = new Float64Array(count)
  const dy = new Float64Array(count)

  for (let round = 0; round < rounds; round += 1) {
    dx.fill(0)
    dy.fill(0)
    for (let i = 0; i < count; i += 1) {
      for (let j = i + 1; j < count; j += 1) {
        let ex = x[i] - x[j]
        let ey = y[i] - y[j]
        let distance = Math.hypot(ex, ey)
        if (distance < 0.01) {
          // Two notes on one spot: part them along a fixed direction, not a random one.
          ex = 0.01 * ((i % 7) - 3 || 1)
          ey = 0.01 * ((j % 5) - 2 || 1)
          distance = Math.hypot(ex, ey)
        }
        const push = (k * k) / distance
        dx[i] += (ex / distance) * push
        dy[i] += (ey / distance) * push
        dx[j] -= (ex / distance) * push
        dy[j] -= (ey / distance) * push
      }
    }
    for (const [a, b] of links) {
      const ex = x[a] - x[b]
      const ey = y[a] - y[b]
      const distance = Math.max(Math.hypot(ex, ey), 0.01)
      const pull = (distance * distance) / k
      dx[a] -= (ex / distance) * pull
      dy[a] -= (ey / distance) * pull
      dx[b] += (ex / distance) * pull
      dy[b] += (ey / distance) * pull
    }
    for (let i = 0; i < count; i += 1) {
      // A weak pull to the middle, so a note with no links does not drift to a corner.
      dx[i] += (cx - x[i]) * 0.02 * k * 0.1
      dy[i] += (cy - y[i]) * 0.02 * k * 0.1
      const length = Math.hypot(dx[i], dy[i])
      if (length > 0) {
        const step = Math.min(length, temperature)
        x[i] += (dx[i] / length) * step
        y[i] += (dy[i] / length) * step
      }
      x[i] = Math.min(width - margin, Math.max(margin, x[i]))
      y[i] = Math.min(height - margin, Math.max(margin, y[i]))
    }
    temperature = Math.max(temperature - cooling, 0.5)
  }

  for (let i = 0; i < count; i += 1) out.set(nodes[i], { x: x[i], y: y[i] })
  return out
}
