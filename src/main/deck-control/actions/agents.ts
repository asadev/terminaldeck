/**
 * Agents, accounts, MCP servers, hooks, routines, settings, voice, updates and logs: every action a person can take, and the tool that takes it.
 *
 * See `./types.ts` for what an entry means. `null` is "not decided yet" and
 * fails `actions.test.ts` on purpose.
 *
 * The tools are in `../agents-area.ts` and the nine factories it assembles.
 * `agents-area.test.ts` checks every `tool` named below against that list, so
 * a renamed tool cannot leave this table pointing at nothing.
 *
 * Several channels share one tool, and that is deliberate rather than a gap:
 * the window splits a reading across channels because it draws it in pieces
 * (`voice:status` beside `voice:providers`, `log:status` beside `settings:paths`),
 * and a model asking "how is dictation set up" wants one answer, not two calls.
 */

import type { CoverageMap } from './types'

/** For the subscribe/unsubscribe pairs: the window asking to be pushed updates. */
const PUSH_PLUMBING =
  'The window asking to be sent live updates as they happen; a tool asks for the current answer whenever it wants one instead.'

/**
 * Settings → Connect an AI app: who outside this app may reach these tools.
 *
 * Every one of these is a grant — a change to who can reach this machine, from
 * this Mac or from the internet — and a grant is only ever changed by the owner
 * at this machine (`COPILOT-REMOTE.md` §5 rule 9: *the approval screen at this
 * keyboard is the only door*). An AI that could make a key could let itself back
 * in; one that could raise a level could raise its own.
 */
const KEYS_ARE_THE_OWNERS =
  'Access keys decide which outside AI apps may reach this computer, so they are changed only by the owner in Settings, never by a tool an AI could call.'

export const agentsCoverage: CoverageMap = {
  'accounts:history-share': { tool: 'accounts.share_history' },
  'accounts:history-state': { tool: 'accounts.status' },
  'accounts:history-unshare': { tool: 'accounts.share_history' },
  'agent:controls:apply': { tool: 'agents.set_control' },
  'agent:controls:models': { tool: 'agents.models' },
  'agent:controls:read': { tool: 'agents.controls' },
  'agents:add': { tool: 'agents.add' },
  'agents:list': { tool: 'agents.list' },
  'agents:remove': { tool: 'agents.remove' },
  'ai-apps:ask-first': { skip: KEYS_ARE_THE_OWNERS },
  'ai-apps:create': {
    skip: 'Making an access key hands back a secret and mints a new way into this computer, so only the owner does it, in Settings.',
  },
  'ai-apps:folders': { skip: KEYS_ARE_THE_OWNERS },
  'ai-apps:internet': {
    skip: 'Opening this computer to AI apps on the internet is the owner’s switch in Settings, never something a tool turns on.',
  },
  'ai-apps:level': {
    skip: 'A tool that changed what an access key may do would let an AI raise its own key, so levels are changed only in Settings.',
  },
  'ai-apps:rename': {
    skip: 'A key’s name is how the owner recognises an outside app in the activity log, so only the owner renames one, in Settings.',
  },
  'ai-apps:revoke': { skip: KEYS_ARE_THE_OWNERS },
  'ai-apps:state': {
    skip: 'The list of which outside AI apps hold keys is the owner’s audit screen; an app holding one has no business listing the others.',
  },
  'brand:get': { tool: 'app.about' },
  'cost:project': { tool: 'usage.cost' },
  'cost:session': { tool: 'usage.cost' },
  'cost:sessions': { tool: 'usage.cost' },
  'cost:unwatch': { skip: PUSH_PLUMBING },
  'cost:watch': { skip: PUSH_PLUMBING },
  'debug:diagnostics': { tool: 'app.diagnostics' },
  'debug:diagnostics-text': { tool: 'app.diagnostics' },
  'debug:ipc-clear': { tool: 'app.clear_log' },
  'debug:ipc-log': { tool: 'app.log' },
  'debug:subscribe': { skip: PUSH_PLUMBING },
  'debug:unsubscribe': { skip: PUSH_PLUMBING },
  'hooks:install': { tool: 'hooks.install' },
  'hooks:offer': { tool: 'hooks.status' },
  'hooks:offer-accept': { tool: 'hooks.install' },
  'hooks:offer-decline': { tool: 'hooks.decline_offer' },
  'hooks:remove': { tool: 'hooks.remove' },
  'hooks:server': { tool: 'hooks.status' },
  'hooks:status': { tool: 'hooks.status' },
  'hooks:sync': { tool: 'hooks.sync' },
  'log:clear': { tool: 'app.clear_log' },
  'log:open-folder': { tool: 'app.reveal' },
  'log:recent': { tool: 'app.log' },
  'log:status': { tool: 'app.about' },
  'mcp:add': { tool: 'mcp.add' },
  'mcp:call': { tool: 'mcp.call' },
  'mcp:connect': { tool: 'mcp.connect' },
  'mcp:disconnect': { tool: 'mcp.disconnect' },
  'mcp:edit': { tool: 'mcp.edit' },
  'mcp:export': { tool: 'mcp.export' },
  'mcp:import': { tool: 'mcp.import' },
  'mcp:inventory': { tool: 'mcp.connect' },
  'mcp:list': { tool: 'mcp.list' },
  'mcp:remove': { tool: 'mcp.remove' },
  'mcp:store': { tool: 'mcp.store' },
  'mcp:store-install': { tool: 'mcp.install' },
  'prefs:get': { tool: 'settings.read' },
  'prefs:set': { tool: 'settings.write' },
  'prereq:check': { tool: 'setup.status' },
  'profiles:account-providers': { tool: 'accounts.list' },
  'profiles:create': { tool: 'accounts.create' },
  'profiles:delete': { tool: 'accounts.delete' },
  'profiles:list': { tool: 'accounts.list' },
  'profiles:rename': { tool: 'accounts.rename' },
  'profiles:resolve': { tool: 'accounts.list' },
  'profiles:set-default': { tool: 'accounts.set_default' },
  'profiles:set-project-default': { tool: 'accounts.set_default' },
  // The probe behind the Accounts pane's sign-in state, and the Sign in button
  // itself, which opens a session on the account for its agent to ask.
  'profiles:signin': { tool: ['accounts.status', 'accounts.sign_in'] },
  'profiles:signout': { tool: 'accounts.sign_out' },
  'profiles:status': { tool: 'accounts.status' },
  'providers:detect': { tool: 'agents.list' },
  'readiness:fix': { tool: 'readiness.fix' },
  'readiness:scan': { tool: 'readiness.scan' },
  'routines:delete': { tool: 'routines.delete' },
  'routines:get': { tool: 'routines.get' },
  'routines:list': { tool: 'routines.list' },
  'routines:pause': { tool: 'routines.pause' },
  'routines:resume': { tool: 'routines.resume' },
  'routines:run': { tool: 'routines.run' },
  // The editor's save writes the exact bytes typed, which `routines/ipc.ts`
  // marks `human` — no tool may. `routines.save` makes the same edit through the
  // draft, whose header guard is what makes it safe to hand a model.
  'routines:save-text': { tool: 'routines.save' },
  'routines:text': { tool: 'routines.get' },
  'settings:about': { tool: 'app.about' },
  'settings:clear-browser-data': { tool: 'settings.clear_browser_data' },
  'settings:get': { tool: 'settings.read' },
  'settings:open-path': { tool: 'app.reveal' },
  'settings:paths': { tool: 'app.about' },
  'settings:reset': { tool: 'settings.reset' },
  'settings:set': { tool: 'settings.write' },
  'setup:status': { tool: 'setup.status' },
  'update:check': { tool: 'updates.status' },
  'update:download': { tool: 'updates.download' },
  'update:get': { tool: 'updates.status' },
  'update:install': { tool: 'updates.install' },
  'usage:context': { tool: 'usage.read' },
  'usage:read': { tool: 'usage.read' },
  'usage:refresh': { tool: 'usage.refresh' },
  'usage:unwatch': { skip: PUSH_PLUMBING },
  'usage:watch': { skip: PUSH_PLUMBING },
  'voice:forget': { tool: 'voice.forget_key' },
  'voice:providers': { tool: 'voice.status' },
  'voice:save': { tool: 'voice.save_key' },
  'voice:status': { tool: 'voice.status' },
  'voice:transcribe': { tool: 'voice.transcribe' },
}
