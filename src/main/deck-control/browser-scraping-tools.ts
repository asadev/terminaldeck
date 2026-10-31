import type { ScrapeOutcome } from '../browser-scraping-ipc'
import type { LiftRequestRow } from '../browser-lift-requests'
import type { ProfileState } from '../browser-profiles'
import type { LiftSummary } from '../browser-session-lift'
import type { PaceSettings } from '../browser-worker-pool'
import {
  actionOf,
  escalateBy,
  notASession,
  optInt,
  optStr,
  profileIdOf,
  str,
} from './browser-area-kit'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * `browser.scraping` — the browser's Scraping panel: a profile's stored
 * scraping settings, what was measured, the fleet of worker profiles, and the
 * inbox of requests to copy a sign-in into them.
 *
 * ## What it gives, and the line it stops at
 *
 * Asad's boundary for the whole scraping feature still holds and this tool keeps
 * it: *"Don't build a full scraping framework inside a terminal app. The browser
 * should expose these capabilities cleanly; the orchestration can live
 * outside."* So what is here is the panel — the settings a profile's pages are
 * armed with, the counts that say whether a run got what it went for, the switch
 * that photographs a page when a site blocks it, and the worker profiles a run
 * uses — and nothing that runs a crawl. The crawl is whatever is calling this.
 *
 * ## The one thing on the panel this does not do: approve a lift
 *
 * The panel's inbox lists requests an agent made, through
 * `browser.lift_request`, to have a profile's signed-in session copied into the
 * workers; Approve copies it. This tool lists the inbox — who asked, from which
 * profile, into which workers, why — and **does not answer it**. An approval is a
 * person's answer to an agent's question about their logins, and a tool that
 * could give it would let the agent that asked approve itself, which is the
 * retry loop `browser-lift-requests.ts` priced at zero by making sure nothing an
 * agent reaches can answer. `forgetlift` is here, because throwing away a copied
 * session the person made is the safe direction.
 *
 * ## The tiers
 *
 * Reading is `read`; showing the capture folder in Finder is `act`; every
 * change — a setting, the fleet's size or pace, a worker added or removed, a
 * capture thrown away, a ledger emptied, a held session forgotten — is `alter`.
 */

/* --------------------------------------------------------------- the deps -- */

export interface ScrapingToolDeps {
  profiles(): ProfileState
  config(profileId: string): unknown
  setConfig(profileId: string, patch: Record<string, unknown>): unknown
  status(profileId: string): unknown
  clearCapture(profileId: string): ScrapeOutcome
  revealCapture(profileId: string): boolean
  clearLedgers(profileId: string): ScrapeOutcome
  blockShots(profileId: string): boolean
  setBlockShots(profileId: string, on: boolean): boolean
  workers(): readonly { profileId: string; name: string }[]
  maxWorkers: number
  ensureWorkers(count: number): readonly { profileId: string; name: string }[]
  addWorker(profileId: string): readonly { profileId: string; name: string }[]
  removeWorker(profileId: string): readonly { profileId: string; name: string }[]
  setPace(raw: Partial<PaceSettings>): { pace: PaceSettings; note: string }
  pace(): PaceSettings
  liftRequests(): readonly LiftRequestRow[]
  lifts(): readonly LiftSummary[]
  forgetLift(id: string): void
}

/* ------------------------------------------------------------- the schema -- */

const ACTIONS = [
  'config',
  'set',
  'status',
  'clearcapture',
  'showcapture',
  'clearledgers',
  'blockshots',
  'workers',
  'addworker',
  'removeworker',
  'pace',
  'forgetlift',
] as const
type Action = (typeof ACTIONS)[number]

const TIERS: Readonly<Record<Action, Tier>> = {
  config: 'read',
  set: 'alter',
  status: 'read',
  clearcapture: 'alter',
  showcapture: 'act',
  clearledgers: 'alter',
  blockshots: 'read',
  workers: 'alter',
  addworker: 'alter',
  removeworker: 'alter',
  pace: 'alter',
  forgetlift: 'alter',
}

const SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...ACTIONS], description: 'Default config.' },
    profile: {
      type: 'string',
      description: 'A profile name or id. Omit for the one switched on. For addworker and removeworker: the worker.',
    },
    patch: {
      type: 'object',
      description:
        'For set: only the groups and fields to change, in the shape config returns — requests, capture ' +
        '{on, keepMB}, assets {upgrade {on, from, to}, ledger {on, refetch}}, checks {coverage {on, pattern}, ' +
        'screenshotOnBlock}, fleet {concurrency, delayMs}. Anything not named is left as it is.',
    },
    on: { type: 'boolean', description: 'For blockshots: true photographs a page whenever a site blocks it. Omit to read it.' },
    count: { type: 'integer', description: 'For workers: the fewest worker profiles there should be. Never removes one.' },
    concurrency: { type: 'integer', description: 'For pace: most workers busy at once.' },
    delayMs: { type: 'integer', description: 'For pace: least time between two leases.' },
    jitterMs: { type: 'integer', description: 'For pace: random extra delay on top.' },
    lift: { type: 'string', description: 'For forgetlift: the held session’s id from status.' },
  },
  additionalProperties: false,
}

export function scrapingTools(deps: ScrapingToolDeps): ToolSpec[] {
  const tierFor = escalateBy(TIERS, 'config')
  const profileFrom = (args: Record<string, unknown>): { id: string; name: string } => {
    const state = deps.profiles()
    const id = profileIdOf(optStr(args, 'profile'), state.profiles, state.activeId)
    return { id, name: state.profiles.find((one) => one.id === id)?.name ?? id }
  }
  const nameOf = (id: string): string => deps.profiles().profiles.find((one) => one.id === id)?.name ?? id

  return [
    {
      id: 'browser.scraping',
      wire: 'browser_scraping',
      tier: 'read',
      title: 'The browser’s Scraping panel',
      description:
        'The browser’s Scraping panel, per profile (profile: a name or id; omit for the one switched on). ' +
        '"config" (the default) gives the stored settings: request rules, background capture, image ' +
        'upgrades and their ledger, the coverage check, and the worker fleet’s pace. "set" changes them ' +
        '(patch: only what changes, in the same shape). "status" gives what was measured — workers busy or ' +
        'idle, what was captured, the last check — plus the inbox of requests to copy a sign-in into the ' +
        'workers and the copied sessions still held. "clearcapture" throws captured runs away, ' +
        '"showcapture" opens their folder in Finder, "clearledgers" empties the image ledgers (files ' +
        'untouched). "blockshots" reads or sets (on) the photograph-when-blocked switch. "workers" makes ' +
        'sure there are at least count worker profiles (it never removes one), "addworker" and ' +
        '"removeworker" make a profile one or stop it being one, "pace" sets how fast they may be used, ' +
        'and "forgetlift" throws away a held ' +
        'copied session. Approving a copy request is the person’s, in the panel.',
      index:
        'Scraping panel: settings, measurements, block photos, worker profiles and pace, sign-in copy inbox.',
      inputSchema: SCHEMA,
      escalate: (args) => {
        if (args.action === 'blockshots' && typeof args.on === 'boolean') return 'alter'
        return tierFor(args)
      },
      precheck: (args, context: ToolContext) => {
        notASession(context, 'browser.scraping')
        const action = actionOf(args, ACTIONS, 'config')
        if (action === 'workers' || action === 'pace' || action === 'forgetlift') {
          if (action === 'workers' && typeof args.count !== 'number') {
            throw new Refused('not-permitted', `workers needs count: how many, from 0 to ${deps.maxWorkers}`)
          }
          if (action === 'forgetlift') {
            const id = str(args, 'lift')
            if (!deps.lifts().some((lift) => lift.id === id)) {
              throw new Refused('not-permitted', `there is no held session ${id}. status lists the ones there are.`)
            }
          }
          return
        }
        if (action === 'removeworker') {
          const profile = profileFrom({ profile: str(args, 'profile') })
          if (!deps.workers().some((worker) => worker.profileId === profile.id)) {
            throw new Refused('not-permitted', `${profile.name} is not a worker`)
          }
          return
        }
        if (action === 'addworker') str(args, 'profile')
        profileFrom(args)
        if (action === 'set') {
          const patch = args.patch
          if (typeof patch !== 'object' || patch === null || Array.isArray(patch) || Object.keys(patch).length === 0) {
            throw new Refused('not-permitted', 'set needs patch: the groups and fields to change, in the shape config returns')
          }
        }
      },
      summary: (args) => {
        const action = typeof args.action === 'string' ? args.action : 'config'
        const where = typeof args.profile === 'string' && args.profile !== '' ? ` for ${args.profile}` : ''
        switch (action) {
          case 'set': {
            const groups = typeof args.patch === 'object' && args.patch !== null ? Object.keys(args.patch) : []
            return `Change the scraping settings${where}: ${groups.join(', ') || 'nothing'}`
          }
          case 'clearcapture':
            return `Throw away the captured runs${where}`
          case 'showcapture':
            return `Show the capture folder${where} in Finder`
          case 'clearledgers':
            return `Empty the image ledgers${where} (the files stay)`
          case 'blockshots':
            return typeof args.on === 'boolean'
              ? `${args.on ? 'Photograph' : 'Stop photographing'} pages when a site blocks them${where}`
              : `Read the photograph-when-blocked switch${where}`
          case 'workers':
            return `Make sure there are at least ${typeof args.count === 'number' ? args.count : '?'} worker profiles`
          case 'addworker':
            return `Make ${typeof args.profile === 'string' ? args.profile : '?'} a worker profile`
          case 'removeworker':
            return `Stop ${typeof args.profile === 'string' ? args.profile : '?'} being a worker profile`
          case 'pace':
            return 'Change how fast worker profiles may be used'
          case 'forgetlift':
            return 'Throw away a copied signed-in session that is being held'
          case 'status':
            return `Read what the Scraping panel measured${where}`
          default:
            return `Read the scraping settings${where}`
        }
      },
      run: async (args): Promise<ToolOutput> => {
        const action = actionOf(args, ACTIONS, 'config')
        const fleet = (): Record<string, unknown> => ({
          workers: deps.workers().map((worker) => worker.name),
          pace: deps.pace(),
          most: deps.maxWorkers,
        })

        switch (action) {
          case 'config': {
            const profile = profileFrom(args)
            return {
              value: { profile: profile.name, config: deps.config(profile.id), blockShots: deps.blockShots(profile.id) },
              summary: { profile: profile.id },
            }
          }
          case 'set': {
            const profile = profileFrom(args)
            const stored = deps.setConfig(profile.id, args.patch as Record<string, unknown>)
            return {
              value: {
                profile: profile.name,
                // What was *stored*, which is clamped where the panel clamps —
                // so a value above what the store accepts comes back as the
                // number that was kept, not the number that was asked for.
                config: stored,
                note: 'Saved. The Scraping panel shows it when it is next opened; pages opened from now on are armed with it.',
              },
              summary: { profile: profile.id },
            }
          }
          case 'status': {
            const profile = profileFrom(args)
            return {
              value: {
                profile: profile.name,
                measured: deps.status(profile.id),
                copyRequests: deps.liftRequests().map((ask) => ({
                  askedBy: ask.askedBy,
                  from: nameOf(ask.fromProfileId),
                  into: ask.intoProfileIds.map(nameOf),
                  reason: ask.reason,
                  at: ask.at,
                })),
                heldSessions: deps.lifts().map((lift) => ({
                  lift: lift.id,
                  site: lift.host,
                  from: lift.sourceProfileName,
                  cookies: lift.cookieCount,
                  expiresAt: lift.expiresAt,
                })),
                ...fleet(),
              },
              summary: { profile: profile.id, requests: deps.liftRequests().length },
            }
          }
          case 'clearcapture':
          case 'clearledgers': {
            const profile = profileFrom(args)
            const outcome = action === 'clearcapture' ? deps.clearCapture(profile.id) : deps.clearLedgers(profile.id)
            if (!outcome.ok) throw new Refused('not-permitted', outcome.message)
            return { value: { profile: profile.name, ...outcome }, summary: { profile: profile.id, count: outcome.count } }
          }
          case 'showcapture': {
            const profile = profileFrom(args)
            const shown = deps.revealCapture(profile.id)
            if (!shown) throw new Refused('not-permitted', `${profile.name} has no capture folder this app can show`)
            return { value: { profile: profile.name, shown: true }, summary: { profile: profile.id } }
          }
          case 'blockshots': {
            const profile = profileFrom(args)
            const on = typeof args.on === 'boolean' ? deps.setBlockShots(profile.id, args.on) : deps.blockShots(profile.id)
            return { value: { profile: profile.name, blockShots: on }, summary: { profile: profile.id, on } }
          }
          case 'workers': {
            const count = optInt(args, 'count', 0, 0, deps.maxWorkers)
            deps.ensureWorkers(count)
            return { value: fleet(), summary: { workers: deps.workers().length } }
          }
          case 'addworker':
          case 'removeworker': {
            const profile = profileFrom({ profile: str(args, 'profile') })
            if (action === 'addworker') deps.addWorker(profile.id)
            else deps.removeWorker(profile.id)
            return { value: fleet(), summary: { workers: deps.workers().length } }
          }
          case 'pace': {
            const current = deps.pace()
            const asked: Partial<PaceSettings> = {
              maxConcurrent: typeof args.concurrency === 'number' ? args.concurrency : current.maxConcurrent,
              minDelayMs: typeof args.delayMs === 'number' ? args.delayMs : current.minDelayMs,
              jitterMs: typeof args.jitterMs === 'number' ? args.jitterMs : current.jitterMs,
            }
            const stored = deps.setPace(asked)
            return {
              value: { pace: stored.pace, ...(stored.note === '' ? {} : { note: stored.note }) },
              summary: { ...stored.pace },
            }
          }
          case 'forgetlift': {
            const id = str(args, 'lift')
            deps.forgetLift(id)
            return { value: { forgotten: id }, summary: { lift: id } }
          }
        }
        throw new Refused('not-permitted', `action must be one of: ${ACTIONS.join(', ')}`)
      },
    },
  ]
}
