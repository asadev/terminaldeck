import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import type { HootSessionView } from '../../shared/hoot-panel-model'
import { AllSessions, what } from './HootPanel'

/**
 * The list of every session the island shows in place of the conversation
 * while its sessions row is hovered: all of them, each one a button that opens
 * it, scrolling when there are more than fit.
 */

const many: HootSessionView[] = Array.from({ length: 40 }, (_, n) => ({
  id: `s${n}`,
  label: `Session ${n + 1}`,
  status: n % 3 === 0 ? ('input' as const) : ('working' as const),
}))

describe('every session in the island', () => {
  it('draws every session as its own button, named for a screen reader with its state', () => {
    const html = renderToStaticMarkup(<AllSessions sessions={many} top={40} onOpen={() => undefined} />)
    expect(html).toContain('role="list" aria-label="All sessions"')
    expect(html.match(/<button type="button" role="listitem" class="hoot-island-all-row"/g)).toHaveLength(40)
    expect(html).toContain('title="Session 39: working"')
    expect(html).toContain('title="Session 1: needs you"')
    expect(html).toContain('padding-top:40px')
  })

  it('scrolls inside the island’s own room rather than growing past it', () => {
    const css = readFileSync(join(__dirname, 'hoot-panel.css'), 'utf8')
    const rule = /\.hoot-island-all \{([^}]*)\}/.exec(css)?.[1] ?? ''
    expect(rule).toContain('overflow-y: auto')
    expect(rule).toContain('min-height: 0')
  })

  it('says plainly when there is nothing open, and names an ended session as ended', () => {
    expect(renderToStaticMarkup(<AllSessions sessions={[]} top={0} onOpen={() => undefined} />)).toContain('No sessions open.')
    expect(what('exited')).toBe('ended')
  })
})
