import { useCallback, useState } from 'react'
import { Button, Notice, SectionHead, SettingList } from '../controls'
import { booleanSetting, sectionMeta, stringSetting } from '../settings-schema'
import { isSoundId, playSound } from '../notification-sound'
import { canNotify, requestNotificationPermission } from '../../notifications'
import { errorText, type SectionProps } from '../settings-bridge'

/**
 * Notifications.
 *
 * The two switches people look for — sound when a session finishes, a banner
 * when one needs attention — are in General now. What is left here is how a
 * banner is delivered rather than whether to ask for one, which is why this
 * section reads two of General's values without owning them.
 *
 * A notification preference is worthless on its own: the OS holds the real
 * switch, and a user who has denied the app can turn every setting here on and
 * never see a banner. So permission state is shown beside the toggles, and the
 * Test buttons are the only honest way to prove the whole chain works —
 * preference, permission, and an audio device.
 *
 * Chromium only shows the permission prompt while the state is `default`;
 * asking again after a denial is a silent no-op, which is why the denied case
 * points at System Settings instead of offering a button that would do nothing.
 */

type Permission = 'granted' | 'denied' | 'default' | 'unavailable'

function readPermission(): Permission {
  if (typeof Notification === 'undefined') return 'unavailable'
  const state = Notification.permission
  return state === 'granted' || state === 'denied' ? state : 'default'
}

export function NotificationsSection({ values, save, loading, goTo }: SectionProps) {
  const meta = sectionMeta('notifications')
  const [permission, setPermission] = useState<Permission>(readPermission)
  const [note, setNote] = useState<string | null>(null)

  // Both of these are General's settings. Read, never written from here — one
  // switch in two places is the drift this window was built to avoid.
  const soundOn = booleanSetting(values, 'general.soundOnFinish')
  const soundName = stringSetting(values, 'notifications.soundName')
  const wantsBanners =
    booleanSetting(values, 'notifications.onComplete') ||
    booleanSetting(values, 'general.notifyOnAttention')

  const ask = useCallback(() => {
    void requestNotificationPermission().then((granted) => {
      setPermission(granted ? 'granted' : readPermission())
      if (!granted) setNote('Your system refused. Nothing was changed.')
    })
  }, [])

  const testBanner = useCallback(() => {
    if (!canNotify()) {
      setNote('The system has not allowed notifications yet, so there is nothing to show.')
      return
    }
    // Deliberately the same shape as a real one — project heading, then what
    // happened — so the test proves the wording as well as the plumbing.
    // Constructing one can throw even with permission granted: on Linux that
    // means no notification daemon is running, and a Test button that takes
    // the whole window down with it is worse than one that reports the failure.
    try {
      const banner = new Notification('Test', {
        body: 'This is what a finished session looks like.',
        silent: true,
      })
      setNote('Sent. If nothing appeared, the banner was suppressed by a Focus mode.')
      window.setTimeout(() => banner.close(), 6000)
    } catch (cause) {
      setNote(errorText(cause, 'Your system refused to show the banner.'))
    }
  }, [])

  const testSound = useCallback(() => {
    const id = isSoundId(soundName) ? soundName : 'chime'
    setNote(playSound(id) ? null : 'No audio output is available to play that on.')
  }, [soundName])

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      {permission === 'default' && wantsBanners && (
        <Notice tone="warn">
          Your system has not been asked yet, so no banner will appear.{' '}
          <button type="button" className="settings-inline-btn" onClick={ask}>
            Ask now
          </button>
        </Notice>
      )}
      {permission === 'denied' && wantsBanners && (
        <Notice tone="warn">
          Your system is blocking notifications from this app. Turn them back on in System Settings —
          asking again from here does nothing once it has been refused.
        </Notice>
      )}
      {permission === 'unavailable' && (
        <Notice tone="warn">This build has no notification support, so these settings do nothing.</Notice>
      )}

      <SettingList
        section="notifications"
        values={values}
        save={save}
        disabled={loading}
        extras={{
          'notifications.onComplete': (
            <Button onClick={testBanner} disabled={permission !== 'granted'}>
              Show a test notification
            </Button>
          ),
          'notifications.soundName': (
            <>
              <Button onClick={testSound} disabled={!soundOn}>
                Test
              </Button>
              {!soundOn && (
                <span className="settings-help">
                  Sounds are off, so this plays nothing.{' '}
                  <button
                    type="button"
                    className="settings-inline-btn"
                    onClick={() => goTo('general')}
                  >
                    Turn them on in General
                  </button>
                </span>
              )}
            </>
          ),
        }}
      />

      {note && <Notice tone="info">{note}</Notice>}
    </>
  )
}
