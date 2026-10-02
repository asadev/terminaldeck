/**
 * Every tool of the agents area, assembled from its nine factories.
 *
 * The area is what `actions/agents.ts` lists: agents and their controls,
 * accounts, the agents' MCP servers, hooks, routines, the app itself (about,
 * logs, diagnostics, updates, the settings reset), setup and readiness, usage
 * and cost, and dictation. Each factory takes a narrow deps interface of plain
 * functions and nothing Electron, so all of them are tested with fakes; the
 * real closures are built once, in `agents-area-live.ts`, which is the only
 * file in this area that imports the app's own main-process modules.
 *
 * ## What every tool here costs the catalogue
 *
 * One line. Every one of them carries an {@link ToolSpec.index}, which holds
 * its description and schema behind `tools.describe` — the rule
 * `describe-tool.ts` sets: *a tool a turn is likely to reach for first keeps
 * its schema; a tool only ever reached for after another one has been used can
 * be an index line.* None of these is a first reach. A turn that changes an
 * account, calls an MCP server or reads a routine has already asked something
 * else about the app — and the fifty-eight of them advertised in full would be
 * several times the whole budget `MAX_CATALOGUE_TOKENS` allows.
 */

import type { ToolSpec } from './catalogue'
import { accountTools, type AccountToolDeps } from './account-tools'
import { agentTools, type AgentToolDeps } from './agent-tools'
import { appTools, type AppToolDeps } from './app-tools'
import { hookTools, type HookToolDeps } from './hook-tools'
import { mcpServerTools, type McpServerToolDeps } from './mcp-server-tools'
import { routineTools, type RoutineToolDeps } from './routine-tools'
import { setupTools, type SetupToolDeps } from './setup-tools'
import { usageTools, type UsageToolDeps } from './usage-tools'
import { voiceTools, type VoiceToolDeps } from './voice-tools'

export interface AgentsAreaDeps {
  agents: AgentToolDeps
  accounts: AccountToolDeps
  mcp: McpServerToolDeps
  hooks: HookToolDeps
  routines: RoutineToolDeps
  app: AppToolDeps
  setup: SetupToolDeps
  usage: UsageToolDeps
  voice: VoiceToolDeps
}

export function agentsAreaTools(deps: AgentsAreaDeps): ToolSpec[] {
  return [
    ...agentTools(deps.agents),
    ...accountTools(deps.accounts),
    ...mcpServerTools(deps.mcp),
    ...hookTools(deps.hooks),
    ...routineTools(deps.routines),
    ...appTools(deps.app),
    ...setupTools(deps.setup),
    ...usageTools(deps.usage),
    ...voiceTools(deps.voice),
  ]
}
