import { existsSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { vi } from 'vitest'
import {
  clearDashboard,
  dashboardFileName,
  dashboardFilePath,
  loadDashboard,
  saveDashboard,
} from './dashboard-store'

/**
 * The store's whole job is to be boring and durable, so these tests are about
 * the failure modes rather than the happy path: identifying a project the same
 * way every time, and never letting a bad write destroy a good layout.
 *
 * Deliberately no import of the renderer's layout model — the store treats a
 * layout as opaque JSON, and `tsconfig.node` cannot see `src/renderer` anyway.
 */

const USER_DATA = join(tmpdir(), `terminaldeck-dashboard-store-test-${process.pid}`)

vi.mock('electron', async () => {
  const { tmpdir: tmp } = await import('node:os')
  const { join: j } = await import('node:path')
  return { app: { getPath: () => j(tmp(), `terminaldeck-dashboard-store-test-${process.pid}`) } }
})

afterAll(() => rmSync(USER_DATA, { recursive: true, force: true }))

const PROJECT = '/Users/asad/Projects/terminaldeck'

function layout(widgetId = 'a'): Record<string, unknown> {
  return {
    version: 1,
    projectPath: PROJECT,
    columns: 12,
    widgets: [{ id: widgetId, type: 'git', x: 0, y: 0, w: 6, h: 6 }],
  }
}

describe('dashboardFileName', () => {
  it('identifies a project the same way however its path is spelled', () => {
    expect(dashboardFileName('/Users/asad/Projects/terminaldeck/')).toBe(dashboardFileName(PROJECT))
    expect(dashboardFileName('/Users/asad/Projects/./terminaldeck')).toBe(dashboardFileName(PROJECT))
  })

  it('keeps same-named folders in different trees apart', () => {
    expect(dashboardFileName('/a/web')).not.toBe(dashboardFileName('/b/web'))
  })

  it('produces a filename with no path separators in it', () => {
    const name = dashboardFileName('/Users/asad/Projects/my app (v2)')
    expect(name).not.toContain('/')
    expect(name).toMatch(/^[a-zA-Z0-9._-]+\.json$/)
  })

  it('never yields a bare extension for a path with no usable basename', () => {
    expect(dashboardFileName('/')).toMatch(/^project-[0-9a-f]{10}\.json$/)
  })
})

describe('saveDashboard', () => {
  it('round-trips a layout', () => {
    saveDashboard(PROJECT, layout())
    expect(loadDashboard(PROJECT)).toEqual(layout())
  })

  it('stores an empty dashboard, because clearing every tile is a choice', () => {
    const project = '/Users/asad/Projects/emptied'
    saveDashboard(project, { version: 1, columns: 12, widgets: [] })
    expect(loadDashboard(project)).toMatchObject({ widgets: [] })
  })

  it('stamps the caller path over any path the payload claims', () => {
    const project = '/Users/asad/Projects/claimant'
    saveDashboard(project, { ...layout(), projectPath: '/somewhere/else' })
    expect(loadDashboard(project)).toMatchObject({ projectPath: project })
  })

  it('rejects a payload that is not a layout', () => {
    for (const junk of [null, 42, 'nope', [], {}, { widgets: 'lots' }]) {
      expect(() => saveDashboard(PROJECT, junk)).toThrow(/not a layout/)
    }
  })

  it('rejects an absurd number of widgets', () => {
    const widgets = Array.from({ length: 201 }, (_, i) => ({ id: `w${i}`, type: 'github' }))
    expect(() => saveDashboard(PROJECT, { widgets })).toThrow(/not a layout/)
  })

  it('rejects a relative project path', () => {
    expect(() => saveDashboard('projects/terminaldeck', layout())).toThrow(/absolute/)
    expect(() => loadDashboard('projects/terminaldeck')).toThrow(/absolute/)
  })

  it('leaves no temp file behind', () => {
    const project = '/Users/asad/Projects/tidy'
    saveDashboard(project, layout())
    const files = readdirSync(join(USER_DATA, 'dashboards'))
    expect(files.some((f) => f.endsWith('.tmp'))).toBe(false)
  })

  it('replaces the previous layout rather than appending to it', () => {
    const project = '/Users/asad/Projects/replaced'
    saveDashboard(project, layout('first'))
    saveDashboard(project, layout('second'))
    const raw = readFileSync(dashboardFilePath(project), 'utf8')
    expect(JSON.parse(raw)).toEqual({ ...layout('second'), projectPath: project })
  })
})

describe('loadDashboard', () => {
  it('returns null on first run', () => {
    expect(loadDashboard('/Users/asad/Projects/never-opened')).toBeNull()
  })

  it('returns null for truncated JSON instead of throwing', () => {
    const project = '/Users/asad/Projects/truncated'
    saveDashboard(project, layout())
    writeFileSync(dashboardFilePath(project), '{"widgets": [{"id":', 'utf8')
    expect(loadDashboard(project)).toBeNull()
  })

  it('ignores a file too large to be a real layout', () => {
    const project = '/Users/asad/Projects/huge'
    saveDashboard(project, layout())
    writeFileSync(dashboardFilePath(project), `{"widgets":[],"pad":"${'x'.repeat(600_000)}"}`, 'utf8')
    expect(loadDashboard(project)).toBeNull()
  })
})

describe('clearDashboard', () => {
  it('removes the file so the next load starts from the defaults', () => {
    const project = '/Users/asad/Projects/reset-me'
    saveDashboard(project, layout())
    expect(existsSync(dashboardFilePath(project))).toBe(true)
    clearDashboard(project)
    expect(loadDashboard(project)).toBeNull()
  })

  it('is a no-op when there is nothing to clear', () => {
    expect(() => clearDashboard('/Users/asad/Projects/never-saved')).not.toThrow()
  })
})
