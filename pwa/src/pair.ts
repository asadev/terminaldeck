/**
 * Pairing: what this browser keeps once six digits have bought a credential.
 *
 * ## What used to be here, and why none of it is
 *
 * This file used to open with a paragraph about reading a pairing token out of
 * a URL fragment — `https://<machine>.<tailnet>.ts.net/#t=<token>` — because the
 * desktop drew that address as a QR code and a phone's camera walked it in. The
 * QR is gone (it did not work), and so is the `terminaldeck://pair?…` link this
 * client also parsed, because a link is a bearer secret with a route through a
 * messaging app attached to it.
 *
 * So there is exactly one way in now: six digits from `shared/short-code.ts`,
 * typed. `main.ts` normalises them and hands them to `rendezvous.ts` to find the
 * machine; nothing arrives in the URL any more, which is why `takePairToken` and
 * the fragment readers are not below. Removing them is not tidying — a reader
 * that accepts a token nobody mints is a second, unexercised way into the one
 * function that writes a credential to disk.
 *
 * No `localStorage` and no `location` are touched at module scope — everything
 * comes in as an argument, which is what lets this be tested with no DOM.
 */

import type { StaticKeyPair } from '../../src/shared/sealed'
import {
  asEndpoint,
  clearDeviceKeys,
  saveDeviceKeys,
  type DeckEndpoint,
  type StorageLike,
} from './endpoint'
import { asHostPlatform, type HostPlatform } from './host-platform'
import { clearAcross, readAcross, writeAcross, type Remember, type Stores } from './remember'

/**
 * Re-exported rather than declared. It lives in `remember.ts` now; every
 * existing caller keeps the name it already imports from here.
 */
export type { StorageLike }

/** Versioned: a format change must not be read back as if it were current. */
export const CREDENTIAL_KEY = 'terminaldeck.credential.v1'

/**
 * How long a remembered browser pairing lives without being used.
 *
 * ## Why a browser gets one at all, when a phone does not
 *
 * A phone's credential has no expiry. It is in the Keychain, the phone is the
 * person's, and the one way it ends is being revoked from the machine — which is
 * correct, because a phone you still have is a phone you still want paired.
 *
 * None of that holds here. The credential is plaintext to any script on the
 * origin, and — the part that actually matters — the browser client's reason to
 * exist is the computer somebody does not own. The pairing left behind on a work
 * laptop is not an unlucky case, it is what happens by default when the feature
 * works and nobody thinks about it afterwards. "Just for this visit" is the
 * answer for the borrowed machine and it is the safe default on the pair screen;
 * this is the backstop for the person who ticked "remember" on a computer they
 * turned out not to keep.
 *
 * ## Why thirty days, and why since last use rather than since pairing
 *
 * Sliding, because the thing worth expiring is *abandonment*, not age. A browser
 * somebody uses is a browser they want; a browser nobody has opened for a month
 * is the one sitting in a profile on a machine that changed hands. On the
 * machine this was actually left on the two are the same number — nothing there
 * reconnects, so the window never slides — and on the person's own laptop the
 * pairing simply keeps working, which is what stops this being the kind of
 * expiry people route around.
 *
 * Thirty days rather than seven because the ceremony it forces is not free: it
 * is standing at the desktop, minting a code and approving a device. Short
 * enough that a stale pairing does not outlive the job somebody borrowed the
 * laptop for; long enough that a browser used every few weeks is not punished.
 *
 * ## What this is not
 *
 * It is not a security boundary and this file will not pretend it is. It is
 * *this browser choosing to forget*, and the machine on the far end knows
 * nothing about it — a credential copied out of `localStorage` and replayed by
 * something that is not this client is unaffected. The thing that actually ends
 * a pairing is Revoke on the desktop, which closes the socket where it stands
 * and refuses it thereafter. This is the half that works when nobody is watching
 * the device list, which is most of the time.
 */
export const REMEMBERED_TTL_MS = 30 * 24 * 60 * 60 * 1000

export interface StoredCredential {
  /** The per-device credential from `redeemPairingToken`, `<id>.<secret>`. */
  token: string
  deviceId: string
  deviceName: string
  pairedAt: number
  /**
   * What kind of machine this credential is for, from the last `welcome`.
   *
   * Kept so that the first paint after a relaunch already has the right noun in
   * it. The session list is drawn before the socket is up — it says "this list
   * is from the last time the … answered" — and a phone that has been paired to
   * a Windows PC for a month should not have to wait for a handshake to stop
   * calling it a Mac. Not a security-relevant field and not trusted as one: it
   * is read back through `readHostPlatform`, which folds anything it does not
   * recognise onto `unknown`, so a hand-edited `localStorage` can make this
   * client say a neutral word and nothing else.
   */
  hostPlatform: HostPlatform
  /**
   * How to reach that machine again.
   *
   * A credential is only a credential *for somewhere*, and until the relay
   * arrived there was only one somewhere — the address this page was served
   * from — so nothing had to be written down. A relay pairing has three facts to
   * remember and `endpoint.ts` holds them.
   *
   * Read back through `asEndpoint`, which folds anything missing or malformed
   * onto the direct route. That is the migration, and it is deliberate: a
   * browser paired before this field existed was talking to its own origin, and
   * making it pair again in order to introduce a field would be an absurd trade.
   */
  endpoint: DeckEndpoint
  /**
   * Epoch ms after which this browser forgets the pairing on its own.
   *
   * Pushed forward on every successful `welcome`, so it measures time since this
   * browser last actually reached the machine rather than time since it paired.
   * See {@link REMEMBERED_TTL_MS} for why there is one at all and why it slides.
   */
  expiresAt: number
}

/* ------------------------------------------------------------- storage --- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * The stored credential in one store, or null when there is not a live one.
 *
 * Anything half-written is treated as nothing. A credential missing its device
 * id would send the app to the session list holding something that cannot
 * authenticate, and the user would see a connection that fails forever with no
 * way back to the pair screen.
 *
 * `now` is an argument rather than a call to `Date.now()` so the expiry can be
 * tested by moving a number, which is the same reason the connection takes a
 * clock. A credential past its expiry is **removed** rather than merely refused:
 * leaving the bytes there would keep a dead secret on a machine somebody may not
 * own for as long as the profile lasts, which is exactly what the expiry is for.
 */
export function loadCredential(storage: StorageLike, now: number): StoredCredential | null {
  let raw: string | null
  try {
    raw = storage.getItem(CREDENTIAL_KEY)
  } catch {
    // Safari throws on storage access in private mode rather than returning
    // null. Unpaired is the honest reading of "cannot read the credential".
    return null
  }
  if (raw === null) return null

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return null
  }
  if (!isRecord(parsed)) return null

  const { token, deviceId, deviceName, pairedAt, hostPlatform, endpoint, expiresAt } = parsed
  if (typeof token !== 'string' || token === '') return null
  if (typeof deviceId !== 'string' || deviceId === '') return null

  /*
   * A missing expiry starts the clock now rather than at `pairedAt`.
   *
   * That is the migration for every browser paired before this field existed,
   * and the obvious alternative is a trap: `pairedAt` defaults to 0 for
   * credentials written by builds older still, so `pairedAt + TTL` would land in
   * 1970 and sign out every one of those people on the launch that introduced
   * the feature. Starting the window at the upgrade is the honest reading — this
   * browser has been in use as recently as right now.
   */
  const expiry = typeof expiresAt === 'number' && Number.isFinite(expiresAt) ? expiresAt : now + REMEMBERED_TTL_MS
  if (expiry <= now) {
    clearCredential(storage)
    return null
  }

  return {
    expiresAt: expiry,
    token,
    deviceId,
    deviceName: typeof deviceName === 'string' && deviceName !== '' ? deviceName : 'This device',
    pairedAt: typeof pairedAt === 'number' && Number.isFinite(pairedAt) ? pairedAt : 0,
    // `asHostPlatform`, not `readHostPlatform`: what is in storage is a value
    // this client wrote in its own vocabulary (`windows`), not the desktop's
    // (`win32`), and reading it with the wire mapping turned every stored
    // answer back into `unknown` on the very next launch.
    //
    // Missing is the normal case for a credential written by a build that
    // predates the field, and `unknown` is the honest reading of it — the same
    // answer an absent `welcome.hostPlatform` gets, for the same reason. It is
    // deliberately not a reason to discard the credential: a phone that had to
    // pair again because this client learned a new noun would be an absurd
    // trade.
    hostPlatform: asHostPlatform(hostPlatform),
    endpoint: asEndpoint(endpoint),
  }
}

export function saveCredential(storage: StorageLike, credential: StoredCredential): void {
  try {
    storage.setItem(CREDENTIAL_KEY, JSON.stringify(credential))
  } catch {
    // Out of quota, or private mode. The session in progress still works — it
    // is holding the credential in memory — so this is not worth interrupting
    // the user for. The next launch will ask them to pair again.
  }
}

export function clearCredential(storage: StorageLike): void {
  try {
    storage.removeItem(CREDENTIAL_KEY)
  } catch {
    // Nothing useful to do; the caller is already on its way to the pair screen.
  }
}

/* ----------------------------------------------------- across both stores -- */

/** A live pairing, and which of the two lifetimes it was kept under. */
export interface LoadedPairing {
  credential: StoredCredential
  remember: Remember
}

/**
 * The pairing this browser is holding, wherever it is held.
 *
 * The tab is searched first — see `readAcross` — so a "just for this visit"
 * pairing made in this tab wins over anything durable that survived beside it.
 * Which store answered is returned rather than inferred later, because it is the
 * answer to a question the person was asked and every subsequent write has to
 * land in the same place.
 */
export function loadPairing(stores: Stores, now: number): LoadedPairing | null {
  const found = readAcross(stores, (storage) => loadCredential(storage, now))
  return found === null ? null : { credential: found.value, remember: found.remember }
}

/**
 * Write the pairing where the answer says, and clear the other store.
 *
 * The credential and this browser's X25519 key move as one, always. They are
 * two halves of the same pairing — the machine checks both, and a device that
 * presents the credential with a different key is refused — so a credential in
 * `sessionStorage` beside a key in `localStorage` would leave a durable
 * identifier for this app on a computer whose owner asked us to leave nothing.
 * The only way to guarantee they cannot drift is for one function to move both.
 */
export function savePairing(
  stores: Stores,
  remember: Remember,
  credential: StoredCredential,
  deviceKeys: StaticKeyPair,
): void {
  writeAcross(
    stores,
    remember,
    (storage) => {
      saveCredential(storage, credential)
      saveDeviceKeys(storage, deviceKeys)
    },
    (storage) => {
      clearCredential(storage)
      clearDeviceKeys(storage)
    },
  )
}

/** Forget in both, and forget both halves. */
export function clearPairing(stores: Stores): void {
  clearAcross(stores, (storage) => {
    clearCredential(storage)
    clearDeviceKeys(storage)
  })
}

/**
 * The same credential with its expiry pushed out to a full window from `now`.
 *
 * Called on every `welcome`, which is the only moment this browser knows it
 * genuinely reached the machine. Deliberately not called on a socket that merely
 * opened: the relay will open one for a host id that has been revoked at the
 * far end, and sliding an expiry on that would be this client renewing itself
 * against something that is not the machine.
 */
export function renewed(credential: StoredCredential, now: number): StoredCredential {
  return { ...credential, expiresAt: now + REMEMBERED_TTL_MS }
}

/* -------------------------------------------------------------- device --- */

/**
 * What this browser calls itself in the desktop's device list.
 *
 * ## The row has to say "a browser", and it did not
 *
 * This used to answer "Windows PC" for a browser on Windows, "Mac" for one on a
 * Mac. That is the same string the native app on that machine sends, so the
 * device list showed a pairing in a browser on a computer somebody borrowed for
 * an afternoon as if it were the app installed on their own desktop. The list is
 * the *only* place a browser pairing can be found and killed — this client has
 * no keychain, no OS-level sign-out and no server-side session anybody can end —
 * so a row that cannot be told apart from a trusted one makes Revoke a button
 * you cannot aim.
 *
 * So: the browser and the platform, both. "Chrome on Windows" is a sentence
 * whose subject is the thing that is actually holding a credential, and it is
 * what somebody scanning the list for what to revoke is looking for.
 *
 * ## Coarse on purpose, and untrusted on the far end
 *
 * The engine, not the version; the OS, not the build. Parsing a user-agent for a
 * model number is a guess dressed as a fact, and the person approving needs to
 * recognise the thing in front of them rather than audit it. `auth.ts` treats
 * this string as untrusted display text and bounds it, which is correct — a
 * client can claim any name, and this one just tells the truth.
 *
 * ## Order is the whole implementation
 *
 * Every one of these strings lies about the others. Edge says Chrome and Safari;
 * Chrome says Safari; Opera says Chrome and Safari; every iOS browser says
 * Safari because iOS made them all WebKit. So the checks run most-specific
 * first, and the tests pin real user-agent strings rather than the shapes.
 */
export function describeDevice(userAgent: string): { name: string; platform: string } {
  const ua = userAgent.toLowerCase()
  const platform = ua.includes('ipad')
    ? 'iPadOS'
    : ua.includes('iphone')
      ? 'iOS'
      : ua.includes('android')
        ? 'Android'
        : ua.includes('windows')
          ? 'Windows'
          : ua.includes('mac os')
            ? 'macOS'
            : ua.includes('linux')
              ? 'Linux'
              : 'unknown'

  const browser = ua.includes('edg/') || ua.includes('edgios') || ua.includes('edga')
    ? 'Edge'
    : ua.includes('opr/') || ua.includes('opios')
      ? 'Opera'
      : ua.includes('samsungbrowser')
        ? 'Samsung Internet'
        : ua.includes('firefox') || ua.includes('fxios')
          ? 'Firefox'
          : ua.includes('crios') || ua.includes('chrome') || ua.includes('chromium')
            ? 'Chrome'
            : ua.includes('safari')
              ? 'Safari'
              : null

  // "on the iPad" reads wrong; "on iPadOS" reads like a spec sheet. The device
  // word is the one a person would use pointing at it.
  const where =
    platform === 'iOS' ? 'iPhone' : platform === 'iPadOS' ? 'iPad' : platform === 'macOS' ? 'Mac' : platform

  // Never a bare platform, and never a bare browser. "Browser" alone is what
  // this returned for anything it could not place, and it is indistinguishable
  // from every other unplaceable device in the list.
  const name =
    browser === null
      ? where === 'unknown'
        ? 'Browser'
        : `Browser on ${where}`
      : where === 'unknown'
        ? browser
        : `${browser} on ${where}`

  return { name, platform }
}
