import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

import { PANELS } from './shell/panels'

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

/**
 * Every hand-written source file under a folder of the renderer, recursively.
 *
 * Tests are left out because a test naming a thing is not the app doing it —
 * this very file mentions `useChipMenu` and would otherwise count itself as a
 * menu, which is the sort of self-reference that makes a derived enumeration
 * quietly wrong.
 */
function sourcesUnder(rel: string): string[] {
  const found: string[] = []
  const walk = (dir: string): void => {
    for (const entry of readdirSync(join(SRC, dir), { withFileTypes: true })) {
      const child = `${dir}/${entry.name}`
      if (entry.isDirectory()) walk(child)
      else if (/\.tsx?$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name)) found.push(child)
    }
  }
  walk(rel)
  return found.sort()
}

/** Every source file in the renderer, for the "declared exactly once" claims. */
function rendererSources(): string[] {
  return sourcesUnder('renderer')
}

/**
 * The files under these folders that render a menu, found by the markup rather
 * than by the implementation. `role="menu"` is a component telling the
 * accessibility tree what it is, which is a claim it makes independently of
 * whatever hook it uses to place itself — so a copy-pasted menu is caught by
 * this and a menu that merely imports the hook to read a constant is not.
 */
function menuSourcesIn(folders: readonly string[]): string[] {
  return folders
    .flatMap((folder) => sourcesUnder(folder))
    .filter((file) => read(file).includes('role="menu"'))
    .sort()
}

/* ------------------------------------------------- the chips under a name -- */

describe('the menu under the session’s name can actually be used', () => {
  const shell = read('renderer/shell/shell.css')
  /*
   * There was a pair of chips here — the folder a session runs in and the
   * account it runs as — and the folder half is not a control any more. Asad,
   * 2026-08-16: *"just title is good enough for us to know which folder we are
   * in right now. That's it. Dropdown will be only for the accounts."* He is
   * right for a mechanical reason: a pty has one working directory for its whole
   * life, so that menu could only ever have offered to start a *different*
   * session, which is a thing three other controls in the window already do.
   *
   * What the folder half leaves behind is this file's original subject — the
   * two invisible failures that made its menu unusable while every line of its
   * CSS read correct. Both are properties of the *toolbar*, not of that chip, so
   * both still have to hold for the account menu that is still there.
   */
  const chip = read('renderer/shell/AccountChip.tsx')
  const title = read('renderer/shell/FolderChip.tsx')
  const menuMechanics = read('renderer/shell/chip-menu.ts')

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
   * The same claim for the bar that is now above it.
   *
   * The strip took the top band on 2026-08-17 and took glass with it, which
   * means it took this trap with it too. It has no menu to lose — the ＋ that
   * briefly sat on each tab was taken off again, and `the chrome's menus` below
   * records that — but the menu was never the only thing at stake. The bar
   * itself is the glass: a `backdrop-filter` box left static paints with the
   * in-flow content, so the strip would go *under* every positioned descendant
   * of `.panes`, and the tabs you are meant to be clicking would be behind the
   * terminal. The folder chip proved the mechanism with a menu; the strip is
   * exposed to it with no menu at all.
   */
  it('puts the tab strip in one too, now that it wears the same glass', () => {
    const strip = rule(read('renderer/browser/WorkspaceTabStrip.css'), '.strip')
    expect(strip, '.strip has no rule any more').toBeTruthy()
    expect(strip).toMatch(/position:\s*relative/)
    const z = /z-index:\s*(\d+)/.exec(strip ?? '')?.[1]
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
    // The menu is not inside the chip's own element, so a check against the
    // chip alone would treat a click on one of the menu's rows as a click
    // outside and close it before the row's handler ran.
    expect(menuMechanics).toMatch(/menuRef\.current\?\.contains/)
    expect(menuMechanics).toMatch(/hostRef\.current\?\.contains/)
  })

  /**
   * The reason the two fixes above are worth a hook rather than a paste.
   *
   * Written twice they would have to be fixed twice, and the copy that gets
   * forgotten is the one a person actually clicks. Neither failure announces
   * itself: a menu that paints under the terminal and a menu that dismisses on
   * its own rows both look like "the button does nothing".
   *
   * ## Why this clause is derived and not a list
   *
   * It was a list, and the list went stale inside a day. It read
   * `[chip, strip]` and required `useChipMenu` of `WorkspaceTabStrip.tsx`,
   * written while every tab still carried a ＋ with a menu behind it. Asad then
   * asked for the ＋ to come off the pills, it came off, and the clause was left
   * demanding machinery that had been correctly deleted — a red test that was
   * not reporting a defect in the app but a defect in itself, which is the worst
   * kind because the honest fix for it looks like weakening a test.
   *
   * So the set is now read out of the tree. A menu is found by its own markup —
   * `role="menu"`, what it tells the accessibility tree it is — and not by the
   * hook it happens to call, because a set filtered on `useChipMenu` and then
   * asserted to use `useChipMenu` is a tautology that an empty set also
   * satisfies. `toEqual` on the enumeration is the part that bites: a second
   * menu appearing in the chrome fails this test until somebody comes here and
   * says whether it shares the mechanics, which is exactly the conversation the
   * ＋ never had.
   */
  it('gives every menu in the chrome the same mechanics, rather than a copy each', () => {
    const menus = menuSourcesIn(['renderer/shell', 'renderer/browser'])
    expect(
      menus,
      'the chrome gained or lost a menu — say here whether it shares the mechanics',
    ).toEqual(['renderer/shell/AccountChip.tsx'])

    for (const file of menus) {
      const source = read(file)
      expect(source, `${file} carries its own menu mechanics`).toContain('useChipMenu')
      expect(source, `${file} renders its menu inside the toolbar's backdrop root`).toContain(
        'createPortal',
      )
      expect(source).toContain('document.body')
    }
  })

  /**
   * The other half of "one implementation", and the half a hook cannot enforce.
   *
   * A hook is only shared while people call it; nothing stops the next menu from
   * pasting the placement maths and its own document listener instead, which is
   * precisely how this class of bug spread the first time. Both are therefore
   * asserted to exist exactly once in the whole renderer, so a paste has to
   * survive a failing test rather than a code review.
   */
  it('declares those mechanics in exactly one module', () => {
    const declaresPlacement = rendererSources().filter((file) =>
      read(file).includes('export function placeMenu'),
    )
    expect(declaresPlacement).toEqual(['renderer/shell/chip-menu.ts'])

    const declaresHook = rendererSources().filter((file) =>
      read(file).includes('export function useChipMenu'),
    )
    expect(declaresHook).toEqual(['renderer/shell/chip-menu.ts'])
  })

  /**
   * The ＋ that was taken off the pills, kept out.
   *
   * Inverted rather than deleted, the same way the GitHub bell is further down
   * this file: a returning ＋ should have to come here and argue for itself.
   * Asad's reason for removing it stands on its own — a tab is a thing you have
   * open, and hanging "make me another one" off each of them put the same
   * command on the bar as many times as there were windows, when the strip
   * already ends in one opener that does it once.
   */
  it('leaves a strip tab as a tab, with no menu hanging off it', () => {
    const strip = read('renderer/browser/WorkspaceTabStrip.tsx')
    expect(strip).not.toContain('useChipMenu')
    expect(strip).not.toContain('createPortal')
    expect(strip).not.toContain('role="menu"')
    // The tab's own controls are the face and the ✕, and that is the whole list.
    expect(strip).toContain('strip-tab-close')
  })

  it('leaves the folder as a title, with no menu mechanics at all', () => {
    /*
     * Not an omission — the point. A control here would have to answer "what
     * happens to the session I am in", and the only true answer is "nothing,
     * a different one starts". The word says where you are and the tooltip says
     * why there is no chevron.
     */
    expect(title).not.toContain('useChipMenu')
    expect(title).not.toContain('createPortal')
    expect(title).not.toContain('<button')
    expect(title).toContain('keeps this folder for its whole life')
  })
})

/* ------------------------------------------ the row gives before it scrolls -- */

/**
 * A tab strip that compresses before it scrolls, which for a while it did not.
 *
 * `.strip-tab` has carried `flex: 0 1 auto` with a 144px floor and a 280px cap
 * since the pills were widened, and the note above it says the row "compresses
 * to the floor before the rail starts scrolling". It did not. `.strip-list` — the
 * flex *parent* — was left at the default `min-width: auto`, which is a flex
 * item's content-based minimum and not zero, so the list could never be squeezed
 * below its max-content width and the shrink factor on the tabs was dead code.
 *
 * Measured in Chrome against the real stylesheet, ten tabs each with a project
 * qualifier. Before: 255px per tab at 1600px, at 820px and at 620px — the
 * natural width at every size — with the rail scrolling at all three. After:
 * 144px per tab and no scroll at 1600px, 144px with a scroll at 820px, and
 * 174px with no scroll at four tabs.
 *
 * Pinned as the parent's declaration rather than as a rendered width because
 * this repo's tests have no DOM and no layout engine; the measurement is what
 * chose the fix, and this is what keeps the fix. The two rules only work
 * together, so removing either one should fail.
 */
describe('the tab strip gives its tabs up before it makes you scroll', () => {
  const strip = read('renderer/browser/WorkspaceTabStrip.css')

  it('lets the row shrink, by clearing the flex parent’s automatic minimum', () => {
    const list = rule(strip, '.strip-list')
    expect(list, '.strip-list has no rule any more').toBeTruthy()
    expect(
      list,
      '.strip-list is a flex item; without min-width:0 its tabs cannot shrink at all',
    ).toMatch(/min-width:\s*0/)
  })

  it('keeps the floor, the cap and the shrink factor that do the compressing', () => {
    const tab = rule(strip, '.strip-tab')
    expect(tab, '.strip-tab has no rule any more').toBeTruthy()
    // `flex-shrink` of 1 is the middle number; `0 0 auto` would freeze the row
    // at its natural width again and the rail would go back to scrolling early.
    expect(tab).toMatch(/flex:\s*0\s+1\s+auto/)
    expect(tab, 'the floor is the width the pills were widened back to').toMatch(
      /min-width:\s*var\(--strip-tab-w\)/,
    )
    expect(tab, 'without a cap a single long title takes the whole bar').toMatch(/max-width:/)
  })

  it('still scrolls once the floor is reached, rather than squeezing past it', () => {
    // The floor is only honoured because the rail is the thing that overflows.
    // A rail that clipped instead would hide tabs with no way to reach them.
    const rail = rule(strip, '.strip-rail')
    expect(rail).toMatch(/overflow-x:\s*auto/)
    expect(rail, 'the rail must be able to shrink or it never overflows').toMatch(/min-width:\s*0/)
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
   *
   * Which is exactly what happened: the sidebar was the sixth, found on a
   * rendered window with the region ending at y=832 and a session row drawn at
   * 817, so the rail's last row was sliced through its letters right above the
   * Settings foot. It is on this list now — the list is the thing that makes
   * "the app already decided how to fix this" survive the next surface.
   */
  it.each([
    ['renderer/settings/SettingsWindow.tsx', 'settings-panel'],
    ['renderer/components/ShortcutsSheet.tsx', 'sheet'],
    ['renderer/dashboard/Dashboard.tsx', 'widget-body'],
    // Was `chat/controls/AgentControls.tsx`, `.ac-sheet`. That component was
    // the composer's copy of the control cluster, and it went with the control
    // row he asked to be removed from the chat box. The sheet it named is now
    // the chrome's, drawn by `SessionControls.tsx` as `.sc-sheet` — so the
    // entry moved rather than being deleted, which would have quietly dropped
    // the one place this fade is now needed.
    ['renderer/shell/SessionControls.tsx', 'sc-sheet'],
    ['renderer/shell/Sidebar.tsx', 'sidebar-scroll'],
  ])('%s wears it on .%s', (file, className) => {
    expect(read(file)).toMatch(new RegExp(`className="${className} scroll-fade`))
  })
})

/* ----------------------------------------------- a heading fits its line -- */

/**
 * The window's bar truncating a sentence it wrote itself.
 *
 * Found on a 2880px-wide window with 842px of empty bar to the right of the
 * text: the Copilot page's line rendered *"…the diffs, the p…"* because
 * `.toolbar-subtitle` was capped at `46ch`, a number chosen back when this line
 * carried a project path. The path is a chip now. The cap stayed, and the app's
 * own copy had grown past it.
 *
 * Two halves, and both have to hold or the defect comes back from the other
 * side. The cap has to be a measure wide enough for the copy — and the copy has
 * to stay inside the measure, which is the half no CSS can enforce and the half
 * that will actually be broken, by somebody writing one more clause into a
 * blurb a year from now.
 */
describe('a page heading fits the sentence it was given', () => {
  const shell = read('renderer/shell/shell.css')

  /**
   * The measure, in characters, and the number the CSS is set to.
   *
   * 75 is the top of the classic 45–75 range for a readable line. The `ch`
   * figure is the same measure converted at the size this line is actually set
   * at, measured on the rendered bar rather than assumed: at `--t-caption` the
   * shipped copy averages 4.91px per character while `1ch` is 6.61px, so 75
   * characters is 56ch. Both numbers are here so that changing one without the
   * other fails rather than quietly re-opening the bug.
   */
  const MEASURE_CHARS = 75
  const MEASURE_CH = 56

  it('caps the line at a reading measure, not at a leftover number', () => {
    const sub = rule(shell, '.toolbar-subtitle')
    expect(sub, '.toolbar-subtitle has no rule any more').toBeTruthy()
    expect(sub).toMatch(new RegExp(`max-width:\\s*${MEASURE_CH}ch`))
  })

  it('does not owe that cap the position of the controls beside it', () => {
    // The old note credited the cap with keeping the actions on screen, which
    // is why raising it felt dangerous. It never did that job: the heading is a
    // flex item that yields, and these two `min-width: 0` declarations are the
    // whole of it. If they went, a wide cap really would push the bar's
    // controls off the right-hand edge of a narrow window.
    expect(rule(shell, '.toolbar-lead')).toMatch(/min-width:\s*0/)
    expect(rule(shell, '.toolbar-heading')).toMatch(/min-width:\s*0/)
  })

  /**
   * The copy, against the measure it has to live in.
   *
   * Every panel's blurb, read from `panels.ts` itself rather than from a list
   * copied into this test — a list that has to be kept in step is a list that
   * stops matching the app and then passes forever. The one that failed was 68
   * characters against a cap that held about 62.
   */
  it.each(PANELS.map((panel) => [panel.label, panel.blurb] as const))(
    '%s says it in one line',
    (_label, blurb) => {
      expect(blurb.length).toBeLessThanOrEqual(MEASURE_CHARS)
    },
  )
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
    /*
     * There is no bell any more, so the strongest form of "it does not spend a
     * session-status colour on a notification" is that the rule is gone.
     *
     * The notifications feature was removed when the app moved to a GitHub App
     * sign-in: GitHub's notifications endpoints accept only classic personal
     * access tokens, and a GitHub App user token is not one — no permission can
     * be added to change that, so the feature could not work at all. This
     * assertion is inverted rather than deleted because a returning bell should
     * have to come here and argue for its colour again.
     */
    expect(rule(css, ".gh-bell[data-mine='true']")).toBeNull()
    expect(css).not.toContain('gh-bell')

    /*
     * Asserted over the whole stylesheet rather than against two named rules.
     *
     * Both rules this test used to reach for — `.gh-bell[data-mine='true']` and
     * `.gh-conn-missing` — no longer exist, and `rule()` answers `null` for a
     * selector it cannot find, which is not a failure so much as a test that has
     * quietly stopped checking anything. The rule being defended is a property
     * of the panel, not of two selectors that happened to hold it, so it is now
     * stated that way and cannot rot the same way twice.
     */
    expect(css).not.toContain('--status-input')
    // The accent bar down the left edge that `UpdateBanner.css` records removing.
    expect(css).not.toMatch(/border-left:\s*[^;]*var\(--/)
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
    //
    // This used to read the composer's copy, which withdrew each picker
    // individually behind a `!shell` guard. That copy is deleted along with the
    // control row it lived in, and the chrome answers the same question more
    // bluntly — it draws no cluster at all for a shell — so the assertion is
    // against the early return rather than against four separate guards.
    const controls = read('renderer/shell/SessionControls.tsx')
    expect(controls).toMatch(/if \(provider === 'shell'\) return null/)
  })

  it('does not invite the user to message an agent that is not there', () => {
    expect(view).toMatch(/placeholder=\{shell \?/)
  })

  /**
   * The same rule, on the chip — where it was being broken in the loudest
   * possible way, by the control contradicting its own tooltip.
   *
   * One frame, read live: the header of a plain-shell session showed
   * `Claude Code · Work`, its `title` attribute read *"A plain shell has no
   * account to sign in to"*, and the body of that same pane in chat mode said
   * *"This session is a shell"*. Three statements, two of them denying the
   * third.
   *
   * Neither half was wrong on its own terms and that is what made it survive: the
   * notice comes from `isolationNotice(provider)`, which is a true statement
   * about the agent a *new* session here would run, while the name and the mark
   * came from `accountForFolder`, which resolves the folder's default account
   * whether or not anything could be handed one. Two subjects, one control.
   *
   * So the chip now decides which subject it is about before it says anything —
   * `names` — and when the answer is "nobody", it names nobody: no account, no
   * agent mark, no account colour, and the notice as the whole tooltip.
   */
  it('does not name an account on a chip that cannot be given one', () => {
    const chip = read('renderer/shell/AccountChip.tsx')
    expect(chip).toContain('const names = current !== null || blocked === null')
    // The label, the mark and the dot all follow that one decision. Each of the
    // three was an independent claim before, which is how they came to disagree.
    expect(chip).toContain("names ? identity.label : 'No login'")
    expect(chip).toMatch(/const mark = names \?/)
    expect(chip).toMatch(/style=\{names && listed \?/)
    // And the notice is the whole tooltip only in that state; over a session
    // that *does* have an account it is one clause about the next session.
    expect(chip).toMatch(/title=\{\s*!names/)
  })
})

/* ------------------------------------------- a list does not spawn processes -- */

/**
 * Reading who an account is signed in as costs a process.
 *
 * `profiles-signin.ts` runs the agent's own `auth status` under that account's
 * configuration directory, so the two hooks that ask are deliberately stingy:
 * `useAccountIdentity` asks about exactly one account — the one the chip on
 * screen is about — and `useAccounts` takes a flag that keeps the whole-list
 * probe behind a menu being opened.
 *
 * The surfaces that most need the address are the ones least able to ask for
 * it. The sidebar draws a row per session and is on screen for the whole life
 * of the window; the Overview board draws a card per session; the Settings
 * picker draws an option per account. Any of them calling a probing hook per
 * row would start a CLI per row on mount, every mount.
 *
 * They read `useKnownSignIns` instead — the answers the chip and the menus have
 * already paid for — and fall back to a label that needs nobody's answer. This
 * is the rule that keeps that true, because the failure it prevents is silent:
 * the labels would look right and the machine would simply get slower.
 */
describe('the lists read sign-in answers rather than asking for them', () => {
  it.each([
    ['renderer/shell/Sidebar.tsx'],
    ['renderer/dashboard/SessionBoard.tsx'],
    ['renderer/settings/sections/AgentsSection.tsx'],
  ])('%s reads the store and starts no probe', (file) => {
    const source = read(file)
    expect(source).toContain('useKnownSignIns')
    expect(source, 'a probe per row').not.toContain('useAccountIdentity')
    expect(source, 'a probe per account in the list').not.toContain('useAccounts(')
  })

  it('keeps the whole-list probe behind a surface that is about the answers', () => {
    /*
     * `useAccounts` is the expensive one — one spawn per account, every time it
     * runs — so its callers are enumerated rather than described, and a third
     * has to come here and say why it can afford it.
     *
     * `AccountsSection` asks because the answers *are* its subject: it is the
     * screen you open to find out which of your logins work. The chip asks with
     * the probe gated on its menu being open, which is the flag's whole reason
     * for existing — the list itself is a file read and lands in milliseconds,
     * and gating that too left the chip unable to name the account for the first
     * second of every session.
     *
     * The copilot's setup flow is the third, and it is the one that pays
     * nothing: it takes the *list* so its account step has rows to draw, and
     * passes `probe: false`, so not a single CLI is spawned by opening it. That
     * promise is asserted below rather than described here — a flow that quietly
     * dropped the flag would start one process per account because somebody
     * clicked Copilot, which is exactly the cost this whole rule is about.
     *
     * The declaring module is filtered out: it is where the hook is written.
     */
    const askers = rendererSources().filter(
      (file) => file !== 'renderer/accounts.ts' && read(file).includes('useAccounts('),
    )
    expect(askers).toEqual([
      'renderer/copilot/CopilotSetup.tsx',
      'renderer/settings/sections/AccountsSection.tsx',
      'renderer/shell/AccountChip.tsx',
    ])
    expect(read('renderer/shell/AccountChip.tsx')).toContain('useAccounts(true, menu.open)')
    expect(read('renderer/copilot/CopilotSetup.tsx')).toContain('useAccounts(open, false)')
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
    /*
     * The guard used to be `about !== null && !checkable`, which left one state
     * out: a build with no `app:about` channel at all reports `about === null`,
     * so the button stayed fully lit beside the only sentence it could show —
     * "Press the button to check." — and pressing it could answer nothing but
     * "this build cannot tell". A lit button under an instruction is the
     * strongest promise this window makes, and that was the one state unable to
     * keep it. Greyed in every state that cannot check, with the reason both
     * beside it and on its hover.
     */
    const about = read('renderer/settings/sections/AboutSection.tsx')
    expect(about).toMatch(/const checkable = about\?\.updates\?\.checkable/)
    expect(about).toMatch(/disabled=\{!checkable\}/)
    // And the sentence beside it is chosen by a function that has a case for
    // each state, rather than by a chain of `??` ending in "press the button".
    expect(about).toMatch(/export function updateNote\(/)
    expect(about).not.toContain("?? 'Press the button to check.'")
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
