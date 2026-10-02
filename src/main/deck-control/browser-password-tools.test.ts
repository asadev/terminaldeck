import { describe, expect, it, vi } from 'vitest'
import type { ProfileState } from '../browser-profiles'
import type { ToolContext } from './catalogue'
import { passwordTools, type PasswordToolDeps } from './browser-password-tools'
import { LOCAL_CALLER } from './surface'

const DESK = { caller: LOCAL_CALLER, attended: true } as unknown as ToolContext
const PHONE = { caller: { kind: 'remote', deviceId: 'd1', tiers: LOCAL_CALLER.tiers }, attended: true } as unknown as ToolContext
const NOBODY = { caller: LOCAL_CALLER, attended: false } as unknown as ToolContext

const STATE: ProfileState = {
  profiles: [{ id: 'default', name: 'Default', partition: 'p', createdAt: 1, isDefault: true, avatar: '' }],
  activeId: 'default',
}

/** A password that must never appear in anything this tool returns or says. */
const SECRET = 'correct horse battery staple'

function deps(over: Partial<PasswordToolDeps> = {}): PasswordToolDeps {
  return {
    available: () => true,
    state: () => ({ available: true, path: '/data/logins.bin', exists: true, fault: 'none', message: '' }),
    profiles: () => STATE,
    list: () => [{ profileId: 'default', origin: 'https://github.com', username: 'asad', updatedAt: 1 }],
    forget: () => ({ ok: true, message: 'Saved.' }),
    forgetAll: () => ({ ok: true, message: 'Cleared.' }),
    reveal: () => true,
    offer: () => null,
    answer: () => ({ ok: true, message: 'Saved.' }),
    signInOffer: (viewId) => (viewId === 'view-a' ? { origin: 'https://github.com', usernames: ['asad', 'work'] } : null),
    fill: () => true,
    windows: {
      windows: () => [
        { tabId: 'tab-a', viewId: 'view-a', url: 'https://github.com/login', title: 'Sign in', w: 3, visible: true, servedBy: '' },
        { tabId: 'tab-b', viewId: 'view-b', url: 'https://example.com/', title: 'Example', w: 4, visible: false, servedBy: '' },
      ],
      slotWindow: () => null,
    },
    ...over,
  }
}

describe('browser.passwords', () => {
  it('lists sites and usernames and never a password', async () => {
    const [tool] = passwordTools(deps())
    const out = await tool.run({}, DESK)
    expect(out.value).toMatchObject({ logins: [{ site: 'https://github.com', username: 'asad' }], canStore: true })
    expect(JSON.stringify(out)).not.toContain('password')
  })

  it('has no action that copies, shows or exports a password', () => {
    const [tool] = passwordTools(deps())
    const actions = (tool.inputSchema.properties as { action: { enum: string[] } }).action.enum
    expect(actions.some((action) => /copy|show|export|read|reveal-password/.test(action))).toBe(false)
  })

  it('makes filling, saving and forgetting alter, so a person says yes to each', () => {
    const [tool] = passwordTools(deps())
    for (const action of ['fill', 'answer', 'forget', 'forgetall']) {
      expect(tool.escalate?.({ action }, DESK), action).toBe('alter')
    }
    expect(tool.escalate?.({}, DESK)).toBe('read')
  })

  it('names the site and the username in the sentence the person answers before a fill', () => {
    const [tool] = passwordTools(deps())
    const sentence = tool.summary({ action: 'fill', window: 'W3', username: 'work' }, DESK)
    expect(sentence).toContain('work')
    expect(sentence).toContain('https://github.com')
  })

  it('fills the named login into the page that announced the form', async () => {
    const fill = vi.fn<PasswordToolDeps['fill']>(() => true)
    const [tool] = passwordTools(deps({ fill }))
    const out = await tool.run({ action: 'fill', window: 'W3', username: 'work' }, DESK)
    expect(fill).toHaveBeenCalledWith('view-a', 'work')
    expect(JSON.stringify(out)).not.toContain(SECRET)
  })

  it('refuses a fill on a page with no sign-in form, before anybody is asked', () => {
    const [tool] = passwordTools(deps())
    expect(() => tool.precheck?.({ action: 'fill', window: 'W4' }, DESK)).toThrow('not showing a sign-in form')
  })

  it('refuses a username this site has no saved login for', () => {
    const [tool] = passwordTools(deps())
    expect(() => tool.precheck?.({ action: 'fill', window: 'W3', username: 'nobody' }, DESK)).toThrow('Saved: asad, work')
  })

  it('says nothing was filled when the page moved between the yes and the fill', async () => {
    const [tool] = passwordTools(deps({ fill: () => false }))
    await expect(tool.run({ action: 'fill', window: 'W3' }, DESK)).rejects.toThrow('nothing was filled')
  })

  it('is the person at this machine’s alone: refused from a paired device and when nobody is there', () => {
    const [tool] = passwordTools(deps())
    expect(() => tool.precheck?.({}, PHONE)).toThrow('only works for the person at this machine')
    expect(() => tool.precheck?.({}, NOBODY)).toThrow('nobody at the machine')
  })

  it('answers an offer only when a page has made one', () => {
    const [tool] = passwordTools(deps())
    expect(() => tool.precheck?.({ action: 'answer', save: true }, DESK)).toThrow('no page is waiting')
  })

  it('refuses to forget a login that is not saved', () => {
    const [tool] = passwordTools(deps())
    expect(() => tool.precheck?.({ action: 'forget', site: 'https://github.com', username: 'ghost' }, DESK)).toThrow(
      'has no saved login',
    )
  })
})
