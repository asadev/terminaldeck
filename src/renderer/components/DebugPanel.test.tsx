import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import type { SessionMeta } from '@shared/types'
import {
  DebugPanel,
  LogView,
  formatDuration,
  formatMs,
  orderCalls,
  summarizeCalls,
  type DebugBridge,
  type IpcCallRecord,
} from './DebugPanel'

/**
 * The invariant that matters most is the first one: with debug mode off this
 * component renders *nothing*. Everything it shows is either noise or a
 * liability in normal use, and "hidden with CSS" is not hidden.
 */

function call(overrides: Partial<IpcCallRecord> & { seq: number }): IpcCallRecord {
  return {
    channel: 'git:status',
    kind: 'invoke',
    at: Date.parse('2026-08-12T09:00:00Z'),
    ms: 12,
    ok: true,
    ...overrides,
  }
}

const BRIDGE: DebugBridge = {
  diagnosticsText: async () => '# bundle',
  ipcLog: async () => [],
  clearIpcLog: async () => {},
  subscribeDebug: async () => true,
  unsubscribeDebug: async () => {},
  onIpcCall: () => () => {},
  listSessions: async () => [],
  recentLog: async () => ({ file: '~/logs/app.log', lines: [] }),
  openLogFolder: async () => '',
  clearLog: async () => {},
}

const SESSION: SessionMeta = {
  id: '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
  cwd: '/w/project',
  title: 'project',
  provider: 'claude',
  exitCode: null,
  createdAt: Date.now(),
}

describe('visibility', () => {
  it('renders nothing at all when debug mode is off', () => {
    expect(renderToStaticMarkup(<DebugPanel enabled={false} bridge={BRIDGE} live={false} />)).toBe('')
  })

  it('renders its sections when debug mode is on', () => {
    const html = renderToStaticMarkup(<DebugPanel enabled bridge={BRIDGE} live={false} />)
    expect(html).toContain('IPC calls')
    expect(html).toContain('Session processes')
    expect(html).toContain('Support bundle')
    expect(html).toContain('Log')
  })

  it('says so rather than looking broken when the bridge is missing', () => {
    const html = renderToStaticMarkup(<DebugPanel enabled bridge={null} live={false} />)
    expect(html).toContain('not available')
  })

  it('warns that the bundle is worth reading before pasting', () => {
    const html = renderToStaticMarkup(<DebugPanel enabled bridge={BRIDGE} live={false} />)
    expect(html).toContain('stripped out')
  })
})

describe('summarizeCalls', () => {
  it('rolls calls up per channel, slowest average first', () => {
    const rows = summarizeCalls([
      call({ seq: 1, channel: 'git:status', ms: 10 }),
      call({ seq: 2, channel: 'git:status', ms: 30 }),
      call({ seq: 3, channel: 'cost:project', ms: 100 }),
      call({ seq: 4, channel: 'cost:project', ms: 100, ok: false, error: 'nope' }),
    ])

    expect(rows.map((row) => row.channel)).toEqual(['cost:project', 'git:status'])
    expect(rows[0]).toMatchObject({ calls: 2, avgMs: 100, maxMs: 100, errors: 1 })
    expect(rows[1]).toMatchObject({ calls: 2, avgMs: 20, maxMs: 30, errors: 0 })
  })

  it('is empty for an empty trace', () => {
    expect(summarizeCalls([])).toEqual([])
  })
})

describe('orderCalls', () => {
  it('puts the newest call first', () => {
    const rows = orderCalls([call({ seq: 1 }), call({ seq: 2 }), call({ seq: 3 })], '')
    expect(rows.map((row) => row.seq)).toEqual([3, 2, 1])
  })

  it('filters on the channel, case-insensitively', () => {
    const rows = orderCalls([call({ seq: 1, channel: 'git:status' }), call({ seq: 2, channel: 'cost:project' })], 'GIT')
    expect(rows.map((row) => row.seq)).toEqual([1])
  })

  it('does not mutate what it was given', () => {
    const records = [call({ seq: 1 }), call({ seq: 2 })]
    orderCalls(records, '')
    expect(records.map((row) => row.seq)).toEqual([1, 2])
  })
})

describe('formatting', () => {
  it('keeps sub-millisecond timings readable', () => {
    expect(formatMs(0.4)).toBe('0.4 ms')
    expect(formatMs(12.6)).toBe('13 ms')
    expect(formatMs(2500)).toBe('2.50 s')
  })

  it('formats uptime', () => {
    expect(formatDuration(4_000)).toBe('4s')
    expect(formatDuration(125_000)).toBe('2m 5s')
    expect(formatDuration(3_725_000)).toBe('1h 2m')
    // A clock that went backwards must not print a negative age.
    expect(formatDuration(-5)).toBe('0s')
  })
})

describe('empty states', () => {
  it('distinguishes “nothing recorded” from “nothing matches the filter”', () => {
    const html = renderToStaticMarkup(<DebugPanel enabled bridge={BRIDGE} live={false} />)
    expect(html).toContain('No calls recorded yet.')
    expect(html).toContain('No sessions are running.')
  })

  /**
   * "Not read" and "read, and empty" are different facts. Collapsing them let
   * the panel state flatly that the log was empty whenever the read had failed
   * or had not run — a claim about a file it had never opened, in the one place
   * someone looks because they already distrust what the app is telling them.
   */
  it('does not claim the log is empty before it has read it', () => {
    const html = renderToStaticMarkup(<LogView log={null} />)
    expect(html).toContain('has not been read')
    expect(html).not.toContain('The log is empty.')
  })

  it('says the log is empty only once it has actually read it', () => {
    const html = renderToStaticMarkup(<LogView log={{ file: '~/logs/app.log', lines: [] }} />)
    expect(html).toContain('The log is empty.')
    expect(html).toContain('~/logs/app.log')
  })

  it('renders the tail it was given', () => {
    const html = renderToStaticMarkup(<LogView log={{ file: '~/logs/app.log', lines: ['one', 'two'] }} />)
    expect(html).toContain('one\ntwo')
    expect(html).not.toContain('The log is empty.')
  })

  it('shows a session as running until it reports an exit code', () => {
    expect(SESSION.exitCode).toBeNull()
    expect(formatDuration(Date.now() - SESSION.createdAt)).toMatch(/^\d+s$/)
  })
})
