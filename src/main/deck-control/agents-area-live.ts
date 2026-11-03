/**
 * The agents area's tools, wired to the real app.
 *
 * The one file in this area that imports the app's own main-process modules —
 * the same split `live-surface.ts` makes for the built-in tools, for the same
 * reason: the factories (and every decision about tiers, secrets and
 * refusals) stay testable with plain fakes, and the only thing this file
 * decides is *which function each dep is*. Every closure below is the function
 * the matching `ipcMain.handle` calls, by name; where a channel's body was
 * inline, it was lifted into a named export beside the channel in the same
 * change, so a tool call and a click cannot come to do different things.
 *
 * **Only `src/main/index.ts` may import this.** Several of these modules reach
 * Electron (`shell`, `safeStorage`, the guest `session`), so pulling this into
 * `deck-control/index.ts` — which the headless host also loads — would take
 * Electron into a process that has none.
 *
 * What `index.ts` owns and hands in is {@link AgentsAreaWiring}: the objects it
 * builds at startup (`core.agents`, `core.controlAccess`, `routines.api`, the
 * update controller) and the one lookup that only it can answer. Everything
 * else is a module function and is imported here directly, which is what lets
 * the wiring in `index.ts` be a single spread.
 */

import type { IpcMain } from 'electron'
import { BRAND } from '../../shared/brand'
import { CUSTOM_PROVIDER_PREFIX } from '../../shared/custom-agents'
import type { ProviderId, SessionMeta } from '../../shared/types'
import { applyControl, discoverModels, readControls, type SessionAccess } from '../agent-controls'
import { logStatus, openLogFolder, recentLog } from '../app-log-ipc'
import { appLog } from '../app-log'
import { listProjectTranscripts, readProjectCost, readSessionCost } from '../cost-ipc'
import type { CustomAgentStore } from '../custom-agents'
import { clearIpcCalls, collectDiagnostics, formatDiagnostics, recentIpcCalls } from '../diagnostics'
import { currentHookEndpoint, hookServerFailure } from '../hook-server'
import {
  acceptHookOffer,
  declineHookOffer,
  defaultContext,
  HOOK_PROVIDER_IDS,
  installHooks,
  readAllStatus,
  readHookOffer,
  removeHooks,
  syncInstalledHooks,
  type HookProviderId,
} from '../hooks'
import { addMcpServer, removeMcpServer } from '../mcp-add'
import {
  callMcpTool,
  disconnectMcpServer,
  editConfiguredMcpServer,
  listMcpServers,
  mcpServerInventory,
  mcpStoreInstall,
  mcpStoreView,
  mcpToolFile,
} from '../mcp-client'
import { userDataDir } from '../platform/paths'
import {
  accountProvidersView,
  createProfile,
  deleteProfile,
  findProfile,
  getState,
  profilesSnapshot,
  profileStatus,
  renameProfile,
  resolveProfile,
  setGlobalDefault,
  setProjectDefault,
  type Profile,
} from '../profiles'
import { readSignIn, signOutAccount } from '../profiles-signin'
import { supportsAccounts } from '../provider-accounts'
import { applyReadinessFix, FIX_IDS, scanReadiness, type ReadinessFixId } from '../readiness'
import type { RoutineApi } from '../routines/ipc'
import { aboutInfo, clearBrowsingData, configPaths, openConfigPath } from '../settings-extra'
import { readSetup } from '../setup'
import {
  describeDelete,
  describeShare,
  describeUnshare,
  shareProjects,
  shareState,
  unshareProjects,
} from '../shared-projects'
import { readSessionContext, readUsage, refreshUsage, type UsageOptions } from '../usage-ipc'
import { storedAccountLimits } from '../account-limits'
import type { UpdateController } from '../updates/updater'
import { clearVoiceKey, saveCheckedVoiceKey, transcribeWithStoredKey, VOICE_PROVIDERS, voiceStatus } from '../voice'
import { agentsAreaTools } from './agents-area'
import type { ToolSpec } from './catalogue'

/** What `src/main/index.ts` holds and this file cannot reach for itself. */
export interface AgentsAreaWiring {
  /** `core.agents` — the store `registerCustomAgentsIpc` serves. */
  agents: CustomAgentStore
  /** `core.controlAccess` — what `registerAgentControlsIpc` is given. */
  controlAccess: SessionAccess
  /** `routines.api` — what `registerRoutinesIpc` is given. */
  routines: RoutineApi
  /** The controller `registerUpdateIpc` returned (`updates` in index.ts), read per call. */
  updates(): UpdateController | null
  /** The session table, for the usage reads: `ptys.list().find(…)`. */
  describeSession(id: string): SessionMeta | null
  /** The body of `providers:detect`: built-in agents plus added ones, installed or not. */
  detectProviders(): Promise<Record<string, boolean>>
  /** For the diagnostics bundle's list of wired channels. */
  ipcMain: IpcMain
}

/** The account a tool names, or a thrown sentence — `subject` in `shared-projects.ts` says the same. */
function account(id: string): Profile {
  const found = findProfile(getState(), id)
  if (!found) throw new Error(`no account with id ${id}`)
  return found
}

export function liveAgentsAreaTools(wiring: AgentsAreaWiring): ToolSpec[] {
  /*
   * The same two pieces `registerUsageIpc` is handed in `index.ts`. The account
   * memory is `store()`-backed, so this second handle reads and writes the very
   * same facts the usage bar's does — it is a second door onto one memory, not
   * a second memory.
   */
  const usage: UsageOptions = { describeSession: wiring.describeSession, accounts: storedAccountLimits() }

  return agentsAreaTools({
    agents: {
      detect: wiring.detectProviders,
      added: () => wiring.agents.list(),
      add: (draft) => wiring.agents.add(draft),
      // The prefix check `registerCustomAgentsIpc` makes, kept: a built-in id
      // never reaches the store's remove.
      remove: (id) => id.startsWith(CUSTOM_PROVIDER_PREFIX) && wiring.agents.remove(id),
      readControls: (sessionId, cwd, provider) => readControls(wiring.controlAccess, sessionId, cwd, provider),
      models: (sessionId, provider) => discoverModels(wiring.controlAccess, sessionId, provider),
      apply: (request) => applyControl(wiring.controlAccess, request),
    },

    accounts: {
      /*
       * `profiles:list`'s own snapshot, now exported — including `vault`, which
       * says for each account whether this app keeps its login and whether it
       * holds one. Slot names and times only; never a value.
       */
      list: (agent) =>
        profilesSnapshot(agent !== null && supportsAccounts(agent as ProviderId) ? (agent as ProviderId) : null),
      agents: () => accountProvidersView(),
      resolve: ({ projectPath, provider }) =>
        resolveProfile(getState(), {
          projectPath,
          provider: provider !== null && supportsAccounts(provider as ProviderId) ? (provider as ProviderId) : null,
        }),
      find: (id) => {
        const found = findProfile(getState(), id)
        return found === null ? null : { id: found.id, name: found.name, provider: found.provider }
      },
      status: (id) => profileStatus(account(id)),
      signIn: (id, refresh) => readSignIn(account(id), { refresh }),
      history: (id) => {
        const state = shareState(account(id))
        return { state, share: describeShare(state), unshare: describeUnshare(state), remove: describeDelete(state) }
      },
      create: (name, options) =>
        createProfile(name, {
          ...(options.configDir === undefined ? {} : { configDir: options.configDir }),
          ...(options.provider === undefined ? {} : { provider: options.provider as ProviderId }),
        }),
      rename: (id, name) => renameProfile(id, name),
      remove: (id, options) => deleteProfile(id, options),
      setDefault: (id) => setGlobalDefault(id),
      setProjectDefault: (projectPath, id) => setProjectDefault(projectPath, id),
      signOut: (id) => signOutAccount(id),
      share: (id) => shareProjects(account(id)),
      unshare: (id) => unshareProjects(account(id)),
    },

    mcp: {
      list: (projectPath) => listMcpServers(projectPath),
      add: (request) => addMcpServer(request),
      edit: (request) => editConfiguredMcpServer(request),
      remove: (request) => removeMcpServer(request),
      inventory: (id, projectPath) => mcpServerInventory(id, projectPath),
      disconnect: (id) => disconnectMcpServer(id),
      call: (id, tool, args, projectPath) => callMcpTool(id, tool, args, projectPath),
      store: (projectPath) => mcpStoreView(projectPath),
      install: (request) => mcpStoreInstall(request),
      toolFile: (name, scope, projectPath) => mcpToolFile(name, scope, projectPath),
    },

    hooks: {
      providers: HOOK_PROVIDER_IDS,
      // `defaultContext()` per call, as `registerHooksIpc` does: the endpoint
      // it carries is the live one, and it is not up yet when this is built.
      status: () => readAllStatus(defaultContext()),
      server: () => {
        const endpoint = currentHookEndpoint()
        // The socket path and nothing else. The endpoint also carries the
        // per-run token the hooks authenticate with, and that never leaves.
        return {
          address: endpoint?.socketPath ?? null,
          running: endpoint !== null,
          error: endpoint === null ? hookServerFailure() : null,
        }
      },
      offer: () => readHookOffer(defaultContext()),
      install: (provider) => installHooks(defaultContext(), provider as HookProviderId),
      remove: (provider) => removeHooks(defaultContext(), provider as HookProviderId),
      sync: () => syncInstalledHooks(defaultContext()),
      acceptOffer: () => acceptHookOffer(defaultContext()),
      declineOffer: () => declineHookOffer(defaultContext()),
    },

    routines: wiring.routines,

    app: {
      about: () => aboutInfo(),
      brand: () => ({ name: BRAND.name, tagline: BRAND.tagline }),
      paths: () => configPaths(),
      logStatus: () => logStatus(),
      openPath: (key) => openConfigPath(key),
      openLogFolder: () => openLogFolder(),
      diagnostics: async ({ text, includeClis, logLines }) => {
        const bundle = await collectDiagnostics({ ipcMain: wiring.ipcMain, includeClis, logLines })
        return text ? formatDiagnostics(bundle) : bundle
      },
      recentLog: (lines) => recentLog(lines),
      recentCalls: (limit) => recentIpcCalls(limit),
      clearLog: () => appLog().clear(),
      clearCalls: () => clearIpcCalls(),
      clearBrowserData: () => clearBrowsingData(),
      updates: wiring.updates,
    },

    setup: {
      setup: () => readSetup(),
      scan: (projectPath) => scanReadiness(projectPath),
      fix: (projectPath, fixId) => applyReadinessFix(projectPath, fixId as ReadinessFixId),
      fixIds: FIX_IDS,
    },

    usage: {
      read: (sessionId) => readUsage(sessionId, usage),
      context: (sessionId) => readSessionContext(sessionId, usage),
      refresh: (sessionId, force) => refreshUsage(sessionId, usage, force),
      projectCost: (projectPath) => readProjectCost(projectPath),
      transcripts: (projectPath) => listProjectTranscripts(projectPath),
      sessionCost: (transcriptPath) => readSessionCost(transcriptPath),
    },

    voice: {
      providers: () => VOICE_PROVIDERS,
      // `userDataDir()`, the seam `registerVoiceIpc`'s thunk reads through, so a
      // `pinUserData` move is followed here too.
      status: () => voiceStatus(userDataDir()),
      save: (provider, key) => saveCheckedVoiceKey(userDataDir(), { provider, key }),
      forget: () => clearVoiceKey(userDataDir()),
      transcribe: (audio, filename) => transcribeWithStoredKey(userDataDir(), { audio, filename }),
    },
  })
}
