/**
 * The GitHub App registration, and why this file exists at all.
 *
 * ## The screen that started it
 *
 * Pressing Connect sends the user to GitHub's consent page, and that page says
 * **"Full control of private repositories"** with no way to choose which ones.
 * That is not a wording problem this app can fix by asking more politely: an
 * OAuth application's `repo` scope is a single all-or-nothing grant over every
 * private repository the account can reach, present and future, with write
 * included. GitHub offers no read-only private-repository scope and no
 * per-repository OAuth scope — `public_repo` exists, and it excludes exactly
 * the repositories a work machine cares about. So an OAuth app that wants to
 * list pull requests on a private repo has to ask for all of them.
 *
 * ## What actually gives per-repository choice
 *
 * A **GitHub App**, which is a different registration with a different consent
 * model:
 *
 *  - The user installs it and picks *All repositories* or *Only select
 *    repositories* at install time, and can change that later without
 *    re-authorising anything.
 *  - Its permissions are fine-grained and read-only where we say so —
 *    Metadata: Read, Pull requests: Read, Issues: Read — instead of one `repo`
 *    that carries write access to everything.
 *  - It still supports the device flow, so the sign-in in this app does not
 *    change shape: same endpoints, same code on screen, minus the `scope`
 *    parameter, because permissions come from the registration rather than
 *    from the request.
 *
 * ## Why the client id below is null and must stay null until a human acts
 *
 * Creating the registration needs a person logged in to github.com clicking
 * through Settings → Developer settings → GitHub Apps → New GitHub App. There
 * is no API for it, and there is no way to guess the identifier it produces.
 *
 * So this file holds the shape and none of the values. A made-up client id
 * would produce a Connect button that reaches GitHub, gets `{"error":"Not
 * Found"}` with HTTP 404 — which does not name the id as the problem — and
 * leaves the user staring at a sign-in that cannot ever succeed. That is a fake
 * feature, and this project has twice refused to ship one. `clientId: null`
 * means the whole GitHub App path reports itself as unconfigured and the OAuth
 * path stays the shipping default, which works today.
 *
 * ## The exact clicks that turn this on
 *
 * 1.  github.com → profile photo → **Settings** → **Developer settings** →
 *     **GitHub Apps** → **New GitHub App**.
 * 2.  **GitHub App name**: `Terminal Deck` (names are global; add a suffix if
 *     it is taken). This is the name the consent screen will show instead of
 *     "GitHub CLI".
 * 3.  **Homepage URL**: `https://terminaldeck.dev`.
 * 4.  **Callback URL**: `https://terminaldeck.dev/oauth/callback`. The field is
 *     required; the device flow never visits it.
 * 5.  **Untick "Expire user authorization tokens"**. Left ticked, GitHub issues
 *     tokens that die after eight hours and expects a refresh-token exchange
 *     this app does not implement. `github-auth.ts` reads the `expires_in`
 *     GitHub returns and reports the expiry honestly rather than pretending,
 *     but the user experience of that is signing in again twice a day.
 * 6.  **Webhook** → untick **Active**. Nothing here listens for webhooks.
 * 7.  **Permissions → Repository permissions** — tick only these:
 *       - **Metadata: Read-only** (mandatory, and what lists the installed
 *         repositories)
 *       - **Pull requests: Read-only** (`gh pr list`)
 *       - **Issues: Read-only** (`gh issue list`)
 *     Leave **Contents** at *No access*: this app reads working copies from
 *     the local disk with `git`, never through the API. Anything ticked here
 *     appears on the install screen, so an unused permission is a permission
 *     the user is asked to grant for nothing.
 * 8.  **Where can this GitHub App be installed?** → *Any account*, so it is not
 *     locked to one login.
 * 9.  Under **Identifying and authorizing users**, tick **Enable Device Flow**.
 *     Without it the device-code request fails and nothing else in this file
 *     matters.
 * 10. **Create GitHub App**. On the app's General page copy the **Client ID**
 *     (it looks like `Iv23li…`), and take the slug out of the app's public URL
 *     `https://github.com/apps/<slug>`.
 * 11. Paste both into `GITHUB_APP` below — or, without touching the source, set
 *     `TERMINALDECK_GITHUB_APP_CLIENT_ID` and `TERMINALDECK_GITHUB_APP_SLUG` in
 *     the environment the app launches with.
 * 12. Install it: `https://github.com/apps/<slug>/installations/new`, and there
 *     choose **Only select repositories**. That screen is the whole point of
 *     the exercise.
 *
 * Nothing in this file has been exercised against a live registration, because
 * there is not one yet. Everything it encodes comes from GitHub's REST and
 * device-flow reference rather than from a captured response, which is the
 * opposite of how the rest of this feature's fixtures were built, and it is
 * flagged here rather than left for a later reader to discover.
 */

/** A GitHub App registration, or the absence of one. */
export interface GitHubAppRegistration {
  /**
   * The app's public client id, e.g. `Iv23li…`. Null means no registration
   * exists and the GitHub App sign-in path must not be offered.
   */
  clientId: string | null
  /**
   * The app's URL slug, used to send the user to the install screen where the
   * per-repository choice is made. Null is survivable — sign-in still works,
   * there is just no link to hand them.
   */
  slug: string | null
}

/**
 * The one place a real registration goes.
 *
 * Both fields null on purpose. See the header: an invented client id is a
 * Connect button that can never succeed.
 */
export const GITHUB_APP: GitHubAppRegistration = {
  clientId: null,
  slug: null,
}

export const APP_CLIENT_ID_ENV = 'TERMINALDECK_GITHUB_APP_CLIENT_ID'
export const APP_SLUG_ENV = 'TERMINALDECK_GITHUB_APP_SLUG'

/**
 * The escape hatch that keeps the old path reachable once a registration
 * exists.
 *
 * Set it and the app signs in through the OAuth client even when a GitHub App
 * is configured. It is here because the two grants are not interchangeable: a
 * GitHub App can only see repositories it has been installed on, so somebody
 * who installs it on three repositories and then wonders where the other forty
 * went needs a way back that is not "edit the source and rebuild".
 */
export const FORCE_OAUTH_ENV = 'TERMINALDECK_GITHUB_FORCE_OAUTH'

/** Which kind of client a sign-in is running through. */
export type ClientKind = 'oauth' | 'github-app'

function clean(value: string | null | undefined): string | null {
  const trimmed = (value ?? '').trim()
  return trimmed === '' ? null : trimmed
}

/**
 * The registration in force, environment over constant.
 *
 * A slug with no client id is deliberately *not* a registration: the slug only
 * builds a link, and offering "install this app" for an app that cannot then be
 * signed in to is a dead end wearing a button.
 */
export function githubAppRegistration(
  env: NodeJS.ProcessEnv = process.env,
): GitHubAppRegistration {
  const clientId = clean(env[APP_CLIENT_ID_ENV]) ?? clean(GITHUB_APP.clientId)
  if (!clientId) return { clientId: null, slug: null }
  return { clientId, slug: clean(env[APP_SLUG_ENV]) ?? clean(GITHUB_APP.slug) }
}

/** True when a real GitHub App registration exists to sign in through. */
export function githubAppConfigured(env: NodeJS.ProcessEnv = process.env): boolean {
  return githubAppRegistration(env).clientId !== null
}

/**
 * Which client a fresh sign-in should use.
 *
 * The GitHub App wins whenever one is registered, because it is strictly the
 * better grant for this product, and the OAuth path remains the default purely
 * because today there is no registration to prefer.
 */
export function clientKindFor(env: NodeJS.ProcessEnv = process.env): ClientKind {
  if (clean(env[FORCE_OAUTH_ENV])) return 'oauth'
  return githubAppConfigured(env) ? 'github-app' : 'oauth'
}

/**
 * Where the user picks which repositories the app may see.
 *
 * `github.com` is not hardcoded: an enterprise host serves the same path, and
 * sending someone to github.com to install an app on their company's server is
 * a link that silently does the wrong thing.
 */
export function appInstallUrl(slug: string | null, host = 'github.com'): string | null {
  if (!slug) return null
  // Slugs are lowercase alphanumerics and hyphens. Anything else came from a
  // typo or an environment variable somebody pasted badly, and it is about to
  // be handed to `shell.openExternal`.
  if (!/^[a-z0-9][a-z0-9-]*$/i.test(slug)) return null
  return `https://${host}/apps/${slug.toLowerCase()}/installations/new`
}

/**
 * What to say when somebody asks why the fine-grained path is not on offer.
 *
 * A sentence rather than a silent absence: "this build has no GitHub App
 * registered" is a fact the user can act on — or at least understand — and a
 * missing option with no explanation reads as a broken app.
 */
export const APP_UNCONFIGURED_REASON =
  'This build has no GitHub App registered, so per-repository access is not available yet. Signing in uses an OAuth app, and GitHub only offers whole-account access there.'
