/**
 * Every tool the app assembles, from every source, the way the app assembles
 * them — one list, for every test that needs "the catalogue that ships".
 *
 * ## Why one list, in its own file
 *
 * Because three times now a test has measured or checked a list that was
 * *almost* the shipped one. `catalogue-cost.test.ts` records the first two in
 * its header, and the third was the 0.16.0 release: four new areas landed, and
 * the budget test still assembled the old nine sources, so it passed at ~6,000
 * tokens while the real listing was ~9,250. A list copied into each test is a
 * list that drifts from the app in each test.
 *
 * So there is one, here, and it is built by **the app's own constructor**:
 * `new DeckControl({ extraTools })`, which appends `tools.run` and
 * `tools.describe` exactly as it does at boot. The `extraTools` mirror
 * `src/main/index.ts` and `deck-control/index.ts` in their order. A source
 * added there and not here is the gap this file exists to close — add it here
 * in the same change.
 *
 * The factories get stand-ins, because a tool's id, wire name, description and
 * schema are literals in its factory. Nothing here calls a `run`, and the
 * dispatcher is never asked to dispatch.
 */

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
import type { ToolSpec } from './catalogue'
import { communityTools } from './community-tools'
import { DeckControl } from './control'
import { deviceTools, type DeviceToolDeps } from './device-tools'
import { copilotAdminTools, type CopilotAdminDeps } from './copilot-admin-tools'
import { coverageTool } from './coverage-tool'
import { extensionTools } from './extension-tools'
import { filesTools, type FilesToolDeps } from './files-tools'
import { createMachineArea } from './machine-area'
import { notifyTools } from './notify-tools'
import { projectTools, type ProjectToolDeps } from './project-tools'
import { sessionMoreTools, type SessionMoreDeps } from './session-more-tools'
import { sessionWindowTools } from './session-window-tools'
import { storeTools } from './store-tools'
import { toolsStoreTools } from './tools-store-tools'
import { tourTool } from './tour-tool'
import type { TourStage } from './tour-stage'
import { uiTools } from './ui-tools'
import { whereTool } from './where-tool'
import { workerTools } from './worker-tools'

/** A dep whose every member is a function that does nothing — for a definition that reads none. */
function inert(): object {
  return new Proxy({}, { get: () => () => undefined })
}

function inertDeps(keys: readonly string[]): Record<string, object> {
  return Object.fromEntries(keys.map((key) => [key, inert()]))
}

/** What `deck-control/index.ts` and `src/main/index.ts` hand `DeckControl` as `extraTools`. */
export function assembledExtraTools(): ToolSpec[] {
  return [
    // `deck-control/index.ts`'s own: the tour, the screen, the AI apps' inbox.
    tourTool({} as TourStage),
    whereTool({ window: { read: async () => null }, page: () => null }),
    ...notifyTools({ hub: () => null }),
    // `src/main/index.ts`, in its order.
    ...sessionWindowTools({
      view: () => ({ windows: [], displays: [] }),
      open: (sessionId) => ({ ok: false, message: '', sessionId }),
      dock: (sessionId) => ({ ok: false, message: '', sessionId }),
    }),
    ...browserTools({} as BrowserDrive),
    browserNetworkTool({} as BrowserDrive),
    ...workerTools({} as never),
    ...assetTools({
      userData: () => '/tmp',
      probe: async () => ({}) as never,
      open: () => {
        throw new Error('the assembled catalogue is definitions; it does not fetch')
      },
    }),
    ...storeTools({ drive: {} as BrowserDrive, installed: () => [] }),
    ...extensionTools({} as never),
    ...serverTools({} as ServerToolsDeps),
    ...createMachineArea().tools({
      servers: { openShells: () => [], shellScreen: async () => null },
      userData: () => '/tmp',
    }),
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
    // The Simulators page's tools, after the browser's and before the sessions
    // lane's — the order `src/main/index.ts` lists them in.
    ...deviceTools({} as DeviceToolDeps),
    // `sessionsLaneTools`, factory by factory.
    ...sessionMoreTools({} as SessionMoreDeps),
    ...projectTools({} as ProjectToolDeps),
    ...filesTools({} as FilesToolDeps),
    ...copilotAdminTools({} as CopilotAdminDeps),
    ...uiTools({ evaluate: async () => null }),
    coverageTool(),
  ]
}

/** The dispatcher the app builds, over every source. Its `tools()` and `cost()` are the real ones. */
export function assembledControl(): DeckControl {
  return new DeckControl({
    surface: {} as never,
    log: {} as never,
    consent: {} as never,
    extraTools: assembledExtraTools(),
  })
}

/** The whole catalogue, `tools.run` and `tools.describe` included. */
export function assembledCatalogue(): readonly ToolSpec[] {
  return assembledControl().tools()
}
