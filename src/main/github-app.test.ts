import { describe, expect, it } from 'vitest'
import {
  APP_CLIENT_ID_ENV,
  APP_SLUG_ENV,
  appInstallUrl,
  clientKindFor,
  FORCE_OAUTH_ENV,
  GITHUB_APP,
  githubAppConfigured,
  githubAppRegistration,
  NO_REGISTRATION,
} from './github-app'

/**
 * The GitHub App registration, and what these assertions are actually for.
 *
 * This file was written while the constant was `{ clientId: null, slug: null }`
 * on purpose, and its first test asserted exactly that. The reasoning was
 * sound: GitHub answers an unregistered device-code request with HTTP 404
 * `{"error":"Not Found"}` and nothing that names the id as the problem, so a
 * *plausible-looking* placeholder ships as a Connect button that reaches the
 * network, fails, and gives the user nothing to act on. The test existed to
 * fail the moment somebody filled the constant in with something they made up
 * to "wire it through for now".
 *
 * A real registration landed on 2026-08-16, so the literal assertion is now
 * false — but the thing it protected is not. What replaces it is the same guard
 * one step along: the constant must hold *the* id that was proven to start a
 * device flow, not merely some id. Pinning the exact string is what makes a
 * change to it show up as a deliberate edit with a stale verification note
 * beside it, rather than as a value that quietly drifted.
 *
 * Everything else here now passes the registration in explicitly. The old
 * tests took it off the module constant, which meant "no registration ⇒ the
 * OAuth path" was really asserting "the constant is still null" — thirteen
 * tests across two files died the hour that stopped being true. A module whose
 * tests depend on a shipping constant having a particular value is a module
 * that breaks the day it ships.
 */

describe('the registration that ships', () => {
  /**
   * Verified by hand on 2026-08-16 through this product's own
   * `GitHubAuthenticator.connect()`, not curl:
   *
   *     POST https://github.com/login/device/code   client_id=Iv23limkNV4N6mChRl60
   *     200 {"device_code":"3d0cf17…84","user_code":"E9EE-04C7",
   *          "verification_uri":"https://github.com/login/device",
   *          "expires_in":899,"interval":5}
   *
   * That cannot be a test — a live-network assertion that fails on an offline
   * runner is worse than none — so what is pinned here is the id that was
   * checked. Change it and this fails, which is the prompt to check the new one
   * the same way before shipping it.
   */
  it('holds the client id that was proven to start a device flow', () => {
    expect(GITHUB_APP.clientId).toBe('Iv23limkNV4N6mChRl60')
    // GitHub's own format for a GitHub App client id. A pasted *OAuth* client
    // id is 20 hex characters with no prefix and would sail through every other
    // check in this file while making the app path send a request GitHub
    // answers 404 to.
    expect(GITHUB_APP.clientId).toMatch(/^Iv[0-9]{2}li[A-Za-z0-9]+$/)
  })

  /**
   * The slug is not decoration: it is the only thing that builds the install
   * screen link, and that screen is the entire reason for preferring a GitHub
   * App over OAuth. A slug that does not resolve is a button that opens a 404.
   */
  it('holds a slug that builds the install screen', () => {
    expect(GITHUB_APP.slug).toBe('terminal-deck')
    expect(appInstallUrl(GITHUB_APP.slug)).toBe(
      'https://github.com/apps/terminal-deck/installations/new',
    )
  })

  /**
   * The pair that decides which sign-in a shipping build runs, asserted from
   * the constant rather than from an environment override — because what a user
   * gets out of the box is precisely the case no override can speak for.
   */
  it('makes the GitHub App the path a shipping build takes', () => {
    expect(githubAppConfigured({})).toBe(true)
    expect(clientKindFor({})).toBe('github-app')
  })

  /**
   * The other branch, which used to be the shipping one and is still real: a
   * fork, an enterprise host, or anyone who has not registered an app of their
   * own. It must keep working, and it must keep being *tested* — a GitHub App
   * client id sent down the OAuth path, or the reverse, is a 404 either way.
   */
  it('falls back to the OAuth client when there is no registration', () => {
    expect(githubAppConfigured({}, NO_REGISTRATION)).toBe(false)
    expect(clientKindFor({}, NO_REGISTRATION)).toBe('oauth')
    expect(githubAppRegistration({}, NO_REGISTRATION)).toEqual({ clientId: null, slug: null })
  })
})

describe('githubAppRegistration', () => {
  it('takes the client id and slug from the environment', () => {
    const env = { [APP_CLIENT_ID_ENV]: 'Iv23liEXAMPLE', [APP_SLUG_ENV]: 'terminal-deck' }
    expect(githubAppRegistration(env, NO_REGISTRATION)).toEqual({
      clientId: 'Iv23liEXAMPLE',
      slug: 'terminal-deck',
    })
    expect(githubAppConfigured(env, NO_REGISTRATION)).toBe(true)
    expect(clientKindFor(env, NO_REGISTRATION)).toBe('github-app')
  })

  /** The environment beats the built-in, or an enterprise build cannot exist. */
  it('overrides the registration compiled into the build', () => {
    const env = { [APP_CLIENT_ID_ENV]: 'Iv23liOTHER', [APP_SLUG_ENV]: 'other-deck' }
    expect(githubAppRegistration(env)).toEqual({ clientId: 'Iv23liOTHER', slug: 'other-deck' })
  })

  it('trims, and treats whitespace as absent rather than as a client id', () => {
    expect(githubAppRegistration({ [APP_CLIENT_ID_ENV]: '  Iv23li7  ' }, NO_REGISTRATION).clientId)
      .toBe('Iv23li7')
    expect(githubAppRegistration({ [APP_CLIENT_ID_ENV]: '   ' }, NO_REGISTRATION).clientId)
      .toBeNull()
    // The slug goes through the same cleaning, and a blank one has to land as
    // null rather than as the empty string: `appInstallUrl('')` is null, but a
    // registration carrying `slug: ''` would read as "has a slug" to anything
    // that checks truthiness one layer up.
    expect(
      githubAppRegistration(
        { [APP_CLIENT_ID_ENV]: 'Iv23li7', [APP_SLUG_ENV]: '  ' },
        NO_REGISTRATION,
      ).slug,
    ).toBeNull()
  })

  /**
   * A present-but-blank variable is an unset shell export or an empty value in
   * a launcher plist, not an instruction. Reading it as "disable the GitHub
   * App" would silently downgrade a user to whole-account OAuth access on the
   * strength of a stray `export TERMINALDECK_GITHUB_APP_CLIENT_ID=`.
   * `FORCE_OAUTH_ENV` is the switch for wanting that, and it says so by name.
   */
  it('falls through a blank override to the built-in rather than clearing it', () => {
    expect(githubAppRegistration({ [APP_CLIENT_ID_ENV]: '   ' })).toEqual({
      clientId: 'Iv23limkNV4N6mChRl60',
      slug: 'terminal-deck',
    })
    expect(clientKindFor({ [APP_CLIENT_ID_ENV]: '' })).toBe('github-app')
  })

  /**
   * A slug alone builds an "install this app" link for an app that cannot then
   * be signed in to — a dead end wearing a button.
   */
  it('ignores a slug with no client id beside it', () => {
    expect(githubAppRegistration({ [APP_SLUG_ENV]: 'terminal-deck' }, NO_REGISTRATION)).toEqual({
      clientId: null,
      slug: null,
    })
  })

  /**
   * The way back for somebody who installs the app on three repositories and
   * then wonders where the other forty went. It matters far more now than when
   * it was written: the app path is what ships, so this is the only lever a
   * user has that does not involve editing source and rebuilding.
   *
   * It changes which client signs in and nothing else — the registration is
   * still there, so `githubAppConfigured` stays true and the panel can still
   * offer the install link.
   */
  it('honours the force-OAuth escape hatch even with a registration', () => {
    const env = { [APP_CLIENT_ID_ENV]: 'Iv23liEXAMPLE', [FORCE_OAUTH_ENV]: '1' }
    expect(githubAppConfigured(env, NO_REGISTRATION)).toBe(true)
    expect(clientKindFor(env, NO_REGISTRATION)).toBe('oauth')

    // And against the registration that actually ships, which is the case a
    // user will hit.
    expect(githubAppConfigured({ [FORCE_OAUTH_ENV]: '1' })).toBe(true)
    expect(clientKindFor({ [FORCE_OAUTH_ENV]: '1' })).toBe('oauth')
  })
})

describe('appInstallUrl', () => {
  it('points at the install screen where repositories are chosen', () => {
    expect(appInstallUrl('terminal-deck')).toBe(
      'https://github.com/apps/terminal-deck/installations/new',
    )
  })

  /** Sending somebody to github.com to install on their company's server. */
  it('stays on the host it was given', () => {
    expect(appInstallUrl('terminal-deck', 'git.acme.co')).toBe(
      'https://git.acme.co/apps/terminal-deck/installations/new',
    )
  })

  /** This string is handed to `shell.openExternal`; a typo is not a URL. */
  it('refuses anything that is not a slug', () => {
    expect(appInstallUrl(null)).toBeNull()
    expect(appInstallUrl('')).toBeNull()
    expect(appInstallUrl('../../evil')).toBeNull()
    expect(appInstallUrl('https://evil.example/apps/x')).toBeNull()
    expect(appInstallUrl('has spaces')).toBeNull()
  })
})
