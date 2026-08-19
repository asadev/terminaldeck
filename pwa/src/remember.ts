/**
 * How long a pairing survives in *this* browser, and where it is kept.
 *
 * ## Why a browser is asked a question the phones are not
 *
 * There are no accounts in this product and there must not be: pairing is the
 * login, the secret is a bearer credential the machine minted, and nothing about
 * any of it exists on a server. That is the whole design and this module does
 * not change it. What it changes is the assumption underneath the *storage* of
 * that credential, which the other two clients get for free and this one cannot.
 *
 * On iOS the credential is in the Keychain and on Android in the Keystore: a
 * store that belongs to the app, that another app cannot read, and that follows
 * the phone rather than the person holding it. A browser has none of that. What
 * it has is:
 *
 *   - **`localStorage`**, which is plaintext to every script on the origin, and
 *     which "clear browsing data" destroys without warning; and
 *   - **`sessionStorage`**, which is the same thing with a shorter life — it is
 *     scoped to the tab and is gone when the tab is.
 *
 * And the browser client's entire reason to exist is the computer you do not
 * own. A phone is yours; the machine you open a web client on is a work laptop,
 * a hotel business centre, a friend's desktop, a machine in a lab. Leaving a
 * live shell credential behind on one of those is not an edge case, it is the
 * ordinary consequence of the feature working.
 *
 * So this client asks, once, at the only moment the answer is knowable: **is
 * this browser yours?** The two answers are two different stores, and the
 * difference between them is the difference between a pairing that outlives the
 * tab and one that does not.
 *
 * ## Exactly one store ever holds it
 *
 * Not "prefer one". Writing to one *clears the other*, every time, and reading
 * looks in the tab first. Two stores that can both hold a credential is a
 * browser that answers "just for this visit" and still leaves the previous
 * pairing sitting in `localStorage` for the next person, which is the precise
 * failure this file exists to prevent — and it would be invisible, because the
 * tab's copy is the one the client would be using.
 *
 * ## Why the callbacks
 *
 * Two different things live under this rule — the credential and this browser's
 * X25519 identity — and they have to move together. A credential in the tab and
 * a device key in `localStorage` leaves half a pairing behind: not enough to get
 * in, and still a durable identifier for a machine that is not yours. Rather
 * than write the two-store dance twice and have the second copy drift, the
 * dance is here once and takes the read, the write and the clear as arguments.
 */

/**
 * The slice of `Storage` this client uses.
 *
 * Declared here rather than in `endpoint.ts`, where it used to live, because
 * this is now the module every storage decision goes through and the interface
 * belongs with the rule. `endpoint.ts` re-exports it, so existing imports keep
 * working.
 */
export interface StorageLike {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
}

/**
 * The answer to "remember this browser?", as a value rather than a boolean.
 *
 * A boolean here would be read at the call site as `remember === true` and
 * written at the UI as `checked`, and the two would be one negation apart
 * forever. These two names cannot be got backwards.
 */
export type Remember = 'this-browser' | 'this-tab'

export interface Stores {
  /** `localStorage`. Survives the tab, the window and the reboot. */
  browser: StorageLike
  /** `sessionStorage`. Gone when the tab is. */
  tab: StorageLike
}

/**
 * A store that holds nothing, for a browser that refuses to give us one.
 *
 * Safari in private mode throws on `localStorage` access rather than returning
 * null, and a browser with storage disabled entirely does the same. The client
 * still works in that state — everything it needs is in memory for the life of
 * the page — and it fails in the safe direction, which is that the next launch
 * has to pair again. A `null` store would put an optional chain on every call
 * site instead, and one of them would eventually be missing.
 */
export function memoryStorage(): StorageLike {
  const values = new Map<string, string>()
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => void values.set(key, value),
    removeItem: (key) => void values.delete(key),
  }
}

/** One `Storage` off `window`, or a memory stand-in if reading it throws. */
function usable(read: () => Storage | undefined): StorageLike {
  try {
    // Touched, not just fetched. Safari's private mode returns the object and
    // throws on the first write, so a check that only looked for the object
    // would pass here and fail at the moment somebody pairs.
    const store = read()
    if (store === undefined) return memoryStorage()
    const probe = '__terminaldeck.probe__'
    store.setItem(probe, '1')
    store.removeItem(probe)
    return store
  } catch {
    return memoryStorage()
  }
}

/** The two real stores, each falling back to memory if the browser refuses. */
export function browserStores(from: Window = window): Stores {
  return {
    browser: usable(() => from.localStorage),
    tab: usable(() => from.sessionStorage),
  }
}

/**
 * Read from whichever store holds something, and say which one that was.
 *
 * The tab first, and that order is the rule rather than a preference: a pairing
 * made in this tab with "just for this visit" is the most recent decision the
 * person made, and it is the one that must win if anything else is somehow
 * lying around.
 */
export function readAcross<T>(
  stores: Stores,
  read: (storage: StorageLike) => T | null,
): { value: T; remember: Remember } | null {
  const inTab = read(stores.tab)
  if (inTab !== null) return { value: inTab, remember: 'this-tab' }
  const inBrowser = read(stores.browser)
  return inBrowser === null ? null : { value: inBrowser, remember: 'this-browser' }
}

/** The store an answer means. */
export function storeFor(stores: Stores, remember: Remember): StorageLike {
  return remember === 'this-tab' ? stores.tab : stores.browser
}

/**
 * Write to the store the answer names, and clear the other one.
 *
 * The clear is not tidiness. Someone re-pairing a browser they had remembered,
 * this time answering "just for this visit", is someone who has decided the
 * durable copy should not be there — and it is the copy they cannot see.
 */
export function writeAcross(
  stores: Stores,
  remember: Remember,
  write: (storage: StorageLike) => void,
  clear: (storage: StorageLike) => void,
): void {
  write(storeFor(stores, remember))
  clear(storeFor(stores, remember === 'this-tab' ? 'this-browser' : 'this-tab'))
}

/** Forget in both, because "forget this machine" may not leave half behind. */
export function clearAcross(stores: Stores, clear: (storage: StorageLike) => void): void {
  clear(stores.tab)
  clear(stores.browser)
}

/* --------------------------------------------------------------- retired -- */

/**
 * Keys this client used to write and no longer does.
 *
 * There is one, and it held a secret: `terminaldeck.copilot.v1` was a map of
 * copilot credentials keyed by machine, written by `copilot-store.ts` when the
 * copilot was a **separate connection** with a six-digit code of its own. That
 * ceremony was deleted on 2026-08-19 — pairing a device as one of his own is now
 * the whole authorisation — and the module that wrote this went with it.
 *
 * Listed rather than forgotten because deleting the writer does not delete what
 * it wrote. Every browser that ever connected a copilot is still holding those
 * strings, in `localStorage` on the ones that answered *"this browser is mine"*,
 * and nothing would ever read them again. A secret nobody can see, that nothing
 * can use, sitting on a work laptop until somebody clears their browsing data,
 * is the exact shape of leftover this client's storage rules exist to prevent —
 * and the browser client's whole reason to exist is the computer you do not own.
 */
export const RETIRED_KEYS: readonly string[] = ['terminaldeck.copilot.v1']

/**
 * Sweep {@link RETIRED_KEYS} out of both stores.
 *
 * Both, unconditionally, on every launch — not "whichever store this browser
 * chose". The answer to *is this browser yours* can have changed since the value
 * was written, and the copy that would be missed is the durable one on a
 * computer somebody has since said is not theirs.
 *
 * Cheap enough to do every launch that no flag records it having been done: a
 * flag would be a key written to avoid removing a key, and it would outlive the
 * removal it was tracking.
 */
export function purgeRetired(stores: Stores): void {
  for (const storage of [stores.tab, stores.browser]) {
    for (const key of RETIRED_KEYS) {
      try {
        storage.removeItem(key)
      } catch {
        // Private mode, or storage switched off. Nothing here is load-bearing —
        // a store that refuses a write is a store that is not keeping the value
        // either — and throwing would take the whole launch with it.
      }
    }
  }
}
