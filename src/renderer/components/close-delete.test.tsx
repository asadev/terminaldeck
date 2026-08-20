import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'

/**
 * One verb, one colour, and what happens to the windows.
 *
 * Asad, 2026-08-20, of the rail's ⋯ menu and the dialog behind it:
 *
 * > *"Close session one and end session, both are the same thing, two times. So
 * > only give the delete button here. It should call only delete. It should give
 * > the warning also, warning should also use the word delete. When I hover on
 * > the delete it will have the white text and red color instead of this blue.
 * > And when it's not hover, it will have red text only."*
 *
 * And, separately, of pressing that control on a session with browser windows
 * attached: *"it shows no message… but otherwise we will not even know that it
 * is the reason."*
 *
 * The harness is `dialog-render.test.tsx`'s: no DOM in this project's setup, so
 * the dialog renders through `react-dom/server` with `Modal`'s portal swapped
 * for a passthrough.
 */

vi.mock('react-dom', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react-dom')>()
  return { ...actual, createPortal: (node: ReactNode) => node }
})
;(globalThis as { document?: unknown }).document = { body: {} }

const { CloseSessionConfirm } = await import('./CloseSessionConfirm')
const { setBindings, resetBindingsForTests } = await import('../browser/binding-view')

beforeEach(() => {
  resetBindingsForTests()
})

function render(extra: Record<string, unknown> = {}): string {
  return renderToStaticMarkup(
    <CloseSessionConfirm
      open
      title="Session 1"
      status="waiting"
      onCancel={() => undefined}
      onConfirm={() => undefined}
      {...extra}
    />,
  )
}

describe('the control is called Delete wherever it is spelled', () => {
  it('asks to delete, and its button says delete', () => {
    const html = render()
    expect(html).toContain('Delete this session?')
    expect(html).toContain('>Delete<')
    // The old label said the same thing twice — `Close Session 1 — ends the
    // session` — which is what he read off the screen as two controls.
    expect(html).not.toContain('Close session')
  })

  it('says delete in the warning too', () => {
    expect(render()).toContain('Deleting this session ends it.')
  })

  it('is the word the rail’s menu uses', () => {
    const menu = readFileSync(join(__dirname, '..', '..', 'main', 'session-row-menu.ts'), 'utf8')
    expect(menu).toContain("label: 'Delete',")
    // Nothing left that spells the consequence a second time in the same row.
    expect(menu).not.toContain('label: request.close')
  })

  it('is red text at rest and white on red under the pointer', () => {
    const css = readFileSync(join(__dirname, 'CloseSessionConfirm.css'), 'utf8')
    const rest = css.slice(css.indexOf('.modal-btn.danger {'))
    const restRule = rest.slice(0, rest.indexOf('}'))
    expect(restRule).toContain('background: transparent')
    expect(restRule).toContain('color: var(--color-critical)')

    const hover = css.slice(css.indexOf('.modal-btn.danger:hover'))
    const hoverRule = hover.slice(0, hover.indexOf('}'))
    expect(hoverRule).toContain('background: var(--color-critical)')
    expect(hoverRule).toContain('color: var(--text-onaccent)')
    // A keyboard reaches the same state a pointer does.
    expect(css).toContain('.modal-btn.danger:focus-visible:not(:disabled)')
  })
})

describe('an attached browser window is never a silent reason', () => {
  it('names the windows the delete lets go of, in one line', () => {
    setBindings({
      sessions: [
        {
          sessionId: 's1',
          machineId: '',
          colour: 0,
          ended: false,
          windows: [
            { n: 1, browserTabId: 'b:1', url: '', title: 'Stripe' },
            { n: 2, browserTabId: 'b:2', url: '', title: 'Docs' },
          ],
        },
      ],
    })

    const html = render({ sessionId: 's1' })

    expect(html).toContain('B1 and B2 stay open, detached.')
    // And it still deletes: the line is an answer, not a refusal.
    expect(html).toContain('>Delete<')
  })

  it('uses the singular for one window', () => {
    setBindings({
      sessions: [
        {
          sessionId: 's1',
          machineId: '',
          colour: 0,
          ended: false,
          windows: [{ n: 3, browserTabId: 'b:1', url: '', title: 'Stripe' }],
        },
      ],
    })
    expect(render({ sessionId: 's1' })).toContain('B3 stays open, detached.')
  })

  it('says nothing at all when nothing is attached', () => {
    expect(render({ sessionId: 's1' })).not.toContain('detached')
  })

  it('says nothing for a project or a machine, where the sentence would be wrong', () => {
    setBindings({
      sessions: [
        {
          sessionId: 's1',
          machineId: '',
          colour: 0,
          ended: false,
          windows: [{ n: 1, browserTabId: 'b:1', url: '', title: 'Stripe' }],
        },
      ],
    })
    // No `sessionId` is passed for those dialogs — `B1` is a fact about one
    // session's numbering, not about a set of them.
    expect(render({ count: 3, subject: 'project' })).not.toContain('detached')
  })
})
