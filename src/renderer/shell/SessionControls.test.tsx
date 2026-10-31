import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { afterEach, describe, expect, it } from 'vitest'
import {
  ConnectorsPicker,
  SessionControls,
  contentsSentence,
  summaryDetail,
  summaryLabel,
  SUMMARY_BOTH_PX,
  SUMMARY_MODEL_PX,
} from './SessionControls'
import { DEFAULT_EFFORT, EFFORT_OPTIONS, controlName } from '../chat/controls/catalog'
import { preferredEffort } from './useSessionControls'

/**
 * What the session's controls put on the chrome, and what withdraws them.
 *
 * Asad, twice, the second time with the first ask quoted back at us:
 *
 *   > *"The thing I'm still missing is the other things I asked you to bring
 *   > there — for example the model selection, all of the things that a chat
 *   > session used to have. I mean efforts, fast mode, model selection, and add
 *   > plugin connectors. … But they should be on the top bar."*
 *
 * They were built and they worked; they were folded into the chat composer,
 * which a session drawn as a terminal never shows. So the failure these guard
 * is not "the control is broken" — every one of them passed its own tests — it
 * is "the control cannot be reached from where the session is". That is a
 * question about what is rendered, which is what this file asks.
 *
 * `react-dom/server`, like every other render test in this folder: this project
 * has no DOM in its test setup, deliberately. That fixes the cluster in its
 * expanded, closed state, which is the state that matters here — everything a
 * person has to look at *before* they find a control is in this markup.
 */

/** The bridge is read off `globalThis` during render, so it has to exist first. */
function withBridge(): void {
  ;(globalThis as { deck?: unknown }).deck = {
    readAgentControls: async () => ({}),
    applyAgentControl: async () => ({}),
  }
}

afterEach(() => {
  delete (globalThis as { deck?: unknown }).deck
})

const noop = (): void => {}

/*
 * `exited: false` because every case in this file is about a session that is
 * running; the ones about a session that has stopped are in
 * `SessionControls.presence.test.tsx`, where the stand-in for the screen makes
 * the difference between the two visible. It is a default *here* and
 * deliberately not one on the prop — see the note on `exited` in
 * `SessionControls.tsx` for what a default would cost at a real call site.
 */
function render(props: Partial<Parameters<typeof SessionControls>[0]> = {}): string {
  return renderToStaticMarkup(
    <SessionControls
      sessionId="s1"
      cwd="/Users/apple/Projects/terminaldeck"
      provider="claude"
      exited={false}
      onOpenConnectors={noop}
      {...props}
    />,
  )
}

/** Every button's accessible name — its aria-label, or its tooltip. */
function names(html: string): string[] {
  return (html.match(/<button[^>]*>/g) ?? []).map(
    (tag) => /aria-label="([^"]*)"/.exec(tag)?.[1] ?? /title="([^"]*)"/.exec(tag)?.[1] ?? '',
  )
}

describe('what a running Claude session gets on its bar', () => {
  it('carries model and effort as chips of their own', () => {
    withBridge()
    const html = render()
    for (const control of ['model', 'effort'] as const) {
      expect(html, control).toContain(controlName(control))
    }
  })

  it('carries fast mode too, at the end of the model menu rather than as a chip', () => {
    /*
     * *"Move fast mode toggle inside the models dropdown at the end."*
     *
     * A shut menu renders nothing, so a static markup test can see the chip
     * that is *gone* and cannot see the item that replaced it. Both halves are
     * asserted, from the two places they can be: the absence off the rendered
     * bar, and the presence out of the source, where `NESTED_CONTROLS` is the
     * one statement of which control ends whose menu. The item's own three
     * states are exercised in `chat/controls/ControlToggle.test.tsx`, which can
     * render it directly.
     */
    withBridge()
    const html = render()
    expect(html, 'fast mode still has a chip on the bar').not.toContain(controlName('fast'))
    expect(html, 'the switch chip is still on the bar').not.toContain('ac-toggle')

    const view = readFileSync(join(__dirname, 'SessionControls.tsx'), 'utf8')
    expect(view).toMatch(/NESTED_CONTROLS[^=]*=\s*\{\s*model:\s*'fast'\s*\}/)
    expect(view, 'nothing passes the nested control to the menu that hosts it').toContain(
      'nested={nestedIn(id)}',
    )
  })

  it('gives every button a name a person can read or hear', () => {
    withBridge()
    const html = render()
    expect(names(html).length).toBeGreaterThan(0)
    for (const name of names(html)) expect(name).not.toBe('')
  })
})

describe('the control that the terminal underneath already draws', () => {
  /**
   * Asad, looking at a chip on the bar reading `Bypass`:
   *
   *   > *"we don't need this part also at the end, now bypass read things
   *   > because we have this here already inside."*
   *
   * "Here already inside" is Claude Code's own indicator, which it redraws along
   * the bottom of every session for as long as the session runs — `⏵⏵ bypass
   * permissions on (shift+tab to cycle)`, captured verbatim in
   * `src/main/cli-screens.capture.json` and matched by
   * `SessionControls.presence.test.tsx` two files over.
   *
   * The chip was therefore a *second* reading of one fact, and it was the one
   * that could be wrong: it showed whatever frame this app last parsed, while
   * the line below it is drawn by the process that owns the answer. This asserts
   * the removal from the surface a person actually looks at;
   * `chat/controls/one-home.test.ts` asserts the other half — that the control
   * still has a home and that the source says which.
   */
  it('draws no permission chip and no mode word on the bar', () => {
    withBridge()
    const html = render()
    expect(html).not.toContain(controlName('permission'))
    // Every mode the picker used to offer, because "no chip" and "no menu" are
    // different failures and only the second is visible in a static render.
    for (const mode of ['Bypass', 'Accept edits', 'Plan mode']) {
      expect(html, mode).not.toContain(mode)
    }
  })
})

describe('fast mode, which is one control and no longer a chip', () => {
  /**
   * Asad, in the same breath as the chip above:
   *
   *   > *"then here also now think we don't need, just one to select is
   *   > enough."*
   *
   * A picker over `Off` and `On` is two clicks to do a one-click thing, and it
   * spends one of its two rows telling you what you are already doing. The whole
   * argument is in `chat/controls/ControlToggle.tsx`.
   */
  it('is not a chip on the bar any more, and left no dead one behind', () => {
    /*
     * A static render reaches no bridge effect, so nothing has read this
     * session's fast mode. That used to make this the place the *unread* chip
     * was checked; the chip is gone — *"move fast mode toggle inside the models
     * dropdown at the end"* — so what is left to check here is that it went
     * cleanly, taking its switch markup with it rather than leaving a greyed
     * husk on the row.
     *
     * The unread state itself did not go anywhere. It is drawn inside the model
     * menu now, still pressable, still offering both settings, and it is
     * asserted in `chat/controls/ControlToggle.test.tsx` against
     * `ControlToggleItem`, which can be rendered with a reading and read
     * without a click.
     */
    withBridge()
    const html = render()
    for (const gone of ['ac-toggle', 'ac-toggle-track', 'role="switch"']) {
      expect(html, `${gone} is still drawn on the bar`).not.toContain(gone)
    }
  })

  it('takes the stylesheet exception with it, rather than leaving it matching nothing', () => {
    /*
     * The names come off the chips on this bar — *"just Opus 5 with drop down is
     * good enough"* — and the switch was that rule's one exception, because a
     * knob names nothing: on or off *what*? With no switch on the bar the
     * exception has nothing to apply to, and a `display: block` aimed at an
     * element that is never rendered is how a stylesheet comes to describe a
     * layout the app no longer has.
     *
     * The control still says what it is. It leads the row inside the model menu
     * with `.ac-item-label`, which nothing here hides — which is the same
     * argument satisfied for free rather than dropped.
     */
    const sheet = readFileSync(join(__dirname, 'SessionControls.css'), 'utf8')
    expect(sheet).not.toContain('.session-controls .ac-toggle .ac-name {')
    withBridge()
    expect(render()).not.toContain('class="ac-name">Fast mode')
  })

  it('picks its shape from the option count, not from the control’s name', () => {
    /*
     * `SessionControls.tsx` tests `optionsForRow(id).length === 2`. Written as
     * `id === 'fast'` it would be this file's private opinion about which
     * control is two-state — a second copy of a fact `catalog.ts` holds, and the
     * copy that goes stale is always the one furthest from the list.
     */
    const view = readFileSync(join(__dirname, 'SessionControls.tsx'), 'utf8')
    expect(view).toContain('optionsForRow(id).length === 2')
    expect(view).not.toMatch(/id === 'fast'/)
  })
})

describe('the names on the chips', () => {
  /**
   * Asad, watching the top bar on 2026-08-17:
   *
   *   > *"No need to show the other things like only show Opus 5. If they drop
   *   > down, they know that this is a model. So no need to tell that Model Opus
   *   > 5 — just Opus 5 with drop down is good enough. Also effort, no need to
   *   > tell effort."*
   *
   * Which is a change to what is *drawn*, and specifically not a change to what
   * is *said*. This pair of tests is the difference: the name comes off the bar
   * and stays in the accessible name, so a person who does not recognise
   * `Ultracode` still gets "Effort: Ultracode — from Claude settings" by resting
   * on it, and a screen-reader user is still told what the control is.
   *
   * The drawn half is a CSS rule and cannot be seen in a rendered string, so it
   * is asserted against the stylesheet — including its one exception, which is
   * the exception that stops the rule producing an empty chip.
   */
  const css = readFileSync(join(__dirname, 'SessionControls.css'), 'utf8')

  it('is not drawn beside the value on this bar', () => {
    expect(css).toContain('.session-controls .ac-picker:not(.sc-connectors) .ac-name {')
    expect(css).toMatch(/\.ac-picker:not\(\.sc-connectors\) \.ac-name \{\s*\n\s*display: none;/)
  })

  it('is still what the chip is called when you hover it or hear it', () => {
    // The chip's tooltip is `${name}: ${value} — ${note}`, built in
    // `ControlPicker`. Hiding the drawn copy must not have been done by
    // deleting the name, which would have taken this with it.
    withBridge()
    const said = names(render()).join(' ')
    /*
     * Model and effort, and fast mode is not in this list because it is not a
     * chip on this bar any more — it is the last item in the model menu, and it
     * carries the same four-part label there, asserted where it can be rendered
     * in `chat/controls/ControlToggle.test.tsx`. Dropped from the loop rather
     * than the loop dropped, so the rule still has to hold for the two controls
     * it is about.
     */
    for (const control of ['model', 'effort'] as const) {
      expect(said, control).toContain(`${controlName(control)}:`)
    }
  })

  it('comes back the moment there is no value for it to be redundant beside', () => {
    /*
     * Found by looking at the rendered toolbar, and it is the reason this rule
     * has an exception at all. With the names off, a window whose session had
     * gone away drew `Unknown ⌄  Unknown ⌄  Not reported ⌄  Unknown ⌄` — four
     * controls in a row that no longer said what any of them were.
     *
     * His sentence carries its own condition: *"just **Opus 5** with drop down
     * is good enough."* `Opus 5` is good enough because it is a model and says
     * so. `Unknown` is not anything, so the label it made redundant stops being
     * redundant the instant the value goes.
     */
    expect(css).toContain(
      '.session-controls .ac-picker:not(.sc-connectors) .cc-chip:has(.ac-value-unknown) .ac-name {',
    )
    // Keyed on the class `ControlPicker` sets from `reading.label === null`, so
    // there is no second definition of "unread" for this to drift from.
    expect(css).toContain('.ac-value-unknown')
  })

  it('follows the same rule on the folded chip, which is drawn by hand', () => {
    // The folded chip draws its own spans rather than going through
    // `ControlPicker`, so the CSS rule above cannot reach it and the same
    // judgement has to be made in the markup — a name only where the value is
    // not one this app read. Its hover label names both either way; see
    // `summaryLabel`.
    const view = readFileSync(join(__dirname, 'SessionControls.tsx'), 'utf8')
    expect(view).toContain(
      "{readings?.model.label ? null : <span className=\"ac-name\">{controlName('model')}</span>}",
    )
    expect(view).toContain(
      "{readings?.effort.label ? null : <span className=\"ac-name\">{controlName('effort')}</span>}",
    )
  })
})

/* -------------------------------------------------------------------------- *
 * The folded chip at widths a person can actually be at.
 *
 * Measured in the running app on 2026-08-18, on a session named "Update Claude
 * Code terminal to new version", with the fade that used to live in
 * `SessionControls.css`:
 *
 *     720px  chip  25px   label drawn    0px of 106
 *     900px  chip  92px   label drawn   45px of 106
 *     1100px chip 137px   label drawn  106px of 106
 *
 * 720 is this app's own `minWidth`, so the first row is not a corner case — it
 * is the narrowest window somebody can make, and the control there was a bare
 * chevron with a hundred and six pixels of invisible words behind it. The second
 * row is the *"faded, clipped text — show it properly or make it a dropdown
 * only"* item from the 2026-08-17 review, arrived in a new place.
 * -------------------------------------------------------------------------- */

describe('the folded chip says less rather than drawing less', () => {
  const css = readFileSync(join(__dirname, 'SessionControls.css'), 'utf8')
  const view = readFileSync(join(__dirname, 'SessionControls.tsx'), 'utf8')

  it('has no mask anywhere in it, at any width or in any state', () => {
    // The whole defect in one assertion. A fade is not a smaller label, it is a
    // label the screen appears to have lost — and at 720 it was the entire
    // label. Whatever this chip does when it runs out of room, it may not do
    // this.
    expect(css).not.toContain('mask-image')
    expect(css).not.toContain('data-clipped')
    expect(view).not.toContain('data-clipped')
  })

  it('carries both values only when the room for both has been measured', () => {
    // 250 is 107 for the reading beside it, 2 for the gap and 137 for the chip
    // carrying `Opus 5 · Ultracode`. Below that the chip stops promising two
    // values it cannot draw.
    expect(summaryDetail(SUMMARY_BOTH_PX)).toBe('both')
    expect(summaryDetail(SUMMARY_BOTH_PX + 400)).toBe('both')
    expect(summaryDetail(SUMMARY_BOTH_PX - 1)).toBe('model')
  })

  it('keeps the model whole rather than showing halves of two values', () => {
    // *"Just Opus 5 with drop down is good enough."* One value read is worth
    // more than two values guessed, and nothing is lost — `summaryLabel` names
    // and quotes both, on hover and to a screen reader.
    expect(summaryDetail(SUMMARY_MODEL_PX)).toBe('model')
    expect(summaryDetail(161)).toBe('model')
  })

  it('becomes an icon rather than an empty chip when there is room for neither', () => {
    expect(summaryDetail(SUMMARY_MODEL_PX - 1)).toBe('glyph')
    expect(summaryDetail(25)).toBe('glyph')
    // An icon that was chosen, not a word that was erased: the glyph is in the
    // markup, and it comes with the caret and the same accessible name.
    expect(view).toContain('sc-summary-glyph')
  })

  it('draws the unclamped row before anything has been measured', () => {
    // The first paint, and this component's own static renders. Same answer
    // `fit` gives to the same state, for the same reason.
    expect(summaryDetail(null)).toBe('both')
  })

  it('gives each of the three states a floor wide enough for what it draws', () => {
    // A single floor could only ever be right for one of them. 72 is 31 of chip
    // chrome around `Opus 5`, measured at 38.2 in the app, plus a few pixels of
    // margin; without it, flex shares a shortfall proportionally and a 900px
    // window drew the one remaining value as `Opus…`. At exactly 69 — the
    // arithmetic to the pixel — it drew `Opus…` as well, which is why the margin
    // is part of the number rather than a rounding-up of it.
    expect(css).toContain(".session-controls[data-detail='model'] .sc-summary {")
    expect(css).toMatch(/\[data-detail='model'\] \.sc-summary \{\s*\n\s*min-width: 72px;/)
    expect(css).toContain(".session-controls[data-detail='glyph'] .sc-summary {")
  })

  it('lets only the trailing value give way, so there is one truncation and not four', () => {
    // Ellipsising every span reads as `M… Opus 5 · E… High`. The last value is
    // the one furthest from the reader's entry point, so it is the one that can
    // afford to end in an ellipsis.
    expect(css).toContain('.sc-summary .sc-summary-text > .ac-value:last-child {')
    expect(css).toContain('.sc-summary .sc-summary-text > * {\n  flex-shrink: 0;\n}')
  })
})

/**
 * The panel behind that chip, and the four blocks of prose it used to print.
 *
 * This is the surface Asad opens whenever his window is narrower than about nine
 * hundred pixels, and it was the one place in the app nobody audited. Rendered
 * on 2026-08-20 it carried a description under every heading, the same two-line
 * refusal three times, a two-line foot under every section naming where the value
 * had been read from and how far a change reaches, and a closing sentence about
 * what pressing anything does. Every one of them is deleted; what a reader still
 * needs is behind the ⓘ or in a hover label.
 *
 *   > *"don't put any single statement in anywhere. Everywhere you are putting a
 *   > lot of statements. We don't need to give the statements. We want
 *   > simplicity. Let the smart people use it. Smart people knows how it
 *   > works."*
 *
 * Source text rather than a render, because the panel is only in the DOM once a
 * chip has been pressed and this project's tests have no DOM. What the panel
 * looks like once open is `ControlSection.test.tsx`'s; what is asserted here is
 * that this file is not putting a sentence back around it.
 */
describe('the folded panel prints no standing sentence of its own', () => {
  const view = readFileSync(join(__dirname, 'SessionControls.tsx'), 'utf8')
  const shared = readFileSync(join(__dirname, '..', 'chat', 'controls', 'AgentControls.css'), 'utf8')

  it('has no foot under the last section', () => {
    expect(view).not.toContain('ac-sheet-foot')
    expect(view).not.toContain('Every change here is typed into this session')
    // And the rules are gone with the markup. A style with nothing drawing it is
    // a paragraph waiting to be written again. (Both class names still appear in
    // this stylesheet's *prose*, saying why they went, so what is checked is that
    // neither opens a rule.)
    expect(shared).not.toMatch(/\.ac-sheet-foot\s*[,{]/)
    expect(shared).not.toMatch(/\.ac-section-desc\s*[,{]/)
  })

  it('does not name the connectors chip twice on one line', () => {
    /*
     * `Connectors` as a section heading over a chip whose only word is
     * `Connectors` — a centimetre apart, in the same panel. *"It doesn't make
     * any sense to keep in both side the same thing."* The chip keeps it,
     * because the chip is also the thing you press.
     */
    expect(view).not.toContain('<h4 className="ac-section-name">Connectors</h4>')
  })
})

describe('connectors, which exist only when there are connectors', () => {
  /**
   * Asad: *"connectors — a dropdown only when some exist. Hide it when empty."*
   *
   * The chip used to be on the bar unconditionally, opening the MCP servers
   * view whether or not a single server was configured — a permanent invitation
   * to an empty room, on a bar shared with five other controls. It is the most
   * repeated finding in his review, and the fix is the one he stated rather than
   * a softening of it: when there is nothing behind it, it is not there.
   */
  const view = readFileSync(join(__dirname, 'SessionControls.tsx'), 'utf8')

  it('draws nothing at all until the answer has come back', () => {
    // `useConnectors` starts `loaded: false`, and effects do not run in a static
    // render — so this is also the "nothing flickers into the bar and pushes the
    // mode switch sideways" case.
    withBridge()
    expect(render()).not.toContain('Connectors')
  })

  it('is mounted only under a condition that counts them, whichever machine they are on', () => {
    /*
     * Counted from two different sources, and never from the wrong one.
     *
     * `listMcpServers` resolves a folder's `.mcp.json` and this app's own
     * registry *here*, so it answers only for a local session. The servers that
     * matter to a session on a paired machine are that machine's, and since
     * 2026-08-20 they travel: the far end resolves its own three files for that
     * session's own folder and puts them on the `controls.reading` it was
     * already sending. Asad: *"I want it exactly like the local ones."*
     *
     * The two branches are pinned separately because folding them into one
     * `connectors.rows.length > 0` is exactly the regression to catch — it would
     * draw *this* machine's servers under a session on his PC.
     */
    expect(view).toContain("const remoteConnectors = target?.kind === 'machine' ? (readings?.connectors ?? null) : null")
    expect(view).toContain(
      'const connectorRows = target === undefined ? connectors.rows : (remoteConnectors ?? [])',
    )
    expect(view).toContain(
      'target === undefined ? connectors.loaded && connectors.rows.length > 0 : connectorRows.length > 0',
    )
    // Both homes: the open row and the folded panel's section. An empty section
    // in the panel is the same dead invitation one fold further in.
    expect(view.match(/hasConnectors \? \(/g) ?? []).toHaveLength(2)
  })

  it('takes the door away over a session that is not on this computer', () => {
    /*
     * The list travels; the action does not. `onOpenConnectors` opens *this*
     * machine's MCP servers view, so under a session on his PC it would be a
     * button that walks from a list of that machine's connectors to a page
     * managing this one's. Withdrawn, and withdrawn silently — a sentence in its
     * place is the habit he asked to have removed everywhere.
     */
    expect(view).toContain('const openConnectorsHere = target === undefined ? onOpenConnectors : null')
    expect(view).toContain('{onOpen !== null || blocked !== null ? (')
    // And the row really is gone rather than disabled, for a picker with neither.
    const html = renderToStaticMarkup(
      <ConnectorsPicker
        rows={[{ id: 'user:github', name: 'github', scope: 'user', transport: 'stdio', enabled: true, disabledReason: null }]}
        onOpen={null}
        blocked={null}
      />,
    )
    // The chip is still there — the list is the substance and it stays. Only the
    // action row is gone. (The panel itself is shut in a static render, which is
    // why the row is asserted by its class rather than by a server's name.)
    expect(html).toContain('Connectors')
    expect(html).not.toContain('sc-sheet-actions')
  })

  it('lists what it found, and offers exactly one thing to press', () => {
    /*
     * The rows are readings, not buttons. This app can do one thing with a
     * server from a toolbar — open the view that owns adding, inspecting and
     * connecting — and that one thing is not per-server, so rows that were
     * buttons would all go to the same place. That is the fault he reported on
     * another page in the same recording: *"every row opens the same session."*
     */
    const html = renderToStaticMarkup(
      <ConnectorsPicker
        rows={[
          { id: 'user:github', name: 'github', scope: 'user', transport: 'stdio', enabled: true, disabledReason: null },
        ]}
        onOpen={noop}
        blocked={null}
      />,
    )
    expect(html).toContain('Connectors')
    // One button: the chip that opens the list. Everything inside it is a `<p>`.
    expect(html.match(/<button/g) ?? []).toHaveLength(1)
    expect(view).toContain('<p key={row.id} className="sc-connector"')
  })

  it('says why the one action cannot act, rather than swallowing the click', () => {
    // A feature can be uninstalled in this app. The control that would have
    // opened it admits that instead of appearing to work.
    const html = renderToStaticMarkup(
      <ConnectorsPicker rows={[{ id: 'a', name: 'a', scope: null, transport: null, enabled: true, disabledReason: null }]} onOpen={null} blocked={null} />,
    )
    expect(html).toContain('Connectors')
    expect(view).toContain('The MCP servers view is not installed in this build')
  })
})

describe('the effort default', () => {
  /**
   * Asad: *"effort defaults to extra-high, and a change sticks."*
   *
   * Both halves are real rather than displayed. The app types `/effort xhigh`
   * into a session that reports **no** effort from any source, which is what a
   * machine looks like when nobody has ever set one; and a value picked from the
   * bar is remembered and used in its place from then on. A control that merely
   * *printed* `Extra high` over a session running at something else would be the
   * one thing this whole cluster is built to refuse.
   */
  it('is extra high when nothing has ever been chosen', () => {
    expect(preferredEffort(null)).toBe(DEFAULT_EFFORT)
    expect(DEFAULT_EFFORT).toBe('xhigh')
    expect(EFFORT_OPTIONS.some((option) => option.id === DEFAULT_EFFORT)).toBe(true)
  })

  it('is the row a reader sees first, so the menu and the app agree', () => {
    // A menu's first row is read as its default whether or not it was meant to
    // be. `Auto` used to be first and is the one option that *undoes* the
    // default rather than being it.
    expect(EFFORT_OPTIONS[0]?.id).toBe(DEFAULT_EFFORT)
  })

  it('gives way to whatever was chosen last', () => {
    expect(preferredEffort({ getItem: () => 'max' })).toBe('max')
  })

  it('applies nothing at all once “auto” has been chosen', () => {
    /*
     * `auto` *is* the cleared state — the CLI answers `Cleared effort from
     * settings` — so a session that has chosen it reports no effort, which is
     * the very condition that triggers the default. Without this, somebody who
     * deliberately wants the model's own default would be handed extra-high
     * again on every new session for ever, with no way to stop it.
     */
    expect(preferredEffort({ getItem: () => 'auto' })).toBeNull()
  })

  it('ignores a value that is not one the CLI accepts', () => {
    // This string is editable by hand in devtools and can be left behind by an
    // older build. Anything unrecognised falls back rather than being typed at
    // somebody's prompt.
    expect(preferredEffort({ getItem: () => 'turbo' })).toBe(DEFAULT_EFFORT)
  })

  it('survives a storage that throws rather than taking the bar down', () => {
    expect(
      preferredEffort({
        getItem: () => {
          throw new Error('blocked')
        },
      }),
    ).toBe(DEFAULT_EFFORT)
  })

  it('is applied by typing it, and only to a session that reported none', () => {
    const hook = readFileSync(join(__dirname, 'useSessionControls.ts'), 'utf8')
    expect(hook).toContain("control: 'effort', value: want")
    // Every guard that stops it overriding a choice or fighting the user.
    expect(hook).toContain('if (readings.effort.label !== null')
    expect(hook).toContain('if (defaulted.has(sessionId)) return')
    expect(hook).toContain("provider !== 'claude'")
    expect(hook).toContain('if (!readings.gate.canType) return')
  })

  it('and the change is what gets remembered, not the reading it produced', () => {
    // For `auto` the two are different facts: the reading that comes back is an
    // absence, and storing the absence would lose the choice.
    const hook = readFileSync(join(__dirname, 'useSessionControls.ts'), 'utf8')
    expect(hook).toContain("if (control === 'effort' && answer.ok) rememberEffort(storage(), value)")
  })
})

describe('a shell session is not an agent', () => {
  it('draws nothing at all', () => {
    /*
     * Withdrawn rather than disabled-with-a-reason, which is what every other
     * unusable state here gets. There is no missing capability to explain: the
     * pty is `/bin/zsh -l` and it has no model. Four greyed chips over a shell
     * would teach the reader that this app could set a model on their shell if
     * only something were different.
     *
     * It is also the bug that produced the rule. The reader behind these values
     * falls back to Claude Code's own settings file when it cannot parse a
     * screen, so a plain shell once reported `Model  Opus 5`.
     *
     * Nothing has read this session's screen — a static render gives the
     * presence hook no chance to resolve a promise — so this is the *unknown*
     * shell as well as the plain one, and both draw nothing for the reason set
     * out in `SessionControls.presence.test.tsx`. What is emphatically no
     * longer covered by this case is a shell with Claude Code running in it;
     * that one is over there and it draws the full cluster.
     */
    withBridge()
    expect(render({ provider: 'shell' })).toBe('')
  })
})

describe('a CLI this build has not been shown how to drive', () => {
  it('keeps the chips and says why they cannot act', () => {
    /*
     * The opposite call from the shell's, and the difference is the honest
     * part: a Codex session certainly *has* a model, and this app has simply
     * not established how to change it from the outside. A gap where a control
     * should be says nothing about why; a chip carrying that sentence does.
     */
    withBridge()
    for (const provider of ['codex', 'gemini'] as const) {
      const html = render({ provider })
      expect(html, provider).toContain(controlName('model'))
      expect(html, provider).toContain('aria-disabled="true"')
      const said = names(html).join(' ')
      expect(said.toLowerCase(), provider).toContain(provider)
      // The sentence lives in `catalog.ts` and is shared with the composer's
      // copy, so the two cannot come to explain one situation two ways.
      expect(said).toContain('has not been shown what they are')
    }
  })
})

describe('a build with no bridge', () => {
  it('says the controls are not wired rather than pretending they are', () => {
    // No `withBridge()`. Every chip is still on screen, drawn back, carrying
    // the reason — the same rule as a foreign CLI.
    const html = render()
    expect(html).toContain(controlName('model'))
    expect(html).toContain('aria-disabled="true"')
    expect(names(html).join(' ')).toContain('not wired into this build')
  })
})

describe('the sentence the folded chip advertises', () => {
  /**
   * The failure this guards is documented at length in `catalog.ts`: a button
   * labelled "More" hid two controls and they were reported as *deleted*,
   * because nothing on screen named them. The folded chip's hover label is the
   * only place its contents are named, so it is built from the contents rather
   * than typed out — and this is what proves it stayed that way.
   */
  it('names every control the cluster holds', () => {
    const sentence = contentsSentence(true)
    /*
     * Permission mode is deliberately not in this list any more, and its absence
     * here is the same decision as its absence from the bar rather than a second
     * one: the sentence is built from `CHROME_CONTROLS`, so it cannot advertise
     * a control the fold is not hiding. *"we don't need this part also at the
     * end, now bypass read things because we have this here already inside"* —
     * the CLI draws `⏵⏵ bypass permissions on (shift+tab to cycle)` under every
     * session, and `chat/controls/one-home.test.ts` is what stops that becoming
     * a quiet deletion.
     */
    for (const control of ['model', 'effort', 'fast'] as const) {
      expect(sentence.toLowerCase(), control).toContain(controlName(control).toLowerCase())
    }
    expect(sentence.toLowerCase()).toContain('connectors')
    expect(sentence.toLowerCase()).not.toContain('permission')
  })

  it('is prose rather than a row of proper nouns', () => {
    expect(contentsSentence(true)).toBe('Model, effort, fast mode and connectors')
  })

  it('never says the word that caused the deletion report', () => {
    expect(contentsSentence(true)).not.toMatch(/\bmore\b/i)
  })
})

describe('what the folded chip still says out loud', () => {
  /**
   * A folded control that hides its own value is worse than one that takes
   * space. The chip carries the model and the effort *on it*, named, and the
   * label carries both in full — the chip truncates a long model name at
   * fourteen characters and this is where the rest of it lives.
   *
   * The first version of this chip named only the model, which is the same
   * mistake as the "More" button one control further along: `Effort Ultracode`
   * is read off a real settings file, and a bar with room to say so that does
   * not is hiding something it knows.
   */
  it('states both readings, each under its own control’s name', () => {
    const said = summaryLabel('Opus 5 (1M context)', 'Ultracode', true)
    expect(said).toContain('model Opus 5 (1M context)')
    expect(said).toContain('effort Ultracode')
  })

  it('still names every control the fold put away', () => {
    const said = summaryLabel('Opus 5', 'High', true).toLowerCase()
    for (const control of ['model', 'effort', 'fast'] as const) {
      expect(said, control).toContain(controlName(control).toLowerCase())
    }
    expect(said).toContain('connectors')
  })

  it('does not advertise connectors on a machine that has none', () => {
    // The same rule the chip obeys, one fold in. Naming a control the panel
    // does not contain is the mirror image of the "More" failure: a label
    // pointing at nothing instead of nothing pointing at a label.
    expect(summaryLabel('Opus 5', 'High', false).toLowerCase()).not.toContain('connectors')
  })

  it('says the unread value rather than inventing one', () => {
    // `displayValue` answers "Unknown" for a model nothing has reported. The
    // label repeats that answer; it never falls back to a plausible name.
    expect(summaryLabel('Unknown', 'Unknown', true)).toContain('model Unknown, effort Unknown')
  })
})

/**
 * Three facts a rendered string cannot carry.
 *
 * The bridge calls happen in an effect and in a click handler, and the fold is
 * decided by a `ResizeObserver` — none of which a static render reaches, and
 * this project has no DOM in its test setup to run them in. So they are
 * asserted against the source, the way `wiring.test.ts` and `finish.test.ts`
 * already assert the things only visible there.
 */
describe('what the chrome controls tell the main process', () => {
  const hook = readFileSync(join(__dirname, 'useSessionControls.ts'), 'utf8')
  const view = readFileSync(join(__dirname, 'SessionControls.tsx'), 'utf8')

  it('names the provider on every call, because the main process refuses on it', () => {
    // Without this the main process sees `provider: undefined` for a Codex
    // session and falls back to asking the screen — correct by luck rather than
    // by design, and wrong the moment another CLI draws something similar.
    /*
     * Both calls go through `controls-target.ts` now — which computer to ask —
     * so the pin follows them there. The provider still has to be named on each,
     * and the router still has to hand it to the local channel; a reading that
     * lost it would put this machine's Claude settings on a Codex session's bar.
     */
    const router = readFileSync(join(__dirname, 'controls-target.ts'), 'utf8')
    expect(hook).toMatch(/readControlsAt\(where\([^)]*\), \{ sessionId, cwd, provider \}\)/)
    expect(hook).toMatch(/applyControlAt\(where\(targetKind, targetMachine\), \{[\s\S]*?provider,/)
    expect(router).toMatch(/readAgentControls[\s\S]{0,400}?provider: request\.provider/)
    expect(router).toMatch(/applyAgentControl[\s\S]{0,600}?provider: request\.provider/)
  })

  it('shows the value the session reported, not the one that was clicked', () => {
    // A picker that ticks the row you pressed is showing an intention rather
    // than a state, and this app has shipped that bug once already.
    expect(hook).toContain('setReadings((was) => (was ? { ...was, [control]: answer.reading } : was))')
    expect(hook).not.toMatch(/\[control\]:\s*\{\s*value\b/)
  })

  it('treats a missing or malformed gate as shut', () => {
    /*
     * The gate is what draws a control back while the session is mid-turn, has
     * a dialog up, or has a draft in its composer. An open default would put
     * live-looking pickers over exactly the states it exists to keep this app's
     * fingers out of — and `value.canType === true` is the whole of the
     * difference between the two defaults.
     */
    expect(hook).toContain('canType: value.canType === true')
    expect(hook).toMatch(/if \(!isRecord\(value\)\) return \{ canType: false/)
  })

  it('types nothing at all to open a menu — only to change something', () => {
    /*
     * The biggest thing in the 2026-08-19 review, in his words:
     *
     *   > *"if I click on Opus, it will run a command just to view, just to view
     *   > it is running a command. I'm not even clicking on the next one which I
     *   > want to choose but just by drop down, as soon as drop down comes down
     *   > it runs the command automatically. At least when I click on something
     *   > then it should run."*
     *
     * The model menu called `discoverAgentModels` on the way open, which typed
     * `/model` into the live session and cancelled the picker — and cancelling
     * makes the CLI print `Kept model as …`, so his recording has **five**
     * `/model` blocks stacked in a working conversation, none of them asked for.
     *
     * Asserted three ways because there are three doors and closing two of them
     * is worse than closing none: the hook no longer holds the call, the row's
     * pickers no longer take an `onOpen` at all, and the folded panel's own
     * opener does not smuggle it back in. The list itself now comes from
     * `catalog.ts`, whose staleness fails safely — the argument, including what
     * a stale list costs, is beside `optionsForRow` in the view.
     */
    /*
     * Matched as a *call* rather than as a mention, on purpose. Both files keep
     * a paragraph explaining what the live read did and why the trade was taken
     * the other way — this codebase keeps superseded reasoning rather than
     * deleting it — and those paragraphs name the function. A bare
     * `toContain('discoverAgentModels')` would make the comment fail the test,
     * which is a rule that punishes writing down why.
     */
    expect(hook, 'the hook still reaches for the live picker').not.toMatch(/discoverAgentModels\s*[?(]/)
    expect(view, 'the model chip still asks the session on open').not.toMatch(/discoverModels\s*\(/)
    /*
     * And the door itself is gone, not merely unused: `ControlPicker` on this
     * bar is handed no `onOpen` at all. Scoped to that tag because
     * `ConnectorsPicker` two elements away has an `onOpen` of its own and is
     * right to — it opens the app's MCP servers view, which is a window, not a
     * keystroke in somebody's session.
     */
    const picker = view.slice(view.indexOf('<ControlPicker'))
    expect(picker.slice(0, picker.indexOf('/>')), 'the model picker still runs something when it opens').not.toContain(
      'onOpen',
    )
    // And what replaced it: the written-down catalogue, with the previous names
    // appended under their own heading. Both halves, because dropping the second
    // would quietly lose "Sonnet 4.6" and "Opus 4.x", which he asked for by name.
    expect(view).toContain('modelOptions()')
    expect(view).toContain('previousModelOptions()')
  })

  it('reads the gate before the click rather than only refusing after it', () => {
    // The refusals were always correct at write time. On a toolbar, a picker
    // that looks live and then apologises is the dead control this repository
    // is audited for, with an apology attached.
    expect(view).toContain('readings.gate.canType')
    expect(view).toContain('readings.gate.reason')
  })

  it('folds by measuring the bar it is in, not the window', () => {
    // A pane's bar and the window's bar are both `<header>`, so one query finds
    // the right element in both homes — and a split pane can be narrow inside a
    // wide window, which is precisely the case a window-width rule gets wrong.
    expect(view).toContain("node.closest('header')")
    expect(view).toContain('new ResizeObserver(measure)')
  })

  it('finds that bar from a callback ref, not from a ref read in an effect', () => {
    /*
     * The bug this replaced, seen in the app and in no test: the window
     * toolbar's cluster folded at every width and a split pane's cluster never
     * folded at all, because the mount effect read `ref.current` before the
     * node it wanted was there. Same component, same code, different timing.
     * A callback ref is called *with* the node, so there is no such window —
     * and depending the observer on the element also re-attaches it when the
     * cluster moves between bars, which happens every time a split opens.
     */
    expect(view).toContain('const attach = useCallback(')
    expect(view).toContain('ref={attach}')
    expect(view).not.toMatch(/const bar = host\.current\?\./)
  })
})

describe('what a session running some other agent is told', () => {
  /**
   * The sweep finding, in the only place it is actually visible.
   *
   * Asad's rule about vendor names in copy is about *who is reading*: a row that
   * is a particular agent may name it, and a screen that serves every agent may
   * not. This sentence is the sharpest available violation of it, because it is
   * drawn on exactly one kind of session and that kind is the one guaranteed
   * not to be running the vendor it named. The bar for a Codex or Gemini session
   * withdraws its four pickers and says why, and until 2026-08-19 what it said
   * was that these work by typing *Claude Code's* commands — a vendor name on a
   * screen showing a different vendor, which is his complaint verbatim.
   *
   * The fix is a rewording, not a withdrawal: the reason still has to be there,
   * or a greyed picker that explains nothing is the dead control this repository
   * is audited for. So both halves are asserted together — the category is
   * named, and the agent that is genuinely in this session still is.
   */
  it('names the category of tool, not a vendor that is not in this session', () => {
    withBridge()
    const html = render({ provider: 'codex' })
    expect(html).toContain('These work by typing one CLI’s own commands into the session.')
    expect(html).toContain('has its own, and this build has not been shown what they are')
  })

  it('still names the agent that is running, which is the readable half', () => {
    // "Codex has its own" tells somebody what to go and look up. "The other one
    // has its own" is the same sentence with the useful word removed, and the
    // rule never asked for that — a row that *is* an agent may say so.
    withBridge()
    expect(render({ provider: 'codex' })).toContain('Codex has its own')
    expect(render({ provider: 'gemini' })).toContain('Gemini has its own')
  })

  it('carries no other agent’s name anywhere on that bar', () => {
    /*
     * The assertion that would have caught this, written against the whole
     * rendered bar rather than against the one string — because the string is
     * only where it happened to be this time. `neutral-naming.test.ts` scans
     * source for the same thing, and it passed throughout: the sentence was on
     * its allowlist, exempted by a rationale that claimed nothing in that module
     * is ever drawn where a different agent could be meant. Rendering the bar
     * for that agent is how you find out whether that claim is true.
     */
    withBridge()
    for (const provider of ['codex', 'gemini'] as const) {
      expect(render({ provider }), provider).not.toMatch(/claude|anthropic/i)
    }
  })
})
