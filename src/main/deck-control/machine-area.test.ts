import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { ServersIpc } from '../servers/ipc'
import { serverTools, type ServerToolsDeps } from '../servers/tools'
import { ActionLog } from './action-log'
import { machinesCoverage } from './actions/machines'
import { catalogueCost, MAX_CATALOGUE_TOKENS, type ToolSpec } from './catalogue'
import { createChannelTap, type TappableIpc } from './channel-tap'
import { ConsentBroker } from './consent'
import { DeckControl } from './control'
import { advertisedCatalogue, withDescribe } from './describe-tool'
import { createMachineArea, type MachineArea } from './machine-area'
import { ALL_TIERS, type DeckSurface } from './surface'

const SERVERS = { openShells: () => [], shellScreen: async () => null }

function areaTools(): ToolSpec[] {
  return createMachineArea().tools({ servers: SERVERS, userData: () => '/nowhere' })
}

describe('the machines area', () => {
  it('has a real tool behind every id the checklist names', () => {
    /*
     * `actions.test.ts` checks the shape of an id and not that it exists, so a
     * checklist entry naming a tool that was renamed — or never written — would
     * pass it. This closes that: every id in `actions/machines.ts` is a tool this
     * area or `servers/tools.ts` actually contributes.
     */
    const ids = new Set([...areaTools(), ...serverTools({} as ServerToolsDeps)].map((tool) => tool.id))
    const named = Object.values(machinesCoverage).flatMap((entry) => {
      if (entry === null || !('tool' in entry)) return []
      return typeof entry.tool === 'string' ? [entry.tool] : [...entry.tool]
    })
    expect(named.filter((id) => !ids.has(id))).toEqual([])
  })

  it('uses every tool it adds', () => {
    const named = new Set(
      Object.values(machinesCoverage).flatMap((entry) =>
        entry !== null && 'tool' in entry ? (typeof entry.tool === 'string' ? [entry.tool] : [...entry.tool]) : [],
      ),
    )
    expect(areaTools().filter((tool) => !named.has(tool.id)).map((tool) => tool.id)).toEqual([])
  })

  it('spells every wire name the dotted id with underscores, once', () => {
    const tools = areaTools()
    for (const tool of tools) expect(tool.wire).toBe(tool.id.replace(/\./g, '_'))
    expect(new Set(tools.map((tool) => tool.wire)).size).toBe(tools.length)
  })

  it('holds every tool behind tools.describe, so the standing cost is one line each', () => {
    const tools = areaTools()
    expect(tools.filter((tool) => tool.index === undefined).map((tool) => tool.id)).toEqual([])
    for (const tool of tools) expect(tool.index?.length ?? 0, `${tool.id}'s index line`).toBeLessThanOrEqual(160)
  })

  it('costs the shared catalogue what it says, and leaves it inside the ceiling', () => {
    /*
     * Measured 2026-10-03: fourteen index lines, 1,546 characters, **~442
     * estimated tokens** on every turn, and no advertised tool added. Pinned as a
     * ceiling rather than a figure because six other lanes land in the same
     * listing this release, and the number that matters to all of them is how
     * much of the room this area took.
     */
    const without = catalogueCost(advertisedCatalogue(withDescribe([...serverTools({} as ServerToolsDeps)])))
    const withArea = catalogueCost(advertisedCatalogue(withDescribe([...serverTools({} as ServerToolsDeps), ...areaTools()])))
    const added = withArea.tokens - without.tokens
    expect(withArea.tools).toBe(without.tools)
    expect(added).toBeLessThan(500)
    expect(withArea.tokens).toBeLessThanOrEqual(MAX_CATALOGUE_TOKENS)
  })

  it('reaches the very handler the window registered, through the dispatcher', async () => {
    const tap = createChannelTap()
    const ipc: TappableIpc = { handle: () => undefined, on: () => undefined }
    tap.attach(ipc)
    let asked = 0
    // What `registerMachinesIpc` does at boot, after the tap is on.
    ipc.handle('machines:list', () => {
      asked += 1
      return { machines: [], links: [], here: 'Mac mini', blocked: null }
    })
    const area = createMachineArea(tap)
    const logDir = mkdtempSync(join(tmpdir(), 'machine-area-'))
    try {
      const deck = new DeckControl({
        surface: {} as DeckSurface,
        log: new ActionLog({ dir: logDir }),
        consent: new ConsentBroker({ ask: () => false, timeoutMs: 10 }),
        extraTools: area.tools({ servers: null, userData: () => logDir }),
      })
      const result = await deck.call('machines.look', {}, { caller: { kind: 'local', tiers: ALL_TIERS } })
      expect(result.ok).toBe(true)
      expect(asked).toBe(1)
      expect(result.value).toEqual(expect.objectContaining({ thisComputer: 'Mac mini', machines: [] }))
    } finally {
      area.watch.dispose()
      rmSync(logDir, { recursive: true, force: true })
    }
  })

  it('takes index.ts’s own `servers` as it is', () => {
    // Compile-time: the wiring line passes `ServersIpc | null` straight through.
    const fits = (servers: ServersIpc | null): Parameters<MachineArea['tools']>[0]['servers'] => servers
    expect(typeof fits).toBe('function')
  })

  it('leaves the server-room tools out when the server room was never built', () => {
    const ids = createMachineArea().tools({ servers: null, userData: () => '/x' }).map((tool) => tool.id)
    expect(ids.some((id) => id.startsWith('servers.'))).toBe(false)
    expect(ids).toContain('machines.look')
  })
})
