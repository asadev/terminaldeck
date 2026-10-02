import type { Visit } from '../browser-history'
import type { BrowserProfile, ProfileState } from '../browser-profiles'
import {
  actionOf,
  escalateBy,
  notASession,
  optInt,
  optStr,
  profileIdOf,
  str,
} from './browser-area-kit'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * `browser.history` and `browser.profiles` — the two lists every other browser
 * setting is filed under.
 *
 * ## Why these two share a file
 *
 * History is kept **per profile** (`browser-history.ts` files every visit under
 * the profile whose partition loaded it), so a history tool that could not say
 * which profile it meant would be answering about whichever happened to be
 * switched on — the dead end `profileSession` was written to stop. Both tools
 * name a profile the same way, through `profileIdOf`, by name or by id, and both
 * default to the one switched on, which is the one the browser's own panels show.
 *
 * ## The tiers
 *
 * Reading the history is `read`. Forgetting one address and clearing a
 * profile's history are `alter`, on the house rule for anything that forgets —
 * neither comes back. Every change to profiles is `alter` too: creating,
 * renaming and badging one change configuration a person sees in the browser's
 * own menu, switching which one is on changes whose logins every new window
 * opens with, and deleting one throws away its cookies, storage and cache.
 *
 * ## What the window shows afterwards
 *
 * The profile menu and the history panel read their lists when they open, and
 * neither has a push from this process. So a change made here is saved and in
 * force the moment the call returns — a new window opens in the profile just
 * switched on — and a panel already open on screen shows it when it next reads
 * its list. The answers say so, rather than letting "done" read as "on screen".
 */

/* --------------------------------------------------------------- the deps -- */

export interface ProfileToolDeps {
  state(): ProfileState
  create(name: string | null): BrowserProfile
  rename(id: string, name: string): ProfileState
  avatar(id: string, avatar: string): ProfileState
  activate(id: string): ProfileState
  remove(id: string): Promise<ProfileState>
}

export interface HistoryToolDeps {
  profiles(): ProfileState
  list(profileId: string, query: string, limit: number): Visit[]
  suggest(profileId: string, typed: string): Visit[]
  /** The profile's list after the address is gone. */
  forget(profileId: string, url: string): Visit[]
  /** The profile's list after it is emptied — `[]`. */
  clear(profileId: string): Visit[]
}

/** Said beside every change, because "saved" and "on screen" are two different facts here. */
const SHOWN_NEXT_READ =
  'Saved. A browser panel that is already open shows it when it next reads its list.'

/* ---------------------------------------------------------------- history -- */

const HISTORY_ACTIONS = ['list', 'suggest', 'forget', 'clear'] as const
type HistoryAction = (typeof HISTORY_ACTIONS)[number]

const HISTORY_TIERS: Readonly<Record<HistoryAction, Tier>> = {
  list: 'read',
  suggest: 'read',
  forget: 'alter',
  clear: 'alter',
}

/** Most visits one call returns. The store keeps three thousand per profile. */
export const MAX_HISTORY_ROWS = 500

const HISTORY_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...HISTORY_ACTIONS], description: 'Default list.' },
    profile: { type: 'string', description: 'A profile name or id. Omit for the one switched on.' },
    query: { type: 'string', description: 'For list: only visits whose address or title contains this.' },
    limit: { type: 'integer', description: `For list. Default 100, max ${MAX_HISTORY_ROWS}.` },
    typed: { type: 'string', description: 'For suggest: what has been typed into the address bar so far.' },
    url: { type: 'string', description: 'For forget: the address to forget, exactly as listed.' },
  },
  additionalProperties: false,
}

function visitOut(visit: Visit): Record<string, unknown> {
  return { url: visit.url, title: visit.title, visitedAt: visit.visitedAt, visits: visit.visits }
}

function nameOfProfile(state: ProfileState, id: string): string {
  return state.profiles.find((profile) => profile.id === id)?.name ?? id
}

export function historyTools(deps: HistoryToolDeps): ToolSpec[] {
  const profileFrom = (args: Record<string, unknown>): { id: string; name: string } => {
    const state = deps.profiles()
    const id = profileIdOf(optStr(args, 'profile'), state.profiles, state.activeId)
    return { id, name: nameOfProfile(state, id) }
  }
  return [
    {
      id: 'browser.history',
      wire: 'browser_history',
      tier: 'read',
      title: 'The browser’s history',
      description:
        'The in-app browser’s history, kept per profile (profile: a name or id; omit for the one switched ' +
        'on). "list" (the default) gives addresses and titles, newest first, with when each was last ' +
        'visited and how often (query narrows it; limit up to 500). "suggest" answers what the address bar ' +
        'would offer for what has been typed. "forget" removes one address; "clear" empties the profile’s ' +
        'history. Both of those ask the person first.',
      index:
        'Browser history per profile: list, search, address-bar suggestions, forget one, clear.',
      inputSchema: HISTORY_SCHEMA,
      escalate: escalateBy(HISTORY_TIERS, 'list'),
      precheck: (args, context: ToolContext) => {
        notASession(context, 'browser.history')
        const action = actionOf(args, HISTORY_ACTIONS, 'list')
        profileFrom(args)
        if (action === 'suggest') str(args, 'typed')
        if (action === 'forget') str(args, 'url')
      },
      summary: (args) => {
        const action = typeof args.action === 'string' ? args.action : 'list'
        const where = typeof args.profile === 'string' && args.profile !== '' ? ` in ${args.profile}` : ''
        if (action === 'forget') return `Forget ${typeof args.url === 'string' ? args.url : '?'} from the browser history${where}`
        if (action === 'clear') return `Clear the browser history${where || ' of the profile that is switched on'}`
        if (action === 'suggest') return `Look up address suggestions${where}`
        return `Read the browser history${where}`
      },
      run: async (args): Promise<ToolOutput> => {
        const action = actionOf(args, HISTORY_ACTIONS, 'list')
        const profile = profileFrom(args)
        switch (action) {
          case 'list': {
            const limit = optInt(args, 'limit', 100, 1, MAX_HISTORY_ROWS)
            const visits = deps.list(profile.id, optStr(args, 'query') ?? '', limit)
            return {
              value: { profile: profile.name, visits: visits.map(visitOut), returned: visits.length },
              summary: { profile: profile.id, returned: visits.length },
            }
          }
          case 'suggest': {
            const visits = deps.suggest(profile.id, str(args, 'typed'))
            return {
              value: { profile: profile.name, suggestions: visits.map(visitOut) },
              summary: { profile: profile.id, suggestions: visits.length },
            }
          }
          case 'forget': {
            const url = str(args, 'url')
            const before = deps.list(profile.id, '', MAX_HISTORY_ROWS * 10).some((visit) => visit.url === url)
            if (!before) {
              throw new Refused('not-permitted', `${url} is not in ${profile.name}'s history`)
            }
            deps.forget(profile.id, url)
            return { value: { profile: profile.name, forgotten: url, note: SHOWN_NEXT_READ }, summary: { profile: profile.id } }
          }
          case 'clear': {
            deps.clear(profile.id)
            return { value: { profile: profile.name, cleared: true, note: SHOWN_NEXT_READ }, summary: { profile: profile.id } }
          }
        }
        throw new Refused('not-permitted', `action must be one of: ${HISTORY_ACTIONS.join(', ')}`)
      },
    },
  ]
}

/* --------------------------------------------------------------- profiles -- */

const PROFILE_ACTIONS = ['list', 'create', 'rename', 'avatar', 'activate', 'delete'] as const
type ProfileAction = (typeof PROFILE_ACTIONS)[number]

const PROFILE_TIERS: Readonly<Record<ProfileAction, Tier>> = {
  list: 'read',
  create: 'alter',
  rename: 'alter',
  avatar: 'alter',
  activate: 'alter',
  delete: 'alter',
}

const PROFILE_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...PROFILE_ACTIONS], description: 'Default list.' },
    profile: { type: 'string', description: 'For rename, avatar, activate and delete: a name or id.' },
    name: { type: 'string', description: 'For create and rename. Up to 40 characters.' },
    avatar: { type: 'string', description: 'For avatar: one character, such as an emoji. Empty puts the initial back.' },
  },
  additionalProperties: false,
}

function profileOut(profile: BrowserProfile, activeId: string): Record<string, unknown> {
  return {
    profile: profile.id,
    name: profile.name,
    avatar: profile.avatar,
    on: profile.id === activeId,
    isDefault: profile.isDefault,
    createdAt: profile.createdAt,
  }
}

export function profileTools(deps: ProfileToolDeps): ToolSpec[] {
  const named = (args: Record<string, unknown>): BrowserProfile => {
    const state = deps.state()
    const id = profileIdOf(str(args, 'profile'), state.profiles, state.activeId)
    const profile = state.profiles.find((one) => one.id === id)
    if (!profile) throw new Refused('not-permitted', `there is no browser profile ${id}`)
    return profile
  }
  return [
    {
      id: 'browser.profiles',
      wire: 'browser_profiles',
      tier: 'read',
      title: 'The browser’s profiles',
      description:
        'The in-app browser’s profiles — separate sets of logins, history and saved passwords. "list" (the ' +
        'default) names each one and says which is switched on. "create" makes a new one (name), ' +
        '"rename" (profile, name), "avatar" sets the one character on its badge, "activate" switches ' +
        'which one new windows open in, and "delete" throws one away with its cookies, storage and cache ' +
        '(the default profile cannot be deleted). Every change asks the person first.',
      index:
        'Browser profiles: list, create, rename, badge, switch which is on, delete.',
      inputSchema: PROFILE_SCHEMA,
      escalate: escalateBy(PROFILE_TIERS, 'list'),
      precheck: (args, context: ToolContext) => {
        notASession(context, 'browser.profiles')
        const action = actionOf(args, PROFILE_ACTIONS, 'list')
        if (action === 'list' || action === 'create') return
        const profile = named(args)
        if (action === 'rename') str(args, 'name')
        if (action === 'avatar' && typeof args.avatar !== 'string') {
          throw new Refused('not-permitted', 'avatar needs one character, or an empty string to put the initial back')
        }
        if (action === 'delete' && profile.isDefault) {
          throw new Refused('not-permitted', 'the default profile cannot be deleted. It holds the logins from before profiles existed.')
        }
      },
      summary: (args) => {
        const action = typeof args.action === 'string' ? args.action : 'list'
        const which = typeof args.profile === 'string' ? args.profile : '?'
        switch (action) {
          case 'create':
            return `Create a browser profile${typeof args.name === 'string' && args.name !== '' ? ` called ${args.name}` : ''}`
          case 'rename':
            return `Rename browser profile ${which} to ${typeof args.name === 'string' ? args.name : '?'}`
          case 'avatar':
            return `Change the badge on browser profile ${which}`
          case 'activate':
            return `Switch the browser to profile ${which}, so new windows open with its logins`
          case 'delete':
            return `Delete browser profile ${which} and its cookies, storage and cache`
          default:
            return 'List the browser profiles'
        }
      },
      run: async (args): Promise<ToolOutput> => {
        const action = actionOf(args, PROFILE_ACTIONS, 'list')
        const listing = (state: ProfileState): Record<string, unknown>[] =>
          state.profiles.map((profile) => profileOut(profile, state.activeId))
        switch (action) {
          case 'list': {
            const state = deps.state()
            return { value: { profiles: listing(state) }, summary: { profiles: state.profiles.length } }
          }
          case 'create': {
            const made = deps.create(optStr(args, 'name'))
            return {
              value: { created: profileOut(made, deps.state().activeId), note: SHOWN_NEXT_READ },
              summary: { profile: made.id },
            }
          }
          case 'rename': {
            const profile = named(args)
            const state = deps.rename(profile.id, str(args, 'name'))
            return { value: { profiles: listing(state), note: SHOWN_NEXT_READ }, summary: { profile: profile.id } }
          }
          case 'avatar': {
            const profile = named(args)
            const state = deps.avatar(profile.id, typeof args.avatar === 'string' ? args.avatar : '')
            return { value: { profiles: listing(state), note: SHOWN_NEXT_READ }, summary: { profile: profile.id } }
          }
          case 'activate': {
            const profile = named(args)
            const state = deps.activate(profile.id)
            return {
              value: {
                on: profile.name,
                profiles: listing(state),
                note:
                  'New browser windows open in this profile from now on. Windows already open keep the profile ' +
                  'they were opened in. A panel already open shows the change when it next reads its list.',
              },
              summary: { profile: profile.id },
            }
          }
          case 'delete': {
            const profile = named(args)
            const state = await deps.remove(profile.id)
            return { value: { deleted: profile.name, profiles: listing(state) }, summary: { profile: profile.id } }
          }
        }
        throw new Refused('not-permitted', `action must be one of: ${PROFILE_ACTIONS.join(', ')}`)
      },
    },
  ]
}
