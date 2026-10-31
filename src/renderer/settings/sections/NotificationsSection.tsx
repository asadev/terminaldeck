import { useCallback, useState } from 'react'
import { Button, Notice, SectionHead, SettingList } from '../controls'
import { booleanSetting, sectionMeta, stringSetting } from '../settings-schema'
import { isSoundId, playSound } from '../notification-sound'
import { turnedOnABanner, useNotificationCheck } from '../notification-check'
import { osName } from '../../platform'
import type { SectionProps } from '../settings-bridge'

/**
 * Notifications — everything the app says without being asked.
 *
 * ## Why all six are here now
 *
 * They were split down the middle: General owned *whether* to interrupt you —
 * the finish sound and the needs-you banner — and this section owned *how*. So
 * the two switches everybody comes looking for were on a different pane from
 * the sound they play and the rule about when a banner is allowed, and both of
 * the General rows had to name this section in their own help text to be
 * comprehensible. His words, and they are the whole reorganisation:
 *
 *   > "desktop notification when session need attention — all of this stuff,
 *   > this is notification part so should be in the notification section.
 *   > Notification section is here but it is there. See again."
 *
 * Insight alerts came with them. It is not a desktop banner — it fills the
 * Alerts panel — but "the app telling you something you did not ask for" is
 * what a person means by notifications, and a switch for it filed under General
 * is a switch nobody finds.
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
 * answered, dropped every banner in silence.
 *
 * So: no permission state is drawn, because none can be read. The Test button
 * is never disabled on a permission this process cannot see. What it prints
 * afterwards comes from `useNotificationCheck`, which asks the OS and has three
 * answers, only one of which sounds like success. And beside it sits a way out
 * — a button to the OS's own notification settings, drawn only on platforms
 * that have such a page.
 */
/**
 * What the Sound row says while nothing is going to play it.
 *
 * The schema's line is "Which sound a finished session plays", and with the
 * switch above it off that is simply false: no finished session plays anything.
 * The row was sitting there asserting it, fully lit, under an off switch — two
 * things on screen disagreeing, which is this project's stated bug class.
 *
 * The picker is *not* the dead half, which is why it is not disabled. It is read
 * by Test on every press, and Test is deliberately always live: hearing a sound
 * before deciding to turn it on is a reasonable thing to want, and disabling it
 * with a paragraph explaining the disabling is the exact shape the brief rules
 * out. `finish.test.ts` pins that decision by reading this file's source. So
 * what changes is the sentence, which is the part that was wrong.
 *
 * Exported so the wording can be asserted without a DOM, the way this window
 * tests every other line that has to be true.
 */
export function soundHelp(playsOnFinish: boolean): string | undefined {
  if (playsOnFinish) return undefined
  return 'Nothing plays this while the switch above is off. Test still previews it.'
}

export function NotificationsSection({ values, save, loading, bridge }: SectionProps) {
  const meta = sectionMeta('notifications')
  const check = useNotificationCheck({ bridge })

  const soundName = stringSetting(values, 'notifications.soundName')
  const soundRowHelp = soundHelp(booleanSetting(values, 'notifications.onFinishSound'))

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
   * switches have now moved between sections twice, and a hard-coded id here
   * would keep compiling and quietly stop asking the moment they move again.
   * That is not hypothetical: both banner switches were in General until this
   * pass, which is why the ask had to be wired in two places at once.
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
        // The one row whose schema sentence stops being true depending on
        // another row. Absent rather than empty when the schema line is right,
        // so the override can never blank a help line by accident.
        helpFor={soundRowHelp ? { 'notifications.soundName': soundRowHelp } : undefined}
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
           * reasonable thing to want *before* deciding to turn it on.
           *
           * The sentence that used to sit beside it — "nothing plays it on its
           * own yet, the finish-work sound is off" with a link to General — is
           * gone with the section boundary it was explaining. The switch it
           * pointed at is now three rows above this one, on screen, which is a
           * better answer than a paragraph about where the switch lives.
           *
           * What that cut took with it, and what `soundHelp` puts back, is a
           * different thing: not *where* the switch is, but the fact that the
           * row's own help line stops being true when it is off. Pointing at
           * another pane was the part worth losing.
           */
          'notifications.soundName': <Button onClick={testSound}>Test</Button>,
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
