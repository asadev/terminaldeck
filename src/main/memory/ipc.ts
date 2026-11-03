/**
 * The Memory page's channels, and the one service behind them and the memory
 * tools.
 *
 * Every handler takes ids and paths out of a window, and none of them trusts
 * one: a space id is looked up among the spaces discovery found, and a note's
 * path is proven to be inside that space's real folder by `notePath` before
 * anything is opened (`service.ts`). A save carries the version it was read at
 * and is refused when the file moved since. Deleting goes to the Trash.
 *
 * Wiring:
 *
 *     import { registerMemoryIpc } from './memory/ipc'
 *     registerMemoryIpc(ipcMain, { userData, hoot, trash, send })
 */

import type { IpcMain, IpcMainInvokeEvent } from 'electron'
import type { CopilotPaths } from '../copilot-home'
import { findProfile, getState, listProfilesForProvider, systemProfileFor } from '../profiles'
import type { SessionMeta } from '../../shared/types'
import { MemoryService } from './service'
import type { AccountStore, DiscoverInput } from './spaces'

export const MEMORY_CHANGED_CHANNEL = 'memory:changed'

export interface MemoryIpcDeps {
  userData(): string
  /** Hoot's paths, or null before it has a home. */
  hoot(): CopilotPaths | null
  /** `shell.trashItem`. */
  trash(path: string): Promise<void>
  /** Tell the window. */
  send(channel: string, ...args: unknown[]): unknown
}

/** Every Claude and Codex account this app knows, each agent's own install first. */
export function accountStores(): AccountStore[] {
  const stores: AccountStore[] = []
  for (const provider of ['claude', 'codex'] as const) {
    for (const profile of listProfilesForProvider(provider)) {
      stores.push({ provider, configDir: profile.configDir, name: profile.name })
    }
  }
  return stores
}

/**
 * The account store a session runs under — its account's config directory —
 * or null for an agent whose memory this app does not read.
 */
export function storeOfSession(session: SessionMeta): string | null {
  if (session.provider !== 'claude' && session.provider !== 'codex') return null
  const state = getState()
  const profile = (session.profileId ? findProfile(state, session.profileId) : null) ?? systemProfileFor(session.provider, state)
  return profile.provider === session.provider ? profile.configDir : null
}

let current: MemoryService | null = null

/** The service the window's channels use, for the tools that must read the same one. */
export function currentMemory(): MemoryService | null {
  return current
}

export function registerMemoryIpc(ipcMain: IpcMain, deps: MemoryIpcDeps): MemoryService {
  const sources = (): DiscoverInput => ({
    stores: accountStores(),
    hootMemory: deps.hoot()?.memory ?? null,
    userData: deps.userData(),
  })
  const service = new MemoryService({
    sources,
    trash: deps.trash,
    hootPaths: deps.hoot,
    onChanged: (spaceId) => deps.send(MEMORY_CHANGED_CHANNEL, spaceId),
    watch: true,
  })
  current = service

  ipcMain.handle('memory:spaces', async (_event: IpcMainInvokeEvent, refresh: unknown) => ({
    spaces: await service.spaces(refresh === true),
  }))

  ipcMain.handle('memory:notes', async (_event: IpcMainInvokeEvent, spaceId: unknown) => {
    if (typeof spaceId !== 'string') return { ok: false, error: 'That is not a memory on this machine.' }
    try {
      const [notes, graph] = await Promise.all([service.notes(spaceId), service.graph(spaceId)])
      return { ok: true, notes, graph }
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) }
    }
  })

  ipcMain.handle('memory:read', (_event: IpcMainInvokeEvent, spaceId: unknown, path: unknown) =>
    typeof spaceId === 'string' ? service.read(spaceId, path) : { ok: false, error: 'That is not a memory on this machine.' },
  )

  ipcMain.handle('memory:search', async (_event: IpcMainInvokeEvent, query: unknown, spaceIds: unknown) => {
    if (typeof query !== 'string' || !Array.isArray(spaceIds)) return { ok: true, hits: [] }
    const ids = spaceIds.filter((id): id is string => typeof id === 'string')
    return { ok: true, hits: await service.searchIn(query, ids, 40) }
  })

  ipcMain.handle(
    'memory:save',
    (_event: IpcMainInvokeEvent, spaceId: unknown, path: unknown, text: unknown, version: unknown) =>
      typeof spaceId === 'string'
        ? service.save(spaceId, path, text, version)
        : { ok: false, error: 'That is not a memory on this machine.' },
  )

  ipcMain.handle('memory:delete', (_event: IpcMainInvokeEvent, spaceId: unknown, path: unknown, indexLine: unknown) =>
    typeof spaceId === 'string'
      ? service.remove(spaceId, path, { indexLine: indexLine === true })
      : { ok: false, error: 'That is not a memory on this machine.' },
  )

  ipcMain.handle('memory:provenance', (_event: IpcMainInvokeEvent, spaceId: unknown, path: unknown) =>
    typeof spaceId === 'string'
      ? service.provenance(spaceId, path)
      : { ok: false, error: 'That is not a memory on this machine.' },
  )

  return service
}
