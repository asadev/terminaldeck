import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ChatComposer } from '../components/ChatComposer'
import { ModeSwitch } from '../shell/ModeSwitch'
import { Sidebar } from '../shell/Sidebar'
import { PANELS } from '../shell/panels'
import { FeatureOffer } from './FeatureOffer'
import { FeaturesProvider } from './FeaturesProvider'
import { useControlOffer } from './offer'
import { feature, featureOwningControl, featureOwningPanel } from './registry'
import {
  defaultFeatureState,
  everythingOff,
  everythingOn,
  isOn,
  withStatus,
  type FeatureState,
} from './state'

/**
 * The store and the gating, actually rendered.
 *
 * `react-dom/server`, like every other render test here: this project has no
 * DOM in its test setup, deliberately. What a static string can still answer is
 * every question that matters about a feature store — is the row there, is the
 * button there, does the uninstall name what it deletes — because all of those
 * are about what is on the page rather than about what happens on a click.
 *
 * **The two extremes are the point.** Every feature on and every feature off
 * both have to produce a window somebody could use, and rule 1 of the spec —
 * features are independent — is what makes those two enough to cover a table
 * that has 3^10 arrangements.
 */

const noop = (): void => {}

function withFeatures(state: FeatureState, node: React.ReactNode): string {
  // `storage={null}` on purpose: nothing here should touch a real store, and
  // Node's `localStorage` is not one this test wants to find out about.
  return renderToStaticMarkup(
    <FeaturesProvider storage={null} initial={state}>
      {node}
    </FeaturesProvider>,
  )
}

/**
 * The sidebar the way `App.tsx` builds it, for a given set of features.
 *
 * The globe's offer comes from `useControlOffer`, which is a hook, so this
 * mirrors the window by putting the call inside a component under the provider
 * rather than reconstructing the wording here — a copy of that sentence in the
 * test is a copy that can agree with itself while the app says something else.
 */
function Rail({ state }: { state: FeatureState }) {
  const panels = PANELS.filter((panel) => {
    const owner = featureOwningPanel(panel.id)
    return owner === null || isOn(state, owner)
  })
  // The bell is a control rather than a panel, so it is gated by its own
  // question — the same one `App.tsx` asks. Mirrored here rather than hardcoded
  // for the reason the comment above gives about the globe's wording: a copy
  // can agree with itself while the app does something else.
  const alertsOwner = featureOwningControl('sidebar.alerts')
  const offer = useControlOffer('sidebar.browser')
  return (
    <Sidebar
      browserOffer={offer?.title ?? null}
      width={264}
      projects={[]}
      tabs={[]}
      activeTabId={null}
      activePanel={null}
      panels={panels}
      browser={isOn(state, 'browser')}
      alerts={alertsOwner === null || isOn(state, alertsOwner)}
      onSelectTab={noop}
      onCloseTab={noop}
      onSelectPanel={noop}
      onNewSession={noop}
      onNewBrowserTab={noop}
      onOpenProject={noop}
      onCloseProject={noop}
      onOpenSettings={noop}
      onOpenAlerts={noop}
      onToggleCollapsed={noop}
      onPeekStart={noop}
      onPeekEnd={noop}
      onStartResize={noop}
    />
  )
}

function sidebar(state: FeatureState): string {
  return withFeatures(state, <Rail state={state} />)
}

describe('the sidebar with everything off', () => {
  const html = sidebar(everythingOff())

  it('lists no row for a view whose feature is gone', () => {
    for (const panel of PANELS.filter((entry) => featureOwningPanel(entry.id) !== null)) {
      expect(html, panel.id).not.toContain(`>${panel.label}</span>`)
    }
  })

  it('takes the bell with the Alerts feature', () => {
    /*
     * Alerts is not in `PANELS` any more — it is a pop-up, not a view — so the
     * loop above cannot see it, and losing this claim is exactly how a feature
     * ends up half switched off: no page, no palette row, and a bell still
     * sitting on the rail opening a sheet for something the app does not have.
     */
    expect(html).not.toContain('Alerts')
  })

  it('still lists everything core, so the app is a whole app', () => {
    for (const panel of PANELS.filter((entry) => featureOwningPanel(entry.id) === null)) {
      expect(html, panel.id).toContain(`>${panel.label}</span>`)
    }
    expect(html).toContain('New session')
    expect(html).toContain('Settings')
  })

  it('keeps the Integrations heading, because the row left under it is core', () => {
    /*
     * This asserted the opposite until 2026-08-19, and both versions are about
     * the same rule in `Sidebar.tsx`: a run with nothing in it loses its
     * heading, because a word above a gap reads as a list that failed to load
     * rather than one that is empty on purpose.
     *
     * What changed is which rows are in the run. GitHub, MCP servers, Session
     * updates and AI readiness are the four panels a feature owns, and all four
     * are here — so switching everything off used to empty it. Machines moved
     * into this run on Asad's word and is not a feature anybody can uninstall:
     * remote access is what the product is differentiated on, and
     * `registry.test.ts` pins that it is in no feature's inventory. So the
     * heading now always has at least this one row under it, and the rule above
     * is exercised by `Sidebar.tsx`'s own guard rather than by this state.
     */
    expect(html).toContain('Integrations')
    expect(html).toContain('>Machines</span>')
  })

  it('keeps the browser button, as an offer rather than as a control', () => {
    /*
     * The globe used to be deleted outright, and that is the failure a feature
     * store actually causes: the button vanishes, and somebody who used it once
     * concludes the app has lost the browser. It stays, marked with the shared
     * offer dot and saying what pressing it does.
     */
    expect(html).not.toContain('aria-label="New browser tab"')
    expect(html).toContain('Browser pane — not installed. Press to install it.')
    expect(html).toContain('data-offer="true"')
  })
})

describe('the sidebar with everything on', () => {
  const html = sidebar(everythingOn())

  it('draws every row exactly once, wherever it belongs', () => {
    /*
     * This matched on the accessible name as well as on the label text while
     * Alerts was a panel in an `icon` group — a glyph on the Settings line
     * whose name lived in `aria-label` rather than in text. Alerts is a pop-up
     * now and not a panel at all, so the loop is back to what it was always
     * about: the rows the rail lists. The bell it used to cover is asserted
     * separately below, because dropping it from `PANELS` without putting a
     * claim somewhere else is how this sweep would have gone quietly vacuous.
     */
    for (const panel of PANELS) {
      const rows = html.match(new RegExp(`>${panel.label}</span>`, 'g')) ?? []
      expect(rows, `${panel.id} appears ${rows.length} times`).toHaveLength(1)
    }
  })

  it('draws the bell exactly once, beside Settings', () => {
    const named = html.match(/aria-label="Alerts(?: \(\d+\))?"/g) ?? []
    expect(named, `the bell appears ${named.length} times`).toHaveLength(1)
  })

  it('offers the browser button', () => {
    expect(html).toContain('aria-label="New browser tab"')
  })
})

/**
 * The store is gone.
 *
 * There were two `describe` blocks here — one for the ten-row shopfront and one
 * for the uninstall confirmation that named what it was about to delete — and
 * both went with `FeaturesSection` when the store was removed on 2026-08-17:
 *
 *   > "they are all necessary basic, they don't need to have uninstall and
 *   > install button, enable and disable thing. Instead of only voice
 *   > dictation."
 *
 * What replaced them is `settings/nothing-dropped.test.tsx`, which asserts that
 * every feature now ships on, so nothing can be stranded by the absence of a
 * shop to turn it on in — the exact failure removing the store could have
 * caused, and the only one worth a test now that there is nothing to render.
 */

describe('the offer that stands where a feature would have been', () => {
  it('names the thing, says what it is, and says where it will be', () => {
    const html = withFeatures(everythingOff(), <FeatureOffer id="github" />)
    expect(html).toContain('GitHub is available')
    expect(html).toContain(feature('github').summary)
    expect(html).toContain(feature('github').where)
    expect(html).toContain('>Install<')
  })

  it('does not offer to install something that is merely switched off', () => {
    // Installed and off is a different sentence from not installed, and a
    // button reading "Install" over a feature that is already installed is the
    // app misreading its own state out loud.
    const html = withFeatures(
      withStatus(defaultFeatureState(), 'github', 'off'),
      <FeatureOffer id="github" />,
    )
    expect(html).toContain('GitHub is switched off')
    expect(html).toContain('Turn it back on')
  })

  it('fills the one action the page exists for', () => {
    /*
     * The mirror image of the rule above. In the store, Install is one of ten
     * rows and takes no accent; here it is the only thing on an otherwise empty
     * screen and nothing can happen until it is pressed — which is exactly the
     * case `PageEmpty` reserves the fill for. It used to be a plain grey pill
     * while the store's copy of the same action was filled blue.
     */
    const html = withFeatures(everythingOff(), <FeatureOffer id="github" />)
    expect(html).toContain('btn-primary')
  })
})

describe('split view, where it would have been', () => {
  it('keeps the button and marks it as an offer', () => {
    const html = renderToStaticMarkup(<ModeSwitch mode="terminal" onChange={noop} splitOffer />)
    expect(html).toContain('ms-offer')
    // The word `Split` is in the accessible name now rather than on the face:
    // the control is two icons since 2026-08-19, so the name is the only place
    // left that can carry it.
    expect(html).toContain('aria-label="Split — two sessions side by side, not installed.')
    // It says what pressing it does. A button that installs has to admit that
    // before it is pressed, or the control has grown a second meaning.
    expect(html).toContain('not installed')
  })

  it('is an ordinary button once the feature is there', () => {
    const html = renderToStaticMarkup(<ModeSwitch mode="terminal" onChange={noop} />)
    expect(html).not.toContain('ms-offer')
    expect(html).not.toContain('not installed')
  })
})

describe('the chat box', () => {
  const props = { onSend: noop, cwd: '/tmp/project' }

  it('has no microphone at all while voice dictation is off', () => {
    /*
     * This asserted the opposite until the store was removed: a ghost
     * microphone offering to install the feature, because the store's rule was
     * "where a feature would have been, offer it".
     *
     * Both halves of that stopped being true at once. There is no store to
     * install from, and the reason voice dictation ships off is that this app
     * cannot transcribe — so a microphone-shaped button in the corner of the
     * box is precisely the promise that must not be made:
     *
     *   > "we also might don't need this mic button until we don't have a
     *   > proper feature for transcription… otherwise it will not come here."
     */
    const html = withFeatures(everythingOff(), <ChatComposer {...props} />)
    expect(html).not.toContain('aria-label="Dictate using macOS Dictation"')
    expect(html).not.toContain('Press to install it')
    expect(html).not.toContain('data-offer="true"')
    // The rest of the row is untouched: this is one control disappearing, not
    // the composer losing its footer.
    expect(html).toContain('cc-send')
  })

  it('keeps the menu on a shell and changes what it offers, whatever is installed', () => {
    /*
     * This test used to assert the opposite — that a shell got no plus at all —
     * and the reasoning behind it was half right. Every entry behind the plus
     * added an `@"path"` mention, which an agent expands and a shell types at
     * its prompt, so the menu really was promising "the agent gets its listing"
     * on a pane that was simultaneously saying "this session is a shell".
     *
     * The conclusion was the wrong half. Deleting the menu left that composer
     * with a microphone and a send button, which is how the redesign came back
     * as "all the options you have actually removed". Picking a file out of the
     * project is not an agent feature; only the mention form was. So the menu
     * stays and switches to inserting a shell-quoted path, and loses only the
     * two rows that need an agent to mean anything.
     */
    const html = withFeatures(everythingOn(), <ChatComposer {...props} shell />)
    expect(html).toContain('at-host')
    expect(html).toContain('Insert a file or folder path into the command line')
    // Nothing on screen claims an agent is listening, which is the half of the
    // old reasoning that was right.
    expect(html.toLowerCase()).not.toContain('the agent gets its listing')
    expect(html).toContain('cc-send')
  })

  it('names files, folders and images, whatever else is installed', () => {
    /*
     * The button's name used to grow and shrink with the MCP feature, because
     * Connectors was a fourth row behind it. It is not any more — the window's
     * own bar carries a Connectors chip, and a copy of it inside the chat box
     * was one of the duplicates he asked to have removed. So the name is now a
     * fact about the three panels this menu opens and nothing else, which is
     * also the only version of it that is true on a session shown as a terminal.
     */
    for (const features of [everythingOff(), everythingOn()]) {
      const html = withFeatures(features, <ChatComposer {...props} />)
      expect(html).toContain('Add files, folders or images to this message')
      expect(html.toLowerCase()).not.toContain('connectors')
      expect(html).toContain('cc-send')
    }
  })
})
