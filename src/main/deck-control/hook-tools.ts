/**
 * The agents' hooks — the Hooks pane, as tools.
 *
 * A hook is a line in an agent's own settings file (`~/.claude/settings.json`,
 * `~/.codex/hooks.json`, `~/.gemini/settings.json`) that makes the agent tell
 * this app what it is doing: started, waiting for input, finished. They are
 * what turns a session's dot amber the moment it needs somebody. Everything the
 * pane offers is here — what is installed, install, remove, repair, and the
 * first-run question.
 *
 * ## Why every write here is `alter`
 *
 * Because these write into **another application's configuration**, in the
 * person's home directory, shared by every copy of this app on the machine.
 * `CLAUDE.md` in this repository records what that sharing cost once: a scratch
 * copy rewrote the hooks to point at itself and every session-event hook on the
 * machine went quietly dead. A tool that can do that must be confirmed by the
 * person whose agents it reconfigures. Declining the first-run offer is the one
 * exception — it writes only this app's own "do not ask again" marker — and it
 * is `act`.
 *
 * The provider is named from a closed set and nothing else crosses: no path, no
 * command, no file. `hooks.ts` owns all three, for the reason its channel
 * comment gives — a channel that accepted them would be a remote-write
 * primitive dressed up as a settings panel, and so would a tool.
 */

import type { JsonSchema, ToolSpec } from './catalogue'
import { oneOf, optStr } from './agents-area-args'
import { Refused } from './surface'

/** One agent's hooks, as `hooks:status` reports them. Passed through. */
export interface HookProviderStatusLike {
  id: string
  label: string
  state: string
  message: string
}

export interface HookWriteLike {
  ok: boolean
  message: string
  status: HookProviderStatusLike
}

export interface HookToolDeps {
  /** The agents that take hooks — `HOOK_PROVIDER_IDS`. */
  providers: readonly string[]
  /** `readAllStatus`. */
  status(): HookProviderStatusLike[]
  /** `hooks:server` — whether this app's hook listener is up, and where. */
  server(): { address: string | null; running: boolean; error: string | null }
  /** `readHookOffer` — the first-run question, and who a yes would cover. */
  offer(): unknown
  /** `installHooks`. */
  install(provider: string): HookWriteLike
  /** `removeHooks`. */
  remove(provider: string): HookWriteLike
  /** `syncInstalledHooks` — re-aim stale hooks at this copy of the app. */
  sync(): HookProviderStatusLike[]
  /** `acceptHookOffer` — install into every eligible agent and remember the yes. */
  acceptOffer(): HookWriteLike[]
  /** `declineHookOffer` — remember the no. */
  declineOffer(): void
}

/** "Every agent the first-run offer covers" — the one-press install the strip offers. */
const EVERY = 'all'

export function hookTools(deps: HookToolDeps): ToolSpec[] {
  const choices = [...deps.providers, EVERY]
  const providerSchema = (allowAll: boolean): JsonSchema => ({
    type: 'object',
    properties: {
      agent: {
        type: 'string',
        enum: allowAll ? choices : [...deps.providers],
        description: allowAll
          ? `Which agent, or "${EVERY}" for every installed agent that has none yet.`
          : 'Which agent.',
      },
    },
    required: ['agent'],
    additionalProperties: false,
  })

  return [
    {
      id: 'hooks.status',
      wire: 'hooks_status',
      tier: 'read',
      title: 'Read the agents’ hook status',
      description:
        'For each coding agent: whether this app’s hooks are installed in its settings file, aimed at this ' +
        'copy (complete), aimed somewhere dead (stale), partly there, or absent — with which events, which ' +
        'hooks belong to other tools, and one sentence saying why. Also whether this app’s hook listener is ' +
        'running, and whether the first-run offer is still waiting for an answer. Without hooks a session ' +
        'cannot say it needs attention the moment it does.',
      index: 'Read whether the agents’ hooks are installed and working.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Read the hook status',
      run: async () => {
        const agents = deps.status()
        return {
          value: { agents, listener: deps.server(), offer: deps.offer() },
          summary: { agents: agents.map((one) => `${one.id}:${one.state}`) },
        }
      },
    },

    {
      id: 'hooks.install',
      wire: 'hooks_install',
      tier: 'alter',
      title: 'Install the agents’ hooks',
      description:
        'Install this app’s hooks into one agent’s settings file, or with "all" into every installed agent that ' +
        'has none yet (the first-run offer’s yes). Other tools’ hooks in the same file are never touched, and ' +
        'the untouched original is backed up before the first write. Some agents then ask the person to trust ' +
        'the new hooks themselves; the result says so.',
      index: 'Install this app’s hooks into an agent’s settings, or into every agent.',
      inputSchema: providerSchema(true),
      summary: (args) =>
        args['agent'] === EVERY
          ? 'Install hooks into every installed agent that has none'
          : `Install hooks into ${optStr(args, 'agent') ?? '?'}’s settings file`,
      precheck: (args) => {
        oneOf(args, 'agent', choices)
      },
      run: async (args) => {
        const agent = oneOf(args, 'agent', choices)
        if (agent === EVERY) {
          const results = deps.acceptOffer()
          return {
            value: { results },
            summary: { agent, installed: results.filter((one) => one.ok).length },
          }
        }
        const result = deps.install(agent)
        if (!result.ok) throw new Refused('not-permitted', result.message)
        return { value: result, summary: { agent, state: result.status.state } }
      },
    },

    {
      id: 'hooks.remove',
      wire: 'hooks_remove',
      tier: 'alter',
      title: 'Remove the agents’ hooks',
      description:
        'Take this app’s hooks out of one agent’s settings file. Other tools’ hooks stay. Its sessions then ' +
        'stop reporting their state the moment it changes.',
      index: 'Remove this app’s hooks from an agent’s settings.',
      inputSchema: providerSchema(false),
      summary: (args) => `Remove hooks from ${optStr(args, 'agent') ?? '?'}’s settings file`,
      precheck: (args) => {
        oneOf(args, 'agent', deps.providers)
      },
      run: async (args) => {
        const agent = oneOf(args, 'agent', deps.providers)
        const result = deps.remove(agent)
        if (!result.ok) throw new Refused('not-permitted', result.message)
        return { value: result, summary: { agent, state: result.status.state } }
      },
    },

    {
      id: 'hooks.sync',
      wire: 'hooks_sync',
      tier: 'alter',
      title: 'Repair the agents’ hooks',
      description:
        'Re-aim every installed hook that points somewhere dead (a stale copy, an old socket) at this copy of ' +
        'the app, and fill in any missing events. Agents with no hooks are left alone. Use it when ' +
        'hooks.status says stale or partial.',
      index: 'Repair stale or partial hooks so they point at this app again.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Re-aim the installed hooks at this copy of the app',
      run: async () => {
        const agents = deps.sync()
        return { value: { agents }, summary: { agents: agents.map((one) => `${one.id}:${one.state}`) } }
      },
    },

    {
      id: 'hooks.decline_offer',
      wire: 'hooks_decline_offer',
      tier: 'act',
      title: 'Decline the hooks offer',
      description:
        'Answer the first-run question "install hooks?" with no, so it stops being asked. Installs nothing and ' +
        'removes nothing; hooks.install still works afterwards.',
      index: 'Say no to the first-run hooks question so it is not asked again.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Decline the first-run hooks offer',
      run: async () => {
        deps.declineOffer()
        return { value: { declined: true, offer: deps.offer() }, summary: { declined: true } }
      },
    },
  ]
}
