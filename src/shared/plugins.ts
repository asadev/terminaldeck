/**
 * Plugins: the shapes both sides of the bridge read.
 *
 * A plugin is a program somebody else wrote, in a folder the person put under
 * `<userData>/plugins/` themselves. It runs as a child process of this app,
 * talks to it over its own stdin and stdout, and may ask for exactly the things
 * below — nothing else exists for it to ask for. `src/main/plugins/` holds the
 * host; this file is the vocabulary the Settings pane draws.
 *
 * ## Why the list is closed
 *
 * The same argument `store-manifest.ts` makes about its grammar, one level up:
 * a permission system that accepts a name it does not recognise is one that
 * will happily accept next year's dangerous one. A plugin names capabilities
 * out of this list; a name not on it is a refusal when the manifest is read, and
 * a request for anything it did not name is refused when it is made.
 */

import { BRAND } from './brand'

/** `<userData>/plugins/<id>/` — where the person puts a plugin's folder. */
export const PLUGINS_DIR = 'plugins'

/** `<userData>/plugin-data/<id>/` — the one folder a plugin may write to. */
export const PLUGIN_DATA_DIR = 'plugin-data'

/** `<userData>/plugin-grants.json` — what each plugin was allowed, keyed by its code. */
export const PLUGIN_GRANTS_FILE = 'plugin-grants.json'

/**
 * Everything a plugin can ask for.
 *
 *  - `tasks.read`: the tasks this app holds — title, project, status.
 *  - `goals.read`: the goals this app holds.
 *  - `knowledge.read`: what is recorded about a project, for the projects the
 *    person chose when they allowed it, and no other.
 *  - `notify`: a notification, with the plugin's name on it.
 *  - `tools.contribute`: tools the plugin's manifest declares, offered to the
 *    assistant at the desk and to nothing else.
 */
export const PLUGIN_CAPABILITIES = ['tasks.read', 'goals.read', 'knowledge.read', 'notify', 'tools.contribute'] as const

export type PluginCapability = (typeof PLUGIN_CAPABILITIES)[number]

/** The capabilities that are granted per project rather than whole. */
export const PROJECT_SCOPED: readonly PluginCapability[] = ['knowledge.read']

/** What each capability is called on screen and in the question that grants it. */
export const CAPABILITY_WORDS: Readonly<Record<PluginCapability, string>> = Object.freeze({
  'tasks.read': 'Read your tasks',
  'goals.read': 'Read your goals',
  'knowledge.read': 'Read what is recorded about the projects you choose',
  notify: 'Show you notifications',
  'tools.contribute': `Give ${BRAND.assistant} new tools`,
})

export function isPluginCapability(value: unknown): value is PluginCapability {
  return typeof value === 'string' && (PLUGIN_CAPABILITIES as readonly string[]).includes(value)
}

/** The tiers a contributed tool can declare. The same three the assistant's own tools have. */
export const PLUGIN_TOOL_TIERS = ['read', 'act', 'alter'] as const

export type PluginToolTier = (typeof PLUGIN_TOOL_TIERS)[number]

/**
 * Where a plugin is in its life, as the pane draws it.
 *
 *  - `off`: the person turned it off, or never turned it on. Never started.
 *  - `needs-ok`: it has never been allowed.
 *  - `changed`: it was allowed, and its files have changed since — the grant
 *    was for other code, so it is not started until allowed again.
 *  - `running`: started, and answered the handshake.
 *  - `stopped`: it was running and is not; `note` says why.
 *  - `broken`: its folder cannot be read as a plugin; `note` says why.
 */
export type PluginState = 'off' | 'needs-ok' | 'changed' | 'running' | 'stopped' | 'broken'

export interface PluginToolView {
  /** The name in the manifest. */
  name: string
  /** What the assistant calls it: `plugin_<id>_<name>`. */
  wire: string
  title: string
  tier: PluginToolTier
}

export interface PluginView {
  /** The folder's name, which is also the manifest's id. */
  id: string
  name: string
  summary: string
  version: string
  /** The person's switch. Off means it is never started. */
  enabled: boolean
  state: PluginState
  /** One plain sentence about the state. */
  note: string
  /** What the manifest asks for. */
  declared: PluginCapability[]
  /** What the person allowed, for this exact code. Empty when the grant is missing or lost. */
  granted: PluginCapability[]
  /** The projects a project-scoped capability was allowed for. */
  projects: string[]
  /** True once allowed for the code that is in the folder now. */
  allowed: boolean
  tools: PluginToolView[]
}

export interface PluginsState {
  /** `<userData>/plugins`, for the sentence that says where to put one. */
  folder: string
  /** One sentence: what holds a plugin in on this computer. */
  confinement: string
  /** The projects a project-scoped capability can be allowed for. */
  projects: string[]
  plugins: PluginView[]
}

export interface PluginsResult {
  ok: boolean
  /** A refusal or a failure, in a sentence. Absent on success. */
  message?: string
  state: PluginsState
}

/** What the pane sends to allow a plugin, or to change what it is allowed. */
export interface PluginAllowInput {
  capabilities: PluginCapability[]
  projects: string[]
}
