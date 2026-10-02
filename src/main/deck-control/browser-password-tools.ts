import type { SaveOutcome, SavedLoginSummary, StoreState } from '../browser-passwords'
import type { ProfileState } from '../browser-profiles'
import {
  actionOf,
  escalateBy,
  notASession,
  optBool,
  optStr,
  profileIdOf,
  str,
} from './browser-area-kit'
import { mayDrive } from './browser-tools'
import { resolveWindow, viewOfWindow, windowName, type WindowToolDeps } from './browser-window-tools'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * `browser.passwords` — the saved-logins manager, everything in it except the
 * one button that hands a password over.
 *
 * ## What is here, and what is not
 *
 * Asad asked for everything he does by hand. Of the saved-logins manager's
 * controls, that is: see which sites have a login and under which username, see
 * whether this Mac can keep them at all and where the file is, show that file in
 * Finder, forget one, forget them all, answer the "save this password?" offer a
 * page just raised, and fill a saved login into the sign-in form in front of him.
 * Every one of those is here.
 *
 * **Copy is not**, and it is the one honest absence. Copy puts the password on
 * the clipboard, which is the secret itself handed to whatever reads the
 * clipboard next — an app on this Mac, a clipboard history, a copilot that can
 * run `pbpaste`. `browser-passwords.ts` built the whole store around a password
 * never leaving the main process except into the field it belongs to, and a tool
 * that could put one on the clipboard would be the single line that undoes it.
 * Fill reaches the same end — the login used where it belongs — without the
 * secret ever being anywhere a caller can read.
 *
 * ## Fill, and why it is `alter` every time
 *
 * Before 0.16.0 there was no call an agent could make that put a credential into
 * a page; `browser-fill-gate.ts` is the long argument for that rule. What changed
 * is that the press may now arrive from another application, and the rule that
 * survives is the one that mattered: **a person says yes to each fill**. This
 * action is `alter`, `consent.ts` has no "allow always", and it is refused when
 * nobody is at the machine, from a paired device and from an ordinary session —
 * {@link mayDrive} and `notASession`, the same two gates every page-touching tool
 * passes. The dialog names the site and the username. The answer carries no
 * password and has no field that could.
 *
 * The page has to have asked: a fill only lands on a window whose page announced
 * a sign-in form for an origin with a saved login, and the origin is the one the
 * view has *committed*, read in `fillSavedLogin` — never the one a caller named.
 * A page that navigated between the question and the yes is not filled.
 *
 * ## Saving an offered login
 *
 * A page that submits a new sign-in raises an offer; the window shows it as a
 * bar with Save and Not now. `answer` is that bar's two buttons. Saving writes a
 * credential into the store, so it is `alter` too — the person sees which site
 * and which username before it is kept. Declining is the safe direction and is
 * still a change to what the store holds, so it goes through the same gate.
 */

/* --------------------------------------------------------------- the deps -- */

export interface PasswordToolDeps {
  /** Whether a secure store exists on this machine at all. */
  available(): boolean
  state(): StoreState
  profiles(): ProfileState
  list(profileId: string): SavedLoginSummary[]
  forget(profileId: string, origin: string, username: string): SaveOutcome
  forgetAll(): SaveOutcome
  /** Show the encrypted file in Finder. False when nothing has been saved. */
  reveal(): boolean
  /** The login a page just offered to save, without its password, or null. */
  offer(): SavedLoginSummary | null
  answer(save: boolean): SaveOutcome
  /** The sign-in form a view has announced, or null. */
  signInOffer(viewId: string): { origin: string; usernames: string[] } | null
  /** Fill a saved login into a view. Whether a fill was sent. */
  fill(viewId: string, username: string): boolean
  /** How a window is named — the same resolution `browser.page` uses. */
  windows: Pick<WindowToolDeps, 'windows' | 'slotWindow'>
}

/* ------------------------------------------------------------- the schema -- */

const ACTIONS = ['list', 'forget', 'forgetall', 'reveal', 'offer', 'answer', 'fill'] as const
type Action = (typeof ACTIONS)[number]

const TIERS: Readonly<Record<Action, Tier>> = {
  list: 'read',
  forget: 'alter',
  forgetall: 'alter',
  reveal: 'act',
  offer: 'read',
  answer: 'alter',
  fill: 'alter',
}

const SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...ACTIONS], description: 'Default list.' },
    profile: { type: 'string', description: 'For list and forget: a profile name or id. Omit for the one switched on.' },
    site: { type: 'string', description: 'For forget: the site exactly as listed, like https://github.com.' },
    username: { type: 'string', description: 'For forget: whose login. For fill: which saved login to use; omit for the newest.' },
    save: { type: 'boolean', description: 'For answer: true keeps the offered login, false turns it down.' },
    window: { type: 'string', description: 'For fill: W3 from browser.windows, or a session slot like B1 with sessionId.' },
    sessionId: { type: 'string', description: 'For fill with a B slot.' },
  },
  additionalProperties: false,
}

function gate(context: ToolContext): void {
  notASession(context, 'browser.passwords')
  mayDrive(context, 'browser.passwords')
}

export function passwordTools(deps: PasswordToolDeps): ToolSpec[] {
  const profileFrom = (args: Record<string, unknown>): { id: string; name: string } => {
    const state = deps.profiles()
    const id = profileIdOf(optStr(args, 'profile'), state.profiles, state.activeId)
    return { id, name: state.profiles.find((one) => one.id === id)?.name ?? id }
  }

  /** The page a fill would land on, with the form it announced — or the sentence for why there is none. */
  const fillTarget = (
    args: Record<string, unknown>,
  ): { name: string; viewId: string; origin: string; username: string } => {
    const row = resolveWindow(deps.windows, args)
    const viewId = viewOfWindow(row)
    const form = deps.signInOffer(viewId)
    if (form === null || form.usernames.length === 0) {
      throw new Refused(
        'not-permitted',
        `${windowName(row)} is not showing a sign-in form this browser has a saved login for. Nothing was asked and nothing was filled.`,
      )
    }
    const wanted = optStr(args, 'username')
    if (wanted !== null && !form.usernames.includes(wanted)) {
      throw new Refused(
        'not-permitted',
        `there is no saved login for ${wanted} on ${form.origin}. Saved: ${form.usernames.join(', ')}.`,
      )
    }
    return { name: windowName(row), viewId, origin: form.origin, username: wanted ?? form.usernames[0] }
  }

  return [
    {
      id: 'browser.passwords',
      wire: 'browser_passwords',
      tier: 'read',
      title: 'Saved passwords',
      description:
        'The in-app browser’s saved logins. Passwords themselves are never returned and cannot be copied ' +
        'from here. "list" (the default) gives each saved site and username for a profile, whether this ' +
        'Mac can store passwords, and where the encrypted file is. "fill" puts a saved login into the ' +
        'sign-in form on a window (window; username optional) — the person is asked every time, and the ' +
        'page must be showing a sign-in form for a site with a saved login. "offer" says whether a page is ' +
        'waiting to have a just-typed login saved, and "answer" saves it (save: true) or turns it down — ' +
        'also asked first. "forget" removes one (site, username), "forgetall" removes every saved login, ' +
        'and "reveal" shows the encrypted file in Finder.',
      index:
        'Saved logins, never the passwords: list, fill one into a page (asks), save, forget.',
      inputSchema: SCHEMA,
      escalate: escalateBy(TIERS, 'list'),
      precheck: (args, context: ToolContext) => {
        gate(context)
        const action = actionOf(args, ACTIONS, 'list')
        if (action === 'list') profileFrom(args)
        if (action === 'forget') {
          const profile = profileFrom(args)
          const site = str(args, 'site')
          const username = typeof args.username === 'string' ? args.username : ''
          const known = deps.list(profile.id).some((row) => row.origin === site && row.username === username)
          if (!known) {
            throw new Refused('not-permitted', `${profile.name} has no saved login for ${username || 'an empty username'} on ${site}`)
          }
        }
        if (action === 'answer') {
          if (typeof args.save !== 'boolean') throw new Refused('not-permitted', 'answer needs save: true or false')
          if (deps.offer() === null) throw new Refused('not-permitted', 'no page is waiting to have a login saved')
        }
        if (action === 'fill') fillTarget(args)
      },
      /*
       * The sentence on the dialog. For the two that touch a credential it names
       * the site and the username, because a person cannot meaningfully say yes
       * to "fill a login" — they can say yes to "fill asad@… on github.com".
       */
      summary: (args) => {
        const action = typeof args.action === 'string' ? args.action : 'list'
        switch (action) {
          case 'fill': {
            try {
              const target = fillTarget(args)
              return `Fill your saved login for ${target.username} into the sign-in form on ${target.origin} (${target.name})`
            } catch {
              return 'Fill a saved login into a page'
            }
          }
          case 'answer': {
            const offer = deps.offer()
            const what = offer === null ? 'the offered login' : `the login for ${offer.username} on ${offer.origin}`
            return optBool(args, 'save', false) ? `Save ${what} in this browser` : `Do not save ${what}`
          }
          case 'forget':
            return `Forget the saved login for ${typeof args.username === 'string' ? args.username : '?'} on ${typeof args.site === 'string' ? args.site : '?'}`
          case 'forgetall':
            return 'Forget every saved password in this browser'
          case 'reveal':
            return 'Show the saved-login file in Finder'
          case 'offer':
            return 'Check whether a page is offering to save a login'
          default:
            return 'List the saved logins (sites and usernames only)'
        }
      },
      run: async (args): Promise<ToolOutput> => {
        const action = actionOf(args, ACTIONS, 'list')
        switch (action) {
          case 'list': {
            const profile = profileFrom(args)
            const logins = deps.list(profile.id).map((row) => ({
              site: row.origin,
              username: row.username,
              updatedAt: row.updatedAt,
            }))
            const state = deps.state()
            return {
              value: {
                profile: profile.name,
                canStore: deps.available(),
                file: state.path,
                fileExists: state.exists,
                ...(state.message === '' ? {} : { problem: state.message }),
                logins,
              },
              summary: { profile: profile.id, logins: logins.length },
            }
          }
          case 'forget': {
            const profile = profileFrom(args)
            const outcome = deps.forget(profile.id, str(args, 'site'), typeof args.username === 'string' ? args.username : '')
            if (!outcome.ok) throw new Refused('not-permitted', outcome.message)
            return { value: { forgotten: true, message: outcome.message }, summary: { profile: profile.id } }
          }
          case 'forgetall': {
            const outcome = deps.forgetAll()
            if (!outcome.ok) throw new Refused('not-permitted', outcome.message)
            return { value: { forgotten: 'all', message: outcome.message }, summary: { all: true } }
          }
          case 'reveal': {
            const shown = deps.reveal()
            if (!shown) throw new Refused('not-permitted', 'nothing has been saved yet, so there is no file to show')
            return { value: { shown: true }, summary: { shown: true } }
          }
          case 'offer': {
            const offer = deps.offer()
            return {
              value:
                offer === null
                  ? { waiting: false }
                  : { waiting: true, site: offer.origin, username: offer.username },
              summary: { waiting: offer !== null },
            }
          }
          case 'answer': {
            const save = optBool(args, 'save', false)
            const outcome = deps.answer(save)
            if (!outcome.ok) throw new Refused('not-permitted', outcome.message)
            return { value: { saved: save, message: outcome.message }, summary: { saved: save } }
          }
          case 'fill': {
            const target = fillTarget(args)
            const filled = deps.fill(target.viewId, target.username)
            if (!filled) {
              /*
               * The page moved, or the form went, between the yes and the fill.
               * `fillSavedLogin` re-reads the committed origin for exactly this
               * reason, and the honest answer is that nothing was filled.
               */
              throw new Refused(
                'not-permitted',
                `nothing was filled: ${target.name} is no longer on the sign-in form for ${target.origin}`,
              )
            }
            return {
              value: { filled: true, window: target.name, site: target.origin, username: target.username },
              summary: { window: target.name, site: target.origin },
            }
          }
        }
        throw new Refused('not-permitted', `action must be one of: ${ACTIONS.join(', ')}`)
      },
    },
  ]
}
