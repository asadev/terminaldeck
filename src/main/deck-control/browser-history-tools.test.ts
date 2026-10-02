import { describe, expect, it, vi } from 'vitest'
import type { Visit } from '../browser-history'
import type { BrowserProfile, ProfileState } from '../browser-profiles'
import type { ToolContext } from './catalogue'
import { historyTools, profileTools, type HistoryToolDeps, type ProfileToolDeps } from './browser-history-tools'
import { LOCAL_CALLER } from './surface'

const DESK = { caller: LOCAL_CALLER, attended: true } as unknown as ToolContext

function profile(id: string, name: string, isDefault = false): BrowserProfile {
  return { id, name, partition: `persist:${id}`, createdAt: 1, isDefault, avatar: '' }
}

const STATE: ProfileState = {
  profiles: [profile('default', 'Default', true), profile('p-work', 'Work')],
  activeId: 'default',
}

const VISITS: Visit[] = [
  { profileId: 'p-work', url: 'https://github.com/', title: 'GitHub', visitedAt: 5, visits: 9 },
  { profileId: 'default', url: 'https://example.com/', title: 'Example', visitedAt: 4, visits: 1 },
]

function historyDeps(over: Partial<HistoryToolDeps> = {}): HistoryToolDeps {
  return {
    profiles: () => STATE,
    list: (profileId) => VISITS.filter((visit) => visit.profileId === profileId),
    suggest: (profileId) => VISITS.filter((visit) => visit.profileId === profileId),
    forget: () => [],
    clear: () => [],
    ...over,
  }
}

describe('browser.history', () => {
  it('reads the profile that is switched on when none is named', async () => {
    const [tool] = historyTools(historyDeps())
    const out = (await tool.run({}, DESK)).value as { profile: string; visits: { url: string }[] }
    expect(out.profile).toBe('Default')
    expect(out.visits.map((visit) => visit.url)).toEqual(['https://example.com/'])
  })

  it('names a profile by its name, the way a person says it', async () => {
    const list = vi.fn<HistoryToolDeps['list']>(() => [])
    const [tool] = historyTools(historyDeps({ list }))
    await tool.run({ profile: 'work' }, DESK)
    expect(list).toHaveBeenCalledWith('p-work', '', 100)
  })

  it('refuses a profile that does not exist, naming the ones that do', () => {
    const [tool] = historyTools(historyDeps())
    expect(() => tool.precheck?.({ profile: 'Home' }, DESK)).toThrow('These exist: Default, Work')
  })

  it('makes forgetting and clearing alter', () => {
    const [tool] = historyTools(historyDeps())
    expect(tool.escalate?.({ action: 'forget' }, DESK)).toBe('alter')
    expect(tool.escalate?.({ action: 'clear' }, DESK)).toBe('alter')
    expect(tool.escalate?.({ action: 'suggest' }, DESK)).toBe('read')
  })

  it('refuses to forget an address that is not there', async () => {
    const forget = vi.fn<HistoryToolDeps['forget']>(() => [])
    const [tool] = historyTools(historyDeps({ forget }))
    await expect(tool.run({ action: 'forget', url: 'https://nowhere.test/' }, DESK)).rejects.toThrow('is not in')
    expect(forget).not.toHaveBeenCalled()
  })

  it('says a change is saved and when an open panel will show it', async () => {
    const [tool] = historyTools(historyDeps())
    const out = (await tool.run({ action: 'clear', profile: 'Work' }, DESK)).value as { note: string }
    expect(out.note).toContain('when it next reads its list')
  })
})

function profileDeps(over: Partial<ProfileToolDeps> = {}): ProfileToolDeps {
  return {
    state: () => STATE,
    create: (name) => profile('p-new', name ?? 'Profile 3'),
    rename: () => STATE,
    avatar: () => STATE,
    activate: () => STATE,
    remove: async () => STATE,
    ...over,
  }
}

describe('browser.profiles', () => {
  it('lists each profile and which one is on', async () => {
    const [tool] = profileTools(profileDeps())
    const out = (await tool.run({}, DESK)).value as { profiles: { name: string; on: boolean }[] }
    expect(out.profiles).toEqual([
      expect.objectContaining({ name: 'Default', on: true }),
      expect.objectContaining({ name: 'Work', on: false }),
    ])
  })

  it('makes every change alter', () => {
    const [tool] = profileTools(profileDeps())
    for (const action of ['create', 'rename', 'avatar', 'activate', 'delete']) {
      expect(tool.escalate?.({ action }, DESK), action).toBe('alter')
    }
  })

  it('refuses to delete the default profile before anybody is asked', () => {
    const [tool] = profileTools(profileDeps())
    expect(() => tool.precheck?.({ action: 'delete', profile: 'Default' }, DESK)).toThrow('cannot be deleted')
  })

  it('switches by name, and says what that does to windows already open', async () => {
    const activate = vi.fn<ProfileToolDeps['activate']>(() => STATE)
    const [tool] = profileTools(profileDeps({ activate }))
    const out = (await tool.run({ action: 'activate', profile: 'Work' }, DESK)).value as { note: string }
    expect(activate).toHaveBeenCalledWith('p-work')
    expect(out.note).toContain('Windows already open keep the profile')
  })

  it('names the profile it is about to delete in the sentence the person answers', () => {
    const [tool] = profileTools(profileDeps())
    expect(tool.summary({ action: 'delete', profile: 'Work' }, DESK)).toContain('cookies, storage and cache')
  })
})
