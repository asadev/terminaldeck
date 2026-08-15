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
    file: 'renderer/App.tsx',
    child: 'SessionInspector',
    props: ['cwd', 'session', 'sessionTitle'],
    why: 'without session it reports the folder’s newest transcript under this session’s name — including one belonging to a claude this app never started',
  },
  {
    file: 'renderer/components/ChatView.tsx',
    child: 'AgentControls',
    props: ['sessionId', 'cwd'],
    why: 'model, effort and permission mode are read off the session screen',
  },
  {
    file: 'renderer/components/ChatView.tsx',
    child: 'UsageStrip',
    props: ['cwd', 'scoped', 'sessionId'],
    // `scoped` is the one that keeps the numbers honest. Without it an absent
    // transcript path reads as "no preference", so the strip picked whichever
    // session in the folder ran last and printed its spend and context fill
    // under the heading "This session" — for a tab that had made no request at
    // all, and, under a second account, for money belonging to another login.
    why: 'plan limits come from the running session; cost comes from the project; scoped decides whether an absent transcript means "the newest one" or "this session has none yet"',
  },
  {
    file: 'renderer/components/ChatComposer.tsx',
    child: 'AttachMenu',
    props: ['mode'],
    why:
      'the plus button is the only way to attach files, folders or MCP servers, and without mode ' +
      'a shell session is offered `@"path"` mentions it would type verbatim at its prompt',
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
    child: 'AccountChip',
    props: ['current', 'projectPath', 'provider', 'onPick'],
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
    why: 'the only place in the window where the account for a session can be seen or chosen',
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
  const tag = openingTag(read('renderer/App.tsx'), 'BrowserWorkspace') ?? ''

  it('decides visibility from the tab alone', () => {
    const visible = propExpression(tag, 'visible')
    expect(visible, '<BrowserWorkspace> has no visible={...}').not.toBeNull()
    expect(visible).toMatch(/activeTab/)
    expect(visible, 'a dialog is not a tab switch — that belongs in parkPage').not.toMatch(
      /Modal|Open\b/,
    )
  })

  it('parks the pages for whatever dialog is open', () => {
    expect(propExpression(tag, 'parkPage')).toMatch(/Modal/)
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
 * Nothing the chat composer offers may be simplified away.
 *
 * This is the only entry in this file that guards against a *deletion made on
 * purpose*, and it is here because that deletion has already happened. Asked
 * for "one large chat box with the options folded neatly inside it", a pass
 * over this composer folded two controls onto the box, put two behind a button
 * labelled "More", and withdrew the attach menu from shell sessions entirely —
 * leaving that composer with a microphone and a send button. What came back
 * was: "you actually removed everything rather than making it simple and all
 * the options you have actually removed."
 *
 * Every check below is one of the things that went, expressed as a question
 * about the source, because none of them would fail a single one of the
 * deleted component's own tests. A control that is not rendered still passes
 * everything ever written about it.
 */
describe('the chat composer keeps every control it was given', () => {
  const composer = read('renderer/components/ChatComposer.tsx')
  const controls = read('renderer/chat/controls/AgentControls.tsx')

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

  it('builds the options panel from every control, not from the remainder', () => {
    // `FOLDED_CONTROLS.map` is what made the panel a list of leftovers. The
    // panel is the complete inventory now, and the row's chips are the
    // shortcut — see `MENU_CONTROLS` in chat/controls/catalog.ts.
    expect(controls, 'the panel lists only the controls that were folded away').not.toMatch(
      /FOLDED_CONTROLS\.map/,
    )
    expect(controls).toMatch(/MENU_CONTROLS\.map/)
  })

  it('names that panel rather than calling it More', () => {
    // A word that names nothing is why the controls behind it were read as
    // deleted. The button says Options and its hover label lists the contents.
    expect(controls).not.toMatch(/^\s*More$/m)
    expect(controls).toMatch(/^\s*Options$/m)
    expect(controls, 'the hover label is typed by hand and will outlive a control it names').toMatch(
      /title=\{optionsLabel\}/,
    )
  })

  it('keeps the pickers, the microphone, the send button and the panel in the box', () => {
    // Each of these is a control someone can reach today. If one is taken out
    // to make the row shorter, this is where it is noticed — the alternative
    // is noticing it in a message from the person using the app.
    for (const held of ['AttachChips', 'AttachMenu', 'DictateButton', 'cc-send', '{controls}']) {
      expect(composer, `${held} is no longer rendered by the composer`).toContain(held)
    }
    for (const held of ['ControlPicker', 'ControlSection']) {
      expect(controls, `${held} is no longer rendered by the controls`).toContain(`<${held}`)
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
