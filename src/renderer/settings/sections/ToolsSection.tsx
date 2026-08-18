import { useEffect } from 'react'
import { Explain, Group, SectionHead } from '../controls'
import { sectionMeta } from '../settings-schema'
import { useFeatures } from '../../features/FeaturesProvider'
import { feature } from '../../features/registry'
import { VoiceKeyRow } from './VoiceKeyRow'

/**
 * Tools — what used to be the Features store.
 *
 * ## Why the store is gone
 *
 * It offered ten things to install and uninstall, and nine of them were parts
 * of the app rather than choices:
 *
 *   > "still I think they doesn't make any sense to be as a feature. Use or not
 *   > use. So maybe let's keep them all installed and all active always and
 *   > remove this section for now… these ones I think remove all of them. They
 *   > are all necessary basic, they don't need to have uninstall and install
 *   > button, enable and disable thing. Instead of only voice dictation."
 *
 * He is right, and the store's own defence made the case against it: every row
 * needed a paragraph explaining that off keeps your settings and uninstalled
 * does not, for features that mostly store nothing at all. Ten rows, three
 * states each, two buttons apiece, to answer a question — "do you want the
 * browser pane?" — that nobody was asking. So everything ships installed and
 * on, and the registry that used to gate them still exists but no longer has a
 * shopfront: see `features/registry.ts`.
 *
 * ## Why one row survived, and what it has become
 *
 *   > "so features or maybe tools, let's actually call it tools and keep this
 *   > voice dictation here. And the other ones also can come here, the ones I
 *   > am talking about."
 *
 * Voice dictation is the one entry that was a genuine choice, and for a long
 * time it was a switch for a *button* rather than for a feature: the microphone
 * did not record, it focused the composer and pointed at the operating system's
 * own dictation. The note that used to be here ended by predicting its own
 * replacement — "the day a transcription backend exists, this row grows the key
 * field and the switch becomes 'is there a key'" — which is what has now
 * happened.
 *
 * So the switch is gone and {@link VoiceKeyRow} is the control. Asad asked for
 * exactly this, twice:
 *
 *   > "maybe we can ask them to put some API in the setting for voice so they
 *   > can put a API and this one will come here… if they put it there, then this
 *   > mic will come here"
 *
 *   > "it should not come there in live until it is solved."
 *
 * A key that has been checked against the provider's own transcription endpoint
 * is the only thing that puts a microphone in the chat box, and removing the key
 * takes it away again. There is no switch left to leave in a state where the
 * feature is on and cannot work.
 *
 * ## And the local model
 *
 * He also asked whether whisper large-v3 could simply be downloaded into the
 * app. The licence question turned out to be clean — MIT for Whisper's code and
 * for the GGML conversions, Apache-2.0 for the large-v3 weights, all three
 * permitting commercial redistribution with attribution — so nothing legal
 * stands in the way. What is missing is a local inference runtime to hand the
 * weights to, and a download button that fetches three gigabytes an app cannot
 * run is the dead control this project keeps being audited for. The finding is
 * recorded in `src/main/voice.ts` so it does not have to be established twice,
 * and the hosted path uses the very same model: Groq serves `whisper-large-v3`
 * itself.
 */

export function ToolsSection() {
  const meta = sectionMeta('features')
  const features = useFeatures()
  const voice = feature('voice')

  /*
   * The registry flag is kept in step with the key, rather than being a second
   * thing to set.
   *
   * `features.on('voice')` is what the rest of the app asks before it draws
   * anything dictation-shaped — the composer reads it through `useControlOffer`,
   * and the command palette and sidebar ask the same question. Leaving it as an
   * independent switch would mean two gates for one feature, which is how a
   * microphone comes to be missing with a working key behind it. So the key is
   * the switch, and this keeps the flag honest for every consumer that has no
   * idea a key exists.
   */
  useEffect(() => {
    const deck = (globalThis as { deck?: { voiceStatus?(): Promise<unknown> } }).deck
    if (typeof deck?.voiceStatus !== 'function') return
    void deck.voiceStatus().then((answer) => {
      const hasKey =
        typeof answer === 'object' && answer !== null && (answer as { hasKey?: unknown }).hasKey === true
      if (features.on('voice') !== hasKey) features.setEnabled('voice', hasKey)
    })
  })

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <Group title={voice.name}>
        <VoiceKeyRow />

        {/* Said once, here, rather than in the chat box where it would be a
            paragraph beside a 16-pixel button. It is the reason there is a key
            field at all, so it belongs next to the key field. */}
        <Explain
          title="Why a key, and not a model in the app"
          more="Speech recognition inside this window does not work: Chromium's own recogniser starts and then stays silent forever, because the service behind it ships only with Google's own builds. Running Whisper locally instead is allowed — its code is MIT, the large-v3 weights are Apache-2.0, and the GGML conversions are MIT, so a download would be legal — but this app has no local inference runtime to run them with yet, and a three-gigabyte download that cannot be used is worse than none. The hosted route uses the same model: Groq serves whisper-large-v3 itself."
        >
          Recording happens here; the words come back from the service you pick.
        </Explain>
      </Group>
    </>
  )
}
