import { PageEmpty } from '../components/PageEmpty'
import { useFeatures } from './FeaturesProvider'
import { feature, type FeatureId } from './registry'

/**
 * What stands where a feature would have been.
 *
 * This is the fix for the one failure a feature store definitely causes: things
 * become undiscoverable. Somebody looks for a capability, does not find it, and
 * concludes the app cannot do it — which is strictly worse than the busy UI the
 * store was built to calm down. **The dead end is the bug, not the absence.**
 *
 * So a page that exists only because a feature does not is still a page with an
 * answer on it: what the thing is, and the button that brings it back. It is
 * not a dead control — pressing it installs, and the panel behind it is
 * rendering a moment later, which is the shortest possible version of "here is
 * where to find it".
 *
 * It wears `PageEmpty`, the app's one blank, rather than a fifth arrangement of
 * a title, a sentence and a button.
 */
export function FeatureOffer({
  id,
  icon,
  onInstalled,
}: {
  id: FeatureId
  /** The view's own glyph, so the page still looks like the page it replaces. */
  icon?: string
  /** Fired after the install, for a host that has something to do next. */
  onInstalled?(): void
}) {
  const features = useFeatures()
  const entry = feature(id)
  /*
   * Two things can be true here and they are not the same sentence.
   *
   * Uninstalled is "you do not have this yet"; off is "you have it and you put
   * it away". Offering to *install* something that is sitting installed and
   * switched off would be the app misreading its own state out loud, and the
   * button under it would appear to do nothing to the thing it named.
   */
  const off = features.status(id) === 'off'

  return (
    <PageEmpty
      icon={icon}
      title={off ? `${entry.name} is switched off` : `${entry.name} is available`}
      action={{
        label: off ? 'Turn it back on' : 'Install',
        /*
         * Filled, because on this page it genuinely is the one thing to do.
         *
         * It was a plain grey pill on an otherwise empty screen, while the
         * identical action in the store — one of ten rows — was filled blue,
         * and the MCP page's "Add a server" beside it was filled too. Same
         * action, three weights, and the quietest one was the page whose entire
         * reason for existing is to offer it. `PageEmpty`'s own rule is the
         * right one and this page qualifies: nothing here can happen until this
         * button is pressed.
         */
        primary: true,
        onClick: () => {
          if (off) features.setEnabled(id, true)
          else features.install(id)
          onInstalled?.()
        },
      }}
      // Where it will be, said before the click rather than only after it —
      // this page is often somebody's first meeting with the feature, and "it
      // appears in the sidebar" is the half of the answer a store confirmation
      // gives too late to be read.
      hint={`It appears in ${entry.where}`}
    >
      {entry.summary}
    </PageEmpty>
  )
}
