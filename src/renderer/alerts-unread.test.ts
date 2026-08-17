import { describe, expect, it } from 'vitest'
import {
  ALERTS_SEEN_KEY,
  alertKey,
  markSeen,
  MAX_REMEMBERED_PROJECTS,
  readSeen,
  unreadAlerts,
  unreadCount,
  writeSeen,
  type SeenAlerts,
} from './alerts-unread'
import type { Alert } from './components/AlertsPanel'

const NOW = Date.parse('2026-08-17T09:00:00.000Z')
const PROJECT = '/Users/apple/Projects/terminaldeck'

function alert(overrides: Partial<Alert> & { id: string }): Alert {
  return {
    kind: 'session-blocked',
    severity: 'warning',
    title: 'Waiting on you for 12 minutes',
    detail: 'Session abc12345 asked a question.',
    at: NOW,
    action: null,
    ...overrides,
  }
}

/** A `Storage` that lives in a Map, for the two functions that touch one. */
function memoryStorage(seed: Record<string, string> = {}): Storage {
  const map = new Map(Object.entries(seed))
  return {
    get length() {
      return map.size
    },
    clear: () => map.clear(),
    getItem: (key) => map.get(key) ?? null,
    key: (index) => [...map.keys()][index] ?? null,
    removeItem: (key) => void map.delete(key),
    setItem: (key, value) => void map.set(key, value),
  }
}

describe('alertKey', () => {
  /**
   * The one that would have shipped wrong.
   *
   * `alerts.ts` promises a stable id "for the same underlying condition", and a
   * blocked session is warning at ten minutes and critical at forty-five under
   * that same id. Keyed on the id alone, glancing at the sheet at minute eleven
   * silences the escalation forever.
   */
  it('treats an escalation as a different alert from the one it escalated from', () => {
    const warning = alert({ id: 'session-blocked:abc', severity: 'warning' })
    const critical = alert({ id: 'session-blocked:abc', severity: 'critical' })
    expect(alertKey(warning)).not.toBe(alertKey(critical))
  })

  it('is stable for the same condition at the same severity', () => {
    expect(alertKey(alert({ id: 'dirty-tree' }))).toBe(alertKey(alert({ id: 'dirty-tree' })))
  })
})

describe('unreadAlerts', () => {
  it('counts everything when nothing has been seen', () => {
    const alerts = [alert({ id: 'a' }), alert({ id: 'b' })]
    expect(unreadCount(alerts, {}, PROJECT)).toBe(2)
  })

  it('drops the ones this project has already been shown', () => {
    const seen = markSeen({}, PROJECT, [alert({ id: 'a' })])
    const alerts = [alert({ id: 'a' }), alert({ id: 'b' })]
    expect(unreadAlerts(alerts, seen, PROJECT).map((entry) => entry.id)).toEqual(['b'])
  })

  it('re-raises an alert that got worse', () => {
    const seen = markSeen({}, PROJECT, [alert({ id: 'session-blocked:abc', severity: 'warning' })])
    const now = [alert({ id: 'session-blocked:abc', severity: 'critical' })]
    expect(unreadCount(now, seen, PROJECT)).toBe(1)
  })

  it('does not carry one project’s reading over to another', () => {
    const seen = markSeen({}, PROJECT, [alert({ id: 'a' })])
    expect(unreadCount([alert({ id: 'a' })], seen, '/Users/apple/Projects/other')).toBe(1)
  })

  it('counts nothing when no project is open', () => {
    // The sheet draws "No project open" in this state, so a dot beside it would
    // be a number about nothing.
    expect(unreadCount([alert({ id: 'a' })], {}, null)).toBe(0)
  })
})

describe('markSeen', () => {
  it('returns the same object when the same alerts are re-confirmed', () => {
    // The feed keeps scanning while the sheet is open and most scans find the
    // same list. Identity is what stops that writing to disk every time.
    const first = markSeen({}, PROJECT, [alert({ id: 'a' })])
    const second = markSeen(first, PROJECT, [alert({ id: 'a' })])
    expect(second).toBe(first)
  })

  it('forgets a key once its alert has resolved', () => {
    const seen = markSeen({}, PROJECT, [alert({ id: 'a' }), alert({ id: 'b' })])
    const after = markSeen(seen, PROJECT, [alert({ id: 'b' })])
    expect(after[PROJECT]).toEqual([alertKey(alert({ id: 'b' }))])
  })

  it('drops the entry entirely for a project with nothing to remember', () => {
    const seen = markSeen({}, PROJECT, [alert({ id: 'a' })])
    const after = markSeen(seen, PROJECT, [])
    expect(Object.keys(after)).not.toContain(PROJECT)
  })

  it('is a no-op for a quiet project it has never heard of', () => {
    const seen: SeenAlerts = {}
    expect(markSeen(seen, PROJECT, [])).toBe(seen)
  })

  it('remembers a bounded number of projects, dropping the least recent', () => {
    let seen: SeenAlerts = {}
    for (let i = 0; i < MAX_REMEMBERED_PROJECTS + 5; i++) {
      seen = markSeen(seen, `/p/${i}`, [alert({ id: `a${i}` })])
    }
    const keys = Object.keys(seen)
    expect(keys).toHaveLength(MAX_REMEMBERED_PROJECTS)
    expect(keys).not.toContain('/p/0')
    expect(keys).toContain(`/p/${MAX_REMEMBERED_PROJECTS + 4}`)
  })

  it('keeps a re-read project from being aged out by the cap', () => {
    let seen = markSeen({}, '/p/first', [alert({ id: 'a' })])
    for (let i = 0; i < MAX_REMEMBERED_PROJECTS - 1; i++) {
      seen = markSeen(seen, `/p/${i}`, [alert({ id: `a${i}` })])
    }
    // Reading it again moves it back to the newest end.
    seen = markSeen(seen, '/p/first', [alert({ id: 'a' })])
    seen = markSeen(seen, '/p/extra', [alert({ id: 'x' })])
    expect(Object.keys(seen)).toContain('/p/first')
  })
})

describe('readSeen and writeSeen', () => {
  it('round-trips through storage', () => {
    const storage = memoryStorage()
    const seen = markSeen({}, PROJECT, [alert({ id: 'a' })])
    writeSeen(storage, seen)
    expect(readSeen(storage)).toEqual(seen)
  })

  it('starts empty rather than throwing on anything that is not the shape', () => {
    // The whole value is one badge. A parse that threw would take the sidebar
    // with it, which is a window that does not draw over a dot that does not
    // matter.
    expect(readSeen(memoryStorage({ [ALERTS_SEEN_KEY]: 'not json' }))).toEqual({})
    expect(readSeen(memoryStorage({ [ALERTS_SEEN_KEY]: '[1,2,3]' }))).toEqual({})
    expect(readSeen(memoryStorage({ [ALERTS_SEEN_KEY]: '"a string"' }))).toEqual({})
    expect(readSeen(memoryStorage({ [ALERTS_SEEN_KEY]: '{"/p": 7}' }))).toEqual({})
    expect(readSeen(memoryStorage({ [ALERTS_SEEN_KEY]: '{"/p": [1, "k", null]}' }))).toEqual({
      '/p': ['k'],
    })
  })

  it('survives having no storage at all', () => {
    // The renderer tests run with no window; so does the harness before the
    // preload lands.
    expect(readSeen(null)).toEqual({})
    expect(() => writeSeen(null, {})).not.toThrow()
  })

  it('does not throw when storage refuses the write', () => {
    const storage = memoryStorage()
    storage.setItem = () => {
      throw new Error('QuotaExceededError')
    }
    expect(() => writeSeen(storage, { [PROJECT]: ['warning:a'] })).not.toThrow()
  })
})
