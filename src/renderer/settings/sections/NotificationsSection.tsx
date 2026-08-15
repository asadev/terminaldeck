import { useCallback, useState } from 'react'
import { Button, Notice, SectionHead, SettingList } from '../controls'
import { booleanSetting, sectionMeta, stringSetting } from '../settings-schema'
import { isSoundId, playSound } from '../notification-sound'
import { turnedOnABanner, useNotificationCheck } from '../notification-check'
import { osName } from '../../platform'
import type { SectionProps } from '../settings-bridge'

/**
 * Notifications.
 *
 * The two switches people look for — sound when a session finishes, a banner
 * when one needs attention — are in General now. What is left here is how a
 * banner is delivered rather than whether to ask for one, which is why this
 * section reads two of General's values without owning them.
 *
 * ## What this section used to get wrong, and must never get wrong again
 *
 * It drew a permission state, gated the Test button on it, and printed
 * **"Sent."** afterwards. All three were fiction. `Notification.permission` in
 * an Electron renderer is **always `granted`**: Chromium answers from its own
 * permission model and never consults the OS. So the pane reported a healthy
 * permission it had not checked, enabled a button on the strength of it, and
 * then reported a delivery it had not confirmed — while macOS, whose
 * authorisation had never been granted because its prompt had never been
 * answered, dropped every banner in silence. The note even blamed a Focus mode,
 * the one cause that had been checked and ruled out.
 *
 * So: no permission state is drawn, because none can be read. The Test button
 * is never disabled on a permission this process cannot see. What it prints
 * afterwards comes from `useNotificationCheck`, which asks the OS and has three
 * answers, only one of which sounds like success. And beside it sits a way out
 * — a button to the OS's own notification settings, drawn only on platforms
 * that have such a page.
 */
export function NotificationsSection({ values, save, loading, goTo, bridge }: SectionProps) {
  const meta = sectionMeta('notifications')
  const check = useNotificationCheck({ bridge })

  // Both of these are General's settings. Read, never written from here — one
  // switch in two places is the drift this window was built to avoid.
  const soundOn = booleanSetting(values, 'general.soundOnFinish')
  const soundName = stringSetting(values, 'notifications.soundName')

  /**
   * Save, and if a banner was just switched on, post one immediately.
   *
   * This is the moment the OS's authorisation prompt has to happen. On macOS it
   * arrives *as a banner*, exactly once, with Allow hidden behind an `Options`
   * control — so if it fires while the user is looking at something else it is
   * gone for good and the feature silently never works again. Firing it here
   * puts it on screen while they are still on this pane, and the note that
   * follows tells them where Allow is.
   *
   * Which ids count is `turnedOnABanner`'s to know, not this file's. These
   * switches have already moved between sections once, and a hard-coded id here
   * would keep compiling and quietly stop asking the moment they move again.
   */
  const saveAndProve = useCallback(
    (patch: Record<string, unknown>) => {
      save(patch)
      if (turnedOnABanner(patch)) check.confirmEnabled()
    },
    [save, check],
  )

  // The sound keeps its own note rather than sharing the banner's: a sound
  // that played is not evidence about a banner, and one message overwriting
  // the other is how a pane starts answering questions it was not asked.
  const [soundNote, setSoundNote] = useState<string | null>(null)
  const testSound = useCallback(() => {
    const id = isSoundId(soundName) ? soundName : 'chime'
    setSoundNote(playSound(id) ? null : 'No audio output is available to play that on.')
  }, [soundName])

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <SettingList
        section="notifications"
        values={values}
        save={saveAndProve}
        disabled={loading}
        extras={{
          'notifications.onComplete': (
            <>
              <Button onClick={check.test} disabled={check.busy}>
                {check.busy ? `Asking ${osName()}…` : 'Show a test notification'}
              </Button>
              {check.canOpenSettings && (
                <Button onClick={check.openSettings}>Open notification settings</Button>
              )}
            </>
          ),
          /*
           * Test is a *preview*, so it is never disabled.
           *
           * It used to switch itself off whenever the finish-work sound was
           * off, and print a sentence beside itself saying so with a link to
           * the other pane. That is a control that looks pressable, is not, and
           * needs a paragraph to explain the difference — which is the exact
           * shape the brief rules out. Hearing what a sound is like is a
           * reasonable thing to want *before* deciding to turn it on, and it is
           * the only way to choose between six of them from a list of names.
           * The line underneath now says what is true of the setting rather
           * than what is wrong with the button.
           */
          'notifications.soundName': (
            <>
              <Button onClick={testSound}>Test</Button>
              {!soundOn && (
                <span className="settings-help">
                  Nothing plays it on its own yet —{' '}
                  <button
                    type="button"
                    className="settings-inline-btn"
                    onClick={() => goTo('general')}
                  >
                    the finish-work sound is off
                  </button>
                  .
                </span>
              )}
            </>
          ),
        }}
      />

      {soundNote && <Notice tone="warn">{soundNote}</Notice>}

      {check.state && (
        <Notice tone={check.state.tone}>
          {check.state.text}
          {check.state.offerSettings && check.canOpenSettings && (
            <>
              {' '}
              <button type="button" className="settings-inline-btn" onClick={check.openSettings}>
                Open notification settings
              </button>
            </>
          )}
        </Notice>
      )}
    </>
  )
}
