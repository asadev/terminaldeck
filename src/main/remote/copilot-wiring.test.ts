import { describe, expect, it } from 'vitest'
import type { ActionRow } from '../deck-control/action-log'
import type { ConsentRequest } from '../deck-control/consent'
import type { SessionMeta } from '../../shared/types'
import { tailForPhone, toCopilotRow, toCopilotSessions, toPendingRow } from './copilot-wiring'

/**
 * What crosses to a phone, and — mostly — what does not.
 *
 * Every assertion here about an *absent* field is the load-bearing one. The
 * rows this module builds are made out of this app's own audit record, and that
 * record carries the arguments of every tool call: the text typed into somebody's
 * sessions, the settings key and value about to be written, the path of a
 * transcript. A pass-through would send all of it, and a pass-through is what
 * anybody would write first.
 */

function row(over: Partial<ActionRow> = {}): ActionRow {
  return {
    v: 1,
    id: 'row-1',
    at: '2026-08-17T09:00:00.000Z',
    action: 'tool.sessions.send',
    tool: 'sessions.send',
    tier: 'act',
    detail: 'typed into api',
    args: { id: 'sess-1', text: 'deploy to production' },
    outcome: 'ok',
    confirmed: { required: false, granted: false, by: null, at: null, reason: null },
    caller: { kind: 'local' },
    ms: 12,
    result: null,
    error: null,
    ...over,
  }
}

describe('an action-log row loses its arguments on the way to a phone', () => {
  it('carries the sentence and drops everything that was typed', () => {
    const wire = toCopilotRow(row())
    expect(wire).toEqual({
      id: 'row-1',
      at: '2026-08-17T09:00:00.000Z',
      tool: 'sessions.send',
      tier: 'act',
      outcome: 'ok',
      detail: 'typed into api',
      refusal: null,
      deviceId: null,
    })
    // Said as its own assertion rather than left implicit in the deep-equal,
    // because this is the property and a future field added to the expected
    // object above would quietly weaken the check without touching this line.
    expect(JSON.stringify(wire)).not.toContain('deploy to production')
  })

  it('makes a refusal legible, in the desktop’s own vocabulary', () => {
    const wire = toCopilotRow(
      row({
        outcome: 'refused',
        confirmed: { required: false, granted: false, by: null, at: null, reason: 'not-granted' },
        caller: { kind: 'remote', deviceId: 'phone-1' },
      }),
    )
    expect(wire.outcome).toBe('refused')
    expect(wire.refusal).toBe('not-granted')
    expect(wire.deviceId).toBe('phone-1')
  })

  it('says null for a call the person at the machine caused', () => {
    expect(toCopilotRow(row({ caller: { kind: 'local' } })).deviceId).toBeNull()
    // A row from a build older than the caller field is not a local call, and
    // guessing that it was would put somebody else's device's action under the
    // owner's name.
    expect(toCopilotRow(row({ caller: undefined })).deviceId).toBeNull()
  })
})

describe('a waiting confirmation is watched, never answered', () => {
  it('carries the summary and the countdown, and not the arguments', () => {
    const request: ConsentRequest = {
      id: 'ask-1',
      tool: 'settings.write',
      tier: 'alter',
      summary: 'Change the default agent to Codex',
      args: { key: 'general.defaultProvider', value: 'codex' },
      requestedAt: 1_000,
      expiresAt: 121_000,
    }
    const wire = toPendingRow(request)
    expect(wire).toEqual({
      id: 'ask-1',
      tool: 'settings.write',
      summary: 'Change the default agent to Codex',
      requestedAt: 1_000,
      expiresAt: 121_000,
    })
    expect(JSON.stringify(wire)).not.toContain('codex')
    // The expiry travels so the phone counts down exactly as the desktop dialog
    // does. Two minutes is not extended for a phone: a longer window is how an
    // approval arrives six minutes later from somebody who has forgotten what
    // they were approving.
    expect(wire.expiresAt - wire.requestedAt).toBe(120_000)
  })
})

describe('the copilot’s sessions, and nobody else’s', () => {
  function session(over: Partial<SessionMeta> & { id: string }): SessionMeta {
    return {
      cwd: '/work/api',
      title: 'api',
      provider: 'claude',
      exitCode: null,
      createdAt: 1_000,
      ...over,
    }
  }

  it('lists only what the copilot started, with the turn that started it', () => {
    const rows = toCopilotSessions(
      [
        session({ id: 'mine', origin: undefined }),
        session({ id: 'theirs', origin: 'copilot', originRunId: 'row-9' }),
        // A session the person opened themselves, said explicitly as well as by
        // omission — `origin` is absent on most rows and `'user'` on some, and a
        // filter that only knew about the absent case would leak the other.
        session({ id: 'ours', origin: 'user' }),
      ],
      () => 'idle',
    )
    expect(rows.map((r) => r.id)).toEqual(['theirs'])
    expect(rows[0].originRunId).toBe('row-9')
  })

  it('says null rather than inventing a link for a session with no origin row', () => {
    const rows = toCopilotSessions([session({ id: 'a', origin: 'copilot' })], () => 'idle')
    expect(rows[0].originRunId).toBeNull()
  })
})

describe('the log tail is bounded and says when it was cut', () => {
  const rows = Array.from({ length: 500 }, (_, i) => row({ id: `row-${i}` }))

  it('answers the newest rows, newest last, and admits there are more', () => {
    const tail = tailForPhone(rows, { limit: 10 })
    expect(tail.rows.map((r) => r.id)).toEqual(
      Array.from({ length: 10 }, (_, i) => `row-${490 + i}`),
    )
    expect(tail.more).toBe(true)
  })

  it('does not claim there are more when the whole log fits', () => {
    expect(tailForPhone(rows.slice(0, 5), { limit: 10 }).more).toBe(false)
  })

  it('pages backwards from a row id the phone was already shown', () => {
    const tail = tailForPhone(rows, { limit: 3, before: 'row-100' })
    expect(tail.rows.map((r) => r.id)).toEqual(['row-97', 'row-98', 'row-99'])
  })

  it('treats an id this log has never held as “from the end”', () => {
    // The only way a phone holds an unknown id is to have paged past a
    // rotation, and answering that with the newest rows is what somebody
    // scrolling expects — an error would strand the pane.
    const tail = tailForPhone(rows, { limit: 2, before: 'row-from-a-rotated-file' })
    expect(tail.rows.map((r) => r.id)).toEqual(['row-498', 'row-499'])
  })

  it('clamps a limit past what a relay should carry, and one below one', () => {
    expect(tailForPhone(rows, { limit: 100_000 }).rows.length).toBe(200)
    expect(tailForPhone(rows, { limit: 0 }).rows.length).toBe(1)
  })
})
