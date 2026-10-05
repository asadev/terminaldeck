/**
 * Settings → Plugins, over IPC.
 *
 * Every channel is the owner's, and only the app's own window may use one — the
 * same guard Settings → Connect an AI app and Tasks carry. There is no tool for
 * any of it (`deck-control/actions/agents.ts` says why for each): an assistant
 * that could allow a plugin could give itself whatever that plugin can do.
 */

import type { InvokeRegistrar } from '../deck-control/ai-apps-ipc'
import { isPluginCapability, type PluginAllowInput, type PluginsResult, type PluginsState } from '../../shared/plugins'
import type { PluginHost } from './host'

export const PLUGINS_CHANGED_CHANNEL = 'plugins:changed'

export interface PluginsIpcDeps {
  host: PluginHost
  isApprover(contents: Electron.WebContents): boolean
  /** Show `<userData>/plugins` in Finder, making it first if it is not there. */
  openFolder(): Promise<void>
}

function idOf(value: unknown): string {
  if (typeof value !== 'string' || value === '') throw new Error('plugins: which plugin?')
  return value
}

/** The pane's allow form, read as the closed shape it has to be. */
export function readAllowInput(value: unknown): PluginAllowInput {
  const raw = typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
  const list = (key: string): unknown[] => (Array.isArray(raw[key]) ? (raw[key] as unknown[]) : [])
  return {
    capabilities: list('capabilities').filter(isPluginCapability),
    projects: list('projects').filter((entry): entry is string => typeof entry === 'string' && entry !== ''),
  }
}

export function registerPluginsIpc(ipcMain: InvokeRegistrar, deps: PluginsIpcDeps): void {
  const guard = (event: { sender: Electron.WebContents }): void => {
    if (!deps.isApprover(event.sender)) throw new Error('plugins: only the app’s own window may change plugins')
  }

  ipcMain.handle('plugins:state', (event): PluginsState => {
    guard(event)
    return deps.host.state()
  })
  ipcMain.handle('plugins:allow', (event, id: unknown, input: unknown): Promise<PluginsResult> => {
    guard(event)
    return deps.host.allow(idOf(id), readAllowInput(input))
  })
  ipcMain.handle('plugins:enable', (event, id: unknown, enabled: unknown): Promise<PluginsResult> => {
    guard(event)
    return deps.host.setEnabled(idOf(id), enabled === true)
  })
  ipcMain.handle('plugins:remove', (event, id: unknown): Promise<PluginsResult> => {
    guard(event)
    return deps.host.remove(idOf(id))
  })
  ipcMain.handle('plugins:open-folder', async (event): Promise<void> => {
    guard(event)
    await deps.openFolder()
  })
}
