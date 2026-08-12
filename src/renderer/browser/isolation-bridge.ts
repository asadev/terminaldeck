/**
 * The browser panel's optional half of the preload bridge.
 *
 * Separate from `bridge.ts` for one reason that matters. `resolveBrowserBridge`
 * returns null — and the panel renders "The browser is not connected" instead of
 * a browser — when *any* method it lists is missing. That is right for
 * navigation, which the panel cannot do anything without. It would be wrong for
 * per-tab isolation: a build whose preload has not caught up yet should lose one
 * toggle, not the whole browser.
 *
 * So these are declared the way `settings-bridge.ts` declares its own: a
 * `…BridgeMethods` interface, resolved to a `Partial`, with every caller
 * checking before it calls. The name also keeps it out of the contract test's
 * "every `*Bridge` interface must be fully exposed" rule, which is exactly the
 * distinction being drawn — these are allowed to be absent.
 */

/** Mirrors the channels registered in `src/main/browser-isolation.ts`. */
export interface IsolationBridgeMethods {
  /** A fresh in-memory partition key, to pass to `browserCreate`. */
  browserIsolationKey(): Promise<unknown>
  /** Throw a closed isolated tab's partition away. */
  browserIsolationDispose(key: string): Promise<unknown>
}

export type IsolationApi = Partial<IsolationBridgeMethods>

const ISOLATION_METHODS: ReadonlyArray<keyof IsolationBridgeMethods> = [
  'browserIsolationKey',
  'browserIsolationDispose',
]

/**
 * Pick whichever of them the preload actually exposes.
 *
 * Each call goes through the host object rather than being torn off it: a
 * detached method loses `this`, and the failure shows up at the first click
 * rather than at mount.
 */
export function resolveIsolationApi(host?: unknown): IsolationApi {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { pawl?: unknown }).pawl)
  if (typeof source !== 'object' || source === null) return {}

  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of ISOLATION_METHODS) {
    if (typeof record[name] !== 'function') continue
    api[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return api as IsolationApi
}

/**
 * True when the toggle can work at all, which needs only the minting half.
 *
 * Deliberately not "both halves". Without `browserIsolationKey` an isolated tab
 * cannot be opened and the switch has to be dead. `browserIsolationDispose` is
 * cleanup: every caller optional-chains it, so a build missing it still opens
 * and closes isolated tabs correctly and only holds their in-memory partitions
 * until quit. Gating the toggle on it would trade a working feature for a
 * tidier teardown.
 */
export function isolationAvailable(api: IsolationApi): boolean {
  return typeof api.browserIsolationKey === 'function'
}

/**
 * Narrow the key the main process minted.
 *
 * The renderer does not decide what a key looks like — `browser-isolation.ts`
 * validates it again on the way back in — but a non-string here would be passed
 * to `browserCreate` and silently produce a *shared* tab labelled Isolated,
 * which is the one failure this feature must not have.
 */
export function asIsolationKey(raw: unknown): string | null {
  return typeof raw === 'string' && raw !== '' && !raw.startsWith('persist:') ? raw : null
}
