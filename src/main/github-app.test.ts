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
} from './github-app'

/**
 * The GitHub App registration, and the one assertion that matters more than
 * all the others put together.
 *
 * This file's whole reason to exist is that a *plausible-looking* client id is
 * worse than none. GitHub answers an unregistered device-code request with
 * HTTP 404 `{"error":"Not Found"}` and nothing that names the id as the
 * problem, so a placeholder would ship as a Connect button that reaches the
 * network, fails, and gives the user nothing to act on. The first test below
 * fails the moment somebody fills the constant in with something they made up
 * to "wire it through for now".
 */

describe('the registration ships empty', () => {
  it('carries no client id, so the GitHub App path cannot pretend to work', () => {
    expect(GITHUB_APP.clientId).toBeNull()
    expect(GITHUB_APP.slug).toBeNull()
    expect(githubAppConfigured({})).toBe(false)
  })

  /**
   * The default has to be the path that works today. A build that shipped
   * `github-app` with no registration would send every user to a sign-in that
   * cannot succeed.
   */
  it('signs in through the OAuth client while no app is registered', () => {
    expect(clientKindFor({})).toBe('oauth')
  })
})

describe('githubAppRegistration', () => {
  it('takes the client id and slug from the environment', () => {
    const env = { [APP_CLIENT_ID_ENV]: 'Iv23liEXAMPLE', [APP_SLUG_ENV]: 'terminal-deck' }
    expect(githubAppRegistration(env)).toEqual({ clientId: 'Iv23liEXAMPLE', slug: 'terminal-deck' })
    expect(githubAppConfigured(env)).toBe(true)
    expect(clientKindFor(env)).toBe('github-app')
  })

  it('trims, and treats whitespace as absent rather than as a client id', () => {
    expect(githubAppRegistration({ [APP_CLIENT_ID_ENV]: '  Iv23li7  ' }).clientId).toBe('Iv23li7')
    expect(githubAppRegistration({ [APP_CLIENT_ID_ENV]: '   ' }).clientId).toBeNull()
  })

  /**
   * A slug alone builds an "install this app" link for an app that cannot then
   * be signed in to — a dead end wearing a button.
   */
  it('ignores a slug with no client id beside it', () => {
    expect(githubAppRegistration({ [APP_SLUG_ENV]: 'terminal-deck' })).toEqual({
      clientId: null,
      slug: null,
    })
  })

  /**
   * The way back for somebody who installs the app on three repositories and
   * then wonders where the other forty went.
   */
  it('honours the force-OAuth escape hatch even with a registration', () => {
    const env = { [APP_CLIENT_ID_ENV]: 'Iv23liEXAMPLE', [FORCE_OAUTH_ENV]: '1' }
    expect(githubAppConfigured(env)).toBe(true)
    expect(clientKindFor(env)).toBe('oauth')
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
