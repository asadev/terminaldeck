import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { SessionStatus } from '@shared/types'
import {
  decide,
  isNotifyingStatus,
  notificationText,
  NOTIFY_COOLDOWN_MS,
  SessionNotifier,
  type NotificationHandle,
  type NotifyDecisionInput,
  type NotifierHost,
  type SessionNotification,
} from './notifications'

/* -------------------------------------------------------------------------- */
/* The policy, in isolation                                                    */
/* -------------------------------------------------------------------------- */

/** A change that fires, so each test can flip exactly the field it is about. */
const FIRING: NotifyDecisionInput = {
  status: 'completed',
  previous: 'working',
  enabled: true,
  watching: false,
  lastFiredAt: null,
  now: 10_000,
  cooldownMs: NOTIFY_COOLDOWN_MS,
}

const verdict = (patch: Partial<NotifyDecisionInput> = {}) => decide({ ...FIRING, ...patch })

describe('isNotifyingStatus', () => {
  it('accepts only completed and input', () => {
    const statuses: SessionStatus[] = ['idle', 'working', 'waiting', 'input', 'completed', 'exited']
    expect(statuses.filter(isNotifyingStatus)).toEqual(['input', 'completed'])
  })
})

describe('decide', () => {
  it('fires on a real transition to completed', () => {
    expect(verdict()).toEqual({ fire: true })
  })

  it('fires on a real transition to input', () => {
    expect(verdict({ status: 'input' })).toEqual({ fire: true })
  })

  it('stays silent when the user turned notifications off', () => {
    expect(verdict({ enabled: false })).toEqual({ fire: false, reason: 'disabled' })
  })

  it('stays silent the first time it sees a session', () => {
    // Restoring a window of finished sessions must not fire a banner per tab.
    expect(verdict({ previous: undefined })).toEqual({ fire: false, reason: 'first-sight' })
  })

  it('stays silent when the status did not actually change', () => {
    expect(verdict({ previous: 'completed' })).toEqual({ fire: false, reason: 'unchanged' })
  })

  it('stays silent for states that are not worth interrupting anyone', () => {
    for (const status of ['idle', 'working', 'waiting', 'exited'] as SessionStatus[]) {
      // `previous` is a notifying state so the change is real — it is the new
      // status, not the transition, that this test is about.
      expect(verdict({ previous: 'completed', status })).toEqual({
        fire: false,
        reason: 'not-notifying',
      })
    }
  })

  it('stays silent for the session the user is looking at', () => {
    expect(verdict({ watching: true })).toEqual({ fire: false, reason: 'watching' })
  })

  it('stays silent for the same status again inside the cooldown', () => {
    expect(verdict({ lastFiredAt: 10_000 - (NOTIFY_COOLDOWN_MS - 1) })).toEqual({
      fire: false,
      reason: 'cooldown',
    })
  })

  it('fires again once the cooldown has elapsed', () => {
    expect(verdict({ lastFiredAt: 10_000 - NOTIFY_COOLDOWN_MS })).toEqual({ fire: true })
  })

  it('lets a status that has never fired through, however recently another did', () => {
    // Asking a question and then finishing are two things the user cares
    // about; only the repeat of one of them is noise. The caller keeps a
    // separate timestamp per status, so `null` here means "this one has never
    // fired" no matter what the other one did a millisecond ago.
    expect(verdict({ status: 'input', lastFiredAt: null })).toEqual({ fire: true })
  })

  it('checks the preference before anything else', () => {
    expect(verdict({ enabled: false, previous: undefined, watching: true })).toEqual({
      fire: false,
      reason: 'disabled',
    })
  })
})

describe('notificationText', () => {
  it('heads with the project and says what happened', () => {
    expect(notificationText('completed', { title: 'ship the picker', project: 'pawl' })).toEqual({
      title: 'pawl',
      body: 'ship the picker finished',
    })
  })

  it('phrases input as a request', () => {
    expect(notificationText('input', { title: 'ship the picker', project: 'pawl' }).body).toBe(
      'ship the picker needs your input',
    )
  })

  it('falls back to the session name when there is no project', () => {
    expect(notificationText('completed', { title: 'ship the picker' }).title).toBe('ship the picker')
  })

  it('never renders an empty heading', () => {
    expect(notificationText('completed', { title: '   ', project: '  ' })).toEqual({
      title: 'Session',
      body: 'Session finished',
    })
  })
})

/* -------------------------------------------------------------------------- */
/* The tracker                                                                 */
/* -------------------------------------------------------------------------- */

/** A clock and a spy in place of a browser. */
function harness(): {
  host: NotifierHost
  fired: SessionNotification[]
  closed: string[]
  advance(ms: number): void
} {
  let clock = 1_000
  const fired: SessionNotification[] = []
  const closed: string[] = []

  return {
    fired,
    closed,
    advance(ms) {
      clock += ms
    },
    host: {
      now: () => clock,
      present(notification): NotificationHandle {
        fired.push(notification)
        return {
          close: () => closed.push(notification.sessionId),
        }
      },
    },
  }
}

describe('SessionNotifier', () => {
  let h: ReturnType<typeof harness>

  beforeEach(() => {
    h = harness()
  })

  it('fires once for a background session that finishes', () => {
    const notifier = new SessionNotifier(h.host, { viewing: { activeSessionId: 'a', windowFocused: true } })

    notifier.observe('b', 'working', { title: 'the task', project: 'pawl' })
    notifier.observe('b', 'completed', { title: 'the task', project: 'pawl' })

    expect(h.fired).toEqual([
      { sessionId: 'b', status: 'completed', title: 'pawl', body: 'the task finished' },
    ])
  })

  it('does not fire for the session on screen', () => {
    const notifier = new SessionNotifier(h.host, { viewing: { activeSessionId: 'a', windowFocused: true } })

    notifier.observe('a', 'working')
    notifier.observe('a', 'input')

    expect(h.fired).toHaveLength(0)
  })

  it('does fire for the active session once the window loses focus', () => {
    // The app is behind something else — the user is not reading anything.
    const notifier = new SessionNotifier(h.host, {
      viewing: { activeSessionId: 'a', windowFocused: false },
    })

    notifier.observe('a', 'working')
    notifier.observe('a', 'input')

    expect(h.fired).toHaveLength(1)
  })

  it('never fires on the first status it sees', () => {
    const notifier = new SessionNotifier(h.host)
    notifier.observe('restored', 'completed')
    expect(h.fired).toHaveLength(0)
  })

  it('does not fire twice when the same status is reported again', () => {
    const notifier = new SessionNotifier(h.host)

    notifier.observe('b', 'working')
    notifier.observe('b', 'completed')
    notifier.observe('b', 'completed')
    notifier.observe('b', 'completed')

    expect(h.fired).toHaveLength(1)
  })

  it('swallows a repaint flap: input, working, input, working, input', () => {
    const notifier = new SessionNotifier(h.host)

    notifier.observe('b', 'working')
    for (let i = 0; i < 3; i++) {
      notifier.observe('b', 'input')
      h.advance(700) // one activity-tracker settle window
      notifier.observe('b', 'working')
      h.advance(700)
    }

    expect(h.fired).toHaveLength(1)
  })

  it('fires again for a genuine second question after the cooldown', () => {
    const notifier = new SessionNotifier(h.host)

    notifier.observe('b', 'working')
    notifier.observe('b', 'input')
    h.advance(NOTIFY_COOLDOWN_MS)
    notifier.observe('b', 'working')
    notifier.observe('b', 'input')

    expect(h.fired).toHaveLength(2)
  })

  it('lets a completion through immediately after a question', () => {
    const notifier = new SessionNotifier(h.host)

    notifier.observe('b', 'working')
    notifier.observe('b', 'input')
    h.advance(50)
    notifier.observe('b', 'completed')

    expect(h.fired.map((n) => n.status)).toEqual(['input', 'completed'])
  })

  it('swallows a flap that alternates between the two notifying statuses', () => {
    // REGRESSION: the cooldown used to be a single most-recent-fire slot, so
    // firing `completed` erased the record of the `input` banner 200ms before
    // it — and a screen flickering between "done" and "needs input" (a
    // permission prompt drawn under a finished-looking summary) alternated
    // past the cooldown on every transition. Twelve banners in 2.4 seconds
    // with a 4-second cooldown. Each status is now remembered separately, so
    // the flap costs one banner each and then goes quiet.
    const notifier = new SessionNotifier(h.host)
    notifier.observe('b', 'working')

    for (let i = 0; i < 6; i++) {
      notifier.observe('b', 'input')
      h.advance(200)
      notifier.observe('b', 'completed')
      h.advance(200)
    }

    expect(h.fired.map((n) => n.status)).toEqual(['input', 'completed'])
  })

  it('still fires each status again once its own cooldown has elapsed', () => {
    // The flap fix must not turn the cooldown into a permanent mute.
    const notifier = new SessionNotifier(h.host, { cooldownMs: 1_000 })

    notifier.observe('b', 'working')
    notifier.observe('b', 'input')
    notifier.observe('b', 'completed')
    h.advance(1_000)
    notifier.observe('b', 'input')
    notifier.observe('b', 'completed')

    expect(h.fired.map((n) => n.status)).toEqual(['input', 'completed', 'input', 'completed'])
  })

  it('takes down the previous banner before showing a new one', () => {
    const notifier = new SessionNotifier(h.host)

    notifier.observe('b', 'working')
    notifier.observe('b', 'input')
    h.advance(50)
    notifier.observe('b', 'completed')

    expect(h.closed).toEqual(['b'])
  })

  it('respects the preference being turned off and back on', () => {
    const notifier = new SessionNotifier(h.host, { enabled: false })

    notifier.observe('b', 'working')
    notifier.observe('b', 'completed')
    expect(h.fired).toHaveLength(0)

    notifier.setEnabled(true)
    notifier.observe('b', 'working')
    notifier.observe('b', 'input')
    expect(h.fired).toHaveLength(1)
  })

  it('dismisses the banner for a session the user switches to', () => {
    const notifier = new SessionNotifier(h.host, {
      viewing: { activeSessionId: 'a', windowFocused: true },
    })

    notifier.observe('b', 'working')
    notifier.observe('b', 'completed')
    expect(h.closed).toEqual([])

    notifier.setViewing({ activeSessionId: 'b', windowFocused: true })
    expect(h.closed).toEqual(['b'])
  })

  it('does not dismiss anything when the window merely regains focus elsewhere', () => {
    const notifier = new SessionNotifier(h.host, {
      viewing: { activeSessionId: 'a', windowFocused: false },
    })

    notifier.observe('b', 'working')
    notifier.observe('b', 'completed')
    notifier.setViewing({ activeSessionId: 'a', windowFocused: true })

    expect(h.closed).toEqual([])
  })

  it('closes the banner and forgets the history when a session is closed', () => {
    const notifier = new SessionNotifier(h.host)

    notifier.observe('b', 'working')
    notifier.observe('b', 'completed')
    notifier.forget('b')
    expect(h.closed).toEqual(['b'])

    // A new session reusing the id starts from scratch: first sight is silent.
    notifier.observe('b', 'completed')
    expect(h.fired).toHaveLength(1)
  })

  it('keeps the history of each session separate', () => {
    const notifier = new SessionNotifier(h.host)

    notifier.observe('a', 'working')
    notifier.observe('b', 'working')
    notifier.observe('a', 'completed')
    notifier.observe('b', 'completed')

    expect(h.fired.map((n) => n.sessionId)).toEqual(['a', 'b'])
  })

  it('honours a custom cooldown', () => {
    const notifier = new SessionNotifier(h.host, { cooldownMs: 100 })

    notifier.observe('b', 'working')
    notifier.observe('b', 'input')
    h.advance(100)
    notifier.observe('b', 'working')
    notifier.observe('b', 'input')

    expect(h.fired).toHaveLength(2)
  })

  it('survives a host that declines to present anything', () => {
    const silent: NotifierHost = { now: () => 0, present: () => null }
    const notifier = new SessionNotifier(silent)

    notifier.observe('b', 'working')
    expect(() => notifier.observe('b', 'completed')).not.toThrow()
    expect(() => notifier.dismiss('b')).not.toThrow()
  })

  it('returns the verdict so callers can see why nothing happened', () => {
    const notifier = new SessionNotifier(h.host)

    expect(notifier.observe('b', 'completed')).toEqual({ fire: false, reason: 'first-sight' })
    expect(notifier.observe('b', 'completed')).toEqual({ fire: false, reason: 'unchanged' })
    expect(notifier.observe('b', 'working')).toEqual({ fire: false, reason: 'not-notifying' })
    expect(notifier.observe('b', 'completed')).toEqual({ fire: true })
  })

  it('defaults the banner name to the session id when nothing describes it', () => {
    const notifier = new SessionNotifier(h.host)
    notifier.observe('sess-1', 'working')
    notifier.observe('sess-1', 'completed')
    expect(h.fired[0].title).toBe('sess-1')
  })
})

/* -------------------------------------------------------------------------- */
/* Browser wiring                                                              */
/* -------------------------------------------------------------------------- */

describe('permission handling', () => {
  it('reports no permission when the API is missing entirely', async () => {
    const { canNotify, requestNotificationPermission } = await import('./notifications')
    vi.stubGlobal('Notification', undefined)
    expect(canNotify()).toBe(false)
    await expect(requestNotificationPermission()).resolves.toBe(false)
    vi.unstubAllGlobals()
  })

  it('does not re-ask after a denial', async () => {
    const requestPermission = vi.fn()
    vi.stubGlobal('Notification', { permission: 'denied', requestPermission })
    const { requestNotificationPermission } = await import('./notifications')
    await expect(requestNotificationPermission()).resolves.toBe(false)
    expect(requestPermission).not.toHaveBeenCalled()
    vi.unstubAllGlobals()
  })

  it('asks once while permission is still undecided', async () => {
    const requestPermission = vi.fn().mockResolvedValue('granted')
    vi.stubGlobal('Notification', { permission: 'default', requestPermission })
    const { requestNotificationPermission } = await import('./notifications')
    await expect(requestNotificationPermission()).resolves.toBe(true)
    expect(requestPermission).toHaveBeenCalledTimes(1)
    vi.unstubAllGlobals()
  })
})
