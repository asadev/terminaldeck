import { describe, expect, it, vi } from 'vitest'
import type { ProfileState } from '../browser-profiles'
import type { ToolContext } from './catalogue'
import { scrapingTools, type ScrapingToolDeps } from './browser-scraping-tools'
import { signInTools, type SignInToolDeps } from './browser-signin-tools'
import { LOCAL_CALLER } from './surface'

const DESK = { caller: LOCAL_CALLER, attended: true } as unknown as ToolContext
const PHONE = { caller: { kind: 'remote', deviceId: 'd1', tiers: LOCAL_CALLER.tiers }, attended: true } as unknown as ToolContext

const STATE: ProfileState = {
  profiles: [
    { id: 'default', name: 'Default', partition: 'p', createdAt: 1, isDefault: true, avatar: '' },
    { id: 'w1', name: 'Worker 1', partition: 'p1', createdAt: 1, isDefault: false, avatar: '' },
  ],
  activeId: 'default',
}

function deps(over: Partial<ScrapingToolDeps> = {}): ScrapingToolDeps {
  const pace = { maxConcurrent: 2, minDelayMs: 500, jitterMs: 100 }
  return {
    profiles: () => STATE,
    config: () => ({ capture: { on: true } }),
    setConfig: (_id, patch) => patch,
    status: () => ({ workers: [] }),
    clearCapture: () => ({ ok: true, message: '2 capture runs thrown away.', count: 2 }),
    revealCapture: () => true,
    clearLedgers: () => ({ ok: true, message: 'This profile has no ledger to empty.', count: 0 }),
    blockShots: () => false,
    setBlockShots: (_id, on) => on,
    workers: () => [{ profileId: 'w1', name: 'Worker 1' }],
    maxWorkers: 8,
    ensureWorkers: () => [],
    addWorker: () => [],
    removeWorker: () => [],
    setPace: (raw) => ({ pace: { ...pace, ...raw }, note: '' }),
    pace: () => pace,
    liftRequests: () => [
      { id: 'r1', askedBy: 'The session driving B1', fromProfileId: 'default', intoProfileIds: ['w1'], reason: 'sign in the fleet', at: 3 },
    ],
    lifts: () => [],
    forgetLift: () => undefined,
    ...over,
  }
}

describe('browser.scraping', () => {
  it('reads at read, changes at alter, and photographs-when-blocked only alters when it is told to', () => {
    const [tool] = scrapingTools(deps())
    expect(tool.escalate?.({}, DESK)).toBe('read')
    expect(tool.escalate?.({ action: 'status' }, DESK)).toBe('read')
    expect(tool.escalate?.({ action: 'showcapture' }, DESK)).toBe('act')
    expect(tool.escalate?.({ action: 'blockshots' }, DESK)).toBe('read')
    expect(tool.escalate?.({ action: 'blockshots', on: true }, DESK)).toBe('alter')
    for (const action of ['set', 'clearcapture', 'clearledgers', 'workers', 'addworker', 'removeworker', 'pace', 'forgetlift']) {
      expect(tool.escalate?.({ action }, DESK), action).toBe('alter')
    }
  })

  it('lists the sign-in copy inbox by name, and has no way to approve one', async () => {
    const [tool] = scrapingTools(deps())
    const out = (await tool.run({ action: 'status' }, DESK)).value as { copyRequests: Record<string, unknown>[] }
    expect(out.copyRequests[0]).toMatchObject({ from: 'Default', into: ['Worker 1'], reason: 'sign in the fleet' })
    const actions = (tool.inputSchema.properties as { action: { enum: string[] } }).action.enum
    expect(actions.some((action) => /^(approve|answer|lift|inject|liftanswer)$/.test(action))).toBe(false)
  })

  it('stores a patch and answers with what was stored', async () => {
    const setConfig = vi.fn<ScrapingToolDeps['setConfig']>(() => ({ capture: { keepMB: 64 } }))
    const [tool] = scrapingTools(deps({ setConfig }))
    const out = (await tool.run({ action: 'set', patch: { capture: { keepMB: 999 } } }, DESK)).value as { config: unknown }
    expect(setConfig).toHaveBeenCalledWith('default', { capture: { keepMB: 999 } })
    expect(out.config).toEqual({ capture: { keepMB: 64 } })
  })

  it('refuses an empty patch before anybody is asked', () => {
    const [tool] = scrapingTools(deps())
    expect(() => tool.precheck?.({ action: 'set', patch: {} }, DESK)).toThrow('set needs patch')
  })

  it('keeps the pace fields it was not given', async () => {
    const setPace = vi.fn<ScrapingToolDeps['setPace']>((raw) => ({ pace: raw as never, note: '' }))
    const [tool] = scrapingTools(deps({ setPace }))
    await tool.run({ action: 'pace', concurrency: 4 }, DESK)
    expect(setPace).toHaveBeenCalledWith({ maxConcurrent: 4, minDelayMs: 500, jitterMs: 100 })
  })

  it('refuses to stop a profile being a worker when it is not one', () => {
    const [tool] = scrapingTools(deps())
    expect(() => tool.precheck?.({ action: 'removeworker', profile: 'Default' }, DESK)).toThrow('is not a worker')
  })
})

describe('browser.signin', () => {
  const signin = (over: Partial<SignInToolDeps> = {}): SignInToolDeps => ({
    diagnose: () => ({ kind: 'google-embedded', headline: 'Google refuses', detail: 'Open it outside.', domains: ['google.com'] }) as never,
    handover: async (url) => ({ url, domains: ['example.com', 'google.com'] }),
    agents: async () => [],
    ...over,
  })

  it('diagnoses at read and hands over at act', () => {
    const [tool] = signInTools(signin())
    expect(tool.escalate?.({ url: 'https://a' }, DESK)).toBe('read')
    expect(tool.escalate?.({ action: 'handover', url: 'https://a' }, DESK)).toBe('act')
  })

  it('refuses a paired device a handover, which opens his own browser', () => {
    const [tool] = signInTools(signin())
    expect(() => tool.precheck?.({ action: 'handover', url: 'https://accounts.google.com' }, PHONE)).toThrow(
      'only works for the person at this machine',
    )
    // A diagnosis reads nothing but the address it is given.
    expect(() => tool.precheck?.({ url: 'https://accounts.google.com' }, PHONE)).not.toThrow()
  })

  it('says which sites to bring back once the person has signed in outside', async () => {
    const [tool] = signInTools(signin())
    const out = (await tool.run({ action: 'handover', url: 'https://example.com/login' }, DESK)).value as { bringBack: string[]; note: string }
    expect(out.bringBack).toEqual(['example.com', 'google.com'])
    expect(out.note).toContain('browser.import')
  })
})
