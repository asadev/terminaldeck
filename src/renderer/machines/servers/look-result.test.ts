import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { asView, lookResult } from './types'

/**
 * Reading a `servers:look` reply. It is `{ ok: true, view }` — the view one
 * level down — or `{ ok: false, sentence }`. Settings' server accounts read the
 * whole reply as the view, found no facts on it, and said every server "was not
 * asked about coding agents" right after asking it.
 */

const VIEW = {
  cards: [],
  facts: {
    agents: { known: 'yes', value: [{ id: 'claude', path: '/usr/bin/claude', version: '1.0.0', signedIn: 'yes', account: 'a@b.c' }], measuredAt: 5, how: 'looked' },
  },
  offered: {},
  absent: {},
  how: [],
  cannot: [],
  measuredAt: 5,
}

describe('a servers:look reply', () => {
  it('is read from the view it carries, with its facts', () => {
    const result = lookResult({ ok: true, view: VIEW }, 'box')
    expect(result.state).toBe('ready')
    if (result.state !== 'ready') return
    expect(result.view.facts.agents).toBeDefined()
    expect(result.view.measuredAt).toBe(5)
  })

  it('was not the view itself — read that way, every fact went missing', () => {
    expect(asView({ ok: true, view: VIEW })?.facts.agents).toBeUndefined()
  })

  it('says the server’s own sentence when it refused, and owns up to an answer it cannot read', () => {
    expect(lookResult({ ok: false, sentence: 'The host key changed.', detail: '' }, 'box')).toEqual({
      state: 'failed',
      problem: 'The host key changed.',
    })
    expect(lookResult({ ok: true, view: 'nonsense' }, 'box')).toEqual({
      state: 'failed',
      problem: 'box answered with something this build cannot read.',
    })
  })

  it('is how Settings’ server accounts read it, as the Machines page already did', () => {
    const accounts = readFileSync(join(__dirname, '../../settings/sections/ServerAccounts.tsx'), 'utf8')
    expect(accounts).toContain('const result = lookResult(raw, server.name)')
    expect(accounts).not.toMatch(/asView\(raw\)/)
    const machines = readFileSync(join(__dirname, 'useServers.ts'), 'utf8')
    expect(machines).toContain('asView((raw as { view?: unknown }).view)')
  })
})
