/**
 * Plugins, assembled for the app: the host, its Settings channels, the native
 * question, and the tools the assistant is offered.
 *
 * Called once from `deck-control/index.ts`, which owns the three things this
 * needs and nothing else has: the dispatcher the tools go through, the window
 * that is the app's own approver, and the task store `tasks.read` reads.
 * Nothing starts at all unless that assembly is given a `plugins` dependency,
 * so a test that builds the dispatcher never scans a real `<userData>`.
 */

import { mkdirSync } from 'node:fs'
import type { ToolSpec } from '../deck-control/catalogue'
import type { InvokeRegistrar } from '../deck-control/ai-apps-ipc'
import { nativePluginConsent } from './consent'
import { PluginHost, type PluginServices } from './host'
import { PLUGINS_CHANGED_CHANNEL, registerPluginsIpc } from './ipc'
import { pluginTools } from './tools'

export { PluginHost } from './host'
export type { PluginServices, PluginTask } from './host'

export interface PluginsDeps {
  userData: string
  isApprover(contents: Electron.WebContents): boolean
  /** The app's own window, when one has said it is the approver. */
  approver(): Electron.WebContents | null
  broadcast(channel: string): void
  services: PluginServices
}

export interface PluginsHandle {
  host: PluginHost
  /** For `DeckControlOptions.liveTools`. */
  tools(): readonly ToolSpec[]
  stop(): Promise<void>
}

export function startPlugins(ipcMain: InvokeRegistrar, deps: PluginsDeps): PluginsHandle {
  const host = new PluginHost({
    userData: deps.userData,
    services: deps.services,
    consent: nativePluginConsent(deps.approver),
    trash: async (path) => {
      const { shell } = await import('electron')
      await shell.trashItem(path)
    },
    onChange: () => deps.broadcast(PLUGINS_CHANGED_CHANNEL),
  })
  registerPluginsIpc(ipcMain, {
    host,
    isApprover: deps.isApprover,
    openFolder: async () => {
      mkdirSync(host.folder, { recursive: true })
      const { shell } = await import('electron')
      const failed = await shell.openPath(host.folder)
      if (failed !== '') throw new Error(failed)
    },
  })
  void host.startAll().catch((error: unknown) => console.error('[plugins] could not start the plugins:', error))
  return {
    host,
    tools: () => pluginTools(host),
    stop: () => host.stopAll(),
  }
}
