import { describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import { serverTools, type ServerToolsDeps } from '../servers/tools'
import { agentsAreaTools, type AgentsAreaDeps } from './agents-area'
import { assetTools } from './asset-tools'
import { dataTools, importTools } from './browser-data-tools'
import { downloadTools } from './browser-download-tools'
import { historyTools, profileTools } from './browser-history-tools'
import { browserNetworkTool } from './browser-network-tool'
import { passwordTools } from './browser-password-tools'
import { scrapingTools } from './browser-scraping-tools'
import { signInTools } from './browser-signin-tools'
import { browserTools } from './browser-tools'
import { windowTools } from './browser-window-tools'
import { buildCatalogue, type ToolSpec } from './catalogue'
import { communityTools } from './community-tools'
import { copilotAdminTools, type CopilotAdminDeps } from './copilot-admin-tools'
import { coverageTool } from './coverage-tool'
import { withDescribe } from './describe-tool'
import { extensionTools } from './extension-tools'
import { filesTools, type FilesToolDeps } from './files-tools'
import { createMachineArea } from './machine-area'
import { projectTools, type ProjectToolDeps } from './project-tools'
import { sessionMoreTools, type SessionMoreDeps } from './session-more-tools'
import { storeTools } from './store-tools'
import { toolsStoreTools } from './tools-store-tools'
import { tourTool } from './tour-tool'
import type { TourStage } from './tour-stage'
import { uiTools } from './ui-tools'
import { whereTool } from './where-tool'
import { workerTools } from './worker-tools'

/**
 * Every tool the app assembles, from every source, as one list — and no two of
 * them with one name.
 *
 * ## Why this is its own test
 *
 * `DeckControl` refuses a catalogue in which two tools share an id or a wire
 * name, and it refuses by throwing in its constructor. In the running app that
 * constructor is inside `registerDeckControlIpc`, whose rejection
 * `src/main/index.ts` catches and logs as *"failed to start, copilot tools
 * disabled"*. So a clash between two areas does not fail a build or a test of
 * either area: it turns the whole tool server off at boot, for every caller,
 * with the app otherwise looking normal. Four lanes built their areas in
 * parallel and each could only check its own names; this is the one place
 * they are checked together.
 *
 * The factories are given stand-ins, because a tool's id and wire name are
 * literals in its factory — nothing here calls a `run`. The list mirrors the
 * `extraTools` in `src/main/index.ts` and the two tools `deck-control/index.ts`
 * adds; a source added there and not here is the gap this file exists to close,
 * so add it here in the same change.
 *
 * What this deliberately does not do is measure the cost of the listing. That
 * is `catalogue-cost.test.ts`, and the budget it guards is being redesigned
 * (a per-area index behind `tools.describe`) by the lane that owns it.
 */
/** A dep whose every member is a function that does nothing — for a definition that reads none. */
function inert(): object {
  return new Proxy({}, { get: () => () => undefined })
}

function inertDeps(keys: readonly string[]): Record<string, object> {
  return Object.fromEntries(keys.map((key) => [key, inert()]))
}

function assembled(): ToolSpec[] {
  return withDescribe([
    // The built-ins, and the two `deck-control/index.ts` contributes.
    ...buildCatalogue(),
    tourTool({} as TourStage),
    whereTool({ window: { read: async () => null }, page: () => null }),
    // What `src/main/index.ts` hands in as `extraTools`, in its order.
    ...browserTools({} as BrowserDrive),
    browserNetworkTool({} as BrowserDrive),
    ...workerTools({} as never),
    ...assetTools({
      userData: () => '/tmp',
      probe: async () => ({}) as never,
      open: () => {
        throw new Error('this file checks names; it does not fetch')
      },
    }),
    ...storeTools({ drive: {} as BrowserDrive, installed: () => [] }),
    ...extensionTools({} as never),
    ...serverTools({} as ServerToolsDeps),
    ...createMachineArea().tools({ servers: { openShells: () => [], shellScreen: async () => null }, userData: () => '/tmp' }),
    // Two of its deps are read by a definition — the hook providers and the
    // readiness fix ids are enums its schemas advertise — so those two are real.
    ...agentsAreaTools({
      ...inertDeps(['agents', 'accounts', 'mcp', 'routines', 'app', 'usage', 'voice']),
      hooks: { ...inert(), providers: ['claude', 'codex', 'gemini'] },
      setup: { ...inert(), fixIds: new Set<string>() },
    } as unknown as AgentsAreaDeps),
    // `browserAreaTools`, factory by factory.
    ...windowTools({} as never),
    ...downloadTools({} as never),
    ...historyTools({} as never),
    ...profileTools({} as never),
    ...passwordTools({} as never),
    ...dataTools({} as never),
    ...importTools({} as never),
    ...signInTools({} as never),
    ...scrapingTools({} as never),
    ...toolsStoreTools({} as never),
    ...communityTools({} as never),
    // `sessionsLaneTools`, factory by factory.
    ...sessionMoreTools({} as SessionMoreDeps),
    ...projectTools({} as ProjectToolDeps),
    ...filesTools({} as FilesToolDeps),
    ...copilotAdminTools({} as CopilotAdminDeps),
    ...uiTools({ evaluate: async () => null }),
    coverageTool(),
  ])
}

describe('the catalogue every area assembles into', () => {
  it('has no two tools answering to one name, which would turn the tool server off at boot', () => {
    // One map, both spellings — the shape `DeckControl` registers them in.
    const names = assembled().flatMap((spec) => [spec.id, spec.wire])
    const twice = [...new Set(names.filter((name, index) => names.indexOf(name) !== index))]
    expect(twice).toEqual([])
  })

  it('spells every wire name as its id with underscores, so a call by either reaches one tool', () => {
    const odd = assembled().filter((spec) => spec.wire !== spec.id.replace(/\./g, '_'))
    expect(odd.map((spec) => `${spec.id} → ${spec.wire}`)).toEqual([])
  })

  it('names every tool the coverage tables point at', async () => {
    const { coverageRows } = await import('./coverage-tool')
    const built = new Set(assembled().map((spec) => spec.id))
    const missing = coverageRows().flatMap((row) =>
      (row.tools ?? []).filter((id) => !built.has(id)).map((id) => `${row.area} ${row.action} → ${id}`),
    )
    expect(missing).toEqual([])
  })
})
