import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { Sidebar } from './Sidebar'
import { WorkspaceTabStrip } from '../browser/WorkspaceTabStrip'
import { NO_DRAG_ATTR, dragStartedOnControl, type HitTestable } from './workspace-tabs'
import type { WorkspaceTab } from './workspace-tabs'
import type { Project } from '../state/store'

/**
 * The controls that sit on a rail row and on a strip tab: they must fire when
 * they are pressed, and they must not be there at all when they cannot act.
 *
 * Two of his complaints, and they are the same subject from opposite ends — a
 * control that looks live and is not.
 *
 * # 1. *"The ✕ sometimes does not work."*
 *
 * ## What it actually is
 *
 * Not sometimes, and not only the ✕. A sidebar row and a strip tab are each a
 * `<div draggable>` wrapped around their own buttons, and once the browser
 * decides a press has become a drag it **cancels the click** — so any press
 * where the hand slides a few pixels between button-down and button-up never
 * reaches the button under it. Measured through CDP against the real components
 * in `.harness/`, with the events logged:
 *
 *     pointerdown → mousedown → dragstart          (4px of movement)
 *     pointerdown → mousedown → mouseup → click    (0px of movement)
 *
 * On a trackpad, where a tap almost always slides, that is most presses. In the
 * rail the press does nothing at all. In the strip it is worse: the drag
 * completes four pixels away and lands back on the same bar, so pressing ✕ on
 * the second tab silently *reorders* the strip instead of removing anything.
 *
 * Both were reproduced and both were fixed the same way, which is why one test
 * file covers both surfaces: the marker on the controls, and the guard that
 * reads it.
 *
 * ## Why these two assertions and not a simulated drag
 *
 * A drag cannot be simulated in this suite — there is no DOM, `Modal` portals,
 * and `dragstart`'s cancellation of the click is browser behaviour rather than
 * anything this code does. So the halves are pinned separately: that every
 * control inside a draggable container carries the marker, and that the guard
 * answers the press point rather than the drag source. Either half missing is
 * the bug back. The end-to-end proof lives in the harness run, not in CI.
 */

const TABS: WorkspaceTab[] = [
  { id: 's1', kind: 'session', label: 'Session 1', status: 'idle', projectPath: '/p', closable: true },
  { id: 's2', kind: 'session', label: 'Session 2', status: 'working', projectPath: '/p', closable: true },
]
const PROJECTS: Project[] = [{ path: '/p', name: 'p' }]

function railMarkup(props: { canResume?: boolean } = {}): string {
  return renderToStaticMarkup(
    <Sidebar
      {...props}
      width={280}
      projects={PROJECTS}
      tabs={TABS}
      activeTabId="s1"
      activePanel={null}
      panels={[]}
      browser={false}
      browserOffer={null}
      alerts={false}
      alertCount={0}
      unread={[]}
      held={[]}
      heldRetrying={[]}
      onRetryHeld={() => {}}
      onForgetHeld={() => {}}
      peeking={false}
      update={null}
      onSelectTab={() => {}}
      onCloseTab={() => {}}
      onSelectPanel={() => {}}
      onNewSession={() => {}}
      onNewBrowserTab={() => {}}
      onOpenProject={() => {}}
      onCloseProject={() => {}}
      onOpenSettings={() => {}}
      onOpenAlerts={() => {}}
      onToggleCollapsed={() => {}}
      onPeekStart={() => {}}
      onPeekEnd={() => {}}
      onStartResize={() => {}}
      storage={null}
    />,
  )
}

describe('every control inside a draggable row or tab is marked', () => {
  it('marks the rail row’s ✕ — the control he reported', () => {
    const html = railMarkup()
    const close = /<button[^>]*class="sb-row-action sb-close"[^>]*>/.exec(html)?.[0] ?? ''
    expect(close, 'the close button has changed shape').not.toBe('')
    expect(close).toContain(NO_DRAG_ATTR)
  })

  it('marks the rail row’s promote toggle', () => {
    // The sharpest case: this button exists so a window can be sent to the top
    // *without* a drag, and a press on it was being eaten by the drag it was
    // there to replace.
    const html = railMarkup()
    const promote = /<button[^>]*class="sb-row-action sb-promote"[^>]*>/.exec(html)?.[0] ?? ''
    expect(promote, 'the promote button has changed shape').not.toBe('')
    expect(promote).toContain(NO_DRAG_ATTR)
  })

  it('marks the strip tab’s ✕, where a swallowed press reorders the bar', () => {
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip tabs={TABS} activeTabId="s1" onSelect={() => {}} onShowInstead={() => {}} storage={null} />,
    )
    const close = /<button[^>]*class="strip-tab-close"[^>]*>/.exec(html)?.[0] ?? ''
    expect(close, 'the strip close button has changed shape').not.toBe('')
    expect(close).toContain(NO_DRAG_ATTR)
  })
})

describe('dragStartedOnControl', () => {
  /** A document that hit-tests one rectangle, the way a real one does. */
  function hitting(answer: { closest(selector: string): unknown } | null): HitTestable {
    return { elementFromPoint: () => answer }
  }

  it('refuses a drag that began on a marked control', () => {
    expect(dragStartedOnControl(10, 10, hitting({ closest: () => ({}) }))).toBe(true)
  })

  it('allows a drag that began anywhere else on the row', () => {
    expect(dragStartedOnControl(10, 10, hitting({ closest: () => null }))).toBe(false)
  })

  it('asks for the marker by attribute, not by class name', () => {
    // The question is behavioural — "may a drag begin here" — and a rule keyed
    // on `.sb-row-action` would stop protecting a button the day it was
    // restyled.
    let asked = ''
    dragStartedOnControl(1, 2, hitting({ closest: (selector) => { asked = selector; return null } }))
    expect(asked).toBe(`[${NO_DRAG_ATTR}]`)
  })

  it('allows the drag when nothing can be hit-tested, which is the old behaviour', () => {
    // A pointer outside the viewport, or a host with no document at all. The
    // safe way to fail is the bug, not a rail whose rows cannot be dragged.
    expect(dragStartedOnControl(0, 0, null)).toBe(false)
    expect(dragStartedOnControl(0, 0, hitting(null))).toBe(false)
  })
})

describe('the guard is wired into both drag sources', () => {
  /*
   * Read from the source rather than exercised, because the thing being pinned
   * is that `onDragStart` *consults* the guard at all — and a `dragstart` cannot
   * be dispatched in a suite with no DOM. Without this, both halves above can
   * pass while nothing calls the function: the markers sit on the buttons, the
   * predicate is correct, and the ✕ is still dead.
   *
   * The press point, specifically. `event.target` inside `onDragStart` is the
   * *drag source* — the element carrying `draggable` — never the deepest node
   * under the pointer, which is what makes the obvious spelling silently useless
   * here. It was tried first and measured always answering "the row".
   */
  const sources: Array<[string, string]> = [
    ['Sidebar.tsx', 'the rail row'],
    ['../browser/WorkspaceTabStrip.tsx', 'the strip tab'],
  ]

  it.each(sources)('%s guards its dragstart with the press point', async (file) => {
    const { readFileSync } = await import('node:fs')
    const { join } = await import('node:path')
    const source = readFileSync(join(__dirname, file), 'utf8')
    expect(source).toContain('dragStartedOnControl(event.clientX, event.clientY)')
    expect(source).toContain('event.preventDefault()')
  })
})

/* ----------------------------------- 2. a control that cannot act is not drawn -- */

/**
 * *"'Continue last conversation' is agent-specific."*
 *
 * It is, and silently. `host-core.ts` spawns with
 * `input.resume && resumeArgs.length > 0 ? resumeArgs : args`, so asking Gemini
 * or a plain shell to continue starts a **fresh** session and says nothing —
 * the glyph appears to work and quietly does the other thing. Claude has
 * `--continue`, Codex has `resume --last`, and `agent-catalog.ts` records that
 * Gemini's own flag errors on an empty history, which is why it has none.
 *
 * The radios in the New session dialog are gone outright; this one is a named
 * command with a single answer, so it survives where it can act and is absent
 * where it cannot. `App.tsx` asks the question of the default agent, because
 * that is the agent this press would start.
 */
describe('continue-last-session on a project heading', () => {
  const controls = (html: string): string[] =>
    [...html.matchAll(/aria-label="([^"]*)"/g)].map((m) => m[1])

  it('is offered when the agent has a resume command', () => {
    expect(controls(railMarkup({ canResume: true }))).toContain(
      'Continue the last session in p',
    )
  })

  it('is not drawn at all when it would start a fresh session instead', () => {
    const labels = controls(railMarkup({ canResume: false }))
    expect(labels).not.toContain('Continue the last session in p')
    // And the two beside it are untouched — the heading still opens a session
    // and still closes the project.
    expect(labels).toContain('New session in p')
    expect(labels).toContain('Close p')
  })

  it('defaults to not drawing it, so a host that never answers cannot lie', () => {
    expect(controls(railMarkup())).not.toContain('Continue the last session in p')
  })
})
