import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Guards the seam the type checker cannot see: a component that is built,
 * unit-tested and correct, but never rendered — or rendered without the one
 * optional prop that makes it live.
 *
 * This happened three times in a single session. `AgentControls` shipped with
 * its bridge methods missing, `UsageStrip` was complete and mounted nowhere,
 * and `ChatView` was mounted without `sessionId`, which silently downgraded
 * both of them to their "no session focused" state. Every one of those built
 * clean, passed its own tests and rendered correctly in the harness, because
 * every prop involved is optional — optional is exactly what lets a component
 * render its empty state instead of failing.
 *
 * Static, like `src/preload/contract.test.ts`, and for the same reason: there
 * is no DOM environment in this project (deliberately — see ChatView.test.tsx,
 * where the absence of `window` is what makes a security invariant testable),
 * so the check reads the source rather than mounting the tree.
 */

const SRC = join(__dirname, '..', '..', 'src')
const read = (rel: string): string => readFileSync(join(SRC, rel), 'utf8')

/**
 * The opening tag of `<Name ... >`, brace-aware so a prop whose value is an
 * inline arrow function does not end the scan early.
 */
function openingTag(source: string, name: string): string | null {
  const start = source.search(new RegExp(`<${name}[\\s/>]`))
  if (start < 0) return null
  let depth = 0
  for (let i = start; i < source.length; i++) {
    const c = source[i]
    if (c === '{') depth++
    else if (c === '}') depth--
    else if (c === '>' && depth === 0) return source.slice(start, i + 1)
  }
  return null
}

/** Each entry is a wiring mistake that actually shipped. */
const SEAMS: Array<{ file: string; child: string; props: string[]; why: string }> = [
  {
    file: 'renderer/App.tsx',
    child: 'ChatView',
    props: ['cwd', 'session', 'sessionId'],
    why: 'without sessionId the controls row and usage strip render their empty state, and without session the pane reads whatever transcript in the folder was written last',
  },
  {
    file: 'renderer/copilot/CopilotView.tsx',
    child: 'ChatView',
    props: ['cwd', 'session', 'sessionId', 'provider'],
    why: 'the copilot is a session like any other, so its conversation pane has the same three seams — and `provider` besides, because without it the pane writes shell copy over an agent',
  },
  {
    file: 'renderer/App.tsx',
    child: 'CopilotView',
    props: ['copilot', 'visible', 'mode', 'focus'],
    // It moved here from `PanelView` on 2026-08-17, when the copilot stopped
    // being a page and became a window: it is rendered beside the other
    // sessions' terminals, because that is where a session is rendered.
    //
    // `visible` and `mode` are the two that joined and they are the two that
    // make it a window rather than a page. Without `visible` it is either
    // painted over whatever tab you actually chose or remounted on every switch
    // — and a remount redraws its terminal from scrollback, losing the place a
    // half-finished login prompt is sitting in. Without `mode` it is stuck on
    // one pane while the window's own Terminal/Chat switch moves everything
    // else, which is the shape of a control that looks broken.
    why: 'without `copilot` it has no connection to the agent and draws its "not wired" state; `visible` and `mode` are what make it a window like the others rather than a page; without `focus` a session row asking why it exists lands on the copilot instead of on the turn that started it',
  },
  {
    file: 'renderer/App.tsx',
    child: 'CopilotConsent',
    props: ['question', 'onAnswer'],
    why: 'this is the renderer half of the alter-tier gate — unmounted or unanswerable, every confirmed call the copilot makes is refused by timeout with nothing ever appearing on screen',
  },
  {
    file: 'renderer/App.tsx',
    child: 'SessionInspector',
    props: ['cwd', 'session', 'sessionTitle'],
    why: 'without session it reports the folder’s newest transcript under this session’s name — including one belonging to a claude this app never started',
  },
  {
    file: 'renderer/shell/SessionControls.tsx',
    child: 'ControlPicker',
    props: ['control', 'reading', 'onPick'],
    // These two entries used to name `AgentControls` and `UsageStrip` inside
    // `ChatView.tsx`, because that is where they were mounted and both had
    // shipped mounted nowhere at all. They moved out of the composer entirely —
    // *"since we have it on top we actually don't need them here"* — so the
    // seam moved with them rather than being deleted, which would have left the
    // one place these are now drawn with no guard on it.
    //
    // `reading` is the prop that makes a picker a picker rather than a label:
    // without it every chip shows `unreadLabel`, which is the confident-looking
    // "Not reported" this feature exists to avoid.
    why: 'model, effort, permission mode and fast mode are read off the session screen and typed back into it; this cluster is the only place any of them can be changed now that the composer has no control row',
  },
  {
    file: 'renderer/shell/SessionControls.tsx',
    child: 'UsageBar',
    props: ['sessionId', 'provider'],
    // The reading that replaced the composer's usage strip on screen. It is a
    // different reading — the account's five-hour and weekly limits rather than
    // this session's tokens — and it is the one he asked for twice.
    why: 'a usage bar folded inside a chat composer could not be seen from a terminal session at all, which is how it came to be asked for twice while it already existed',
  },
  {
    file: 'renderer/components/ChatView.tsx',
    child: 'ChatComposer',
    props: ['sessionId'],
    why:
      'without it the composer cannot ask whether this session is held inside a folder, and a ' +
      'session a phone or the copilot started would be offered a file from outside that folder ' +
      'which the OS refuses — a chip, a mention, and an agent saying it cannot open the file',
  },
  {
    file: 'renderer/components/ChatComposer.tsx',
    child: 'AttachMenu',
    props: ['mode', 'startIn'],
    why:
      'the plus button is the only way to attach a file, and without mode a shell session is ' +
      'offered `@"path"` mentions it would type verbatim at its prompt; without startIn the ' +
      'operating system’s panel opens on a confined session in a folder that session cannot read, ' +
      'so every row in the first screen it shows would be refused',
  },
  {
    file: 'renderer/components/ChatComposer.tsx',
    child: 'DictateButton',
    props: [],
    why: 'the microphone has no other entry point',
  },
  {
    file: 'renderer/App.tsx',
    child: 'BrowserWorkspace',
    props: ['visible', 'parkPage'],
    why: 'visible hides the whole panel per tab; parkPage hides only the native pages under a dialog',
  },
  {
    file: 'renderer/App.tsx',
    child: 'WindowToolbar',
    props: ['title', 'sessionId'],
    // The same failure this table exists for, one control along. The rename
    // itself has been in the store since the rail grew a field, and the heading
    // over the terminal renders the same session's name — but without the id it
    // cannot say *which* session it is the name of, so the double-click has
    // nothing to write to and `SessionTitle` correctly draws a plain heading.
    // Dropped, the feature is invisible and looks unbuilt: "session name also
    // inside the terminal, if we want to change we should be able to change."
    why: 'the heading over the terminal is the second place a session can be renamed, and sessionId is what makes it one',
  },
  {
    file: 'renderer/App.tsx',
    child: 'AccountChip',
    props: ['current', 'projectPath', 'provider', 'onPick', 'session', 'onSwitchAccount'],
    // The failure this table exists for, and this feature's own history: the
    // whole account engine — isolated config directories, per-project defaults,
    // a resolution chain, tests — shipped with no way in, and was reported as
    // "I don't see any kind of feature that I can use to have multiple
    // accounts". `current` is what the running session actually runs as,
    // `projectPath` is where a new one would start, and `onPick` is the choice
    // itself; without any one of them the chip is a caption again.
    //
    // `provider` is the fourth because without it the chip offers a choice the
    // spawn then drops. An account is a config directory handed to the agent,
    // so it means nothing to a plain shell or to Codex and Gemini — and with
    // the default coding tool set to Plain shell, picking an account opened a
    // session, `host-core.ts` rightly refused to label it, and the chip snapped
    // back to the default account with nothing said. Passed, the menu explains
    // itself instead of silently ignoring the click.
    // `session` and `onSwitchAccount` are the fifth and sixth, and they are one
    // requirement rather than two: together they are what makes a row switch the
    // session on screen instead of opening a second one beside it —
    // *"when I change account from the dropdown it starts a new session with
    // that account, instead of changing it in the same session."* With only the
    // first, the chip draws a switch-shaped menu whose rows still open a new
    // session; with only the second it has nothing to switch and falls back to
    // the old behaviour silently. Either way the reported bug is still there and
    // the code looks like it was fixed.
    why: 'the only place in the window where the account for a session can be seen, chosen, or changed on the session already running',
  },
  {
    file: 'renderer/settings/sections/AddAccountDialog.tsx',
    child: 'AccountProviderList',
    props: ['rows', 'selected', 'onSelect'],
    // This exact failure, twice over. The main process has answered
    // `profiles:account-providers` since accounts grew providers and no window
    // ever called it, because the preload had no method to call it with; and an
    // Add-account dialog was written, tested, and rendered by nothing. Both were
    // correct code that a user could not reach, so the app went on making every
    // account a Claude account — "if I add any new account it just redirects me
    // to claude only". `onSelect` is in the list because without it the rows are
    // a picture of a choice.
    //
    // The list moved into the popup on 2026-08-18 — *"'Add' and 'Sign in'
    // should be one thing, called Add account. It must open a small popup with
    // only the sign-in steps."* The entry below is the other half of that move,
    // and it is the more important of the two: a dialog rendered by nothing is
    // the failure this note already records once.
    why: 'the only place in the app where an account can be made for an agent other than Claude',
  },
  {
    file: 'renderer/settings/sections/AccountsSection.tsx',
    child: 'AddAccountDialog',
    props: ['open', 'providerRows', 'onSignIn', 'onClose'],
    // `open` because a dialog that is never opened is the same defect as one
    // that is never mounted; `providerRows` because without it the popup asks
    // which agent and offers none; `onSignIn` because it is the whole act, and
    // a null there is the pane silently declining to make accounts; `onClose`
    // because a popup over the settings sheet that cannot be closed takes the
    // sheet with it.
    why: 'the only route to adding an account at all, and the last one was written and rendered by nothing',
  },
  {
    file: 'renderer/App.tsx',
    child: 'AlertsWindow',
    props: ['open', 'projectPath', 'onAction', 'report', 'onRescan'],
    // Alerts stopped being a page on 2026-08-17 — *"and notifications should be
    // a pop-up just like settings, not a full page"* — and a dialog is the
    // easiest thing in this codebase to build and never mount: the bell would
    // set a flag nothing reads, and pressing it would do nothing at all, which
    // is the failure this table exists for. `projectPath` is what it scans;
    // without it the sheet is permanently the "no project open" state. `onAction`
    // is the whole point of an alert — the page it replaces spent its life with
    // that prop undefined, drawing buttons that swallowed the click. `report`
    // and `onRescan` joined the list when the scan moved out of the panel into
    // `alerts-feed.ts`: the sheet fetches nothing now, so a missing `report`
    // is a dialog permanently reading "Checking…" and a missing `onRescan` is
    // a "Check again" button with nothing behind it.
    why: 'the bell and the palette row both open this, and it is the only thing that renders an alert',
  },
  {
    file: 'renderer/App.tsx',
    child: 'UpdateBanner',
    props: [],
    // It takes no required props on purpose — it resolves its own bridge, and
    // every state it can draw is pushed to it. Being rendered *at all* is the
    // entire wiring, which is exactly the failure this table exists for: a
    // shipped update nobody in the app is ever told about.
    why: 'it is the only place in the app that says an update exists or asks for the restart',
  },
  {
    file: 'renderer/App.tsx',
    child: 'Tooltips',
    props: [],
    // Props would be the wrong thing to assert here: it takes none, listens on
    // the document and finds its own targets. Not being rendered does not break
    // anything visibly — every `title=` in the window simply goes back to being
    // an OS tooltip in the wrong font — which is exactly the shape of failure
    // this table exists for: a component that is built, tested, correct and
    // mounted nowhere.
    why: 'unmounted, every hover label in the app reverts to the OS tooltip the design brief replaced',
  },
  {
    file: 'renderer/browser/BrowserWorkspace.tsx',
    child: 'DriveBanner',
    props: ['status', 'onResume'],
    // The one place a person can see that the copilot is moving a page, and
    // the only place they can hand it back after a handover. Unmounted, a
    // `browser.handover` call is a page that stops responding to the agent
    // with nothing on screen saying so and no way to release it — the tool
    // would sit there until its window closed and then say "still waiting"
    // forever. `onResume` is half of that: without it the banner draws and
    // its buttons do nothing.
    why: 'without it a driven page moves with no explanation, and a handover can never be answered',
  },
]

describe('components that are built are also wired', () => {
  for (const { file, child, props, why } of SEAMS) {
    it(`${file} renders <${child}>${props.length ? ` with ${props.join(', ')}` : ''}`, () => {
      const tag = openingTag(read(file), child)
      expect(tag, `<${child}> is not rendered in ${file} — ${why}`).not.toBeNull()
      for (const prop of props) {
        expect(tag, `<${child}> in ${file} is missing ${prop} — ${why}`).toMatch(
          new RegExp(`[\\s{]${prop}[=}]`),
        )
      }
    })
  }
})

/**
 * A session started from a paired phone has to arrive, and has to arrive
 * quietly.
 *
 * Both halves shipped broken once. The main process broadcast `session:created`
 * and the preload exposed `onSessionCreated`, and nothing in the renderer
 * listened — a real pty ran on this Mac with no row anywhere in the window.
 * The obvious repair is worse than the bug: `addSession` sets the active
 * session, so subscribing without `focus: false` means answering a message on
 * your phone yanks the Mac out of whatever terminal you were typing into.
 *
 * Static, like the table above, and asserted on the source for the same reason
 * — this project has no DOM to mount an effect in.
 */
describe('a session started from a phone appears without stealing focus', () => {
  const app = read('renderer/App.tsx')

  it('subscribes to session:created', () => {
    expect(
      app,
      'nothing in the renderer listens for onSessionCreated — a session started from a paired ' +
        'phone runs a real pty on this Mac and never appears in the window',
    ).toMatch(/window\.deck\.onSessionCreated\(/)
  })

  it('adds the session without focus', () => {
    // The whole subscription, from the call through to its closing brace.
    const at = app.indexOf('window.deck.onSessionCreated(')
    const body = app.slice(at, at + 400)
    expect(body).toMatch(/addSession\([^)]*\{[^}]*focus:\s*false/)
  })

  it('badges the new row rather than switching to it', () => {
    const at = app.indexOf('window.deck.onSessionCreated(')
    expect(
      app.slice(at, at + 400),
      'an arrival with no focus and no badge is an arrival nobody can see',
    ).toMatch(/unread\.recordOutput\(/)
  })
})

/**
 * Every button that starts a session goes through the dialog, and there is no
 * second way round it.
 *
 * Asad, 2026-08-17: *"if we click directly on the whole button it opens a quick
 * window. We don't want this quick window at all. We just always wanted this
 * pop-up to come up so we choose which type of terminal we want to open…
 * 'Remember these choices for this project' is good enough."*
 *
 * This is a wiring claim rather than a component one, which is why it is here.
 * Every control involved lives in a different file — the rail's button, the
 * strip's terminal glyph, ⌘T, the application menu's ⌘⇧T — and each of them is
 * correct on its own however it is wired. The thing that can regress is the one
 * line in `App.tsx` that decides where each of them lands, and nothing about
 * that line is visible from inside the components it feeds.
 */
describe('one route to a new session, and it is the dialog', () => {
  const app = read('renderer/App.tsx')

  it('sends the rail’s New session button to the dialog, not to a spawn', () => {
    const tag = openingTag(app, 'Sidebar') ?? ''
    expect(tag, 'no <Sidebar> in App.tsx — has the shell been rewritten?').not.toBe('')
    expect(tag).toMatch(/onNewSession=\{[\s\S]*openNewSessionDialog/)
    // The chevron beside it is gone, by name: "remove this drop-down button at
    // all from the side panel."
    expect(tag).not.toContain('onNewSessionOptions')
  })

  it('keeps the folder a project’s ＋ named, rather than dropping it', () => {
    // The ＋ on a project heading is the one press that means a *specific*
    // folder. It used to spawn straight into it; now that it opens the dialog,
    // that intent has to survive the trip or the press quietly changes project.
    const tag = openingTag(app, 'NewSessionDialog') ?? ''
    expect(tag).toMatch(/projectPath=\{newSessionPath \?\? activeProjectPath\}/)
  })

  it('leaves Continue last session immediate, because it is not the same question', () => {
    const tag = openingTag(app, 'Sidebar') ?? ''
    expect(tag).toMatch(/resume \?[\s\S]*newSession\(/)
  })

  it('sends the strip’s terminal glyph to the dialog too', () => {
    const tag = openingTag(app, 'WorkspaceTabStrip') ?? ''
    expect(tag, 'no <WorkspaceTabStrip> in App.tsx').not.toBe('')
    expect(tag).toMatch(/onNewSession=\{\(\) => openNewSessionDialog\(\)\}/)
  })

  it('gives the strip no way to close a session at all', () => {
    /*
     * The ✕ on a tab takes the tab off the bar and leaves the session running.
     * The strongest form that guarantee can take is that the component is not
     * handed a close: no prop, no path, nothing to wire wrongly later.
     */
    const tag = openingTag(app, 'WorkspaceTabStrip') ?? ''
    expect(tag).not.toContain('onClose')
    expect(tag).toMatch(/onShowInstead=\{showInstead\}/)
  })

  it('lands ⌘T and ⌘⇧T on the same dialog, and offers one palette row', () => {
    // ⌘T is `session.new`; ⌘⇧T is `session.newDialog`, which is the accelerator
    // an Electron menu in the main process prints beside "New Session…" — so it
    // has to keep working even though its palette row has gone.
    expect(app).toMatch(/id: 'session\.new',[^}]*run: \(\) => openNewSessionDialog\(\)/)
    expect(app).toMatch(/case 'session\.newDialog':\s*\n\s*openNewSessionDialog\(\)/)
    // And exactly one row offering it, rather than two names for one place.
    expect(app.match(/id: 'session\.newDialog', title:/g)).toBeNull()
  })
})

/**
 * The copilot is a window, with everything a window has — and there is no page
 * left to reach.
 *
 * Asad, 2026-08-17: *"Give the copilot a full window like the other windows. It
 * is not that much of a big window, it is like a small box inside the copilot
 * page. Let it have a proper window like others — proper dropdowns on the top,
 * like changing the counts, efforts, models, all those things should be there,
 * exactly like the other sessions. It should have all of those things, nothing
 * should be less than that. And it can stay as a window pill with the other
 * windows."*
 *
 * Every one of those is a wiring claim rather than a component one, which is
 * why they are here. `SessionControls`, `AccountChip`, `ModeSwitch` and the tab
 * strip were all already correct and already mounted; what the copilot was
 * missing was being in the *list* they are fed from. It was filtered out of
 * `sessions` — for good reasons, because it is not one of your project's
 * sessions — and that one filter is what withheld the pill, the name, the
 * account and the whole control cluster at once. Nothing about that is visible
 * from inside any of the components involved.
 *
 * The dangerous half, again, is a route left behind: a palette row or a pinned
 * row that navigates to a panel nobody renders is a blank window.
 */
describe('the copilot is a window, not a view', () => {
  const app = read('renderer/App.tsx')

  it('is not a view at all, so nothing can navigate to it', () => {
    const panels = read('renderer/shell/panels.ts')
    expect(panels).not.toMatch(/\|\s*'copilot'/)
    expect(panels).not.toMatch(/id: 'copilot'/)
    expect(read('renderer/shell/PanelView.tsx')).not.toContain("case 'copilot':")
    expect(app, 'nothing may navigate the window to a copilot page').not.toContain(
      "showPanel('copilot')",
    )
  })

  it('is a tab like the others, kept on the bar when it is opened', () => {
    // `isCopilot` on a `kind: 'session'` tab is the whole of it: everything that
    // asks "is this a session" gets a yes, and the handful of genuinely
    // different behaviours hang off the flag. Without the tab there is no pill,
    // no heading, no account chip and no control cluster — one filter withheld
    // all four.
    expect(app).toMatch(/isCopilot: true as const/)
    const show = /const showCopilot = useCallback\([\s\S]*?\n {2}\)/.exec(app)?.[0] ?? ''
    expect(show, 'showCopilot has changed shape').not.toBe('')
    expect(show).toContain('copilot.ensure()')
    // `selectTab`, not `showTab`: while the window is split a click in the rail
    // fills the pane you are looking at, and pressing Copilot has to obey the
    // same rule or it changes the selection and nothing on screen.
    expect(show).toContain('selectTab(copilotSessionId)')
    expect(show).toContain('keepNewWindowInStrip(copilotSessionId)')
  })

  /*
   * The first-run questions come before the spawn, and this is the assertion
   * that keeps them there.
   *
   * *"Show what it is about to become before it starts, rather than starting and
   * letting him discover it."* Everything in the app that opens the copilot goes
   * through `openCopilot`, so the gate is worth exactly as much as that
   * function's refusal to start anything itself: the moment somebody moves a
   * `copilot.ensure()` back into it, an install that has never been asked
   * anything spawns a CLI and bills for it while the dialog is still opening.
   *
   * `hasRun()` rather than a piece of state, because the click can land before
   * the file has been read — `useCopilotSetup` carries that argument.
   */
  it('asks the setup questions before it starts anything', () => {
    const open = /const openCopilot = useCallback\([\s\S]*?\n {2}\)/.exec(app)?.[0] ?? ''
    expect(open, 'openCopilot has changed shape').not.toBe('')
    expect(open).toContain('copilotSetup.hasRun()')
    expect(open).toContain('showCopilot(turn)')
    expect(open).toContain('setCopilotSetupOpen(true)')
    expect(open, 'the flow must gate the spawn, not race it').not.toContain('copilot.ensure()')
    // And the flow is mounted, or the flag would open nothing at all.
    expect(openingTag(app, 'CopilotSetup') ?? '').toContain('open={copilotSetupOpen}')
  })

  it('feeds the bar’s controls from a list the copilot is in', () => {
    /*
     * `headingSession` is what `SessionControls` acts on — model, effort, fast
     * mode, connectors, usage — and it used to be resolved against `sessions`,
     * which is the one list the copilot is deliberately not in. That single
     * lookup is why the copilot had no cluster: the component was mounted, the
     * bar was drawn, and the session was never found.
     */
    expect(app).toMatch(/const headingSession =[\s\S]{0,200}windowSessions\.find/)
  })

  it('keeps its pinned row, and points it at the window', () => {
    const tag = openingTag(app, 'Sidebar') ?? ''
    expect(tag, 'no <Sidebar> in App.tsx').not.toBe('')
    expect(tag).toMatch(/onOpenCopilot=\{\(focus\) => openCopilot\(focus\)\}/)
    // And the row says whether the window it opens is the one on screen. It
    // cannot be derived from `activeTabId` in there, because the copilot's tab
    // is deliberately not among the tabs the rail draws.
    expect(propExpression(tag, 'copilot')).toContain('active:')
  })

  it('offers a way to stop it, since the rail gives it no ✕', () => {
    // A singleton has no row in the rail and so no ✕ that ends it; the ✕ on its
    // pill takes the pill off the bar like every other pill's does. Losing the
    // Stop that lived on its page would have left the one session in the window
    // that cannot be switched off from anywhere you can see it.
    expect(openingTag(app, 'CopilotStop')).toMatch(/[\s{]copilot[=}]/)
  })
})

/**
 * Closing every tab leaves an empty pane, rather than putting one back.
 *
 * Asad, 2026-08-17: *"If there are three or two windows open and I close all of
 * them, the last one I will not be able to close from the top bar — I can just
 * close a few ones."*
 *
 * The strip already answered `select: null` for that press. What made the tab
 * come straight back was `App.tsx` resolving a null selection to `tabs[0]`, so
 * `shownTabs` drew it again as a transient tab — three correct pieces composing
 * into a control that does not work. The resolution is a pure function with its
 * own tests now (`shell/tab-selection.ts`); what those cannot see is whether
 * this file still routes the press into it, which is exactly the seam this file
 * is for.
 */
describe('the last tab can be closed', () => {
  const app = read('renderer/App.tsx')

  it('holds the selection in a type that can say "nothing, on purpose"', () => {
    // A `string | null` cannot tell "nobody has chosen yet" from "the person
    // emptied the bar", and answering the first for both is the bug.
    expect(app).toMatch(/useState<TabSelection>\(AUTO_SELECTION\)/)
    expect(app).toMatch(/resolveActiveTab\(selection, tabs\)/)
    expect(app, 'the old two-state selection is back').not.toMatch(/setActiveTabId\(/)
  })

  it('routes the strip’s ✕ through it, null and all', () => {
    const showInstead = /const showInstead = useCallback\([\s\S]*?\n {2}\)/.exec(app)?.[0] ?? ''
    expect(showInstead, 'showInstead has changed shape').not.toBe('')
    expect(showInstead).toContain('setSelection(showTabSelection(id))')
  })

  it('draws the pane’s own empty state rather than the launch screen', () => {
    /*
     * Two different nothings. With no windows open it is a launch, and the
     * launch screen is a door: open a project. With windows open it is somebody
     * having emptied the bar, and showing "nothing is open" while four agents
     * run beside it would be the app contradicting its own sidebar.
     */
    expect(app).toMatch(/if \(tabs\.length === 0\) return <EmptyState/)
    expect(app).toMatch(/if \(!activeTab\) \{[\s\S]{0,200}Nothing in this pane yet/)
  })

  it('lets a split survive the bar being emptied', () => {
    /*
     * The order in `mainView` is the whole of this. Swarm and split draw
     * sessions the strip's selection has nothing to do with — every terminal at
     * once, or a hand-made layout — so an empty-selection branch above them
     * would throw away an arrangement that is still on screen and still holding
     * two running agents, and would leave the mode switch reading "Split" over a
     * blank. The way back out of a split is that switch, so it has to survive.
     */
    const main = /const mainView = \(\) => \{[\s\S]*?\n {2}\}/.exec(app)?.[0] ?? ''
    expect(main, 'mainView has changed shape').not.toBe('')
    expect(main.indexOf('if (splitting)')).toBeLessThan(main.indexOf('if (!activeTab)'))
    expect(main.indexOf('if (swarm)')).toBeLessThan(main.indexOf('if (!activeTab)'))
  })

  it('leaves the bar saying nothing rather than naming some other session', () => {
    // The fallback that put a guest's name in the host's bar was removed on
    // purpose; the emptied window is the same claim in a different costume.
    expect(app).toMatch(/: splitting \|\| tabs\.length > 0/)
  })
})

/**
 * Every way into Alerts opens the sheet, and none of them navigates.
 *
 * Asad, 2026-08-17: *"and notifications should be a pop-up just like settings,
 * not a full page."*
 *
 * This is a wiring claim for the same reason the one above is. Alerts moving
 * from the rail to a bell beside Settings already happened once and left the
 * press still navigating the pane to a full page — the control moved and the
 * destination did not, which no component test could see, because every piece
 * involved was correct about itself. What can regress is the set of call sites,
 * and they are spread across four files.
 *
 * The dangerous half is not the bell; it is a route left behind. A palette row
 * that navigates to a panel nobody renders is a blank window, and this
 * repository has caught that exact bug more than once.
 */
describe('Alerts is a pop-up, and there is no page left to reach', () => {
  const app = read('renderer/App.tsx')

  it('is not a view at all, so nothing can navigate to it', () => {
    // The union is the gate: `showPanel` takes a `PanelId`, and `isPanelId` is
    // what lets a remembered id come back out of storage and fill the window at
    // the next launch. While `alerts` was in it, an app quit on the Alerts page
    // reopened on a panel with no case to render.
    const panels = read('renderer/shell/panels.ts')
    expect(panels).not.toMatch(/\|\s*'alerts'/)
    expect(panels).not.toMatch(/id: 'alerts'/)
    expect(read('renderer/shell/PanelView.tsx')).not.toContain("case 'alerts':")
    expect(app, 'nothing may navigate the window to Alerts').not.toContain("showPanel('alerts')")
  })

  it('sends the rail’s bell to the sheet', () => {
    const tag = openingTag(app, 'Sidebar') ?? ''
    expect(tag, 'no <Sidebar> in App.tsx — has the shell been rewritten?').not.toBe('')
    expect(tag).toMatch(/onOpenAlerts=\{\(\) => setAlertsOpen\(true\)\}/)
  })

  it('sends the palette row to the sheet, keeping the id the registry gates on', () => {
    // `view.alerts` is what `features/registry.ts` declares and what any menu
    // item or chord would dispatch, so the id stays and only its `run` changes
    // — the same trade `view.search` made when session search became a sigil.
    expect(app).toMatch(/id: 'view\.alerts',[^}]*run: \(\) => setAlertsOpen\(true\)/)
  })

  it('closes the sheet before an alert’s button acts on the window behind it', () => {
    // All five actions land somewhere the modal is covering — a panel, a tab, a
    // terminal, another sheet. Acting without closing is the same defect the
    // handlers were written to fix: something happens out of sight and the
    // surface in front of you does not move.
    const tag = openingTag(app, 'AlertsWindow') ?? ''
    const action = propExpression(tag, 'onAction') ?? ''
    expect(action, '<AlertsWindow> has no onAction={...}').not.toBe('')
    expect(action.indexOf('setAlertsOpen(false)')).toBeGreaterThanOrEqual(0)
    expect(action.indexOf('setAlertsOpen(false)')).toBeLessThan(action.indexOf('switch (action.kind)'))
  })

  /**
   * The bell's number, and the reason this is a wiring test rather than a
   * component one.
   *
   * `Sidebar` has drawn `alertCount` since the bell was put on the Settings
   * line, it has a test of its own, and until 2026-08-17 nothing in `App.tsx`
   * passed it — so the dot was unreachable in the shipped app while every piece
   * of it was correct and covered. Asad: *"if there is an alerts option and we
   * don't wire anything to it to give us the alerts, why would we have an
   * alerts option?"*
   *
   * The prop being optional is what made that invisible, which is exactly the
   * class of failure this file exists for, so the connection is pinned at both
   * ends: something must feed the rail, and one feed must serve both surfaces.
   */
  describe('the bell carries a real count', () => {
    it('feeds the rail from App.tsx', () => {
      const sidebar = openingTag(app, 'Sidebar') ?? ''
      const count = propExpression(sidebar, 'alertCount') ?? ''
      expect(count, '<Sidebar> has no alertCount={...} — the dot is unwired again').not.toBe('')
    })

    it('counts from the same report the sheet draws', () => {
      // Two fetches would be two answers: the dot saying three while the list
      // shows two is worse than no dot, because it sends you to look at
      // something that is not there.
      expect(app).toContain('useProjectAlerts(')
      const window = openingTag(app, 'AlertsWindow') ?? ''
      expect(propExpression(window, 'report')).toContain('alertsFeed.report')
      expect(app).toMatch(/unreadCount\(/)
    })

    it('clears when the sheet is opened, and only then', () => {
      // `markSeen` is the whole definition of "read" — see `alerts-unread.ts`.
      // Guarding it on `alertsOpen` is what makes opening the popup the
      // clearing event rather than, say, a scan landing behind it.
      expect(app).toMatch(/if \(!alertsOpen[^)]*\) return\s*\n\s*const next = markSeen\(/)
    })

    it('does not scan on a timer for the sake of the dot', () => {
      // The reason the count was left unwired in the first place: a scan reads
      // every transcript in the project, and the window would not pay that on a
      // clock. `alerts-feed.test.ts` holds the feed to the same rule.
      expect(app).not.toMatch(/useEvery\([^)]*projectAlerts/)
      expect(app).not.toContain('window.deck.projectAlerts')
    })
  })

  it('respects the feature the way the page did', () => {
    // The page was gated twice: no row in the rail, and `FeatureOffer` for
    // anyone already on it when the feature went off. The sheet needs both
    // halves too, or switching Alerts off leaves a dialog on screen for
    // something the app no longer has.
    const sidebar = openingTag(app, 'Sidebar') ?? ''
    expect(sidebar).toContain("alerts={features.controlOn('sidebar.alerts')}")
    const open = propExpression(openingTag(app, 'AlertsWindow') ?? '', 'open') ?? ''
    expect(open).toMatch(/features\.on\('alerts'\)/)
    // And a third half the page never needed: the feed behind the dot reads
    // every transcript in the project, so a feature that is off must stop the
    // scanning and not merely the drawing.
    expect(app).toMatch(/useProjectAlerts\(features\.on\('alerts'\)/)
  })

  it('parks the browser’s native pages while the sheet is up', () => {
    // Same reason every other dialog is in `anyModalOpen`: the browser's pages
    // are native views layered above the HTML, so a sheet opened over one is
    // drawn underneath a web page and cannot be seen at all.
    expect(app).toMatch(/anyModalOpen =[\s\S]{0,240}alertsOpen/)
  })
})

/** The value of `<Name prop={...}>`, or null. Brace-aware, like `openingTag`. */
function propExpression(tag: string, prop: string): string | null {
  const at = tag.search(new RegExp(`[\\s{]${prop}=\\{`))
  if (at < 0) return null
  const from = tag.indexOf('{', at)
  let depth = 0
  for (let i = from; i < tag.length; i++) {
    if (tag[i] === '{') depth++
    else if (tag[i] === '}' && --depth === 0) return tag.slice(from + 1, i)
  }
  return null
}

/**
 * Two different questions that were once one prop.
 *
 * `visible` used to mean "this tab is on screen AND no dialog is open", which
 * forced a choice between two wrong screens: park the pages for a dialog and
 * the panel keeps painting over other tabs, or hide the panel for a dialog and
 * the workspace blanks out behind it. Folding the modal flag back into
 * `visible` brings one of those back.
 */
describe('the browser panel is hidden per tab, parked per dialog', () => {
  /*
   * There are two of these panels in `App.tsx` since 2026-08-17 and they answer
   * `visible` differently, so the tag has to be found by *where* it is rather
   * than by being the first one in the file.
   *
   *  - inside a pane, put there by the split renderer: what makes it visible is
   *    that its pane is on screen. There is no "active tab" involved — the pane
   *    is showing this page whatever the strip's selection is, which is the
   *    whole of the fix that let a pane hold a page at all;
   *  - filling the window, from the flat list: visible only while its own tab
   *    is the selected one, because every other page is mounted and hidden
   *    behind it.
   *
   * Both must keep the dialog out of `visible`, which is the mistake this
   * describe block was written for and the one that duplicates most easily.
   */
  const app = read('renderer/App.tsx')
  const paned = openingTag(app, 'BrowserWorkspace') ?? ''
  const flat = openingTag(app.slice(app.indexOf(paned) + paned.length), 'BrowserWorkspace') ?? ''

  it('finds both panels, so neither rule below is checked twice', () => {
    expect(paned, 'the split renderer has no <BrowserWorkspace>').not.toBe('')
    expect(flat, 'the flat tab list has no <BrowserWorkspace>').not.toBe('')
  })

  it('decides visibility from the tab alone, for the panel filling the window', () => {
    const visible = propExpression(flat, 'visible')
    expect(visible, '<BrowserWorkspace> has no visible={...}').not.toBeNull()
    expect(visible).toMatch(/activeTab/)
    expect(visible, 'a dialog is not a tab switch — that belongs in parkPage').not.toMatch(
      /Modal|Open\b/,
    )
  })

  it('decides it from the pane, for the panel inside one', () => {
    const visible = propExpression(paned, 'visible')
    expect(visible, 'the paned <BrowserWorkspace> has no visible={...}').not.toBeNull()
    // Not `activeTab`: a pane draws what the pane holds. Keying this off the
    // strip's selection is how a page in the unfocused half of a split would go
    // blank the moment you clicked the other half.
    expect(visible).not.toMatch(/activeTab/)
    expect(visible, 'a dialog is not a tab switch — that belongs in parkPage').not.toMatch(
      /Modal|Open\b/,
    )
  })

  it('parks the pages for whatever dialog is open, in both', () => {
    expect(propExpression(flat, 'parkPage')).toMatch(/Modal/)
    expect(propExpression(paned, 'parkPage')).toMatch(/Modal/)
  })
})

/**
 * One empty-state treatment, in every panel.
 *
 * The app had four: GitHub drew its own centred block with its own glyph and
 * its own retry button, MCP printed a bare sentence with literal backticks in
 * it, the task board dropped inline text into a column, the Overview wrote a
 * third title-plus-detail-plus-button by hand — four sizes of type and three
 * greys for the same thought, on four pages of the same window. (The board has
 * since been removed outright, so its file is no longer in the sweep below —
 * `column-empty` stays in RETIRED because the point of that list is that no
 * page may reinvent a blank, and the cheapest place to reinvent one is the
 * class name somebody remembers.)
 *
 * They are all `PageEmpty` (a whole page with nothing on it) and `PageNote`
 * (one section of a working page, or a page still reading) now. Static like
 * everything else in this file: what is being pinned is that no panel has gone
 * back to writing its own, which is a question about the source rather than
 * about any one render.
 */
describe('every panel wears the same blank', () => {
  /** Class names each panel invented for the job the shared pair now does. */
  const RETIRED = [
    'gh-message',
    'git-message',
    'mcp-empty',
    'hooks-empty',
    'readiness-empty',
    'dashboard-empty',
    'column-empty',
  ]

  const FILES = [
    'renderer/components/GitPanel.tsx',
    'renderer/components/GitHubPanel.tsx',
    'renderer/components/McpInspector.tsx',
    'renderer/components/HooksPanel.tsx',
    'renderer/components/ReadinessPanel.tsx',
    'renderer/components/AlertsPanel.tsx',
    'renderer/components/FileViewer.tsx',
    'renderer/dashboard/Dashboard.tsx',
    'renderer/shell/PanelView.tsx',
  ]

  it.each(FILES)('%s renders the shared blank and none of its own', (file) => {
    const source = read(file)
    expect(source, 'no panel should still be hand-rolling an empty state').toMatch(
      /\b(PageEmpty|PageNote)\b/,
    )
    for (const dead of RETIRED) expect(source, dead).not.toContain(`"${dead}"`)
  })

  /**
   * The half that is easy to lose: a page that says "Reading…" and then says
   * what it found has to say both in the same place, or the answer arrives
   * somewhere the eye is not. `PageNote page` and `PageEmpty` are parked at the
   * same height in `shell.css` for exactly that.
   */
  it('parks the reading line where the answer will land', () => {
    const css = read('renderer/shell/shell.css')
    const blank = /\.page-blank \{[^}]*margin:\s*([^;]+);/.exec(css)?.[1]
    const line = /\.page-blank-line\[data-page\] \{[^}]*margin:\s*([^;]+);/.exec(css)?.[1]
    expect(blank, '.page-blank has no margin rule').toBeTruthy()
    expect(line, '.page-blank-line[data-page] has no margin rule').toBeTruthy()
    expect(line).toBe(blank)
  })
})

/**
 * A terminal follows the theme after it is built, not only while it is built.
 *
 * xterm paints on a canvas, so its colours are resolved to literals the moment
 * a terminal is constructed and never look at the stylesheet again. Switching
 * Appearance → Theme therefore left every session that was already open in the
 * old palette — a black slab on a white app, and a white slab on a black one
 * for a session made the other way round. Remounting repaired it, which is why
 * the same session read correctly in Split mode and wrongly in Terminal mode a
 * second later: nothing was broken except the one thing nobody had written.
 *
 * `subscribeTheme` was exported for this from the day the theme controller was
 * written — its own comment says "e.g. to recolour the terminals" — and no
 * caller ever existed. That is this repository's signature bug: built, tested,
 * correct, wired to nothing. So the wiring is what gets pinned, in both files
 * that own a terminal.
 */
describe('every terminal repaints when the theme changes', () => {
  const OWNERS = [
    'renderer/components/TerminalView.tsx',
    'renderer/machines/RemoteTerminal.tsx',
  ]

  it.each(OWNERS)('%s subscribes to the theme', (file) => {
    const source = read(file)
    expect(
      source,
      'a terminal that never re-reads the palette stays in the theme it was born in',
    ).toMatch(/subscribeTheme\(/)
    expect(source, 'subscribing without writing options.theme changes nothing').toMatch(
      /options\.theme\s*=\s*terminalTheme\(\)/,
    )
  })

  it('both terminals resolve the palette through one function', () => {
    // Two hand-copied colour tables is how the app came to have a purple-blue
    // terminal months after that palette was retired. `tokens.test.ts` checks
    // the literals in TerminalView against the sheet; this checks that the
    // other terminal has none of its own to drift.
    expect(read('renderer/machines/RemoteTerminal.tsx')).toMatch(
      /import \{ terminalTheme \} from '\.\.\/components\/TerminalView'/,
    )
  })
})

/**
 * Nothing the chat composer offers may be *lost*. Moving it is a different act.
 *
 * This is the only entry in this file that guards against a deletion made on
 * purpose, and it is here because that deletion has already happened. Asked for
 * "one large chat box with the options folded neatly inside it", a pass over
 * this composer folded two controls onto the box, put two behind a button
 * labelled "More", and withdrew the attach menu from shell sessions entirely —
 * leaving that composer with a microphone and a send button. What came back
 * was: "you actually removed everything rather than making it simple and all
 * the options you have actually removed."
 *
 * The controls row has since gone from the composer altogether, and that is
 * emphatically not the same event: every control on it is drawn by
 * `shell/SessionControls.tsx` in the window's own bar, over every session
 * including the ones shown as a terminal, which never had them here at all.
 * *"Options is showing the same options that we already have here."*
 *
 * So the checks below moved with the controls rather than being deleted with
 * the row, and the one thing that is still asserted *here* is what stayed: the
 * attach menu, on a shell as well as an agent. `chat/controls/one-home.test.ts`
 * is the other half — it fails if a control ends up drawn in neither place.
 *
 * Every check is a question about the source, because none of them would fail a
 * single one of the moved component's own tests. A control that is not rendered
 * still passes everything ever written about it.
 */
describe('the chat composer keeps every control it was given', () => {
  const composer = read('renderer/components/ChatComposer.tsx')
  const controls = read('renderer/shell/SessionControls.tsx')

  it('draws the attach menu on a shell too, switching its mode instead', () => {
    // `{!shell && <AttachMenu …>}` is the exact line that removed it. Picking a
    // file out of the project is not an agent feature; only the mention form
    // the pick used to produce was, and a mode changes a form.
    expect(
      composer,
      'the attach menu is conditional on not being a shell — a shell composer then has no options at all',
    ).not.toMatch(/\{\s*!shell\s*&&/)
    expect(openingTag(composer, 'AttachMenu')).toMatch(/[\s{]mode[=}]/)
  })

  it('builds the window bar’s panel from every control it carries, not from a remainder', () => {
    // `FOLDED_CONTROLS.map` is what once made a panel a list of leftovers, and
    // nothing on screen named what was in it. The folded cluster draws the same
    // list it draws open, so the two cannot come apart.
    expect(controls, 'the panel lists only the controls that were folded away').not.toMatch(
      /FOLDED_CONTROLS\.map/,
    )
    expect(controls).toMatch(/CHROME_CONTROLS\.map/)
  })

  it('names what the fold hides, rather than calling it More', () => {
    // A word that names nothing is why the controls behind it were read as
    // deleted. The folded chip's hover label is built from the contents.
    expect(controls).not.toMatch(/^\s*More$/m)
    expect(controls).toMatch(/contentsSentence\(/)
  })

  it('keeps attach, the chips, the microphone and the send button in the box', () => {
    // Each of these is a control someone can reach today, and none of them has
    // a twin anywhere else — which is exactly what stops this list shrinking to
    // nothing on the same argument that emptied the controls row.
    for (const held of ['AttachChips', 'AttachMenu', 'DictateButton', 'cc-send']) {
      expect(composer, `${held} is no longer rendered by the composer`).toContain(held)
    }
    for (const held of ['ControlPicker', 'ControlSection']) {
      expect(controls, `${held} is no longer rendered by the window bar`).toContain(`<${held}`)
    }
  })

  it('offers the microphone back where it would have been, rather than dropping it', () => {
    // Voice dictation can be uninstalled, and uninstalling it used to delete
    // the microphone without a trace — which teaches the reader that this app
    // cannot dictate. FEATURE-STORE.md: where a feature would have been, offer
    // it.
    expect(composer).toMatch(/useControlOffer\('chat\.dictate'\)/)
  })
})

/**
 * The three ways in from outside the project.
 *
 * All three are event handlers on elements, and this project has no DOM in its
 * tests — so the logic behind each of them is unit-tested in
 * `chat/attach/outside.test.ts`, and what is checked here is the one thing that
 * file cannot see: whether the handler is attached to anything. A `onDrop`
 * written, exported and wired to nothing is precisely the failure this file
 * exists for, and it is the failure this feature started as: there was no drop
 * target and no paste handler on the composer at all, so there was genuinely no
 * way to attach anything the project did not already contain.
 *
 *   > "I should be able to take anything from my PC to paste here."
 */
describe('the composer accepts a file from outside the project', () => {
  const composer = read('renderer/components/ChatComposer.tsx')

  it('takes a drop, and tells the browser it will', () => {
    // `onDragOver` with `preventDefault` is not optional decoration: without it
    // the drop never fires and Chromium navigates the window to the dropped
    // file instead, replacing the entire app with a picture.
    expect(composer, 'nothing accepts a dropped file').toMatch(/onDrop=\{/)
    expect(composer, 'without onDragOver a drop navigates the window to the file').toMatch(
      /onDragOver=\{/,
    )
    expect(composer).toMatch(/preventDefault/)
  })

  it('takes a paste, on the box a person is typing in', () => {
    expect(composer, 'the textarea has no paste handler').toMatch(/onPaste=\{onPaste\}/)
  })

  it('asks what the session may read before it attaches anything', () => {
    // The honest half of the feature. Without the question, a session a phone
    // or the copilot started is handed a file the OS will not let it open, and
    // the failure arrives a minute later in the agent's words instead of at the
    // click.
    expect(composer).toMatch(/sessionBoundary\(/)
  })

  it('applies that answer per pick rather than refusing the session outright', () => {
    /*
     * This used to be `browseRefusal={outsideRefusal}` — the whole of Browse
     * disabled whenever the session was confined — and that was fine only
     * because a confined session still had the in-app project list to fall back
     * on. The list is gone (*"we should not even have this search bar"*), so a
     * blanket refusal would now leave those sessions unable to attach anything
     * at all, including the files inside the folder they are held in.
     *
     * `splitByBoundary` is what replaced it: attach what this session can read,
     * refuse the rest with the reason. Losing it silently would take the
     * warning away, not the boundary — the OS still holds that — which is
     * exactly the kind of regression nobody notices until an agent says it
     * cannot open a file.
     */
    expect(composer, 'the boundary is no longer applied to the picks').toMatch(
      /splitByBoundary\(boundary, picks\)/,
    )
    expect(composer, 'a refused pick no longer says why').toMatch(/outsideRefusal !== null/)
    expect(composer, 'the panel no longer opens where the session can read').toMatch(
      /startIn=\{browseStart\(boundary, root\)\}/,
    )
  })

  it('reaches outside only where it says it is doing so', () => {
    // `addAttachment` refuses an outside path unless the caller passes
    // 'anywhere'. Every route is an outside route now, so the default is no
    // longer protecting a caller that exists — it is protecting the next one.
    expect(composer).toMatch(/'anywhere'/)
    expect(read('renderer/chat/attach/mentions.ts')).toMatch(
      /scope: AttachScope = 'project'/,
    )
  })
})

/* ------------------------------------------- sessions, windows and the copilot -- */

/**
 * Four seams from his 2026-08-17 review that are wiring rather than logic, and
 * therefore invisible to every other kind of test in this project.
 */
describe('opening a window, and the copilot not swallowing one', () => {
  const app = read('renderer/App.tsx')

  it('opens a rail row beside the window you are in, rather than replacing it', () => {
    /*
     * *"whenever I click on side panel on anyone, it should open a new window
     * instead of switching. It should open its own new window next to it."*
     *
     * The strip drew one pill and overwrote it on every click, because a row
     * opened from the rail was never *kept* — it rode up as a transient tab and
     * evaporated the moment the next thing became active. Which is also the
     * whole of *"if I click on commander, they go away."*
     *
     * Wiring, not logic: `keepBesideInStrip` is unit-tested next to the store it
     * writes to, and `openTabWindow` is what connects it to the rail. Handing
     * `selectTab` back to `onSelectTab` restores the bug with nothing else
     * failing.
     */
    const tag = openingTag(app, 'Sidebar') ?? ''
    expect(tag, 'no <Sidebar> in App.tsx').not.toBe('')
    expect(tag).toMatch(/onSelectTab=\{openTabWindow\}/)
    expect(app).toMatch(/const anchor = activeTab\?\.id \?\? null/)
    expect(app).toMatch(/keepWindowBesideInStrip\(id, anchor\)/)
  })

  it('leaves the strip’s own pills switching rather than promoting', () => {
    // Moving between windows you already have is not opening one. A strip that
    // promoted on its own click would pin whatever you glanced at, which is the
    // automatic strip `workspace-strip.ts` opens by rejecting.
    const tag = openingTag(app, 'WorkspaceTabStrip') ?? ''
    expect(tag).toMatch(/onSelect=\{selectTab\}/)
  })

  it('does not hide a session just for being in the copilot’s folder', () => {
    /*
     * *"If I am opening same as copilot folder, it is taking me directly to the
     * commander… it will just be a normal another session."*
     *
     * The filter used to read `session.projectPath !== copilotRoot`, which threw
     * away any session started in that folder: no row, no tab, and a selection
     * pointing at nothing — so `resolveActiveTab` fell back to `tabs[0]`, which
     * with the copilot open is the copilot. Reproduced in the harness before it
     * was changed.
     */
    expect(app, 'the copilot filter is back to hiding a whole folder').not.toMatch(
      /session\.projectPath !== copilotRoot/,
    )
    expect(app).toMatch(/copilotIds\.current\.has\(session\.id\)/)
  })

  it('remembers an ended copilot so it does not resurface as somebody’s session', () => {
    // Nothing removes a session from the store when its process ends, while
    // `copilot:state` drops its `sessionId` the moment it goes — so the live id
    // alone is not enough at that instant.
    expect(app).toMatch(/copilotIds\.current\.add\(copilotSessionId\)/)
  })

  it('gives the copilot’s folder a heading once it holds a session of yours', () => {
    // Otherwise that session lands in the rail's orphan bucket, which means
    // "your project was closed out from under this" and is not what happened.
    expect(app).toMatch(/sessions\.some\(\(session\) => session\.projectPath === copilotRoot\)/)
  })

  it('sends every New session press through the dialog, including the two that did not', () => {
    /*
     * *"It is not asking me for this kind of pop-ups when I am opening from
     * here. Everywhere it should be consistent."* The swarm grid's empty slot
     * and the split pane's empty state both spawned straight into the active
     * folder on the default agent.
     */
    expect(app, 'a New session button still spawns without asking').not.toMatch(
      /onClick: \(\) => newSession\(\)/,
    )
    expect(app).not.toMatch(/onNewSession=\{\(\) => newSession\(\)\}/)
  })

  it('offers Continue-last-session only to an agent that has one', () => {
    // `host-core.ts` falls back to the ordinary arguments when `resumeArgs` is
    // empty, so on Gemini or a shell this started a *fresh* session and said
    // nothing. A control that cannot act is absent.
    const tag = openingTag(app, 'Sidebar') ?? ''
    expect(tag).toMatch(/canResume=\{canResumeDefault\}/)
    expect(app).toMatch(/canResumeDefault\s*\n?\s*\?\s*\[\{ id: 'session\.resume'/)
  })

  it('asks before closing anything, however calm it looks', () => {
    /*
     * *"Always ask."* The project ✕ used to count only the busy sessions and
     * skip the dialog when there were none — four calm agents, one press, gone
     * without a word. Reproduced in the harness.
     */
    expect(app, 'the project close is gated on busy sessions again').not.toMatch(
      /if \(risky\.length === 0\)/,
    )
    expect(app).toMatch(/if \(!confirmClose\) \{[\s\S]{0,80}closeProjectNow\(path\)/)
    // And a session whose status has not arrived yet is asked about too — the
    // old `tab.status &&` skipped exactly the sessions a person knows least
    // about: one restored at launch, one a phone started.
    expect(app).toMatch(/needsCloseConfirm\(tab\.status \?\? 'idle', confirmClose\)/)
  })
})
