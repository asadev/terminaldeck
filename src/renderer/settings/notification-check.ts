/**
 * Posting a banner and then saying, honestly, what became of it.
 *
 * ## Why this is not three lines inside the settings pane
 *
 * It used to be. The Test button constructed a `Notification`, the constructor
 * returned, and the pane printed **"Sent. If nothing appeared, the banner was
 * suppressed by a Focus mode."**
 *
 * Every word of that was wrong in the case that mattered. `Notification.permission`
 * in an Electron renderer is always `granted` — Chromium answers from its own
 * permission model and never asks the OS — so the button was enabled, the
 * constructor succeeded and `onshow` fired while macOS, whose authorisation was
 * still `notDetermined` because its prompt had never been answered, dropped the
 * banner silently. The app then named the one cause that had been checked and
 * ruled out, and sent whoever was debugging it to look at Focus modes.
 *
 * So the rules this module encodes:
 *
 *  1. **Never claim delivery that has not been confirmed.** There are three
 *     outcomes, not one, and only one of them is allowed to sound like success.
 *  2. **Never name a single cause the app has not checked.** Where the app
 *     cannot know, it says it cannot know — and says which layer holds the
 *     answer.
 *  3. **Always leave a way out.** Every uncertain outcome is paired with the
 *     button that opens the OS's own notification settings, so the user is
 *     never left with a sentence and no next step.
 *  4. **Ask while the user is looking.** The macOS authorisation prompt appears
 *     *as a banner*, once, with **Allow** hidden behind its `Options` control.
 *     Fire it on a background status change and it is gone forever and the
 *     feature silently never works again — which is precisely what happened.
 *     So `confirmEnabled` posts a banner the moment a preference is switched
 *     on, when the user is on this screen and can answer.
 *
 * The confirmation itself comes from `src/main/os-notifications.ts`, which
 * reads macOS's own notification store. When that read is unavailable — any
 * other platform, an older preload, a schema Apple changed — the answer is
 * `unknown` and the copy for `unknown` promises nothing.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { detectPlatform, osName, type UiPlatform } from '../platform'
import {
  errorText,
  toDeliveryReport,
  toNotificationSupport,
  type DeliveryReport,
  type SettingsBridge,
} from './settings-bridge'

/* ---------------------------------------------------------------- copy -- */

/**
 * Where **Allow** hides.
 *
 * This sentence is the entire bug, written down. macOS asks for notification
 * authorisation with a banner that offers only `Options ⌄`; until that is
 * opened and Allow is clicked, authorisation stays `notDetermined` and every
 * banner is dropped without a word. Nobody finds this by looking.
 */
const WHERE_ALLOW_HIDES =
  'If it is asking permission, the request arrives as a banner in the corner and Allow is hidden under its Options button.'

/** The sentence that admits what the app cannot see, per platform. */
function cannotRead(platform: UiPlatform): string {
  return `Whether a banner actually appears is decided by ${osName(platform)}, and the app cannot read that.`
}

export interface DeliveryCopy {
  text: string
  /** Warn when something is likely wrong; info when it plainly worked. */
  tone: 'info' | 'warn'
  /** Whether to offer the escape hatch beside the note. */
  offerSettings: boolean
}

/**
 * Turn a verdict into the one sentence the app can stand behind.
 *
 * Pure, and exported, so the wording is testable without a DOM, a clock or a
 * notification permission — the same reason `decide` in `notifications.ts` is
 * pure. The wording is the feature here; a test that could not read it would
 * be testing the wrong half.
 */
export function deliveryCopy(
  report: DeliveryReport,
  kind: 'test' | 'enabled',
  platform: UiPlatform,
): DeliveryCopy {
  const os = osName(platform)

  if (report.verdict === 'delivered') {
    const when = report.at ? ` at ${report.at.slice(11)}` : ''
    return {
      text:
        kind === 'test'
          ? `${os} recorded a banner${when}. Notifications are working.`
          : `On, and proven: ${os} recorded a banner${when}.`,
      tone: 'info',
      offerSettings: false,
    }
  }

  if (report.verdict === 'absent') {
    return {
      text:
        `${os} has no record of showing it. Authorisation is most likely still pending or has been refused — ` +
        `the app cannot read which. ${WHERE_ALLOW_HIDES}`,
      tone: 'warn',
      offerSettings: true,
    }
  }

  return {
    text:
      kind === 'test'
        ? `The banner was handed to ${os}. ${cannotRead(platform)} If nothing appeared, check there.`
        : `On. ${os} may now ask you to allow notifications. ${WHERE_ALLOW_HIDES}`,
    tone: 'warn',
    offerSettings: true,
  }
}

/* ------------------------------------------------- when to ask the OS -- */

/**
 * The preferences whose being switched **on** is the moment to ask macOS for
 * authorisation.
 *
 * One list, in one file, rather than a literal id compared inside each section
 * that happens to draw one of these switches. That is not tidiness — it is the
 * only arrangement that survives the settings window being reorganised. These
 * two switches have already moved once (both were in Notifications; the
 * headline pair now lives in General), and the section that draws a switch is
 * the section that has to trigger the prompt, because the prompt has to appear
 * while the user is looking at the thing they just flipped. Leave the id
 * hard-coded in the section and the next move silently detaches the ask from
 * the switch — and "silently" is the whole problem: macOS asks exactly once,
 * with a banner whose Allow is hidden under `Options`, so a prompt that fires
 * with nobody watching is a feature that never works again and never says why.
 */
export const BANNER_SETTINGS: readonly string[] = [
  'general.notifyOnAttention',
  'notifications.onComplete',
]

/**
 * Did this save just switch a banner on?
 *
 * Strictly `=== true`: a patch that merely *contains* the key is not a
 * switch-on, and switching one **off** must not fire a banner at the user to
 * tell them they will not be getting banners.
 */
export function turnedOnABanner(patch: Record<string, unknown>): boolean {
  return BANNER_SETTINGS.some((id) => patch[id] === true)
}

/* --------------------------------------------------------------- state -- */

export interface CheckState {
  /** The note under the controls, or null when nothing has been tried yet. */
  text: string
  tone: 'info' | 'warn' | 'error'
  offerSettings: boolean
}

export interface NotificationCheck {
  /** Is there an OS settings page to send the user to at all? */
  canOpenSettings: boolean
  /** What happened last, or null. */
  state: CheckState | null
  /** True while a banner is out and the OS has not been asked yet. */
  busy: boolean
  /** The user pressed Test. */
  test(): void
  /** A banner preference was just switched on. */
  confirmEnabled(): void
  /** Open the OS's own notification settings. */
  openSettings(): void
}

/** Just enough of the global to post a banner, so tests can supply a fake. */
export interface BannerFactory {
  (title: string, body: string): { close(): void }
}

function realBanner(title: string, body: string): { close(): void } {
  // `silent` because Electron's default chime fires on every banner regardless
  // of the sound preference — the same reason `browserNotificationHost` sets it.
  return new Notification(title, { body, silent: true })
}

/**
 * How long a proof banner is left alone before the app tidies it away.
 *
 * This used to be six seconds, and six seconds is exactly wrong. macOS does not
 * record a banner when it appears — it records it when it *leaves the screen*,
 * about six seconds in (measured; see `os-notifications.ts`). Closing at six
 * seconds therefore raced the only evidence there is, and could delete the row
 * before anything read it. So the banner is taken down when the OS has been
 * asked and answered, and this is only the backstop for the path where there is
 * nothing to ask.
 */
const BANNER_MS = 6000

/** Said while the OS is being asked, so a ten-second wait is not a dead click. */
const CHECKING: CheckState = {
  text: 'Waiting to hear whether it arrived — the OS does not record a banner until it leaves the screen.',
  tone: 'info',
  offerSettings: false,
}

export interface NotificationCheckOptions {
  bridge: SettingsBridge
  platform?: UiPlatform
  banner?: BannerFactory
  now?: () => number
}

/**
 * Post banners on demand and report what the OS did with them.
 *
 * The support probe runs once on mount: whether to draw an "Open notification
 * settings" button is a question about the platform, not about anything the
 * user did, and a button that appears only after a failure is a button nobody
 * finds when they need it.
 */
export function useNotificationCheck({
  bridge,
  platform = detectPlatform(),
  banner = realBanner,
  now = Date.now,
}: NotificationCheckOptions): NotificationCheck {
  const [canOpenSettings, setCanOpenSettings] = useState(false)
  const [state, setState] = useState<CheckState | null>(null)
  const [busy, setBusy] = useState(false)

  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const support = bridge.notificationSupport
  useEffect(() => {
    if (!support) return
    void support().then(
      (raw) => {
        if (alive.current) setCanOpenSettings(toNotificationSupport(raw).settingsPane)
      },
      // A build whose main process does not answer offers no button. Silent on
      // purpose: there is nothing the user could do about it and nothing broken.
      () => {},
    )
  }, [support])

  const delivery = bridge.notificationDelivery
  const openSettingsCall = bridge.openNotificationSettings

  const fire = useCallback(
    (kind: 'test' | 'enabled') => {
      if (typeof Notification === 'undefined') {
        setState({
          text: 'This build has no notification support, so there is nothing to show.',
          tone: 'error',
          offerSettings: false,
        })
        return
      }

      const since = now()
      let handle: { close(): void }
      try {
        handle =
          kind === 'test'
            ? banner('Test', 'This is what a finished session looks like.')
            : banner('Notifications are on', 'One of these appears when a session finishes or needs you.')
      } catch (cause) {
        // Constructing one can throw even with permission granted: on Linux
        // that means no notification daemon is running, and a button that
        // takes the window down with it is worse than one that reports it.
        setState({
          text: errorText(cause, `${osName(platform)} refused to show the banner.`),
          tone: 'error',
          offerSettings: true,
        })
        return
      }
      if (!delivery) {
        // No channel to ask on. Say so as "unknown" rather than inventing a
        // success — this is exactly the branch the old "Sent." came from.
        window.setTimeout(() => handle.close(), BANNER_MS)
        setState(deliveryCopy({ verdict: 'unknown', at: null }, kind, platform))
        return
      }

      setBusy(true)
      setState(CHECKING)
      const settle = (report: DeliveryReport) => {
        // Tidied away only now: closing it earlier would have deleted the row
        // being waited for. The banner has already left the screen by this
        // point, so this only clears it out of Notification Center.
        handle.close()
        if (!alive.current) return
        setBusy(false)
        setState(deliveryCopy(report, kind, platform))
      }
      void delivery(since).then(
        (raw) => settle(toDeliveryReport(raw)),
        () => settle({ verdict: 'unknown', at: null }),
      )
    },
    [banner, delivery, now, platform],
  )

  const openSettings = useCallback(() => {
    if (!openSettingsCall) return
    void openSettingsCall().then(
      () => {},
      () => {
        if (!alive.current) return
        setState({
          text: `${osName(platform)} would not open its notification settings.`,
          tone: 'error',
          offerSettings: false,
        })
      },
    )
  }, [openSettingsCall, platform])

  return useMemo(
    () => ({
      canOpenSettings: canOpenSettings && openSettingsCall !== undefined,
      state,
      busy,
      test: () => fire('test'),
      confirmEnabled: () => fire('enabled'),
      openSettings,
    }),
    [canOpenSettings, openSettingsCall, state, busy, fire, openSettings],
  )
}
