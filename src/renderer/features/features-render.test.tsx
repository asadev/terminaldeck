import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ChatComposer } from '../components/ChatComposer'
import { FeaturesSection } from '../settings/sections/FeaturesSection'
import { ModeSwitch } from '../shell/ModeSwitch'
import { Sidebar } from '../shell/Sidebar'
import { PANELS } from '../shell/panels'
import { FeatureOffer } from './FeatureOffer'
import { FeaturesProvider } from './FeaturesProvider'
import { useControlOffer } from './offer'
import { FEATURES, feature, featureOwningPanel } from './registry'
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
      onSelectTab={noop}
      onCloseTab={noop}
      onSelectPanel={noop}
      onNewSession={noop}
      onNewBrowserTab={noop}
      onOpenProject={noop}
      onCloseProject={noop}
      onOpenSettings={noop}
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

function section(state: FeatureState): string {
  return withFeatures(
    state,
    <FeaturesSection
      values={{}}
      save={noop}
      bridge={{}}
      loading={false}
      goTo={noop}
      reload={noop}
    />,
  )
}

describe('the sidebar with everything off', () => {
  const html = sidebar(everythingOff())

  it('lists no row for a view whose feature is gone', () => {
    for (const panel of PANELS.filter((entry) => featureOwningPanel(entry.id) !== null)) {
      expect(html, panel.id).not.toContain(`>${panel.label}</span>`)
    }
  })

  it('still lists everything core, so the app is a whole app', () => {
    for (const panel of PANELS.filter((entry) => featureOwningPanel(entry.id) === null)) {
      expect(html, panel.id).toContain(`>${panel.label}</span>`)
    }
    expect(html).toContain('New session')
    expect(html).toContain('Settings')
  })

  it('drops the heading over an empty run rather than leaving it hanging', () => {
    // Every integration belongs to a feature, so with all of them off the
    // heading would sit above a gap — which reads as a list that failed to
    // load rather than one that is empty on purpose.
    expect(html).not.toContain('Integrations')
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
    for (const panel of PANELS) {
      const rows = html.match(new RegExp(`>${panel.label}</span>`, 'g')) ?? []
      expect(rows, `${panel.id} appears ${rows.length} times`).toHaveLength(1)
    }
  })

  it('offers the browser button', () => {
    expect(html).toContain('aria-label="New browser tab"')
  })
})

describe('the store', () => {
  it('puts every feature in one of the two lists, and never in both', () => {
    const html = section(defaultFeatureState())
    for (const entry of FEATURES) {
      const shown = html.match(new RegExp(`>${entry.name}</span>`, 'g')) ?? []
      expect(shown, `${entry.id} appears ${shown.length} times`).toHaveLength(1)
    }
  })

  it('says what each one is, for somebody who does not already know', () => {
    const html = section(defaultFeatureState())
    for (const entry of FEATURES) expect(html, entry.id).toContain(entry.summary)
  })

  it('offers an install for everything with nothing installed', () => {
    const html = section(everythingOff())
    expect(html).toContain('Nothing is installed')
    const installs = html.match(/>Install</g) ?? []
    expect(installs).toHaveLength(FEATURES.length)
  })

  it('says so rather than showing an empty list when everything is installed', () => {
    const html = section(everythingOn())
    expect(html).toContain('Everything is installed')
    expect(html).not.toContain('>Install<')
  })

  it('tells the reader that off and uninstalled are not the same thing', () => {
    // The one fact somebody has to have before they press either control, and
    // the one they cannot learn any other way than by losing something.
    expect(section(defaultFeatureState())).toContain('off keeps its settings')
    // And the row itself says it again, in the state where it matters: a
    // feature that is switched off looks identical to one that was never
    // installed unless the row says which of the two it is.
    const off = section(withStatus(defaultFeatureState(), 'github', 'off'))
    expect(off).toContain('your settings are kept')
  })

  it('offers the way back only once something has been changed', () => {
    expect(section(defaultFeatureState())).not.toContain('Back to the starter set')
    expect(section(withStatus(defaultFeatureState(), 'hooks', 'on'))).toContain(
      'Back to the starter set',
    )
  })
})

describe('an uninstall that is a decision rather than a shrug', () => {
  /*
   * "Are you sure?" asks for a decision while withholding the fact the decision
   * turns on. What is asserted here is the opposite: the settings named, the
   * data named, and — for the features that store nothing — the fact that
   * nothing goes, which is exactly what somebody hovering wants to know.
   *
   * The confirmation is opened by a click this environment cannot make, so the
   * words themselves are checked at their source and the row is checked for the
   * control that opens them.
   */
  it('puts an uninstall on every installed row', () => {
    const html = section(everythingOn())
    const buttons = html.match(/>Uninstall</g) ?? []
    expect(buttons).toHaveLength(FEATURES.length)
  })

  it('gives the on/off switch the feature’s own name to be labelled by', () => {
    // Two controls sit on every row and only one of them carries text. A switch
    // announced as "switch" is the row somebody turns off by mistake.
    const html = section(everythingOn())
    const labels = [...html.matchAll(/aria-labelledby="([^"]+)"/g)].map((match) => match[1])
    expect(labels).toHaveLength(FEATURES.length)
    for (const id of labels) expect(html).toContain(`<span class="feat-name" id="${id}">`)
  })
})

describe('the offer that stands where a feature would have been', () => {
  it('names the thing, says what it is, and says where it will be', () => {
    const html = withFeatures(everythingOff(), <FeatureOffer id="github" />)
    expect(html).toContain('GitHub is available')
    expect(html).toContain(feature('github').summary)
    expect(html).toContain(feature('github').where)
    expect(html).toContain('>Install<')
  })

  it('spends the accent on nothing in the list', () => {
    /*
     * Every available row used to draw a filled accent Install. In the light
     * theme that put six blue buttons on screen at once, plus the dialog's own
     * blue Done — and "a screen where four things are blue has no accent at
     * all". The accent marks *the* action of a screen; this screen has ten
     * equal ones.
     */
    const html = section(everythingOff())
    expect(html).toContain('Install')
    expect(html).not.toContain('data-tone="primary"')
  })

  it('says nothing under a row whose switch already says it', () => {
    // Every installed row printed a literal "On" under its description, six
    // hundred pixels from the switch that was already saying so.
    const html = section(everythingOn())
    expect(html).not.toContain('>On</span>')
    // Off and uninstalled keep their line: neither is obvious from a switch.
    expect(section(withStatus(everythingOn(), 'alerts', 'off'))).toContain(
      'Off — your settings are kept',
    )
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
  it('keeps the segment and marks it as an offer', () => {
    const html = renderToStaticMarkup(<ModeSwitch mode="terminal" onChange={noop} splitOffer />)
    expect(html).toContain('ms-offer')
    expect(html).toContain('>Split<')
    // It says what pressing it does. A segment that installs has to admit that
    // before it is pressed, or a segmented control has grown a second meaning.
    expect(html).toContain('not installed')
  })

  it('is an ordinary segment once the feature is there', () => {
    const html = renderToStaticMarkup(<ModeSwitch mode="terminal" onChange={noop} />)
    expect(html).not.toContain('ms-offer')
    expect(html).not.toContain('not installed')
  })
})

describe('the chat box', () => {
  const props = { onSend: noop, cwd: '/tmp/project' }

  it('offers the microphone back where it would have been', () => {
    const html = withFeatures(everythingOff(), <ChatComposer {...props} />)
    // Not the real button…
    expect(html).not.toContain('aria-label="Dictate using macOS Dictation"')
    // …and not nothing, either, which is what it used to be.
    expect(html).toContain('Voice dictation — not installed. Press to install it.')
    expect(html).toContain('data-offer="true"')
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

  it('drops connectors from the button’s own name while MCP is not installed', () => {
    const html = withFeatures(everythingOff(), <ChatComposer {...props} />)
    expect(html).toContain('Add files, folders or images to this message')
    expect(html).not.toContain('connectors')
  })

  it('has both when both features are installed', () => {
    const html = withFeatures(everythingOn(), <ChatComposer {...props} />)
    expect(html).toContain('Add files, folders, images or connectors to this message')
    expect(html).toContain('cc-send')
  })
})
