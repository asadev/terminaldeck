import { contextBridge, ipcRenderer, type IpcRendererEvent } from 'electron'
import type { CreateSessionInput, SessionMeta } from '../shared/types'

/**
 * The renderer's only route to the main process. Everything is an explicit
 * method — no raw ipcRenderer is ever exposed to page code.
 */
const api = {
  getBrand: (): Promise<{ name: string; tagline: string }> => ipcRenderer.invoke('brand:get'),

  detectProviders: (): Promise<Record<string, boolean>> => ipcRenderer.invoke('providers:detect'),

  listProjects: (): Promise<Array<{ path: string; lastOpenedAt: number }>> =>
    ipcRenderer.invoke('projects:list'),
  addProject: (path: string): Promise<unknown> => ipcRenderer.invoke('projects:add', path),
  removeProject: (path: string): Promise<void> => ipcRenderer.invoke('projects:remove', path),
  getPreferences: (): Promise<Record<string, unknown>> => ipcRenderer.invoke('prefs:get'),
  setPreferences: (patch: Record<string, unknown>): Promise<Record<string, unknown>> =>
    ipcRenderer.invoke('prefs:set', patch),

  pickProjectFolder: (): Promise<string | null> => ipcRenderer.invoke('project:pick'),

  createSession: (input: CreateSessionInput): Promise<SessionMeta> =>
    ipcRenderer.invoke('session:create', input),

  writeToSession: (id: string, data: string): void => {
    ipcRenderer.send('session:write', id, data)
  },

  resizeSession: (id: string, cols: number, rows: number): void => {
    ipcRenderer.send('session:resize', id, cols, rows)
  },

  getScrollback: (id: string): Promise<string> => ipcRenderer.invoke('session:scrollback', id),

  killSession: (id: string): Promise<void> => ipcRenderer.invoke('session:kill', id),

  listSessions: (): Promise<SessionMeta[]> => ipcRenderer.invoke('session:list'),

  /** Returns an unsubscribe function so React effects can clean up properly. */
  onSessionData: (cb: (id: string, data: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, data: string) => cb(id, data)
    ipcRenderer.on('session:data', handler)
    return () => ipcRenderer.off('session:data', handler)
  },

  onSessionExit: (cb: (id: string, exitCode: number) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, code: number) => cb(id, code)
    ipcRenderer.on('session:exit', handler)
    return () => ipcRenderer.off('session:exit', handler)
  },

  onSessionStatus: (cb: (id: string, status: string) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, id: string, status: string) => cb(id, status)
    ipcRenderer.on('session:status', handler)
    return () => ipcRenderer.off('session:status', handler)
  },

  /* ------------------------------------------------------------ cost -- */

  getProjectCost: (cwd: string): Promise<unknown> => ipcRenderer.invoke('cost:project', cwd),
  getSessionCost: (transcriptPath: string): Promise<unknown> =>
    ipcRenderer.invoke('cost:session', transcriptPath),
  listSessionTranscripts: (cwd: string): Promise<unknown> => ipcRenderer.invoke('cost:sessions', cwd),
  watchProjectCost: (cwd: string): Promise<unknown> => ipcRenderer.invoke('cost:watch', cwd),
  unwatchProjectCost: (cwd: string): Promise<void> => ipcRenderer.invoke('cost:unwatch', cwd),
  getModelPricing: (model: string): Promise<unknown> => ipcRenderer.invoke('cost:pricing', model),
  formatCost: (value: number): Promise<string> => ipcRenderer.invoke('cost:format', value),
  onCostUpdate: (cb: (summary: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, summary: unknown) => cb(summary)
    ipcRenderer.on('cost:update', handler)
    return () => ipcRenderer.off('cost:update', handler)
  },

  /* ------------------------------------------------------------- git -- */

  gitStatus: (cwd: string): Promise<unknown> => ipcRenderer.invoke('git:status', cwd),
  gitDiff: (cwd: string, path: string, options?: { staged?: boolean; untracked?: boolean }): Promise<string> =>
    ipcRenderer.invoke('git:diff', cwd, path, options ?? {}),
  watchGit: (cwd: string): Promise<unknown> => ipcRenderer.invoke('git:watch', cwd),
  unwatchGit: (cwd: string): void => {
    ipcRenderer.send('git:unwatch', cwd)
  },
  onGitStatus: (cb: (cwd: string, status: unknown) => void): (() => void) => {
    const handler = (_e: IpcRendererEvent, cwd: string, status: unknown) => cb(cwd, status)
    ipcRenderer.on('git:status-changed', handler)
    return () => ipcRenderer.off('git:status-changed', handler)
  },

  /* -------------------------------------------------------- files -- */

  listDir: (root: string, relDir: string, options?: { showIgnored?: boolean }): Promise<unknown> =>
    ipcRenderer.invoke('fs:list', root, relDir, options ?? {}),
  readFile: (root: string, relPath: string): Promise<unknown> =>
    ipcRenderer.invoke('fs:read', root, relPath),

  searchProjectFiles: (request: { root: string; refresh?: boolean; limit?: number }): Promise<unknown> =>
    ipcRenderer.invoke('search:files', request),
  cancelProjectFileSearch: (): Promise<void> => ipcRenderer.invoke('search:cancel'),
  invalidateProjectFiles: (root?: string): Promise<void> =>
    ipcRenderer.invoke('search:invalidate', root),

  /* ------------------------------------------------------------ board -- */

  loadBoard: (projectPath: string): Promise<unknown> => ipcRenderer.invoke('board:load', projectPath),
  saveBoard: (projectPath: string, board: unknown): Promise<void> =>
    ipcRenderer.invoke('board:save', projectPath, board),
}

contextBridge.exposeInMainWorld('pawl', api)

export type PawlBridge = typeof api
