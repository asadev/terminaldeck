import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ModeSwitch } from './ModeSwitch'
import { PaneBar, type PaneSubject } from './PaneBar'
import { WindowToolbar } from './WindowToolbar'
import { StoreProvider } from '../state/store'

/**
 * The window's chrome described one session while the window could show two.
 *
 * Asad, 2026-08-17: *"In a split view, it can be from two different projects,
 * two different folders, two different accounts. That's why the accounts and
 * other things related to it should not be always above — above the view, not
 * inside the view. … So it can be a problem, it can be a confusion — which one
 * it is showing right now."*
 *
 * That is a correctness bug and it is what these pin. The account chip states a
 * fact about **one** session — which config directory the agent was handed at
 * spawn — and it was drawn once for a **window** spanning both halves of a
 * split.
 *
 * The first fix over-applied. It moved *every* pane's identity into that pane
 * and left the window's bar with nothing, and Asad sent it back:
 *
 *   > *"We wanted to keep it in the top bar, under the pills of windows, so it
 *   > feels like a main session and the other ones like secondary sessions. If
 *   > we make both exactly the same placement — if the name and the account
 *   > come down — then there is no reason to keep one of them in a box, because
 *   > all the sizes, everything, is the same. So let's keep the main."*
 *
 * So the arrangement these pin is asymmetric on purpose, and every claim below
 * is one half of it:
 *
 *   1. a **guest** pane carries its own name, folder and account over its own
 *      content, so no chip can be read as belonging to the other pane;
 *   2. the **host** does not — its chrome stays in the window's toolbar, where
 *      it sat before the split, and that is what makes the box around a guest
 *      mean something rather than decorate it;
 *   3. the two are told apart by more than the box: the toolbar's heading dims
 *      when the keyboard is in a guest, at the same weight a guest's bar dims
 *      when it is not, so the pair reads as one idiom;
 *   4. a pane holding a page says something true about a page rather than
 *      borrowing a session's chrome or drawing an empty session bar.
 *
 * `react-dom/server`, like every other render test here: this project has no
 * DOM in its test setup, deliberately.
 */

const noop = (): void => {}

const SESSION: PaneSubject = {
  kind: 'session',
  id: 's1',
  title: 'Wire up split panes',
  status: 'working',
  folder: '/Users/apple/Projects/terminaldeck',
  account: { id: 'work', name: 'Work' },
  onPickAccount: noop,
  onManageAccounts: noop,
}

/** The other pane: another project, another login. The whole point. */
const OTHER: PaneSubject = {
  kind: 'session',
  id: 's2',
  title: 'School billing',
  status: 'idle',
  folder: '/Users/apple/Projects/science-locus',
  account: { id: 'school', name: 'School' },
  onPickAccount: noop,
  onManageAccounts: noop,
}

/*
 * Inside a store, because the rename gesture only exists where there is a name
 * to write to — `SessionTitle` renders a plain heading otherwise, deliberately,
 * and a test outside a store would be pinning the inert shape.
 */
const render = (subject: PaneSubject, focused = true): string =>
  renderToStaticMarkup(
    <StoreProvider>
      <PaneBar paneId="pane-1" subject={subject} focused={focused} onClose={noop} />
    </StoreProvider>,
  )

describe('a pane states its own identity', () => {
  const first = render(SESSION)
  const second = render(OTHER, false)

  it('names the session, its folder and its account, in one bar', () => {
    expect(first).toContain('Wire up split panes')
    expect(first).toContain('terminaldeck')
    expect(first).toContain('Work')
  })

  it('says something different for a different pane, which is the bug', () => {
    /*
     * The two bars are rendered from two subjects and disagree about all three
     * facts. Drawn once for the window, exactly one of these was ever on
     * screen — so the account named there was wrong for the other pane, and
     * nothing said which one it was right about.
     */
    expect(second).toContain('School billing')
    expect(second).toContain('science-locus')
    expect(second).toContain('School')
    expect(second).not.toContain('Work')
    expect(first).not.toContain('School')
  })

  it('keeps the rename where the name is', () => {
    // The heading is the same control the window's bar carries — double-click
    // or F2 — because a session's name has to be editable in the place it is
    // written, and inside a split that place is the pane.
    expect(first).toContain('double-click or F2 to rename')
    expect(first).toContain('aria-keyshortcuts="F2"')
  })

  it('sets that heading at the pane’s scale, not the window’s', () => {
    // Two window-title headings side by side is two windows' worth of chrome in
    // one window. Same component, same gesture, one attribute.
    expect(first).toContain('data-scale="pane"')
  })

  it('marks which pane the keyboard is in', () => {
    expect(first).toContain('data-focused="true"')
    expect(second).toContain('data-focused="false"')
  })

  it('carries the pane’s own close button, named for a screen reader', () => {
    expect(first).toContain('aria-label="Close this pane"')
  })
})

describe('the slot the session’s controls will land in', () => {
  /**
   * Model, effort and usage are being built by two other passes — a pty write
   * path so choosing a model reaches the running agent, and the usage window
   * over IPC. This is the place they compose into.
   *
   * It is empty rather than stubbed, deliberately: a picker that does not
   * change anything is a dead control, and a dead control in the bar whose
   * whole purpose is stating true facts about this pane is worse than a gap.
   * What is pinned is that the gap is *named and positioned*, so the follow-up
   * is composition and not a third pass through the layout.
   */
  it('exists, is named, and is empty', () => {
    const html = render(SESSION)
    expect(html).toContain('data-slot="session-controls"')
    expect(html).toContain('<div class="pane-cell-slot" data-slot="session-controls"></div>')
  })

  it('takes whatever is composed into it', () => {
    const html = renderToStaticMarkup(
      <PaneBar
        paneId="pane-1"
        subject={SESSION}
        focused
        controls={<span className="probe">opus · high</span>}
        onClose={noop}
      />,
    )
    expect(html).toMatch(/data-slot="session-controls"><span class="probe">/)
  })

  it('is not offered to a page, which has no model and no effort', () => {
    const html = render({ kind: 'page', title: 'localhost:3000' })
    expect(html).not.toContain('data-slot')
  })
})

describe('a pane holding a page', () => {
  const html = render({ kind: 'page', title: 'localhost:3000 — Terminal Deck' })

  it('says what the page is, because that is the true thing there is to say', () => {
    expect(html).toContain('localhost:3000 — Terminal Deck')
    expect(html).toContain('pane-cell-kind')
  })

  it('borrows no part of a session’s chrome', () => {
    /*
     * A page has no account, no folder and no status: there is no agent, no
     * config directory and no pty. Rendering the session bar with those blank
     * would read as a session whose account failed to load, which is a bug
     * report waiting to happen.
     */
    expect(html).not.toContain('account-chip')
    expect(html).not.toContain('folder-title')
    expect(html).not.toContain('status-dot')
  })

  it('still closes, like any other pane', () => {
    expect(html).toContain('aria-label="Close this pane"')
  })
})

describe('a pane nobody has filled', () => {
  const html = render({ kind: 'empty' })

  it('says so plainly and offers nothing else', () => {
    expect(html).toContain('Empty pane')
    expect(html).not.toContain('account-chip')
  })

  it('is flagged so its close button stops hiding', () => {
    // There is nothing else in that header for a reveal-on-hover to protect,
    // and closing it is the only thing you can do to it.
    expect(html).toContain('data-empty="true"')
  })

  it('is offered no controls slot either', () => {
    // The cluster withdraws wherever there is nothing to control — a shell
    // session, a page, and this. The same judgement in all three places, and
    // the same reason: four chips over something with no model would be
    // teaching the reader that this app could set one if only something were
    // different. See `SessionControls.tsx`.
    expect(html).not.toContain('data-slot')
  })
})

/* -------------------------------------------- the window's bar, in a split -- */

/**
 * What the window's bar carries while the window is split: the **host** pane's
 * identity, unmoved.
 *
 * This is the assertion the reverted pass had backwards, so it is the one most
 * likely to be "tidied" back. The tidy looks principled — a bar spanning two
 * panes cannot name both, therefore it should name neither — and it is wrong
 * for a reason that is easy to lose: the two panes are not interchangeable. The
 * host is the pane the window is *about*, drawn flush with no box, with this
 * bar sitting directly on top of it. Emptying it made both panes the same
 * shape, and *"then there is no reason to keep one of them in a box."*
 */
const hostToolbar = (props: { focused?: boolean } = {}): string =>
  renderToStaticMarkup(
    <StoreProvider>
      <WindowToolbar
        title="Wire up split panes"
        sessionId="s1"
        headingFocused={props.focused ?? true}
        meta={
          <div className="toolbar-chips">
            <span className="folder-title">terminaldeck</span>
            <span className="account-chip">Work</span>
          </div>
        }
        sidebarHidden={false}
        underStrip
        onRevealSidebar={noop}
        onEdgeEnter={noop}
      >
        <ModeSwitch mode="split" onChange={noop} />
      </WindowToolbar>
    </StoreProvider>,
  )

describe('the host keeps its chrome in the window’s bar', () => {
  const split = hostToolbar()

  it('names the host session, its folder and its account, up top', () => {
    /*
     * All three, in the toolbar, while the mode switch says "Split". The pane
     * below draws none of them — see the source check further down — so these
     * are the only copy on screen and there is nothing to mistake them for.
     */
    expect(split).toContain('toolbar-heading')
    expect(split).toContain('Wire up split panes')
    expect(split).toContain('terminaldeck')
    expect(split).toContain('Work')
  })

  it('renames from up there, exactly as it does unsplit', () => {
    // The gesture must not move house when a window is split: it is the same
    // heading, in the same place, over the same session. `sessionId` is what
    // makes it one — drop it and `SessionTitle` correctly draws a plain <h1>.
    expect(split).toContain('double-click or F2 to rename')
    expect(split).toContain('aria-keyshortcuts="F2"')
  })

  it('keeps the mode switch, which is the way back out of the split', () => {
    // The one control here that is genuinely the window's. Hiding it because
    // the host pane happens to hold a page would shut the door behind you.
    expect(split).toContain('mode-switch')
    expect(split).toContain('aria-pressed="true"')
  })

  it('draws the heading back when the keyboard is in a guest', () => {
    /*
     * The host has no border to ring — it is flush with the window on purpose —
     * so this attribute is its entire focus mark, and it is also what teaches
     * the convention. The top bar fades as the guest's bar comes up; two things
     * that dim together are one thing.
     */
    expect(hostToolbar({ focused: false })).toContain('data-focused="false"')
    expect(split).toContain('data-focused="true"')
  })

  it('is at full strength whenever the window shows one thing', () => {
    // The default, because unsplit there is nowhere else for focus to be and a
    // permanently half-lit title reads as a disabled app.
    const single = renderToStaticMarkup(
      <StoreProvider>
        <WindowToolbar
          title="Wire up split panes"
          sessionId="s1"
          sidebarHidden={false}
          underStrip
          onRevealSidebar={noop}
          onEdgeEnter={noop}
        >
          <ModeSwitch mode="terminal" onChange={noop} />
        </WindowToolbar>
      </StoreProvider>,
    )
    expect(single).toContain('data-focused="true"')
    expect(single).toContain('double-click or F2 to rename')
  })

  it('says nothing when there is nothing to name', () => {
    // A launch with nothing open, and a split whose host pane is empty. A
    // heading is absent rather than blank — see `App.tsx`, which deliberately
    // does *not* fall back to the active tab there, because the active tab
    // while split can be the guest.
    const blank = renderToStaticMarkup(
      <WindowToolbar
        title={null}
        sidebarHidden={false}
        underStrip
        onRevealSidebar={noop}
        onEdgeEnter={noop}
      >
        <ModeSwitch mode="split" onChange={noop} />
      </WindowToolbar>,
    )
    expect(blank).not.toContain('toolbar-heading')
    expect(blank).toContain('mode-switch')
  })
})

/**
 * The two halves of the arrangement, read out of `App.tsx`.
 *
 * A rendered string cannot see which pane got a bar, because the pane tree is
 * not mounted here — so this reads the source, the way `wiring.test.ts` and
 * `reachable.test.ts` already do for the seams a static render cannot show.
 */
describe('only the guests draw a bar of their own', () => {
  const APP = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8')

  it('renders PaneBar for a guest and not for the host', () => {
    /*
     * `{!primary && (<PaneBar` is the whole correction of 2026-08-17, and it is
     * one character away from being undone. Without it the host states its name,
     * folder and account twice — once in the window's bar and once forty pixels
     * below — and with the window's heading removed instead, the two panes
     * become identical and the box is arbitrary.
     */
    const at = APP.indexOf('<PaneBar')
    expect(at, 'PaneBar is no longer rendered by App.tsx').toBeGreaterThan(0)
    expect(APP.slice(Math.max(0, at - 120), at)).toContain('{!primary && (')
  })

  it('reads the host off the same traversal that boxes the guests', () => {
    // Two answers to "which pane is the host" is how a window ends up drawing
    // one pane's box around another pane's chrome. `primaryPane` is the single
    // answer; `SplitView` uses it too.
    expect(APP).toContain('primaryPane(panes)')
    expect(APP).toMatch(/primaryPane,[\s\S]{0,80}from '\.\/layout\/pane-tree'/)
    expect(
      readFileSync(join(__dirname, '..', 'layout/SplitView.tsx'), 'utf8'),
      'SplitView has gone back to working the host out for itself',
    ).toContain('primaryPane(layout)')
  })

  it('does not let the window’s heading follow focus', () => {
    /*
     * A heading that changed with the focused pane would be the original bug
     * wearing a disguise — still one heading over two sessions, just changing
     * its mind about which. It reads the host's tab, and it has no fallback to
     * the active tab, because while split the active tab can be the guest.
     */
    expect(APP).toContain('hostPane?.tabId')
    expect(APP).not.toMatch(/const headingTab = splitting\s*\n\s*\?\s*tabs\.find/)
  })

  it('leaves a way to close the host, since it has no ✕ of its own', () => {
    /*
     * Every guest bar draws one. The host has no bar, so without this the pane
     * the window is about could never be closed — and with three panes there is
     * not even an equivalent route through the mode switch. A capability with
     * no glyph belongs in the palette, which is where people look for one.
     */
    expect(APP).toContain("id: 'pane.close'")
    expect(APP).toContain('Close the focused pane')
    // Only while there is a split. Outside one it would run and do nothing,
    // which is the shape `keymap.ts` argues against beside ⌘D.
    const row = APP.indexOf("id: 'pane.close'")
    expect(APP.slice(Math.max(0, row - 200), row)).toContain('...(splitting')
  })
})

/* ------------------------------------------------- the shape of the split -- */

/**
 * The primary/secondary treatment, read out of the stylesheets.
 *
 * There is no layout engine in this test run, so the alternative to reading the
 * sheet is nothing at all — and what these guard is the pair of rules that only
 * mean anything together. Asad:
 *
 *   > *"The first view, main view, can be on the left side with the overall same
 *   > background, everything. The other one — the new split view, secondary
 *   > view — it can be only inside a box, and the other one will not be inside a
 *   > box."*
 *
 * A future edit is most likely to "tidy" this by giving both panes the same
 * treatment again, because symmetry looks like the cleaner rule right up until
 * you remember that it is the thing that made the two panes indistinguishable.
 */
describe('the split is deliberately not symmetrical', () => {
  const read = (file: string): string =>
    readFileSync(join(__dirname, '..', file), 'utf8')
  const SPLIT = read('layout/SplitView.css')
  const SHELL = read('shell/shell.css')
  const rule = (css: string, selector: string): string =>
    new RegExp(`${selector.replace(/[.[\]='*]/g, (c) => `\\${c}`)} \\{[\\s\\S]*?\\n\\}`).exec(
      css,
    )?.[0] ?? ''

  it('boxes the second pane and every one after it', () => {
    const box = rule(SPLIT, ".pane-leaf[data-primary='false']")
    expect(box, 'the boxed pane has lost its rule').not.toBe('')
    // Three things make a box: room around it, a corner, and a lift off the
    // desk it is sitting on.
    expect(box).toContain('margin: var(--sp-2)')
    expect(box).toContain('border-radius: var(--radius-lg)')
    expect(box).toContain('box-shadow: var(--shadow-sm)')
  })

  it('leaves the first pane flush with the window', () => {
    const host = rule(SPLIT, ".pane-leaf[data-primary='true']")
    expect(host).toContain('border-radius: 0')
    expect(host).not.toContain('margin')
    // And no ring: the window's own edge is already this pane's boundary, so a
    // second one drawn inside it is the extra separation the brief forbids.
    expect(SPLIT).toContain(".pane-leaf[data-primary='true']::after")
  })

  it('does not inset the whole grid, or "flush" cannot mean flush', () => {
    // `.split-view:has(> .pane-split) { padding: var(--sp-2) }` is what used to
    // float both panes as cards; with it, the primary pane sits eight pixels
    // off the window's own edges.
    expect(SPLIT).not.toMatch(/\.split-view:has\(> \.pane-split\) \{\s*padding/)
  })

  it('gives both panes the same focus mark, so there is one idiom and not two', () => {
    /*
     * The box says it in its border; the flush pane has no border to say it in.
     * What both of them have is a *name*, and the mark is that the name dims
     * when the keyboard is elsewhere — in the guest's own bar, and for the
     * host, in the window's toolbar where its name lives.
     *
     * The two weights are asserted equal rather than merely present. Drift them
     * and clicking between panes changes two things by different amounts, which
     * stops reading as one thing swapping and starts reading as two bugs.
     */
    expect(SHELL).toContain(".pane-cell-head[data-focused='false']")
    expect(SHELL).toContain(".toolbar-heading[data-focused='false']")
    expect(SPLIT).toContain(".pane-leaf[data-focused='true']::after")

    const dim = (selector: string): string | undefined =>
      /opacity:\s*([\d.]+)/.exec(rule(SHELL, selector))?.[1]
    expect(dim(".pane-cell-head[data-focused='false']")).toBe('0.55')
    expect(dim(".toolbar-heading[data-focused='false']")).toBe(
      dim(".pane-cell-head[data-focused='false']"),
    )
  })

  it('fades the swap in both directions', () => {
    // A transition is read off the style the element is moving *to*, so one
    // written only on the dimmed state fades out and then snaps back. Both of
    // these therefore have to be on the base rule.
    expect(rule(SHELL, '.toolbar-heading')).toContain('transition: opacity')
    expect(rule(SHELL, '.pane-cell-head')).toContain('transition: opacity')
  })
})

/**
 * *"Just the text will be a little bit folded to left to stay in place."*
 *
 * The window's bar now carries the host session's name, its folder and its
 * account alongside the mode switch, and a window can be dragged narrow enough
 * that all of that does not fit. What must happen then is that the heading
 * loses characters and everything else stays exactly where it is — the switch
 * must not be pushed off the right-hand edge, and the heading must not wrap into
 * a second line and change the bar's height.
 *
 * There is no layout engine in this test run, so what is pinned is the chain of
 * declarations that produces it. Every one of them has a way of being deleted
 * as redundant, and each deletion breaks the bar only at a width nobody tests
 * at.
 */
describe('the heading gives way before any control does', () => {
  const SHELL = readFileSync(join(__dirname, 'shell.css'), 'utf8')
  const rule = (selector: string): string =>
    new RegExp(`${selector.replace(/[.[\]='*]/g, (c) => `\\${c}`)} \\{[\\s\\S]*?\\n\\}`).exec(
      SHELL,
    )?.[0] ?? ''

  it('lets the heading shrink below its own content', () => {
    // A flex item's automatic minimum is its content, so without `min-width: 0`
    // the heading refuses to get smaller and the overflow is taken out of
    // whatever is beside it — which here is the mode switch.
    expect(rule('.toolbar-lead')).toContain('min-width: 0')
    expect(rule('.toolbar-heading')).toContain('min-width: 0')
  })

  it('spends that room on an ellipsis rather than a second line', () => {
    for (const selector of ['.toolbar-title', '.folder-title', '.account-chip-name']) {
      const body = rule(selector)
      expect(body, `${selector} has lost its rule`).not.toBe('')
      expect(body, selector).toContain('white-space: nowrap')
      expect(body, selector).toContain('text-overflow: ellipsis')
      // `overflow: hidden` is doing two jobs and only one of them is visible:
      // it is also what makes the automatic minimum size zero, so a nowrap
      // heading can actually be squeezed.
      expect(body, selector).toContain('overflow: hidden')
    }
  })

  it('keeps the account chip inside the heading rather than across the bar', () => {
    /*
     * An inline-flex box is as wide as its contents and paints straight out of
     * a parent that is narrower — so on a small window this chip drew a whole
     * email address over the controls on the right while the heading it belongs
     * to had already given up all of its width.
     *
     * The `+ var(--sp-1)` is not a fudge: the chip is pulled four pixels left of
     * its box by `margin-left`, so its right edge only reaches the parent's at
     * `100% + 4px`. Plain `100%` takes those four pixels off the far end
     * instead, and an account named "Work" renders as "W…" on a window with
     * three hundred spare pixels.
     */
    const chip = rule('.folder-chip-button')
    expect(chip).toContain('min-width: 0')
    expect(chip).toContain('max-width: calc(100% + var(--sp-1))')
    expect(chip).toContain('margin-left: calc(var(--sp-1) * -1)')
  })

  it('never lets the controls be the thing that moves', () => {
    // The switch is `flex-shrink: 0` inside a slot that is `flex-shrink: 0`,
    // and the drag region between them is the elastic. Take either away and the
    // segmented control starts losing its words instead of the title.
    expect(rule('.toolbar-actions')).toContain('flex-shrink: 0')
    expect(rule('.toolbar-drag')).toContain('flex: 1')
  })
})

/**
 * The band and the thing under it are one surface, in both appearances.
 *
 * The rule for the window's bar — measured, argued and written up under
 * `--tab-active` in `tokens.css` — now has to hold one level further in,
 * because the band that sits on a terminal is the pane's. In the dark theme the
 * paper and the canvas are the same colour and it is free; in the light theme
 * the terminal is a recessed grey and the app's chrome is white, so a bar
 * painted with the canvas stands twenty-three levels above its own session.
 */
describe('a pane’s bar is the same surface as the pane’s content', () => {
  const read = (file: string): string => readFileSync(join(__dirname, '..', file), 'utf8')

  it('paints the bar with the terminal’s own paper', () => {
    expect(read('shell/shell.css')).toMatch(
      /\.pane-cell-head \{[\s\S]*?background: var\(--terminal-bg\);/,
    )
  })

  it('paints the pane and its body with the same token', () => {
    const split = read('layout/SplitView.css')
    expect(split).toMatch(/\.pane-leaf \{[\s\S]*?background: var\(--terminal-bg\);/)
    expect(split).toMatch(/\.pane-leaf-body \{[\s\S]*?background: var\(--terminal-bg\);/)
  })
})
