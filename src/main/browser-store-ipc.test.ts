import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  installBrowserStore,
  installedBrowserTools,
  registerBrowserStoreIpc,
  resetBrowserStore,
} from './browser-store-ipc'
import { BROWSER_TOOL_CATALOGUE } from './browser-store-catalogue'

/**
 * The seam between the panel and the store, and the one state it has to be
 * honest about.
 *
 * A build whose wiring order changed underneath this has no store. Every channel
 * still answers, and every answer says so — an empty list rather than a throw
 * into a React effect, and a refusal with a sentence rather than a promise. The
 * same judgement `browserDriveTools` makes about the drive: a feature that is
 * absent should be visibly absent, not a crash at launch.
 */

type Handler = (event: unknown, ...args: unknown[]) => unknown

function fakeIpc(): { ipcMain: IpcMain; handlers: Map<string, Handler> } {
  const handlers = new Map<string, Handler>()
  const ipcMain = {
    handle: (channel: string, handler: Handler) => handlers.set(channel, handler),
  } as unknown as IpcMain
  return { ipcMain, handlers }
}

let root = ''

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-store-ipc-'))
  resetBrowserStore()
})

afterEach(() => {
  resetBrowserStore()
  rmSync(root, { recursive: true, force: true })
})

describe('with no store built', () => {
  it('hands the tool layer an empty list rather than throwing', () => {
    expect(installedBrowserTools()).toEqual([])
  })

  it('answers every channel, and refuses with a sentence', async () => {
    const { ipcMain, handlers } = fakeIpc()
    registerBrowserStoreIpc(ipcMain)
    expect([...handlers.keys()].sort()).toEqual([
      'browser-store:install',
      'browser-store:list',
      'browser-store:remove',
    ])
    const view = (await handlers.get('browser-store:list')?.(null)) as {
      view: { tools: unknown[] }
      orphans: unknown[]
    }
    expect(view.view.tools).toEqual([])
    expect(view.orphans).toEqual([])
    const install = (await handlers.get('browser-store:install')?.(null, 'page-images')) as {
      ok: boolean
      message: string
    }
    expect(install.ok).toBe(false)
    expect(install.message).not.toBe('')
  })
})

describe('with a store built', () => {
  it('lists the shipped catalogue, all of it available until somebody chooses', async () => {
    installBrowserStore({ userData: () => root })
    const { ipcMain, handlers } = fakeIpc()
    registerBrowserStoreIpc(ipcMain)
    const answer = (await handlers.get('browser-store:list')?.(null)) as {
      view: { tools: { id: string; state: string }[] }
    }
    expect(answer.view.tools.map((tool) => tool.id)).toEqual(
      BROWSER_TOOL_CATALOGUE.map((entry) => entry.id),
    )
    expect(answer.view.tools.every((tool) => tool.state === 'available')).toBe(true)
  })

  it('installs through the channel, and the tool layer sees it on the next call', async () => {
    installBrowserStore({ userData: () => root })
    const { ipcMain, handlers } = fakeIpc()
    registerBrowserStoreIpc(ipcMain)
    // Read as a function per call, never captured: pressing Install has to land
    // on the next tool call rather than on the next launch.
    expect(installedBrowserTools()).toHaveLength(0)
    const result = (await handlers.get('browser-store:install')?.(null, 'page-images')) as {
      ok: boolean
    }
    expect(result.ok).toBe(true)
    expect(installedBrowserTools().map((tool) => tool.recipe.id)).toEqual(['page-images'])

    const removed = (await handlers.get('browser-store:remove')?.(null, 'page-images')) as {
      ok: boolean
    }
    expect(removed.ok).toBe(true)
    expect(installedBrowserTools()).toHaveLength(0)
  })

  it('refuses an id that is not a string, so nothing can be aimed at a path', async () => {
    installBrowserStore({ userData: () => root })
    const { ipcMain, handlers } = fakeIpc()
    registerBrowserStoreIpc(ipcMain)
    const result = (await handlers.get('browser-store:install')?.(null, { id: 'x' })) as {
      ok: boolean
    }
    expect(result.ok).toBe(false)
  })
})
