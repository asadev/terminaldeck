import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ServerGrants } from '../servers/grants'
import { fakeRoom } from '../servers/test-fixtures'
import { serverTools } from '../servers/tools'
import { tiersFor, type AccessLevel } from './access-keys'
import { ActionLog } from './action-log'
import { hereOnly } from './area-shared'
import { assembledCatalogue } from './assembled-catalogue.fixture'
import { fillMustBeAnswered } from './browser-password-tools'
import { mayDrive } from './browser-tools'
import type { ToolContext, ToolSpec } from './catalogue'
import { ConsentBroker, type ConsentRequest } from './consent'
import { DeckControl, standingApproval } from './control'
import { askerName, liftAskTool } from './lift-ask-tool'
import { keyRig } from './key-door.fixture'
import { tourTool } from './tour-tool'
import type { TourStage } from './tour-stage'
import { workerTools } from './worker-tools'
import { actsAsOwner, type Caller } from './surface'

/**
 * What an AI app holding an access key may reach beyond the session tools: the
 * machines area, the browser, worker profiles, the ask for logins, and
 * `servers.control` — as the owner, bounded by its level — and the three things
 * that stay the person's even for a key.
 *
 * The gates are asked directly here, with the context they read, because each
 * one is a single condition and the property is the condition: a key passes, a
 * paired device and an ordinary session do not. The two rules decided for keys
 * — a password fill is always put to a person, and a server terminal needs Full
 * control and honours ask-first — go through the real dispatcher, because they
 * are properties of what `DeckControl.call` does with a tool, not of the tool.
 */

function key(level: AccessLevel, extra: Partial<Caller> = {}): Caller {
  return { kind: 'key', keyId: 'k1', keyName: 'ChatGPT', tiers: tiersFor(level), ...extra }
}
const local: Caller = { kind: 'local', tiers: tiersFor('full') }
const remote: Caller = { kind: 'remote', deviceId: 'phone-1', tiers: tiersFor('full') }
const session: Caller = { kind: 'session', sessionId: 's1', machineId: '', tiers: tiersFor('work') }

function contextFor(caller: Caller, attended = true): ToolContext {
  return { caller, attended } as unknown as ToolContext
}

describe('who acts as the owner', () => {
  it('is the person here and an AI app on a key, and nobody else', () => {
    expect(actsAsOwner(local)).toBe(true)
    expect(actsAsOwner(key('look'))).toBe(true)
    expect(actsAsOwner(remote)).toBe(false)
    expect(actsAsOwner(session)).toBe(false)
  })
})

describe('the gates that used to say "local only"', () => {
  it('lets a key into the machines area, and still refuses a paired device', () => {
    expect(() => hereOnly(key('look'), 'Looking at the other computers')).not.toThrow()
    expect(() => hereOnly(remote, 'Looking at the other computers')).toThrow(/A paired device cannot/)
    expect(() => hereOnly(session, 'Looking at the other computers')).toThrow()
  })

  it('lets a key drive the browser, and still refuses a paired device and an unwatched run', () => {
    expect(() => mayDrive(contextFor(key('work')), 'browser.open')).not.toThrow()
    expect(() => mayDrive(contextFor(remote), 'browser.open')).toThrow(/only works for the person/)
    expect(() => mayDrive(contextFor(key('work'), false), 'browser.open')).toThrow(/nobody at the machine/)
  })

  it('lets a key use worker profiles, holding its own leases', async () => {
    const taken: string[] = []
    const tools = workerTools({
      pool: {
        take: (holder: string) => {
          taken.push(holder)
          return { ok: false, reason: 'none free' }
        },
      },
    } as never)
    const worker = tools.find((spec) => spec.id === 'browser.worker') as ToolSpec
    expect(() => worker.precheck?.({ action: 'take' }, contextFor(key('work')))).not.toThrow()
    expect(() => worker.precheck?.({ action: 'take' }, contextFor(remote))).toThrow(/only works for the person/)
  })

  it('lets a key ask for a login lift, named by its key in the inbox', () => {
    const lift = liftAskTool()
    expect(() => lift.precheck?.({ from: 'Default' }, contextFor(key('work')))).not.toThrow()
    expect(() => lift.precheck?.({ from: 'Default' }, contextFor(remote))).toThrow(/paired device/)
    expect(askerName(contextFor(key('work')))).toBe('“ChatGPT”, an AI app you gave a key to')
  })

  it('lets a key reach servers.control, never riding the copilot’s grant on a server', () => {
    const grants = new ServerGrants()
    grants.grant('s1', local)
    const tool = serverTools({ room: fakeRoom(), grants }).find((spec) => spec.id === 'servers.control') as ToolSpec
    const call = { serverId: 's1', cardId: 'service:td-scratch.service', action: 'restart' }
    expect(() => tool.precheck?.(call, contextFor(key('full')))).not.toThrow()
    expect(() => tool.precheck?.(call, contextFor(remote))).toThrow(/only works for the person/)
    // The copilot's grant makes this `act` for the copilot; a key always asks for alter.
    expect(tool.escalate?.({ serverId: 's1' }, contextFor(local))).toBe('act')
    expect(tool.escalate?.({ serverId: 's1' }, contextFor(key('full')))).toBe('alter')
  })

  it('still refuses a key a tour, which needs somebody watching the screen', () => {
    const tour = tourTool({} as TourStage)
    expect(() => tour.precheck?.({ question: 'what happened', stops: [] }, contextFor(key('full')))).toThrow(
      /only runs for the person sitting at this machine/,
    )
  })
})

describe('what a key reaches is still bounded by its level', () => {
  let dir = ''
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'td-key-reach-'))
  })
  afterEach(() => rmSync(dir, { recursive: true, force: true }))

  it('refuses a Look only key every machines change, at the tier, before anything runs', async () => {
    const rig = keyRig(dir)
    const { id } = rig.key('look')
    const caller: Caller = { kind: 'key', keyId: id, keyName: 'x', tiers: tiersFor('look'), askFirst: true }
    const result = await rig.control.call('settings.write', { scope: 'settings', patch: { 'appearance.density': 'compact' } }, { caller })
    expect(result.refusal).toBe('not-granted')
    rig.door.stop()
  })
})

/* ------------------------------------------------- the two decided rules -- */

/**
 * A dispatcher over two stand-in tools shaped like the real ones: an `alter`
 * tool with no exemption (a server terminal), and a multi-verb tool whose
 * `fill` must be answered (saved passwords). The real specs' own flags are
 * pinned against the assembled catalogue below, so a stand-in cannot drift
 * from them unnoticed.
 */
function rigWith(answer: boolean | null): { control: DeckControl; asked: ConsentRequest[]; ran: string[]; dir: string } {
  const dir = mkdtempSync(join(tmpdir(), 'td-key-rules-'))
  const asked: ConsentRequest[] = []
  const ran: string[] = []
  const consent: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      asked.push(request)
      if (answer === null) return true
      queueMicrotask(() => consent.respond(request.id, answer, 'device:his-phone'))
      return true
    },
    timeoutMs: 50,
  })
  const tool = (id: string, extra: Partial<ToolSpec> = {}): ToolSpec => ({
    id,
    wire: id.replace(/\./g, '_'),
    tier: 'alter',
    title: id,
    description: id,
    inputSchema: { type: 'object', properties: { action: { type: 'string' } }, additionalProperties: false },
    summary: () => `Run ${id}`,
    run: async () => {
      ran.push(id)
      return { value: { ok: true }, summary: {} }
    },
    ...extra,
  })
  const control = new DeckControl({
    surface: {} as never,
    log: new ActionLog({ dir }),
    consent,
    extraTools: [
      tool('servers.shellish'),
      tool('browser.passwordsish', { tier: 'read', ownerMustAnswer: fillMustBeAnswered }),
    ],
  })
  return { control, asked, ran, dir }
}

describe('a saved-password fill is always put to the owner', () => {
  it('asks even when the key is set not to ask, and runs only on his answer', async () => {
    const rig = rigWith(true)
    const caller = key('full', { askFirst: false })
    const result = await rig.control.call('browser.passwordsish', { action: 'fill' }, { caller })
    expect(rig.asked.map((question) => question.tool)).toEqual(['browser.passwordsish'])
    expect(result.ok).toBe(true)
    expect(result.row.confirmed.by).toBe('device:his-phone')
    rmSync(rig.dir, { recursive: true, force: true })
  })

  it('refuses when nobody answers, and needs Full control to be asked at all', async () => {
    const rig = rigWith(null)
    const silent = await rig.control.call('browser.passwordsish', { action: 'fill' }, { caller: key('full', { askFirst: false }) })
    expect(silent.refusal).toBe('timeout')
    const work = await rig.control.call('browser.passwordsish', { action: 'fill' }, { caller: key('work', { askFirst: false }) })
    expect(work.refusal).toBe('not-granted')
    expect(rig.ran).toEqual([])
    rmSync(rig.dir, { recursive: true, force: true })
  })

  it('leaves the rest of the tool alone: a list is still a read', async () => {
    const rig = rigWith(null)
    const listed = await rig.control.call('browser.passwordsish', { action: 'list' }, { caller: key('look') })
    expect(listed.ok).toBe(true)
    expect(rig.asked).toEqual([])
    rmSync(rig.dir, { recursive: true, force: true })
  })
})

describe('a server terminal needs Full control and honours ask-first', () => {
  it('is refused to a Work key', async () => {
    const rig = rigWith(true)
    const result = await rig.control.call('servers.shellish', {}, { caller: key('work') })
    expect(result.refusal).toBe('not-granted')
    rmSync(rig.dir, { recursive: true, force: true })
  })

  it('asks a Full control key that asks first', async () => {
    const rig = rigWith(true)
    const result = await rig.control.call('servers.shellish', {}, { caller: key('full', { askFirst: true }) })
    expect(rig.asked).toHaveLength(1)
    expect(result.ok).toBe(true)
    rmSync(rig.dir, { recursive: true, force: true })
  })

  it('runs for a Full control key set not to ask, and writes that down', async () => {
    const rig = rigWith(null)
    const result = await rig.control.call('servers.shellish', {}, { caller: key('full', { askFirst: false }) })
    expect(rig.asked).toEqual([])
    expect(result.ok).toBe(true)
    expect(result.row.confirmed.by).toBe(standingApproval('k1'))
    rmSync(rig.dir, { recursive: true, force: true })
  })
})

describe('the real tools carry the flags the stand-ins above assume', () => {
  const catalogue = assembledCatalogue()
  const find = (id: string): ToolSpec => {
    const spec = catalogue.find((entry) => entry.id === id)
    if (!spec) throw new Error(`${id} is missing`)
    return spec
  }

  it('marks a password fill, and only a fill, as the owner’s to answer', () => {
    const passwords = find('browser.passwords')
    expect(passwords.ownerMustAnswer?.({ action: 'fill' })).toBe(true)
    expect(passwords.ownerMustAnswer?.({ action: 'list' })).toBe(false)
    expect(passwords.ownerMustAnswer?.({})).toBe(false)
  })

  it('keeps servers.shell at alter with nothing that lowers it or forces the question', () => {
    const shell = find('servers.shell')
    expect(shell.tier).toBe('alter')
    expect(shell.ownerMustAnswer).toBeUndefined()
  })

  it('puts every change of who can reach this computer to the owner, whatever a key says', () => {
    for (const id of ['remote.manage', 'machines.manage']) {
      expect(find(id).ownerMustAnswer?.({ do: 'show-code' }), id).toBe(true)
    }
  })
})
