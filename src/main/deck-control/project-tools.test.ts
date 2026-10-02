import { describe, expect, it } from 'vitest'
import { contextFor, fakeSurface, toolNamed } from './lane-fakes'
import { projectTools, type FolderEntry, type ProjectToolDeps } from './project-tools'
import { Refused } from './surface'

function depsWith(overrides: Partial<ProjectToolDeps> = {}): { deps: ProjectToolDeps; calls: string[] } {
  const calls: string[] = []
  const folders = new Set(['/Users/me', '/Users/me/Projects', '/Users/me/Projects/app', '/Users/me/Projects/app/.git', '/work/api'])
  const listing: FolderEntry[] = [
    { name: 'Projects', kind: 'dir', blocked: false },
    { name: '.config', kind: 'dir', blocked: false },
    { name: 'notes.txt', kind: 'file', blocked: false },
    { name: 'loop', kind: 'dir', blocked: true },
  ]
  const deps: ProjectToolDeps = {
    home: () => '/Users/me',
    listFolder: async () => ({ entries: listing, truncated: false }),
    isFolder: async (path) => folders.has(path),
    addProject: (path) => {
      calls.push(`add ${path}`)
    },
    removeProject: (path) => {
      calls.push(`remove ${path}`)
    },
    showInWindow: async () => true,
    initRepo: async (cwd) => {
      calls.push(`init ${cwd}`)
      return { repo: true, cwd }
    },
    devServers: {
      list: () => [{ folder: '/work/api', status: 'idle' }],
      start: async (folder) => {
        calls.push(`dev ${folder}`)
        return { folder, status: 'starting' }
      },
      ports: async () => [{ port: 5173, process: 'node' }],
    },
    dashboard: {
      load: () => null,
      save: (path) => {
        calls.push(`save ${path}`)
      },
      clear: (path) => {
        calls.push(`clear ${path}`)
      },
    },
    artifacts: {
      list: async (cwd, options) => ({ cwd, ...options }),
      history: async (cwd, relPath) => ({ cwd, relPath }),
    },
    ...overrides,
  }
  return { deps, calls }
}

describe('choosing a folder with nobody at the Mac', () => {
  it('browses folders only, hides dot-folders unless asked, and says which are repositories', async () => {
    const { surface } = fakeSurface()
    const browse = toolNamed(projectTools(depsWith().deps), 'projects.browse')
    const plain = (await browse.run({}, contextFor(surface))).value as { path: string; folders: Array<{ name: string; repo: boolean }> }
    expect(plain.path).toBe('/Users/me')
    expect(plain.folders.map((folder) => folder.name)).toEqual(['Projects'])

    const hidden = (await browse.run({ showHidden: true }, contextFor(surface))).value as { folders: Array<{ name: string }> }
    expect(hidden.folders.map((folder) => folder.name)).toEqual(['Projects', '.config'])
  })

  it('refuses a relative path rather than guessing what it is relative to', async () => {
    const { surface } = fakeSurface()
    await expect(toolNamed(projectTools(depsWith().deps), 'projects.browse').run({ path: 'Projects' }, contextFor(surface))).rejects.toThrow(
      /absolute/,
    )
  })

  it('confirms opening a project, because the open projects bound what every tool may name', () => {
    expect(toolNamed(projectTools(depsWith().deps), 'projects.add').tier).toBe('alter')
    expect(toolNamed(projectTools(depsWith().deps), 'projects.remove').tier).toBe('alter')
  })

  it('never opens this app’s own storage as a project, before anybody is asked', () => {
    const { surface } = fakeSurface()
    const add = toolNamed(projectTools(depsWith().deps), 'projects.add')
    expect(() => add.precheck?.({ path: '/state/copilot' }, contextFor(surface))).toThrow(Refused)
    expect(() => add.precheck?.({ path: '/state' }, contextFor(surface))).toThrow(Refused)
    // A sibling whose name merely starts the same is not inside it.
    expect(() => add.precheck?.({ path: '/state-two' }, contextFor(surface))).not.toThrow()
  })

  it('opens a folder, and says whether the window took it', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith({ showInWindow: async () => false })
    const output = await toolNamed(projectTools(deps), 'projects.add').run({ path: '/Users/me/Projects/app' }, contextFor(surface))
    expect(calls).toEqual(['add /Users/me/Projects/app'])
    expect(output.value).toMatchObject({ inWindow: false })
    expect((output.value as { note: string }).note).toMatch(/once a session starts there/)
  })

  it('puts a project away without stopping what runs in it, and says what still does', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const output = await toolNamed(projectTools(deps), 'projects.remove').run({ path: '/work/api' }, contextFor(surface))
    expect(calls).toEqual(['remove /work/api'])
    expect(output.value).toMatchObject({ stillRunning: ['s1'] })
  })
})

describe('the views’ own writes', () => {
  it('inits a repository only where there is none', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const init = toolNamed(projectTools(deps), 'git.init')
    expect((await init.run({ cwd: '/work/api' }, contextFor(surface))).value).toMatchObject({ created: false })
    expect((await init.run({ cwd: '/work/web' }, contextFor(surface))).value).toMatchObject({ created: true })
    expect(calls).toEqual(['init /work/web'])
  })

  it('starts a dev server only in an open project, as ordinary work; listing is a read', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const dev = toolNamed(projectTools(deps), 'dev.servers')
    expect(dev.escalate?.({ action: 'list' }, contextFor(surface))).toBe('read')
    expect(dev.escalate?.({ action: 'start', cwd: '/work/api' }, contextFor(surface))).toBe('act')
    expect(() => dev.precheck?.({ action: 'start', cwd: '/tmp' }, contextFor(surface))).toThrow(/not a folder this app has open/)
    await dev.run({ action: 'start', cwd: '/work/api' }, contextFor(surface))
    expect(calls).toEqual(['dev /work/api'])
  })

  it('confirms saving or resetting an Overview arrangement', async () => {
    const { surface } = fakeSurface()
    const { deps, calls } = depsWith()
    const layout = toolNamed(projectTools(deps), 'dashboard.layout')
    expect(layout.escalate?.({ action: 'read', cwd: '/work/api' }, contextFor(surface))).toBe('read')
    expect(layout.escalate?.({ action: 'reset', cwd: '/work/api' }, contextFor(surface))).toBe('alter')
    expect(() => layout.precheck?.({ action: 'save', cwd: '/work/api' }, contextFor(surface))).toThrow(/layout/)
    await layout.run({ action: 'save', cwd: '/work/api', layout: { widgets: [] } }, contextFor(surface))
    expect(calls).toEqual(['save /work/api'])
  })

  it('reads one file’s history only by a path inside the project', async () => {
    const { surface } = fakeSurface()
    const artifacts = toolNamed(projectTools(depsWith().deps), 'artifacts.list')
    await expect(artifacts.run({ cwd: '/work/api', path: '../secrets.txt' }, contextFor(surface))).rejects.toThrow(/relative/)
    expect((await artifacts.run({ cwd: '/work/api', path: 'src/a.ts' }, contextFor(surface))).value).toEqual({
      cwd: '/work/api',
      relPath: 'src/a.ts',
    })
  })
})
