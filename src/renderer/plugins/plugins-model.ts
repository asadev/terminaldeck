/**
 * Settings → Plugins, on the window's side: the bridge, and the answers read
 * back into shapes the pane can trust.
 *
 * Everything crosses the preload as `unknown` and is narrowed here, the way
 * `tasks-model.ts` does it — a field this file does not recognise is dropped
 * rather than drawn, so a main process one version ahead cannot put a control
 * on screen the pane does not understand.
 */

import {
  isPluginCapability,
  PLUGIN_TOOL_TIERS,
  type PluginAllowInput,
  type PluginState,
  type PluginsResult,
  type PluginsState,
  type PluginToolTier,
  type PluginToolView,
  type PluginView,
} from '../../shared/plugins'

export interface PluginsBridge {
  pluginsState(): Promise<unknown>
  pluginsAllow(id: string, input: PluginAllowInput): Promise<unknown>
  pluginsEnable(id: string, enabled: boolean): Promise<unknown>
  pluginsRemove(id: string): Promise<unknown>
  pluginsOpenFolder(): Promise<unknown>
  onPluginsChanged(callback: () => void): () => void
}

const BRIDGE_METHODS: ReadonlyArray<keyof PluginsBridge> = [
  'pluginsState',
  'pluginsAllow',
  'pluginsEnable',
  'pluginsRemove',
  'pluginsOpenFolder',
  'onPluginsChanged',
]

/** The methods the preload actually has. A missing one stays missing, so the pane can say so. */
export function resolvePluginsBridge(host?: unknown): Partial<PluginsBridge> {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return {}
  const all = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof all[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown => (all[name] as (...a: unknown[]) => unknown).apply(all, args)
  }
  return bridge as Partial<PluginsBridge>
}

/* ------------------------------------------------------------- narrowing -- */

const STATES: readonly PluginState[] = ['off', 'needs-ok', 'changed', 'running', 'stopped', 'broken']

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string') : []
}

function toTool(raw: unknown): PluginToolView | null {
  const one = record(raw)
  if (one === null || text(one.name) === '' || text(one.wire) === '') return null
  const tier = (PLUGIN_TOOL_TIERS as readonly string[]).includes(text(one.tier)) ? (one.tier as PluginToolTier) : null
  if (tier === null) return null
  return { name: text(one.name), wire: text(one.wire), title: text(one.title) || text(one.name), tier }
}

function toPlugin(raw: unknown): PluginView | null {
  const one = record(raw)
  if (one === null || text(one.id) === '') return null
  const state = STATES.includes(one.state as PluginState) ? (one.state as PluginState) : null
  if (state === null) return null
  return {
    id: text(one.id),
    name: text(one.name) || text(one.id),
    summary: text(one.summary),
    version: text(one.version),
    enabled: one.enabled === true,
    state,
    note: text(one.note),
    declared: strings(one.declared).filter(isPluginCapability),
    granted: strings(one.granted).filter(isPluginCapability),
    projects: strings(one.projects),
    allowed: one.allowed === true,
    tools: (Array.isArray(one.tools) ? one.tools : []).map(toTool).filter((tool): tool is PluginToolView => tool !== null),
  }
}

export function toPluginsState(raw: unknown): PluginsState | null {
  const one = record(raw)
  if (one === null || !Array.isArray(one.plugins)) return null
  return {
    folder: text(one.folder),
    confinement: text(one.confinement),
    projects: strings(one.projects),
    plugins: one.plugins.map(toPlugin).filter((plugin): plugin is PluginView => plugin !== null),
  }
}

export function toPluginsResult(raw: unknown): { ok: boolean; message: string | null; state: PluginsState | null } {
  const one = record(raw)
  if (one === null) return { ok: false, message: 'The app answered with something this page cannot read.', state: null }
  const result = one as Partial<PluginsResult>
  return {
    ok: result.ok === true,
    message: typeof result.message === 'string' ? result.message : null,
    state: toPluginsState(one.state),
  }
}

/** The last folder name of a project path, for a compact choice. */
export function projectName(path: string): string {
  const parts = path.split(/[\\/]/).filter((part) => part !== '')
  return parts[parts.length - 1] ?? path
}
