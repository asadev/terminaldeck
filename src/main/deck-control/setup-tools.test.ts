import { describe, expect, it, vi } from 'vitest'
import { fakeContext, tool } from './agents-area.fixture'
import { setupTools, type SetupToolDeps } from './setup-tools'

const GITIGNORE_FIX = {
  id: 'create-gitignore',
  label: 'Create .gitignore',
  description: 'Writes a .gitignore for this stack.',
  touches: ['.gitignore'],
  destructive: false,
}

function deps(overrides: Partial<SetupToolDeps> = {}): SetupToolDeps {
  return {
    setup: async () => ({ tools: [] }),
    scan: async () => ({ checks: [{ id: 'gitignore', fix: GITIGNORE_FIX }, { id: 'readme', fix: null }] }),
    fix: async () => ({ ok: true, message: 'Wrote .gitignore.', changed: ['.gitignore'] }),
    fixIds: new Set(['create-gitignore', 'create-readme']),
    ...overrides,
  }
}

describe('readiness', () => {
  it('scans only an open folder', async () => {
    const { context } = fakeContext()
    expect(() => tool(setupTools(deps()), 'readiness.scan').precheck?.({ projectPath: '/etc' }, context)).toThrow(
      /not a folder this app has open/,
    )
  })

  it('applies a fix the folder’s scan is offering, and returns what it applied', async () => {
    const fix = vi.fn<SetupToolDeps['fix']>(deps().fix)
    const { context } = fakeContext()
    const out = await tool(setupTools(deps({ fix })), 'readiness.fix').run({ projectPath: '/work/api', fixId: 'create-gitignore' }, context)
    expect(fix).toHaveBeenCalledWith('/work/api', 'create-gitignore')
    expect(out.value).toMatchObject({ changed: ['.gitignore'], applied: GITIGNORE_FIX })
  })

  it('refuses a fix the scan is not offering right now, without applying anything', async () => {
    const fix = vi.fn<SetupToolDeps['fix']>(deps().fix)
    const { context } = fakeContext()
    await expect(
      tool(setupTools(deps({ fix })), 'readiness.fix').run({ projectPath: '/work/api', fixId: 'create-readme' }, context),
    ).rejects.toThrow(/not offering create-readme/)
    expect(fix).not.toHaveBeenCalled()
  })

  it('refuses a fix id the channel would not accept, before anybody is asked', () => {
    const { context } = fakeContext()
    expect(() =>
      tool(setupTools(deps()), 'readiness.fix').precheck?.({ projectPath: '/work/api', fixId: 'rm-rf' }, context),
    ).toThrow(/not a fix this version can apply/)
  })
})
