import { describe, expect, it, vi } from 'vitest'
import { accountTools, type AccountToolDeps } from './account-tools'
import { fakeContext, tool } from './agents-area.fixture'

const WORK = { id: 'work', name: 'Work', provider: 'claude' }

function deps(overrides: Partial<AccountToolDeps> = {}): AccountToolDeps {
  return {
    list: () => ({ profiles: [{ ...WORK, configDir: '/accounts/work' }], defaultProfileId: null }),
    agents: () => ({ providers: [] }),
    resolve: () => ({ id: 'work' }),
    find: (id) => (id === 'work' ? WORK : null),
    status: () => ({ exists: true }),
    signIn: async () => ({ state: 'signed-out', detail: 'Run claude to sign in.' }),
    history: () => ({ state: {}, share: 'Shares 2 folders.', unshare: 'Gives it its own copy.', remove: '3 folders of history go.' }),
    create: (name) => ({ id: 'new', name }),
    rename: (id, name) => ({ id, name }),
    remove: () => ({ removed: true, filesDeleted: false, credentialsRetained: true }),
    setDefault: () => ({}),
    setProjectDefault: () => ({}),
    signOut: async () => ({ ok: true, message: 'Signed out.' }),
    share: () => ({ ok: true }),
    unshare: () => ({ ok: true }),
    ...overrides,
  }
}

describe('reading accounts', () => {
  it('includes which account a folder would use, only for an open folder', async () => {
    const resolve = vi.fn<AccountToolDeps['resolve']>(() => ({ id: 'work' }))
    const { context } = fakeContext()
    const list = tool(accountTools(deps({ resolve })), 'accounts.list')
    const out = await list.run({ projectPath: '/work/api' }, context)
    expect((out.value as { newSessionHere: unknown }).newSessionHere).toEqual({ id: 'work' })
    expect(resolve).toHaveBeenCalledWith({ projectPath: '/work/api', provider: null })
    await expect(list.run({ projectPath: '/etc' }, context)).rejects.toThrow(/not a folder this app has open/)
  })

  it('never hands back a string under a credential’s name, even if the store grows one', async () => {
    // The accounts vault is being rebuilt in parallel. A token field appearing
    // on a profile must not reach a model in another application.
    const { context } = fakeContext()
    const leaky = deps({
      list: () => ({ profiles: [{ ...WORK, token: 'sk-ant-secret', credentialsRetained: true }] }),
    })
    const out = await tool(accountTools(leaky), 'accounts.list').run({}, context)
    const text = JSON.stringify(out.value)
    expect(text).not.toContain('sk-ant-secret')
    expect(text).toContain('"token":"[withheld]"')
    // A boolean under the same family of names is a fact, and survives.
    expect(text).toContain('"credentialsRetained":true')
  })

  it('checks sign-in, status and history for one account in one answer', async () => {
    const { context } = fakeContext()
    const out = await tool(accountTools(deps()), 'accounts.status').run({ accountId: 'work' }, context)
    expect(out.value).toMatchObject({ account: WORK, signIn: { state: 'signed-out' }, history: { share: 'Shares 2 folders.' } })
  })
})

describe('changing accounts', () => {
  it('names the account and what is lost in the delete confirmation', () => {
    const { context } = fakeContext()
    const spec = tool(accountTools(deps()), 'accounts.delete')
    expect(spec.summary({ accountId: 'work', deleteFiles: true }, context)).toBe(
      'Delete the claude account Work and its files on disk. 3 folders of history go.',
    )
    expect(spec.summary({ accountId: 'work' }, context)).toContain('its files stay on disk')
  })

  it('refuses an account that does not exist rather than passing the id through', async () => {
    const { context } = fakeContext()
    await expect(tool(accountTools(deps()), 'accounts.rename').run({ accountId: 'nope', name: 'X' }, context)).rejects.toThrow(
      /no account with id nope/,
    )
  })

  it('sets a folder’s default only for an open folder, and the global one without', async () => {
    const setDefault = vi.fn<AccountToolDeps['setDefault']>(() => ({}))
    const setProjectDefault = vi.fn<AccountToolDeps['setProjectDefault']>(() => ({}))
    const { context } = fakeContext()
    const spec = tool(accountTools(deps({ setDefault, setProjectDefault })), 'accounts.set_default')
    await spec.run({ accountId: 'work' }, context)
    await spec.run({ accountId: 'work', projectPath: '/work/web' }, context)
    await spec.run({}, context)
    expect(setDefault.mock.calls).toEqual([['work'], [null]])
    expect(setProjectDefault).toHaveBeenCalledWith('/work/web', 'work')
  })

  it('shares or stops sharing history by the share flag, and quotes the sentence for that direction', async () => {
    const share = vi.fn(() => ({}))
    const unshare = vi.fn(() => ({}))
    const { context } = fakeContext()
    const spec = tool(accountTools(deps({ share, unshare })), 'accounts.share_history')
    expect(spec.summary({ accountId: 'work', share: false }, context)).toContain('Gives it its own copy.')
    await spec.run({ accountId: 'work', share: false }, context)
    expect(unshare).toHaveBeenCalledWith('work')
    expect(share).not.toHaveBeenCalled()
  })
})

describe('signing in', () => {
  it('starts a session on the account, in an open folder, as the copilot’s own', async () => {
    const { context, record } = fakeContext()
    const out = await tool(accountTools(deps()), 'accounts.sign_in').run({ accountId: 'work', folder: '/work/api' }, context)
    expect(record.started).toEqual([
      {
        input: expect.objectContaining({ cwd: '/work/api', provider: 'claude', profileId: 'work', origin: 'copilot', originRunId: 'call-1' }),
        device: undefined,
      },
    ])
    // Noted as started by this run, so reading its sign-in link is not a dialog per read.
    expect(record.noted).toEqual(['started-1'])
    expect(out.value).toMatchObject({ sessionId: 'started-1', accountId: 'work' })
  })

  it('holds a paired device to the folders it was granted', async () => {
    const { context, record } = fakeContext({
      caller: { kind: 'remote', deviceId: 'phone-1', tiers: { read: true, act: true, alter: true } },
    })
    const spec = tool(accountTools(deps()), 'accounts.sign_in')
    expect(() => spec.precheck?.({ accountId: 'work', folder: '/work/api' }, context)).toThrow()
    await spec.run({ accountId: 'work', folder: '/work/web' }, context)
    expect(record.started[0]?.device).toBe('phone-1')
  })
})
