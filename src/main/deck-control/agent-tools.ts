/**
 * The agents this app can run, and the controls of a running one.
 *
 * Six tools over three things a person does on the Agents pane and in a
 * session's toolbar:
 *
 *  - `agents.list` — which agent CLIs are installed here, and the ones somebody
 *    added by hand (`providers:detect` and `agents:list`, one answer).
 *  - `agents.add`, `agents.remove` — the "Add an agent" form and its Remove.
 *  - `agents.controls`, `agents.models`, `agents.set_control` — the model,
 *    effort, fast-mode and permission-mode pickers beside a session's name.
 *
 * ## Every one of these calls the function the window calls
 *
 * The deps below are closures over `CustomAgentStore`, `detectProviders` and
 * `agent-controls.ts` — the objects `registerCustomAgentsIpc` and
 * `registerAgentControlsIpc` already put behind their channels. In particular
 * the controls go through `applyControl` with no shortcut of its own: that
 * module types into the session's terminal exactly as a person would, refuses
 * when it cannot see where it would be typing, carries a half-typed draft
 * across the change and puts it back unsent. A tool that wrote `/model` into a
 * pty directly would be a second, weaker copy of four passes of measurement on
 * a real CLI.
 *
 * ## Tiers
 *
 * Adding or removing an agent is `alter`: an added agent is a program this app
 * will spawn by name, which is configuration in the plainest sense. Reading the
 * controls is `read` — it reads the screen and two files, and types nothing.
 *
 * Changing a control, and opening the model picker to list what is in it, both
 * *type into the session*. In a session this run started that is the ordinary
 * `act` of driving its own work; in anybody else's it is theirs to allow, the
 * same line `sessions.send` draws. Permission mode is `alter` everywhere, because
 * the modes include `bypass`, and turning off an agent's own confirmations is a
 * decision about what may happen without being asked — not a preference.
 */

import type { CustomAgentDraft } from '../../shared/custom-agents'
import { AGENT_ENTRIES } from '../../shared/agent-catalog'
import type { AddAgentOutcome } from '../custom-agents'
import {
  EFFORT_LEVELS,
  PERMISSION_MODES,
  type ApplyRequest,
  type ApplyResult,
  type ControlsReading,
  type ModelCatalogResult,
} from '../agent-controls'
import { requireSession, type JsonSchema, type ToolSpec } from './catalogue'
import { oneOf, optStr, sessionTier, str } from './agents-area-args'
import { Refused, type Tier } from './surface'

/** One agent somebody added, as `agents:list` hands it to the window. */
export interface AddedAgent {
  id: string
  label: string
  description: string
  command: string
  args: readonly string[]
  resumeArgs: readonly string[]
  addedAt: number
}

export interface AgentToolDeps {
  /** Which agents are installed here, by id — built-in and added. `providers:detect`. */
  detect(): Promise<Record<string, boolean>>
  /** `CustomAgentStore.list`. */
  added(): readonly AddedAgent[]
  /** `CustomAgentStore.add`: validates, finds the command on the login PATH, writes. */
  add(draft: CustomAgentDraft): Promise<AddAgentOutcome>
  /** `CustomAgentStore.remove`, behind the same `custom:` prefix check the channel makes. */
  remove(id: string): boolean
  /** `readControls(access, …)` for a session on this computer. */
  readControls(sessionId: string, cwd: string, provider: string): Promise<ControlsReading>
  /** `discoverModels(access, …)`: opens the session's `/model` picker, reads it, cancels out. */
  models(sessionId: string, provider: string): Promise<ModelCatalogResult>
  /** `applyControl(access, …)`. */
  apply(request: ApplyRequest): Promise<ApplyResult>
}

const CONTROLS = ['model', 'effort', 'fast', 'permission'] as const

/** What each control accepts, said back so a model never has to guess a value. */
export const CONTROL_VALUES = {
  model: 'a model name from agents.models, such as sonnet or opus, or "default"',
  effort: EFFORT_LEVELS.map((level) => level.id).join(', '),
  fast: 'on, off',
  permission: PERMISSION_MODES.map((mode) => mode.id).join(', '),
} as const

const SESSION_SCHEMA: JsonSchema = {
  type: 'object',
  properties: { sessionId: { type: 'string', description: 'A session on this computer, from sessions.list.' } },
  required: ['sessionId'],
  additionalProperties: false,
}

export function agentTools(deps: AgentToolDeps): ToolSpec[] {
  return [
    {
      id: 'agents.list',
      wire: 'agents_list',
      tier: 'read',
      title: 'List the coding agents',
      description:
        'Which coding agents this computer can run: the built-in ones (Claude Code, Codex, Gemini CLI, a plain ' +
        'shell) with whether each is installed, and any agent somebody added by hand with the command it runs. ' +
        'The ids here are what sessions.start takes as provider and what accounts and hooks are keyed by.',
      index: 'Which coding agents are installed here, plus agents added by hand.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'List the coding agents',
      run: async () => {
        const installed = await deps.detect()
        const builtIn = AGENT_ENTRIES.map((entry) => ({
          id: entry.id,
          label: entry.label,
          description: entry.description,
          // The shell has no binary to look for and is always there.
          installed: entry.bin === null ? true : installed[entry.id] === true,
        }))
        const added = deps.added().map((agent) => ({
          ...agent,
          installed: installed[agent.id] === true,
        }))
        return {
          value: { builtIn, added },
          summary: { builtIn: builtIn.length, added: added.length },
        }
      },
    },

    {
      id: 'agents.add',
      wire: 'agents_add',
      tier: 'alter',
      title: 'Add an agent',
      description:
        'Add a coding agent this app does not know about, by the command that starts it — any CLI that runs in ' +
        'a terminal. The command must already be installed: it is looked up on the login PATH first and refused ' +
        'if it cannot be found. It then appears in the New session picker. The person confirms it.',
      index: 'Add a custom coding agent by the command that starts it.',
      inputSchema: {
        type: 'object',
        properties: {
          label: { type: 'string', description: 'The name it is shown under.' },
          command: { type: 'string', description: 'A program on PATH, or an absolute path.' },
          args: { type: 'string', description: 'Arguments for a fresh session, as typed on a command line.' },
          resumeArgs: { type: 'string', description: 'Arguments that continue the last conversation. Optional.' },
          description: { type: 'string', description: 'One line shown under the name. Optional.' },
        },
        required: ['label', 'command'],
        additionalProperties: false,
      },
      summary: (args) => {
        const extra = optStr(args, 'args')
        return `Add an agent called ${optStr(args, 'label') ?? '?'} that runs \`${optStr(args, 'command') ?? '?'}${extra === null ? '' : ` ${extra}`}\``
      },
      precheck: (args) => {
        str(args, 'label')
        str(args, 'command')
      },
      run: async (args) => {
        const draft: CustomAgentDraft = {
          label: str(args, 'label'),
          command: str(args, 'command'),
          args: optStr(args, 'args') ?? '',
          resumeArgs: optStr(args, 'resumeArgs') ?? '',
          description: optStr(args, 'description') ?? '',
        }
        const outcome = await deps.add(draft)
        if (!outcome.ok) {
          // The store's own sentences, per field — they are written for the
          // person who typed the form, and they read the same to a model.
          throw new Refused(
            'not-permitted',
            `the agent was not added: ${Object.values(outcome.problems).filter(Boolean).join(' ')}`,
          )
        }
        return {
          value: { added: true, agent: outcome.agent },
          summary: { id: outcome.agent.id, command: outcome.agent.command },
        }
      },
    },

    {
      id: 'agents.remove',
      wire: 'agents_remove',
      tier: 'alter',
      title: 'Remove an added agent',
      description:
        'Remove an agent somebody added by hand. The built-in agents cannot be removed. Sessions already ' +
        'running it keep running; it just stops being offered. Use agents.list for the id.',
      index: 'Remove an agent that was added by hand.',
      inputSchema: {
        type: 'object',
        properties: { agentId: { type: 'string', description: 'The id from agents.list, starting custom:.' } },
        required: ['agentId'],
        additionalProperties: false,
      },
      summary: (args) => `Remove the added agent ${optStr(args, 'agentId') ?? '?'}`,
      run: async (args) => {
        const id = str(args, 'agentId')
        if (!deps.remove(id)) {
          throw new Refused(
            'not-permitted',
            `no added agent has the id ${id}. Only agents added by hand can be removed; agents.list shows them.`,
          )
        }
        return { value: { removed: true, agentId: id }, summary: { agentId: id } }
      },
    },

    {
      id: 'agents.controls',
      wire: 'agents_controls',
      tier: 'read',
      title: 'Read a session’s agent controls',
      description:
        'The model, effort level, fast mode and permission mode of the agent running in a session, each with ' +
        'where the value was read from (its screen, its transcript, its settings file). A value nobody could ' +
        'read is null — unknown, not off. Also says whether a change could be typed right now and, if not, why. ' +
        'Read-only: nothing is typed. The accepted values for agents.set_control come back too.',
      index: 'Read the model, effort, fast mode and permission mode of a running session.',
      inputSchema: SESSION_SCHEMA,
      summary: (args) => `Read the agent controls of session ${optStr(args, 'sessionId') ?? '?'}`,
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        const reading = await deps.readControls(session.id, session.cwd, session.provider)
        return {
          value: { sessionId: session.id, ...reading, accepts: CONTROL_VALUES },
          summary: { sessionId: session.id, live: reading.live, model: reading.model.value },
        }
      },
    },

    {
      id: 'agents.models',
      wire: 'agents_models',
      tier: 'act',
      title: 'List the models a session can switch to',
      description:
        "Open the session's own /model picker, read the models it offers, and close it again — so the list is " +
        "the agent's, never a stale one. This types into the session's terminal for a moment: in a session you " +
        'started that is ordinary; in one the person started they are asked first.',
      index: 'List the models a running session offers, read from its own /model picker.',
      inputSchema: SESSION_SCHEMA,
      escalate: (args, context) => sessionTier(args, context),
      summary: (args) => `Open the model picker in session ${optStr(args, 'sessionId') ?? '?'} and read it`,
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        const found = await deps.models(session.id, session.provider)
        return {
          value: { sessionId: session.id, ...found },
          summary: { sessionId: session.id, models: found.models.length },
        }
      },
    },

    {
      id: 'agents.set_control',
      wire: 'agents_set_control',
      tier: 'act',
      title: 'Change a session’s model, effort or mode',
      description:
        'Change the model, effort level, fast mode or permission mode of the agent in a running session, by ' +
        'typing the same command a person would and reading back what the agent printed. A model or effort ' +
        'change may also become the default for new sessions — the result quotes which. Anything half-typed at ' +
        'the prompt is put back afterwards. Refused when the session is mid-turn or showing a dialog. ' +
        'Permission mode always needs the person to confirm, because one of the modes turns off the agent’s ' +
        'own permission prompts. Read agents.controls first.',
      index: 'Change the model, effort, fast mode or permission mode of a running session.',
      inputSchema: {
        type: 'object',
        properties: {
          sessionId: { type: 'string' },
          control: { type: 'string', enum: [...CONTROLS] },
          value: {
            type: 'string',
            description:
              `model: ${CONTROL_VALUES.model}. effort: ${CONTROL_VALUES.effort}. fast: ${CONTROL_VALUES.fast}. ` +
              `permission: ${CONTROL_VALUES.permission}.`,
          },
        },
        required: ['sessionId', 'control', 'value'],
        additionalProperties: false,
      },
      escalate: (args, context): Tier => (args['control'] === 'permission' ? 'alter' : sessionTier(args, context)),
      precheck: (args) => {
        oneOf(args, 'control', CONTROLS)
        str(args, 'value')
      },
      summary: (args) =>
        `Set ${optStr(args, 'control') ?? '?'} to ${optStr(args, 'value') ?? '?'} in session ${optStr(args, 'sessionId') ?? '?'}`,
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        const control = oneOf(args, 'control', CONTROLS)
        const value = str(args, 'value')
        const result = await deps.apply({
          sessionId: session.id,
          cwd: session.cwd,
          control,
          value,
          provider: session.provider,
        })
        return {
          value: { sessionId: session.id, control, ...result },
          summary: { sessionId: session.id, control, value, ok: result.ok },
        }
      },
    },
  ]
}
