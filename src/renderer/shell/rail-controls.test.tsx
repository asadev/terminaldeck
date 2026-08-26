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

function railMarkup(
  props: { canResume?: boolean; tabs?: WorkspaceTab[]; projects?: Project[] } = {},
): string {
  const { tabs = TABS, projects = PROJECTS, ...rest } = props
  return renderToStaticMarkup(
    <Sidebar
      {...rest}
      width={280}
      projects={projects}
      tabs={tabs}
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
  it('marks the rail row’s ⋯ — the one button the reported controls became', () => {
    /*
     * This assertion used to be made twice, once for the ✕ and once for the
     * promote arrow, and both of those are entries in this button's menu now:
     * *"instead of these two buttons, give … one three-dot button."* The defect
     * it guards is unchanged and is the sharpest case of it — the row is
     * draggable, so a press that slides four pixels becomes a drag and the
     * click is cancelled, which is exactly what he reported happening to the ✕
     * that now lives behind this menu.
     */
    const html = railMarkup()
    const more = /<button[^>]*class="sb-row-action sb-more"[^>]*>/.exec(html)?.[0] ?? ''
    expect(more, 'the row’s menu button has changed shape').not.toBe('')
    expect(more).toContain(NO_DRAG_ATTR)
  })

  it('leaves no ✕ or promote arrow on the row to be swallowed', () => {
    // The other half of the same change, asserted rather than assumed: a second
    // control creeping back onto the row is how the name loses its pixels again.
    const html = railMarkup()
    expect(html).not.toContain('sb-row-action sb-close')
    expect(html).not.toContain('sb-row-action sb-promote')
  })

  it('marks the strip tab’s ✕, where a swallowed press reorders the bar', () => {
    /* A browser tab, because that is the only tab the strip draws a ✕ on since
       2026-08-20 — *"session can be only closed from the sidebar, not from the
       top bar."* The defect being guarded is unchanged: the tab is draggable,
       so an unmarked press that slides four pixels reorders the bar instead of
       closing the window. */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={[...TABS, { id: 'b1', kind: 'browser', label: 'New tab', closable: true }]}
        activeTabId="s1"
        onSelect={() => {}}
        onCloseWindow={() => {}}
        storage={null}
      />,
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
    // and still ends the sessions in the project. That second one says `Delete`
    // since 2026-08-27, and names the sessions rather than the folder: the
    // folder is exactly what the press does not touch.
    expect(labels).toContain('New session in p')
    expect(labels).toContain('Delete the sessions in p')
  })

  it('defaults to not drawing it, so a host that never answers cannot lie', () => {
    expect(controls(railMarkup())).not.toContain('Continue the last session in p')
  })
})

/* ------------------------------------------- which panel lists which window -- */

/**
 * *"Browser windows will not be on the side bar at all. They will be always
 * only on the top bar. Side bar is only for the sessions. Browser can be on the
 * top bar only, and session can be on both side bar and the top bar."*
 * — 2026-08-20, after talking through both arrangements and settling on this.
 *
 * It is one sentence and it takes two components to keep, in opposite
 * directions, which is exactly the kind of rule that half-rots: the rail stops
 * drawing pages, and the strip starts drawing every one of them whether or not
 * anybody promoted it. Half of that is a browser window listed twice; the other
 * half is a browser window listed nowhere, open, and unreachable.
 */
/** A storage already holding a promoted order, so every named tab is on the bar. */
function promoting(ids: readonly string[]): Storage {
  const held = new Map<string, string>([['terminaldeck.strip.promoted', JSON.stringify(ids)]])
  return {
    get length() {
      return held.size
    },
    clear: () => held.clear(),
    getItem: (key: string) => held.get(key) ?? null,
    key: (index: number) => [...held.keys()][index] ?? null,
    removeItem: (key: string) => void held.delete(key),
    setItem: (key: string, value: string) => void held.set(key, value),
  }
}

describe('a browser window lives on the strip and nowhere else', () => {
  const WITH_PAGE: WorkspaceTab[] = [
    ...TABS,
    { id: 'b1', kind: 'browser', label: 'localhost:5173', closable: true },
  ]

  it('draws no row for it in the rail, even though the rail is given it', () => {
    // Given it deliberately: the session rows read the same list to wear their
    // `B1`/`B2` chips. So this is the rail *filtering*, which is a thing a test
    // can hold, rather than the window withholding, which would be a different
    // bug wearing the same screenshot.
    const html = railMarkup({ tabs: WITH_PAGE })
    expect(html).not.toContain('localhost:5173')
    // The sessions it was passed alongside are still there, so an accidental
    // "draw nothing" would fail here rather than pass the assertion above.
    expect(html).toContain('Session 1')
  })

  it('says the rail is empty when only pages are open, because for the rail it is', () => {
    /*
     * The line used to count browser windows, back when they had rows: printing
     * "Nothing open yet." over four of them would have been the app
     * contradicting itself in one glance. With the rows gone the count would be
     * the contradiction — a rail with genuinely no rows, refusing to say so
     * because of something drawn in another component.
     */
    const html = railMarkup({ tabs: [WITH_PAGE[2]!], projects: [] })
    expect(html).toContain('Nothing open yet.')
  })

  it('keeps it in the strip with no promotion at all', () => {
    /*
     * The other direction, and the one that turns a layout preference into a
     * lost window. `storage={null}` is a strip that has never been arranged —
     * nothing promoted, nothing remembered — and the page still has to be
     * drawn, because there is no second panel for it to fall back to.
     */
    const html = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={WITH_PAGE}
        activeTabId="s1"
        onSelect={() => {}}
        onCloseWindow={() => {}}
        storage={null}
      />,
    )
    expect(html).toContain('data-tab-id="b1"')
    expect(html).toContain('localhost:5173')
  })

  /**
   * *"Now the browsers are up there, which is the right design, and sessions are
   * here."* — 2026-08-21, pointing at the strip and then at the rail.
   *
   * He is describing the arrangement as correct, which makes this a guard rather
   * than a change. The two halves above hold one direction each for a page; this
   * holds the other object, which is the half a page-only test cannot see: a
   * **session** belongs in both places, and a filter written to keep pages out
   * of the rail is one edit away from keeping a session out of the strip.
   *
   * The rail's side of it for sessions that run somewhere else is in
   * `machine-group.test.tsx` and `server-group.test.tsx`, which build the groups
   * this rail draws them under.
   */
  it('draws a tab for every session and a rail row for none of the pages', () => {
    /*
     * Promoted, unlike the page above: *"session can be on both side bar and the
     * top bar"*, and the strip is the half a person arranges. A session that is
     * neither promoted nor on screen is correctly absent from the bar — that is
     * the whole distinction `shownTabs` draws — so what is being checked is that
     * a session can get there at all, for every session in the list.
     */
    const strip = renderToStaticMarkup(
      <WorkspaceTabStrip
        tabs={WITH_PAGE}
        activeTabId="s1"
        onSelect={() => {}}
        onShowInstead={() => {}}
        onCloseWindow={() => {}}
        storage={promoting(WITH_PAGE.map((tab) => tab.id))}
      />,
    )
    for (const tab of WITH_PAGE) {
      expect(strip, `${tab.id} is not in the strip`).toContain(`data-tab-id="${tab.id}"`)
    }
    // And the same list down the side, with the page and only the page missing.
    const rail = railMarkup({ tabs: WITH_PAGE })
    expect(rail).toContain('Session 1')
    expect(rail).toContain('Session 2')
    expect(rail).not.toContain('localhost:5173')
  })
})
