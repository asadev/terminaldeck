/**
 * Stays Fixed: every action a person can take on a project's Stays Fixed page, and the tool that takes it.
 *
 * See `./types.ts` for what an entry means. These channels are new — the page
 * and its handlers in `staysfixed/ipc.ts` — and the preload gains them when the
 * integrator applies `WIRING-staysfixed.md`. Until then `actions.test.ts`
 * reports them as stale, which is that test noticing the preload is behind, not
 * this table being wrong; `fixed.test.ts` beside this file checks the table on
 * its own terms meanwhile.
 *
 * Every entry resolves to a `fixed.*` tool in `../fixed-tools.ts`, and every
 * one of those calls the same `StaysFixedService` method the channel's handler
 * calls. There are no skips: everything on the page is something an AI may be
 * asked to do, and the one act that must stay a person's — marking a build as
 * good — is a tool that always asks the owner, not a missing one.
 */

import type { Coverage, CoverageMap } from './types'

/** Every channel this area answers for, in the order `staysfixed/ipc.ts` documents them. */
export const FIXED_CHANNELS = [
  'staysfixed:status',
  'staysfixed:readiness',
  'staysfixed:setup',
  'staysfixed:check',
  'staysfixed:stop',
  'staysfixed:results',
  'staysfixed:mark-good',
  'staysfixed:agents',
] as const

type FixedChannel = (typeof FIXED_CHANNELS)[number]

const coverage: Readonly<Record<FixedChannel, Coverage>> = {
  'staysfixed:status': { tool: 'fixed.status' },
  // What this Mac can check here: the same answer, asked with `machine: true`.
  'staysfixed:readiness': { tool: 'fixed.status' },
  'staysfixed:setup': { tool: 'fixed.setup' },
  'staysfixed:check': { tool: 'fixed.check' },
  'staysfixed:stop': { tool: 'fixed.stop' },
  // The page's results and its Full report, which is `full: true`.
  'staysfixed:results': { tool: 'fixed.results' },
  'staysfixed:mark-good': { tool: 'fixed.mark_good' },
  'staysfixed:agents': { tool: 'fixed.agents' },
}

export const fixedCoverage: CoverageMap = coverage
