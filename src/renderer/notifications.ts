/**
 * Desktop notification policy for session state changes.
 *
 * The banner is the whole point of leaving an agent running while you do
 * something else, and it is also the fastest way to make an app unbearable.
 * The rules that keep it useful are the substance of this module; presenting
 * the banner is three lines at the bottom.
 *
 * The policy is a pure function — `decide` — and the class around it is only
 * bookkeeping, so every rule is testable without a browser, a clock or a
 * notification permission.
 *
 * ## The rules
 *
 * 1. Only `completed` and `input` notify. `working`, `waiting` and `idle` are
 *    passing weather; `exited` is either the user closing a tab or a crash
 *    they are already looking at.
 * 2. Only a real transition notifies. The main process re-broadcasts status on
 *    reconnect and the tracker re-classifies on every settle, so the same
 *    status arriving twice is the normal case, not an event.
 * 3. The first status seen for a session never notifies. Restoring a window
 *    full of finished sessions would otherwise fire a banner per tab.
 * 4. Nothing notifies for the session the user is watching — the active tab in
 *    a focused window. They can see it.
 * 5. A session that just fired cannot fire again for the same status inside
 *    the cooldown. Agent TUIs repaint constantly, so a session waiting on a
 *    permission prompt flickers input → working → input; without this the user
 *    gets a banner every second. Each notifying status carries its own
 *    cooldown, so answering a question and then finishing are still two
 *    banners — see `SessionRecord.firedAt`.
 */

import type { SessionStatus } from '@shared/types'

/** The two states worth interrupting someone for. */
export const NOTIFYING_STATUSES = ['completed', 'input'] as const

export type NotifyingStatus = (typeof NOTIFYING_STATUSES)[number]

export function isNotifyingStatus(status: SessionStatus): status is NotifyingStatus {
  return status === 'completed' || status === 'input'
}

/**
 * How long a session stays quiet after firing.
 *
 * Sized against the activity tracker's 700ms settle window: a genuine second
 * question, asked after the user answered the first, is minutes away, while a
 * repaint-induced flap is under a second. Four seconds swallows every flap and
 * delays no real event.
 */
export const NOTIFY_COOLDOWN_MS = 4000

/* -------------------------------------------------------------------------- */
/* The decision                                                                */
/* -------------------------------------------------------------------------- */

/** Why a status change did not produce a banner. Named so tests read as prose. */
export type SuppressionReason =
  | 'disabled'
  | 'first-sight'
  | 'unchanged'
  | 'not-notifying'
  | 'watching'
  | 'cooldown'

export type NotifyVerdict = { fire: true } | { fire: false; reason: SuppressionReason }

export interface NotifyDecisionInput {
  /** The status just reported. */
  status: SessionStatus
  /** The last status seen for this session, or undefined if it is new to us. */
  previous: SessionStatus | undefined
  /** Has the user turned notifications on? */
  enabled: boolean
  /** Is this session the active tab of a focused window? */
  watching: boolean
  /**
   * When a banner for *this same status* last fired for this session, or null
   * if it never has.
   *
   * Per status rather than per session, because a session that asks a question
   * and then finishes has genuinely done two things and swallowing the second
   * would lose the event the user cares most about. Per status *and remembered
   * separately*, because a single most-recent-fire slot is no cooldown at all:
   * see the caller.
   */
  lastFiredAt: number | null
  now: number
  cooldownMs: number
}

/**
 * Apply the five rules, in the order that makes the cheapest check first and
 * the most surprising one last.
 */
export function decide(input: NotifyDecisionInput): NotifyVerdict {
  if (!input.enabled) return { fire: false, reason: 'disabled' }
  if (input.previous === undefined) return { fire: false, reason: 'first-sight' }
  if (input.previous === input.status) return { fire: false, reason: 'unchanged' }
  if (!isNotifyingStatus(input.status)) return { fire: false, reason: 'not-notifying' }
  if (input.watching) return { fire: false, reason: 'watching' }

  if (input.lastFiredAt !== null && input.now - input.lastFiredAt < input.cooldownMs) {
    return { fire: false, reason: 'cooldown' }
  }

  return { fire: true }
}

/* -------------------------------------------------------------------------- */
/* Wording                                                                     */
/* -------------------------------------------------------------------------- */

export interface SessionDescriptor {
  /** What the tab is called — see `session-title.ts`. */
  title: string
  /** Project folder name. Heads the banner when present, since it locates the work. */
  project?: string
}

export interface NotificationText {
  title: string
  body: string
}

/**
 * Banner copy. The heading is where the work is, the body is what happened —
 * that ordering means the notification is readable when the OS truncates it.
 *
 * The name is dropped from the body when it is the same string as the heading.
 * A tab keeps the folder name until the conversation has a title of its own, so
 * the common case — a session started a minute ago in a project — had both
 * halves saying the same word. Seen on screen, driving a real session to
 * `input`, the banner read *"terminaldeck / terminaldeck needs your input"*.
 * Saying it once is the rule; a notification is the worst place to break it,
 * because it is two short lines and half of one was wasted.
 */
export function notificationText(
  status: NotifyingStatus,
  descriptor: SessionDescriptor,
): NotificationText {
  const name = descriptor.title.trim() || 'Session'
  const project = descriptor.project?.trim()
  const heading = project || name
  const subject = heading === name ? '' : `${name} `
  return {
    title: heading,
    body:
      status === 'input'
        ? `${subject}${subject ? 'needs' : 'Needs'} your input`
        : `${subject}${subject ? 'finished' : 'Finished'}`,
  }
}

/* -------------------------------------------------------------------------- */
/* The tracker                                                                 */
/* -------------------------------------------------------------------------- */

/** A banner that is on screen and can be taken down again. */
export interface NotificationHandle {
  close(): void
}

export interface SessionNotification extends NotificationText {
  sessionId: string
  status: NotifyingStatus
}

/**
 * Everything the tracker needs from the outside world, so tests can supply a
 * clock and a spy instead of a browser.
 */
export interface NotifierHost {
  now(): number
  /** Show a banner. Returning a handle lets a stale one be dismissed. */
  present(notification: SessionNotification): NotificationHandle | null
}

export interface ViewingState {
  /** Which tab is on screen. */
  activeSessionId: string | null
  /** Whether the app window itself has focus — a backgrounded app watches nothing. */
  windowFocused: boolean
}

export interface NotifierOptions {
  enabled?: boolean
  cooldownMs?: number
  viewing?: ViewingState
}

interface SessionRecord {
  status: SessionStatus | undefined
  /**
   * When each notifying status last fired, keyed by the status itself.
   *
   * A single most-recent-fire slot looks equivalent and is not: firing
   * `completed` would overwrite the record of an `input` banner from 200ms
   * ago, so a screen that flickers between "done" and "needs input" — a
   * permission prompt drawn under a finished-looking summary — alternates past
   * the cooldown on every transition and banners forever. Two slots cost two
   * numbers and bound the damage to one banner per status per cooldown.
   */
  firedAt: Partial<Record<NotifyingStatus, number>>
  live: NotificationHandle | null
}

/**
 * Watches session status changes and fires desktop notifications when the
 * policy above says to.
 *
 * Feed it every status change; it decides. Keeping the filtering here rather
 * than at each call site is what makes rules 2, 3 and 5 possible at all —
 * they are all statements about history, and only something that remembers can
 * enforce them.
 */
export class SessionNotifier {
  private readonly sessions = new Map<string, SessionRecord>()
  private enabled: boolean
  private readonly cooldownMs: number
  private viewing: ViewingState

  constructor(
    private readonly host: NotifierHost,
    options: NotifierOptions = {},
  ) {
    this.enabled = options.enabled ?? true
    this.cooldownMs = options.cooldownMs ?? NOTIFY_COOLDOWN_MS
    this.viewing = options.viewing ?? { activeSessionId: null, windowFocused: true }
  }

  /** Mirror the preference. Turning it off does not retract banners already up. */
  setEnabled(enabled: boolean): void {
    this.enabled = enabled
  }

  /**
   * Tell the tracker what the user is looking at.
   *
   * Also dismisses the banner for whatever they just switched to: reading the
   * session is the acknowledgement, and leaving the banner in Notification
   * Center to be clicked later would take them somewhere they already are.
   */
  setViewing(viewing: ViewingState): void {
    this.viewing = viewing
    const watched = this.watchedId()
    if (watched) this.dismiss(watched)
  }

  /**
   * Report a status. Returns the verdict so callers can log or test it, but
   * the common case ignores it.
   */
  observe(
    sessionId: string,
    status: SessionStatus,
    descriptor: SessionDescriptor = { title: sessionId },
  ): NotifyVerdict {
    const record = this.record(sessionId)
    const previous = record.status
    record.status = status

    const verdict = decide({
      status,
      previous,
      enabled: this.enabled,
      watching: this.watchedId() === sessionId,
      lastFiredAt: isNotifyingStatus(status) ? (record.firedAt[status] ?? null) : null,
      now: this.host.now(),
      cooldownMs: this.cooldownMs,
    })
    if (!verdict.fire || !isNotifyingStatus(status)) return verdict

    // Take down this session's previous banner first: each notification gets
    // its own OS-level identity, so nothing replaces it automatically and the
    // user would otherwise accumulate one per event in Notification Center.
    this.dismiss(sessionId)

    record.firedAt[status] = this.host.now()
    record.live = this.host.present({
      sessionId,
      status,
      ...notificationText(status, descriptor),
    })

    return verdict
  }

  /** Drop everything remembered about a session, and close its banner. */
  forget(sessionId: string): void {
    this.dismiss(sessionId)
    this.sessions.delete(sessionId)
  }

  /** Close a live banner without forgetting the session's history. */
  dismiss(sessionId: string): void {
    const record = this.sessions.get(sessionId)
    if (!record?.live) return
    record.live.close()
    record.live = null
  }

  /** The session the user is actually watching, if any. */
  private watchedId(): string | null {
    return this.viewing.windowFocused ? this.viewing.activeSessionId : null
  }

  private record(sessionId: string): SessionRecord {
    const existing = this.sessions.get(sessionId)
    if (existing) return existing
    const created: SessionRecord = {
      status: undefined,
      firedAt: {},
      live: null,
    }
    this.sessions.set(sessionId, created)
    return created
  }
}

/* -------------------------------------------------------------------------- */
/* Browser wiring                                                              */
/* -------------------------------------------------------------------------- */

/**
 * True when constructing a `Notification` here will not throw.
 *
 * Read what this deliberately does **not** claim. In an Electron renderer
 * `Notification.permission` is **always `granted`** — Chromium answers it out
 * of its own permission model and never consults `UNUserNotificationCenter` —
 * so this is a check that the API exists and Chromium is not refusing, and
 * nothing more. It says nothing about whether the OS will show the banner.
 *
 * That distinction is not pedantry. Treating this as "the user will see it"
 * is exactly how the settings pane came to print "Sent." for banners macOS was
 * dropping on the floor, for weeks, with no way to tell from inside the app.
 * The only honest answer to "did it appear?" comes from the OS afterwards —
 * see `src/main/os-notifications.ts`.
 *
 * There is deliberately no `requestNotificationPermission` beside this. In a
 * renderer `Notification.requestPermission()` resolves `granted` immediately
 * without asking anyone, so a button wired to it did nothing while looking
 * like it had done something. The OS's own prompt is triggered by *posting* a
 * notification, which is why the settings pane posts one the moment a banner
 * preference is switched on.
 */
export function canNotify(): boolean {
  return typeof Notification !== 'undefined' && Notification.permission !== 'denied'
}

/**
 * A host backed by the real Notification API.
 *
 * Two deliberate choices. No `tag`: Chromium uses the tag as a
 * non-persistent notification's identity, and registering a second one under a
 * known id destroys the first's click handler while its banner is still in
 * Notification Center — clicking it then does nothing. And `silent`, because
 * Electron's default chime fires on every banner regardless of the user's
 * sound preference.
 *
 * `onActivate` receives the session id so the app can raise the window and
 * select the tab; the id is captured rather than the session object so a
 * retained banner cannot pin a dead session's state alive.
 */
export function browserNotificationHost(onActivate: (sessionId: string) => void): NotifierHost {
  return {
    now: () => Date.now(),
    present(notification) {
      if (!canNotify()) return null
      const banner = new Notification(notification.title, {
        body: notification.body,
        silent: true,
      })
      banner.onclick = () => {
        onActivate(notification.sessionId)
        banner.close()
      }
      return banner
    },
  }
}
