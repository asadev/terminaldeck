import { useFeatures } from './FeaturesProvider'
import { feature, featureOwningControl, type ControlId } from './registry'

/**
 * What stands in the place of a control whose feature is not there.
 *
 * `FeatureOffer` answers this for a whole page. This is the same answer for a
 * *control* — the globe beside New session, the microphone in the chat box,
 * Connectors in the Add menu — where there is no room for a title, a paragraph
 * and a button, and where the honest substitute is the control itself, marked
 * as an offer and wired to the install.
 *
 * It exists because half the store's features were disappearing without a
 * trace. Split view offered itself back from the mode switch and every
 * panel-owning feature offered itself back from its own page, but uninstalling
 * the browser pane simply deleted the globe and uninstalling voice dictation
 * simply deleted the microphone. FEATURE-STORE.md's central rule is the
 * opposite: *"where a feature would have been, offer it… the dead end is the
 * bug, not the absence."*
 *
 * The words are built from the registry rather than typed at each site, so
 * three offers in three different corners of the window say the same thing
 * about the same feature — and a feature that is renamed is renamed in all of
 * them.
 */
export interface ControlOffer {
  /** The feature's name, for a host that has room to write its own sentence. */
  name: string
  /** The hover label: what is missing, and what pressing this does. */
  title: string
  /** Put it back. Installing something merely switched off simply turns it on. */
  accept(): void
}

/**
 * The offer to draw where `control` would have been, or null when the feature
 * is installed and on and the real control belongs there instead.
 *
 * Off and uninstalled get different words on purpose. "You do not have this
 * yet" and "you have it and you put it away" are not the same sentence, and a
 * button offering to *install* something that is sitting installed and switched
 * off is the app misreading its own state out loud.
 */
export function useControlOffer(control: ControlId): ControlOffer | null {
  const features = useFeatures()
  const id = featureOwningControl(control)
  const status = features.status(id)
  if (status === 'on') return null
  const entry = feature(id)
  return {
    name: entry.name,
    // The same sentence the mode switch's Split offer has said since it was
    // written, so two offers in one window do not describe the same situation
    // two ways.
    title:
      status === 'off'
        ? `${entry.name} is switched off. Press to turn it back on.`
        : `${entry.name} — not installed. Press to install it.`,
    // One call for both: `install` writes 'on', which is precisely what
    // turning a switched-off feature back on does.
    accept: () => features.install(id),
  }
}
