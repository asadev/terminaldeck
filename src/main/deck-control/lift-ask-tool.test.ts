/**
 * `browser.lift_request` — the ask that must never become the act.
 *
 * Driven through a real `DeckControl` rather than by calling `run` by hand,
 * because the audit of 2026-08-22 overturned a row of "done"s whose only proof
 * was a unit test on a function nothing calls. Here the tool is registered the
 * way `index.ts` registers it — inside `workerTools()` — and called over the
 * same dispatch a session's MCP endpoint uses.
 *
 * What is pinned, in order of what it would cost to lose:
 *
 *  1. filing an ask moves nothing — no lift, no jar, no cookie anywhere in the
 *     answer, only a row the person's inbox now holds;
 *  2. the retry loop buys the same row back, and the result says so;
 *  3. the two caller gates every worker tool keeps — no paired devices, no
 *     unattended runs — hold here too;
 *  4. the asker is named in panel vocabulary (a window slot), never an id.
 */

import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { attach, resetForTests } from '../browser-binding'
import {
  configureLiftRequests,
  listLiftRequests,
  resetLiftRequestsForTests,
} from '../browser-lift-requests'
import { ActionLog } from './action-log'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import { askerName } from './lift-ask-tool'
import type { ToolContext } from './catalogue'
import { ALL_TIERS as ALL, type Caller, type DeckSurface } from './surface'
import { workerTools, type WorkerToolDeps } from './worker-tools'

const session: Caller = { kind: 'session', sessionId: 's1', machineId: '', tiers: ALL }
const phone: Caller = { kind: 'remote', deviceId: 'd1', tiers: ALL }

function deps(): WorkerToolDeps {
  return {
    list: () => [
      { profileId: 'w1', name: 'Worker 1', partition: 'persist:w1', busy: false, holder: '', readyInMs: 0 },
    ],
    pace: () => ({ maxConcurrent: 1, minDelayMs: 0, jitterMs: 0 }),
    workerOfView: () => null,
    injectionsFor: () => [],
    take: async () => ({ ok: false, reason: 'not under test' }),
    release: () => false,
    renew: () => false,
  }
}

function control(dir: string): DeckControl {
  const broker: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      broker.respond(request.id, true, WINDOW_SURFACE)
      return true
    },
    timeoutMs: 50,
  })
  return new DeckControl({
    surface: {} as DeckSurface,
    log: new ActionLog({ dir }),
    consent: broker,
    extraTools: workerTools(deps()),
  })
}

let dir = ''
let notified = 0

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-lift-ask-'))
  resetForTests()
  resetLiftRequestsForTests()
  notified = 0
  configureLiftRequests({
    profiles: () => [
      { id: 'p-default', name: 'Default' },
      { id: 'w1', name: 'Worker 1' },
    ],
    workers: () => [{ id: 'w1', name: 'Worker 1' }],
    notify: () => {
      notified += 1
    },
  })
})

afterEach(() => {
  resetLiftRequestsForTests()
  rmSync(dir, { recursive: true, force: true })
})

describe('the ask, over the real dispatch', () => {
  it('files a row the person will see, and moves nothing', async () => {
    const deck = control(dir)
    const result = await deck.call(
      'browser_lift_request',
      { from: 'Default', reason: 'The marina run needs signed-in workers.' },
      { caller: session },
    )
    expect(result.ok).toBe(true)
    const value = result.value as Record<string, unknown>
    expect(value.asked).toBe(true)
    expect(value.repeated).toBe(false)
    expect(value.from).toBe('Default')
    expect(value.into).toEqual(['Worker 1'])
    // The row is real and in the inbox the panel reads.
    const inbox = listLiftRequests()
    expect(inbox).toHaveLength(1)
    expect(inbox[0].reason).toBe('The marina run needs signed-in workers.')
    expect(notified).toBe(1)
    // And nothing moved: no jar was touched anywhere in this suite's setup,
    // and the answer tells the agent so in words that stop a retry.
    expect(String(value.note)).toContain('Do not retry')
  })

  it('hands the same row back on a repeat, which is what makes the retry loop worthless', async () => {
    const deck = control(dir)
    const first = await deck.call('browser_lift_request', { from: 'Default' }, { caller: session })
    const again = await deck.call('browser_lift_request', { from: 'Default' }, { caller: session })
    expect(again.ok).toBe(true)
    const value = again.value as Record<string, unknown>
    expect(value.repeated).toBe(true)
    expect(value.requestId).toBe((first.value as Record<string, unknown>).requestId)
    expect(listLiftRequests()).toHaveLength(1)
  })

  it('refuses an unknown profile with the desk’s sentence, not an empty success', async () => {
    const deck = control(dir)
    const result = await deck.call('browser_lift_request', { from: 'Nope' }, { caller: session })
    expect(result.ok).toBe(false)
    expect(result.error).toContain('no profile called "Nope"')
    expect(listLiftRequests()).toHaveLength(0)
  })

  it('refuses a paired device — asking for a person’s logins is not a remote verb', async () => {
    const deck = control(dir)
    const result = await deck.call('browser_lift_request', { from: 'Default' }, { caller: phone })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
    expect(listLiftRequests()).toHaveLength(0)
  })

  it('refuses an unattended run — an inbox nobody is at is not consent-in-waiting', async () => {
    const deck = control(dir)
    const result = await deck.call(
      'browser_lift_request',
      { from: 'Default' },
      { caller: session, attended: false },
    )
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted-unattended')
    expect(result.error).toContain('Do not retry')
    expect(listLiftRequests()).toHaveLength(0)
  })
})

describe('who the row says asked', () => {
  const context = (caller: Caller): ToolContext =>
    ({ caller, attended: true } as unknown as ToolContext)

  it('names the caller’s window slot — the panel’s own vocabulary', () => {
    attach({ sessionId: 's1', browserTabId: 'tab-a', viewId: 'view-a' })
    expect(askerName(context(session))).toBe('The session driving B1')
  })

  it('never prints a session id at a person', () => {
    expect(askerName(context(session))).toBe('A session in this app')
    expect(askerName(context(session))).not.toContain('s1')
  })

  it('names the copilot as itself', () => {
    expect(askerName(context({ kind: 'local', tiers: ALL }))).toBe('The copilot')
  })
})
