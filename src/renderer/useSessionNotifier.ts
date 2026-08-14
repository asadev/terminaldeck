import { useEffect, useMemo, useRef } from 'react'
import type { SessionStatus } from '@shared/types'
import {
  SessionNotifier,
  browserNotificationHost,
  type NotifierHost,
  type SessionDescriptor,
  type ViewingState,
} from './notifications'
import { isSoundId, playSound } from './settings/notification-sound'
import { booleanSetting, stringSetting, type SettingValues } from './settings/settings-schema'

/**
 * The thing that actually rings.
 *
 * `notifications.ts` has held a complete, heavily tested notification policy
 * since the day it was written and nobody ever built one: the module was
 * imported — the settings pane borrows `canNotify` off it to draw a permission
 * warning — so it looked wired, while `SessionNotifier` was never constructed
 * and no banner has ever been shown by this app. Five settings pointed at it:
 * "Notify when a session finishes", "Only notify when the app is in the
 * background", "Desktop notifications when sessions need attention", "Play
 * sound when session finishes work", and the sound picker underneath them.
 * All five were switches over nothing.
 *
 * The policy stays where it is. This is the wiring, and the two decisions the
 * policy deliberately does not make:
 *
 * - **Which statuses are allowed** is per status, not global, because the two
 *   events have their own switches. `enabled` is set immediately before each
 *   `observe`, which is what makes a per-status gate out of a single flag
 *   without teaching the tracker about settings.
 * - **What "firing" means** is the host's business. A finish can ring, banner,
 *   both or neither, so `present` plays the sound and then decides whether
 *   there is also a banner to show. Returning null is already how the host
 *   says "nothing on screen"; nothing else has to change.
 */

export interface SessionNotifierOptions {
  values: SettingValues
  /** Every live session, for the name and folder a banner is headed with. */
  describe: (sessionId: string) => SessionDescriptor
  viewing: ViewingState
  /** Clicking a banner brings you to the session it is about. */
  onActivate: (sessionId: string) => void
}

/** Whether a status may fire at all, given the settings and where the user is. */
export function notifyPolicy(
  values: SettingValues,
  windowFocused: boolean,
): { banner: (status: SessionStatus) => boolean; sound: boolean } {
  const onlyWhenUnfocused = booleanSetting(values, 'notifications.onlyWhenUnfocused')
  // The switch reads "only notify when the app is in the background", so a
  // focused window silences banners entirely — not just the session on screen,
  // which the policy's own `watching` rule already covers.
  const banners = !onlyWhenUnfocused || !windowFocused
  const onComplete = booleanSetting(values, 'notifications.onComplete')
  const onAttention = booleanSetting(values, 'general.notifyOnAttention')

  return {
    banner: (status) =>
      banners && (status === 'completed' ? onComplete : status === 'input' ? onAttention : false),
    sound: booleanSetting(values, 'general.soundOnFinish'),
  }
}

export interface SessionNotifierHandle {
  /** Feed every status change. The policy decides what, if anything, happens. */
  observe(sessionId: string, status: SessionStatus): void
  /** Drop a closed session, so its banner goes with it. */
  forget(sessionId: string): void
}

export function useSessionNotifier({
  values,
  describe,
  viewing,
  onActivate,
}: SessionNotifierOptions): SessionNotifierHandle {
  // Everything the notifier reads at fire time lives in refs: the tracker is
  // built once and must not be rebuilt when a setting changes, or every
  // session's history — which is what rules 2, 3 and 5 are made of — is lost.
  const policyRef = useRef(notifyPolicy(values, viewing.windowFocused))
  policyRef.current = notifyPolicy(values, viewing.windowFocused)

  const soundRef = useRef('chime')
  soundRef.current = stringSetting(values, 'notifications.soundName')

  const describeRef = useRef(describe)
  describeRef.current = describe

  const activateRef = useRef(onActivate)
  activateRef.current = onActivate

  const notifier = useMemo(() => {
    const base = browserNotificationHost((sessionId) => activateRef.current(sessionId))
    const host: NotifierHost = {
      now: base.now,
      present(notification) {
        if (notification.status === 'completed' && policyRef.current.sound) {
          const id = soundRef.current
          if (isSoundId(id)) playSound(id)
        }
        return policyRef.current.banner(notification.status) ? base.present(notification) : null
      },
    }
    return new SessionNotifier(host)
  }, [])

  useEffect(() => {
    notifier.setViewing(viewing)
  }, [notifier, viewing])

  return useMemo(
    () => ({
      observe(sessionId, status) {
        const policy = policyRef.current
        // One flag, set per call: a status nobody asked to hear about is
        // "disabled" for exactly this observation, and the tracker still
        // records the transition so the next one is judged correctly.
        notifier.setEnabled(policy.banner(status) || (status === 'completed' && policy.sound))
        notifier.observe(sessionId, status, describeRef.current(sessionId))
      },
      forget(sessionId) {
        notifier.forget(sessionId)
      },
    }),
    [notifier],
  )
}
