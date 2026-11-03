/**
 * Where the community catalogue is fetched from, and how that can be pointed
 * somewhere else.
 *
 * ## One constant, and an override that takes its environment as an argument
 *
 * `src/shared/**` is compiled into the renderer as well as the main process, and
 * there is not one read of `process.env` anywhere in it. That is not an accident
 * and this file does not become the first: {@link storeApiBase} takes the
 * environment it should read as a parameter, exactly the way the relay's own
 * override does — the constant lives in `shared/relay-wire.ts` and
 * `remote/relay-client.ts` passes `env` in. A pure function of two arguments is
 * also the only shape a test can ask a question of without setting a global and
 * hoping to put it back.
 *
 * ## Why plain http is allowed for loopback and nowhere else
 *
 * The first milestone of this store is entirely local: a signed index served as
 * a static file by `python3 -m http.server` on this machine, with no box, no
 * database and no account behind it. That server cannot speak https, so a rule
 * of *https only* would mean the whole thing could never be looked at before it
 * was deployed.
 *
 * So `http://127.0.0.1:8931` is honoured and `http://catalogue.example.com` is
 * not, and the difference is the one `httpsFetchBytes` in `browser-store.ts`
 * already argues: a store that would fetch a catalogue over plain http on a
 * coffee-shop network is a store whose signature check is the only thing between
 * that network and this app. Loopback has no network in front of it. Anything
 * else is refused, the default is used instead, and the reason comes back in
 * {@link StoreApiChoice.ignored} so a screen can print it rather than silently
 * fetching from somewhere the person did not ask for.
 */

/** Where the catalogue lives when nobody says otherwise. */
export const DEFAULT_STORE_API = 'https://terminaldeck.dev'

/**
 * The variable that points this app at a different catalogue.
 *
 * Named the way this app names its other variables — `TERMINALDECK_VERSION`,
 * `TERMINALDECK_SESSION_ID`, `TERMINALDECK_GITHUB_APP_CLIENT_ID` — so a person
 * reading a shell profile can tell whose it is.
 */
export const STORE_API_ENV = 'TERMINALDECK_STORE_API'

/** The one path under the base, so nothing spells it twice. */
export const STORE_INDEX_PATH = '/store/index.json'

export interface StoreApiChoice {
  /** The base to fetch from, with no trailing slash. */
  base: string
  /** True when the answer came from somewhere other than the built-in default. */
  overridden: boolean
  /** What was asked for and refused, and why, or null when nothing was. */
  ignored: string | null
}

/** Loopback, spelled the three ways a person or a tool actually writes it. */
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '::1', '[::1]'])

function judge(raw: string): { base: string } | { why: string } {
  const trimmed = raw.trim()
  if (trimmed === '') return { why: 'it was empty' }
  let parsed: URL
  try {
    parsed = new URL(trimmed)
  } catch {
    return { why: `${trimmed} is not a web address` }
  }
  if (parsed.protocol === 'https:') return { base: stripSlash(parsed) }
  if (parsed.protocol === 'http:') {
    if (LOOPBACK.has(parsed.hostname.toLowerCase())) return { base: stripSlash(parsed) }
    return { why: `${trimmed} is plain http, which is only allowed on this machine` }
  }
  return { why: `${trimmed} is not http or https` }
}

function stripSlash(parsed: URL): string {
  const base = `${parsed.origin}${parsed.pathname}`
  return base.endsWith('/') ? base.slice(0, -1) : base
}

/**
 * Which catalogue this run should read, and what it refused on the way.
 *
 * `configured` is a value a person set in settings and beats nothing; the
 * environment variable beats it, because a variable is what a developer types
 * for one run and a setting is what a person leaves behind.
 */
export function resolveStoreApi(env: NodeJS.ProcessEnv, configured?: string | null): StoreApiChoice {
  const attempts: string[] = []
  const fromEnv = env[STORE_API_ENV]
  if (typeof fromEnv === 'string') attempts.push(fromEnv)
  if (typeof configured === 'string') attempts.push(configured)

  const refused: string[] = []
  for (const attempt of attempts) {
    const verdict = judge(attempt)
    if ('base' in verdict) {
      return { base: verdict.base, overridden: true, ignored: refused.length === 0 ? null : refused[0] }
    }
    refused.push(verdict.why)
  }
  return { base: DEFAULT_STORE_API, overridden: false, ignored: refused.length === 0 ? null : refused[0] }
}

/** The base to fetch from, for callers that do not need to print a refusal. */
export function storeApiBase(env: NodeJS.ProcessEnv, configured?: string | null): string {
  return resolveStoreApi(env, configured).base
}

/** The full address of the signed catalogue. */
export function storeIndexUrl(base: string): string {
  return `${base.endsWith('/') ? base.slice(0, -1) : base}${STORE_INDEX_PATH}`
}
