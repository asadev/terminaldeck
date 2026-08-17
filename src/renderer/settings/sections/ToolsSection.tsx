import { useId } from 'react'
import { Explain, Group, Row, SectionHead, Switch } from '../controls'
import { sectionMeta } from '../settings-schema'
import { useFeatures } from '../../features/FeaturesProvider'
import { feature } from '../../features/registry'
import { isMac } from '../../chat/voice/dictation'

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
 * ## Why one row survived, and what it is
 *
 *   > "so features or maybe tools, let's actually call it tools and keep this
 *   > voice dictation here. And the other ones also can come here, the ones I
 *   > am talking about."
 *
 * Voice dictation is the one entry that was a genuine choice, because it is the
 * one that puts a control in the chat box for something this app cannot yet do
 * itself. The microphone does not record: `chat/voice/dictation.ts` records the
 * measurements — in this exact Electron, `SpeechRecognition` starts and then
 * emits nothing forever, there is no on-device model, the cloud path is
 * Chrome's private endpoint, and the bundle declares no microphone usage
 * string. What the button does is put the caret in the composer and say where
 * the operating system's own dictation lives.
 *
 * So the switch is honest about being a switch for a *button*, not for a
 * transcription service. What he asked for beyond that —
 *
 *   > "maybe we can ask them to put some API in the setting for voice so they
 *   > can put a API and this one will come here… if they put it there, then
 *   > this mic will come here"
 *
 * — is a field for an API key that nothing in this app would send anything to.
 * There is no transcription pipeline here to hold the key, and shipping the
 * field anyway would be a control over nothing, which this project has twice
 * refused to do. The switch is the true version of the same behaviour today:
 * off by default, so the microphone is not in the chat box until somebody asks
 * for it. The day a transcription backend exists, this row grows the key field
 * and the switch becomes "is there a key".
 */
export function ToolsSection() {
  const meta = sectionMeta('features')
  const features = useFeatures()
  const ids = useId()
  const voice = feature('voice')
  const on = features.on('voice')

  /*
   * Which dictation this machine actually has, named.
   *
   * Read from the user agent rather than assumed, the same way
   * `dictationGuidance` does it — the popover the button opens says "Edit ▸
   * Start Dictation" on a Mac and "Win + H" elsewhere, and a settings row that
   * named the wrong one would be a settings row nobody can act on.
   */
  const os =
    typeof navigator === 'undefined' || isMac(navigator.userAgent)
      ? 'macOS Dictation'
      : 'your system’s dictation'

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <Group title={voice.name}>
        <Row
          label="Microphone in the chat box"
          help={`Puts a microphone beside Send that hands over to ${os}.`}
          more="This app does not record or transcribe anything itself — the button focuses the message box and tells you where your operating system's dictation is. Off, the chat box has no microphone at all."
          control={
            <Switch
              checked={on}
              labelledBy={`${ids}-voice`}
              onChange={(next) => features.setEnabled('voice', next)}
            />
          }
          labelId={`${ids}-voice`}
        />

        {/* Said once, here, rather than in the chat box where it would be a
            paragraph beside a 16-pixel button. It is the reason the switch
            starts off, so it belongs next to the switch. */}
        <Explain
          title="No transcription yet"
          more="Speech recognition inside this window would need Chrome's own speech service, which Electron does not ship: it starts and then stays silent forever, so there is no honest recording state to show. Dictation from the operating system types into the box and works today."
        >
          The dictation is your operating system’s, not this app’s.
        </Explain>
      </Group>
    </>
  )
}
