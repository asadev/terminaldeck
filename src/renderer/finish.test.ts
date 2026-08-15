import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The finish pass, pinned.
 *
 * A whole class of defect in this app is invisible to both the type checker and
 * a code review: the CSS reads correct and the rendered result is wrong. The
 * folder chip is the case that proves it — `z-index: 40`, `position: absolute`,
 * full glass, all of it correct on the page and none of it on the screen, and
 * the menu opened *under* the terminal in all three modes with no error
 * anywhere. Nobody would report it, either, because you cannot see a thing that
 * paints under an opaque canvas: the chip just looks like it does nothing.
 *
 * So the facts a look-with-your-eyes pass established are written down here, in
 * the shape the rest of this repository already uses for the same problem —
 * `wiring.test.ts` and `tokens.test.ts` both read the real files rather than
 * mounting a tree, because this project deliberately has no DOM in its tests.
 * These are not style opinions; each one is a rule that was broken, found by
 * rendering the app and measuring it, and is cheap to break again.
 */

const SRC = join(__dirname, '..', '..', 'src')
const read = (rel: string): string => readFileSync(join(SRC, rel), 'utf8')

/** The body of one CSS rule, by selector. Rules in this repo do not nest. */
function rule(css: string, selector: string): string | null {
  const at = css.indexOf(`\n${selector} {`)
  if (at < 0) return null
  const end = css.indexOf('\n}', at)
  return end < 0 ? null : css.slice(at, end)
}

/* ------------------------------------------------------- the folder chip -- */

describe('the folder chip can actually be used', () => {
  const shell = read('renderer/shell/shell.css')
  const chip = read('renderer/shell/FolderChip.tsx')

  /**
   * The stacking half.
   *
   * `backdrop-filter` makes the toolbar a stacking context, and a stacking
   * context on a *static* box paints with the in-flow content — beneath every
   * positioned descendant of `.panes`, whatever z-index it asks for. Positioning
   * the toolbar is what enters the chrome into the same layer race as the work.
   */
  it('puts the toolbar in a layer above the panes', () => {
    const toolbar = rule(shell, '.toolbar')
    expect(toolbar, '.toolbar has no rule any more').toBeTruthy()
    expect(toolbar).toMatch(/position:\s*relative/)
    const z = /z-index:\s*(\d+)/.exec(toolbar ?? '')?.[1]
    expect(z, '.toolbar declares no z-index, so its glass is in-flow content').toBeTruthy()
    expect(Number(z)).toBeGreaterThan(0)
  })

  /**
   * The frosting half, and the reason a z-index alone was not the whole fix.
   *
   * An element carrying `backdrop-filter` is a *backdrop root*: a descendant's
   * own `backdrop-filter` may only sample what is painted inside that ancestor.
   * Inside the toolbar's glass the menu declared a 26px blur and blurred
   * nothing at all, and the terminal read straight through its labels. Rendered
   * under <body> the backdrop is the document.
   */
  it('renders the menu outside the toolbar, so its glass has something to frost', () => {
    expect(chip).toContain('createPortal')
    expect(chip).toContain('document.body')
    const menu = rule(shell, '.folder-menu')
    expect(menu).toMatch(/position:\s*fixed/)
    expect(menu, 'a portalled menu must still wear the app glass').toMatch(/backdrop-filter/)
  })

  it('still dismisses on a click that lands outside both halves', () => {
    // The menu is no longer inside the chip's own element, so a check against
    // the chip alone would treat a click on one of the menu's rows as a click
    // outside and close it before the row's handler ran.
    expect(chip).toMatch(/menuRef\.current\?\.contains/)
    expect(chip).toMatch(/hostRef\.current\?\.contains/)
  })
})

/* ---------------------------------------------------- scrolling and edges -- */

describe('a scrolling region fades instead of slicing', () => {
  const app = read('renderer/styles/app.css')

  it('defines the fade once, and registers the lengths so they can animate', () => {
    expect(app).toContain('@property --scroll-fade-head')
    expect(app).toContain('@property --scroll-fade-foot')
    const fade = rule(app, '.scroll-fade')
    expect(fade).toMatch(/mask-image/)
    expect(fade, 'a static mask dims the first line of an unscrolled region').toMatch(
      /animation-timeline:\s*scroll\(/,
    )
  })

  /**
   * Five separate surfaces were caught cutting text through the middle of the
   * glyphs at a scroll edge in one sweep. They are listed by file because the
   * fix is one class and the failure is forgetting to put it on the sixth.
   */
  it.each([
    ['renderer/settings/SettingsWindow.tsx', 'settings-panel'],
    ['renderer/components/ShortcutsSheet.tsx', 'sheet'],
    ['renderer/dashboard/Dashboard.tsx', 'widget-body'],
    ['renderer/chat/controls/AgentControls.tsx', 'ac-sheet'],
  ])('%s wears it on .%s', (file, className) => {
    expect(read(file)).toMatch(new RegExp(`className="${className} scroll-fade`))
  })
})

/* ------------------------------------------------------- nothing is warm -- */

describe('the only colour in the chrome is the blue', () => {
  it('does not paint a session at its own prompt in the warning amber', () => {
    const css = read('renderer/styles/app.css')
    // The `waiting` dot has no rule of its own any more: it is the base
    // `.status-dot`, which is the same hollow ring `idle` gets. What has to
    // stay true is that neither of them is painted the warning colour.
    expect(rule(css, ".status-dot[data-status='waiting']")).toBeNull()
    const base = rule(css, '.status-dot')
    expect(base, '.status-dot lost its base rule').toBeTruthy()
    expect(base).not.toContain('--status-waiting')
    expect(base, 'the resting mark is a ring, not a filled dot').toContain('inset 0 0 0 1.5px')
  })

  it('calls that state what it is, and says the same of the state beside it', () => {
    // "Waiting" reads as blocked on something. It is reached by SessionStart
    // and by a shell sitting at `%`, which is a session in perfect health.
    // "Idle" is the classifier's fallback and means the same thing to a reader
    // — two words for one situation is one word too many.
    const source = read('renderer/components/StatusDot.tsx')
    expect(source).toMatch(/waiting:\s*'Ready'/)
    expect(source).toMatch(/idle:\s*'Ready'/)
  })

  it('does not spend a session-status token on a GitHub notification', () => {
    const css = read('renderer/components/GitHubPanel.css')
    expect(rule(css, ".gh-bell[data-mine='true']")).not.toContain('--status-input')
    // The rule down the left edge that `UpdateBanner.css` records removing.
    expect(rule(css, '.gh-conn-missing')).not.toMatch(/border-left/)
  })
})

/* -------------------------------------------------------- nothing is fake -- */

describe('a shell session is not described as an agent', () => {
  const view = read('renderer/components/ChatView.tsx')

  it('has a state of its own rather than borrowing "no transcript yet"', () => {
    expect(view).toMatch(/\|\s*'shell'/)
    expect(view).toMatch(/provider\s*===\s*'shell'/)
  })

  it('is handed the provider by the app, or it cannot know', () => {
    expect(read('renderer/App.tsx')).toMatch(/provider=\{session\.provider\}/)
  })

  it('withdraws the model, effort and permission pickers', () => {
    // They are read from the CLI's settings file when the session's own screen
    // cannot be parsed, which is how a `/bin/zsh -l` came to report a model of
    // "Opus 5" and a permission mode of "Unknown".
    const controls = read('renderer/chat/controls/AgentControls.tsx')
    expect(controls).toMatch(/const shell = provider === 'shell'/)
    expect(controls).toMatch(/&&\s*!shell/)
  })

  it('does not invite the user to message an agent that is not there', () => {
    expect(view).toMatch(/placeholder=\{shell \?/)
  })
})

/* ------------------------------------------------------ no dead controls -- */

describe('a control that looks pressable answers', () => {
  it('will not let an empty MCP form submit into silence', () => {
    const form = read('renderer/components/McpAddForm.tsx')
    expect(form).toContain('export function missingFrom')
    expect(form).toMatch(/disabled=\{busy \|\| missing !== null\}/)
  })

  it('greys the update check on a build that cannot be updated', () => {
    const about = read('renderer/settings/sections/AboutSection.tsx')
    expect(about).toMatch(/const checkable = about\?\.updates\?\.checkable/)
    expect(about).toMatch(/disabled=\{about !== null && !checkable\}/)
  })

  it('lets the sound be previewed whether or not anything plays it for you', () => {
    // It used to disable itself and print a sentence explaining the disabling,
    // which is a control that looks pressable, is not, and needs a manual.
    const notifications = read('renderer/settings/sections/NotificationsSection.tsx')
    expect(notifications).toMatch(/<Button onClick=\{testSound\}>Test<\/Button>/)
  })
})

/* ------------------------------------------------- wired to boot, not a button */

describe('a renderer that reloads does not orphan its ptys', () => {
  /**
   * This repository's stated bug class is a feature wired to a button and never
   * wired to boot. This is its sibling and it had shipped: the session list
   * lived only in renderer state, so ⌘R emptied the sidebar while the ptys
   * carried on running under the main process — verified with `ps`, a
   * `/bin/zsh -l` still parented to Electron with no row in the window able to
   * reach it or close it. `session:list` and `session:scrollback` both already
   * existed; nothing had ever called the first one.
   */
  it('asks the main process what is still running, on mount', () => {
    const app = read('renderer/App.tsx')
    expect(app).toMatch(/window\.deck\s*[\s\S]{0,40}\.listSessions\(\)/)
  })

  it('does not put that behind the restore-projects preference', () => {
    // A pty running *right now*, in this very main process, is not something a
    // "reopen what I had last time" setting has an opinion about.
    const app = read('renderer/App.tsx')
    const effect = /listSessions\(\)[\s\S]*?\}, \[([^\]]*)\]\)/.exec(app)?.[1] ?? ''
    expect(effect).not.toMatch(/settings/)
  })
})

/* --------------------------------------------------- filling the window -- */

describe('an empty view is centred in what it was dropped into', () => {
  const shell = read('renderer/shell/shell.css')

  it('no longer parks the blank at a fraction of the viewport', () => {
    // `vh` is the window; the container is a pane. The same rule that looked
    // deliberate in a full-height panel put the message 290px above the middle
    // of a split pane with half the window empty underneath it.
    expect(rule(shell, '.page-blank')).not.toMatch(/\dvh/)
    expect(rule(shell, '.page-blank-line[data-page]')).not.toMatch(/\dvh/)
  })

  it('centres it from the container, which is the only thing that knows', () => {
    expect(shell).toMatch(/\.pane-cell-body:has\(> \.page-blank:only-child\)/)
  })

  it('does the same for the conversation', () => {
    expect(read('renderer/components/ChatView.css')).toMatch(/\.cv-scroll:has\(> \.cv-empty\)/)
  })
})
