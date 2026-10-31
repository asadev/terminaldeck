/**
 * The GitHub App registration, and why this file exists at all.
 *
 * ## The screen that started it
 *
 * Pressing Connect used to send the user to GitHub's *OAuth* consent page, and
 * that page said **"Full control of private repositories"** with no way to
 * choose which ones. That is not a wording problem this app could have fixed by
 * asking more politely: an OAuth application's `repo` scope is a single
 * all-or-nothing grant over every private repository the account can reach,
 * present and future, with write included. GitHub offers no read-only
 * private-repository scope and no per-repository OAuth scope — `public_repo`
 * exists, and it excludes exactly the repositories a work machine cares about.
 * So an OAuth app that wanted to list pull requests on a private repo had to
 * ask for all of them.
 *
 * ## What actually gives per-repository choice
 *
 * A **GitHub App**, which is a different registration with a different consent
 * model:
 *
 *  - The user installs it and picks *All repositories* or *Only select
 *    repositories* at install time, and can change that later without
 *    re-authorising anything.
 *  - Its permissions are fine-grained and per-resource, so each one is a line
 *    on the install screen the user can read and refuse, instead of one `repo`
 *    that silently carries write access to everything they can reach.
 *  - It still supports the device flow, so the sign-in in this app does not
 *    change shape: same endpoints, same code on screen, minus the `scope`
 *    parameter, because permissions come from the registration rather than
 *    from the request.
 *
 * ## There is one way to sign in, and this is it
 *
 * Until 2026-08-16 this sat behind an OAuth path that borrowed the GitHub CLI's
 * public client id, kept as a fallback for builds with no registration of their
 * own. That fallback is gone. It was two consent screens, two grant shapes, two
 * repository-listing endpoints and a switch between them, all to keep alive a
 * sign-in whose own consent screen said the wrong app's name and asked for
 * everything the account could reach. A build with no registration now says so
 * — see `APP_UNCONFIGURED_REASON` — rather than quietly signing the user in as
 * somebody else's application.
 *
 * A fork or an enterprise host registers its own app and points this build at
 * it with `TERMINALDECK_GITHUB_APP_CLIENT_ID` and `TERMINALDECK_GITHUB_APP_SLUG`.
 * That is the only override there is, and the steps below are written for
 * whoever is about to use it.
 *
 * ## The registration exists now, and this file stopped being a plan
 *
 * Until 2026-08-16 the constant below was `{ clientId: null, slug: null }` on
 * purpose. Creating a registration needs a person logged in to github.com
 * clicking through Settings → Developer settings → GitHub Apps → New GitHub
 * App; there is no API for it, and no way to guess the identifier it produces.
 * A made-up client id would have shipped a Connect button that reaches GitHub,
 * gets `{"error":"Not Found"}` with HTTP 404 — which does not name the id as
 * the problem — and can never succeed. So the file held the shape and none of
 * the values, and the whole GitHub App path reported itself as unconfigured.
 *
 * A human has now done the clicking. The values below are real, and they have
 * been exercised against the live endpoint rather than assumed — the record of
 * that is on `GITHUB_APP` itself.
 *
 * ## What was ticked, and why each one
 *
 * Kept as a record rather than as instructions, because the next person to need
 * it is somebody registering a second app — a fork, or an enterprise host,
 * where this registration does not exist and `TERMINALDECK_GITHUB_APP_*` is the
 * way in.
 *
 * 1.  github.com → profile photo → **Settings** → **Developer settings** →
 *     **GitHub Apps** → **New GitHub App**.
 * 2.  **GitHub App name**: `Terminal Deck` (names are global). This is the name
 *     the consent screen shows. The OAuth path it replaced showed "GitHub CLI",
 *     because that is whose client id it borrowed.
 * 3.  **Homepage URL**: `https://terminaldeck.dev`.
 * 4.  **Callback URL**: `https://terminaldeck.dev/oauth/callback`. The field is
 *     required; the device flow never visits it.
 * 5.  **Untick "Expire user authorization tokens"** — done. Left ticked, GitHub
 *     issues tokens that die after eight hours and expects a refresh-token
 *     exchange this app does not implement, because exchanging a refresh token
 *     needs a client secret and the device flow has none. `github-auth.ts`
 *     reads whatever `expires_in` GitHub sends and reports the expiry honestly
 *     rather than pretending, so a re-ticked box degrades to "sign in again
 *     twice a day" instead of to a lie — but it is off.
 * 6.  **Webhook** → untick **Active** — done. Nothing here listens for
 *     webhooks, and an active one is a URL that has to stay up.
 * 7.  **Permissions.** Deliberately the shape of Anthropic's own `claude` app,
 *     measured from a live installation rather than recalled, because that is
 *     the permission set users of this kind of tool have already agreed to once
 *     and the one an agent needs to do the work:
 *       - Read: **commit statuses**, **metadata** (mandatory, and what lists
 *         the installed repositories), **email addresses** (so a commit is
 *         attributable to the person who made it).
 *       - Read and write: **actions**, **checks**, **contents**, **issues**,
 *         **pull requests**, **webhooks**, **workflows**.
 *     Not requested: discussions, administration, deployments, packages, pages,
 *     secrets, environments. Anything ticked appears on the install screen, so
 *     an unused permission is one the user is asked to grant for nothing —
 *     `discussions` is on the `claude` app because it replies in discussion
 *     threads and is absent here because this app has no such feature.
 * 8.  **Where can this GitHub App be installed?** → *Any account*, so it is not
 *     locked to one login.
 * 9.  Under **Identifying and authorizing users**: **Enable Device Flow**
 *     ticked, and **Request user authorization (OAuth) during installation**
 *     ticked. Without the first, the device-code request fails and nothing else
 *     in this file matters — and it fails *indistinguishably from an app that
 *     does not exist*, which is why it is verified live rather than assumed.
 * 10. **No private key was generated.** See `GITHUB_APP` below.
 * 11. Client id and slug pasted into `GITHUB_APP` below. Neither is a secret;
 *     both can be overridden without touching the source by setting
 *     `TERMINALDECK_GITHUB_APP_CLIENT_ID` and `TERMINALDECK_GITHUB_APP_SLUG` in
 *     the environment the app launches with.
 * 12. Install it: `https://github.com/apps/<slug>/installations/new`, and there
 *     choose **Only select repositories**. That screen is the whole point of
 *     the exercise, and `appInstallUrl` below is what sends the user to it.
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
 * The one place a real registration goes — and it is a real one now.
 *
 * Registered 2026-08-16 on `asadev`, public page
 * `https://github.com/apps/terminal-deck`.
 *
 * **A client id is not a secret.** It ships inside every copy of this app and
 * is sent in the clear on the first leg of the device flow; GitHub's own
 * documentation treats it as public, which is why there is no client *secret*
 * here. The device flow exists precisely so a desktop app never has to hold
 * one. Nothing in this constant needs protecting, and putting it in a
 * repository secret would only make it harder to build.
 *
 * **No private key was generated, deliberately.** A private key buys
 * server-to-server (installation) tokens, which act as *the app* rather than as
 * the person. Everything here is user-to-server: the whole point is that a
 * push is attributable to whoever signed in, and GitHub enforces that person's
 * own repository access. Generating a key we do not use would create a
 * credential that can only ever leak.
 *
 * What it asks for is deliberately the shape of Anthropic's own `claude` app —
 * measured from a live installation rather than recalled — minus `discussions`,
 * which that app needs because it replies in discussion threads and this one
 * has no such feature. Plus `email addresses`, read-only, so a commit can be
 * attributed to the person who actually made it.
 *
 * ## Verified live, by hand, on 2026-08-16
 *
 * Checked rather than assumed, because a client id GitHub does not know, and a
 * registration with **Enable Device Flow** left unticked, both answer HTTP 404
 * `{"error":"Not Found"}` with nothing that names the cause. "The checkbox did
 * not save" is therefore invisible from the response, and the only way to know
 * is to start a flow.
 *
 * Driven through this product's own `GitHubAuthenticator.connect()` with a
 * recording transport in the seam the tests already use — not a raw curl, since
 * what needed proving was our request, not GitHub's endpoint:
 *
 *     POST https://github.com/login/device/code
 *     Accept: application/json
 *     client_id=Iv23limkNV4N6mChRl60          ← no `scope`, as an App must not
 *
 *     200 {"device_code":"3d0cf1759c7e976f0297aa34a35989776b7ae884",
 *          "user_code":"E9EE-04C7",
 *          "verification_uri":"https://github.com/login/device",
 *          "expires_in":899,"interval":5}
 *
 * So: the registration exists, Device Flow is on, and the no-`scope` request
 * this module sends in `github-app` mode is the one GitHub accepts. The flow
 * was cancelled before its first poll — starting one is the test, and finishing
 * it would have minted a real user token for no reason.
 *
 * That response is the fixture in `github-app.test.ts` and in the app-path
 * device-flow test, which is how the finding survives without a live-network
 * test that would fail on an offline runner. **It is not re-checked
 * automatically.** If sign-in ever starts failing with the "check the app still
 * exists and has Enable Device Flow ticked" sentence, run that request again
 * before believing anything else.
 */
export const GITHUB_APP: GitHubAppRegistration = {
  clientId: 'Iv23limkNV4N6mChRl60',
  slug: 'terminal-deck',
}

/**
 * The absence of a registration, as a value.
 *
 * Every function below took the registration off the module constant, which was
 * fine for exactly as long as that constant was null: the tests that pin "what
 * happens with no registration" were really pinning "the constant is still
 * empty", and thirteen of them broke the hour a real client id landed. A module
 * whose tests depend on a shipping constant having a particular value is a
 * module that breaks the day it ships.
 *
 * So the registration is a parameter now, defaulted to `GITHUB_APP`, and this
 * is what a caller passes to ask the other question. It is also the honest
 * production case for a fork or an enterprise host, where this registration
 * does not exist and `TERMINALDECK_GITHUB_APP_*` is the only way in.
 */
export const NO_REGISTRATION: GitHubAppRegistration = { clientId: null, slug: null }

/**
 * The two overrides a fork needs, and the only two there are.
 *
 * A fork, or an enterprise host, registers its own GitHub App by following the
 * steps in the header and points this build at it with these — no rebuild, no
 * source edit. There used to be a third variable, `TERMINALDECK_GITHUB_CLIENT_ID`,
 * naming an *OAuth* application; it is gone with the path that read it, because
 * an OAuth client id sent through a GitHub App device request would be a
 * request with no `scope` for an id that requires one, which GitHub answers with
 * a 404 that names nothing.
 */
export const APP_CLIENT_ID_ENV = 'TERMINALDECK_GITHUB_APP_CLIENT_ID'
export const APP_SLUG_ENV = 'TERMINALDECK_GITHUB_APP_SLUG'

function clean(value: string | null | undefined): string | null {
  const trimmed = (value ?? '').trim()
  return trimmed === '' ? null : trimmed
}

/**
 * The registration in force, environment over built-in.
 *
 * `built` is the registration compiled into the build, and it is a parameter
 * rather than a straight read of `GITHUB_APP` so that "what happens with no
 * registration" stays answerable after one shipped — see `NO_REGISTRATION`. It
 * defaults to `GITHUB_APP`, so every production caller is unchanged.
 *
 * An environment variable that is present but blank falls through to the
 * built-in rather than clearing it. That is deliberate: `TERMINALDECK_…=` with
 * nothing after it is what an empty shell variable or an unset value in a
 * launcher plist looks like, and reading that as "disable the GitHub App" would
 * turn a stray export into a build that cannot sign in at all.
 *
 * A slug with no client id is deliberately *not* a registration: the slug only
 * builds a link, and offering "install this app" for an app that cannot then be
 * signed in to is a dead end wearing a button.
 */
export function githubAppRegistration(
  env: NodeJS.ProcessEnv = process.env,
  built: GitHubAppRegistration = GITHUB_APP,
): GitHubAppRegistration {
  const clientId = clean(env[APP_CLIENT_ID_ENV]) ?? clean(built.clientId)
  if (!clientId) return { clientId: null, slug: null }
  return { clientId, slug: clean(env[APP_SLUG_ENV]) ?? clean(built.slug) }
}

/** True when a real GitHub App registration exists to sign in through. */
export function githubAppConfigured(
  env: NodeJS.ProcessEnv = process.env,
  built: GitHubAppRegistration = GITHUB_APP,
): boolean {
  return githubAppRegistration(env, built).clientId !== null
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
 * What a build with no registration says when Connect is pressed.
 *
 * It used to be a note about a feature that was merely unavailable, because
 * there was an OAuth fallback underneath it that would sign the user in anyway.
 * There is not any more, so this is the whole answer: without a registration
 * this app has nothing to send GitHub, and the sentence says what to do instead
 * rather than leaving a button that can only ever fail.
 *
 * `gh auth login` is named because it genuinely works — an existing GitHub CLI
 * login is still picked up and used, and it is the one way into a fork's build
 * that needs nothing registered at all. The environment variable is named
 * second because it is the permanent fix for whoever maintains that fork.
 */
export const APP_UNCONFIGURED_REASON =
  'This build has no GitHub App registered, so there is nothing here to sign in through. Run gh auth login in a terminal and this app will use it, or set TERMINALDECK_GITHUB_APP_CLIENT_ID to a registration of your own.'
