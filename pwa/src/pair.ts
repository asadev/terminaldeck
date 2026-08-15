/**
 * Pairing: getting the token off the QR code, and keeping what it bought.
 *
 * The desktop shows a QR encoding `https://<machine>.<tailnet>.ts.net/#t=<token>`.
 * The token lives in the **fragment**, and that placement is the whole security
 * argument for this file: a fragment is never sent to the server in a request,
 * so it cannot land in an access log, a proxy log or a `Referer` header on the
 * way to becoming a bearer secret in somebody's log aggregator.
 *
 * It is still visible in the address bar, in the back-forward list and in any
 * screenshot of the phone, so `takePairToken` is a *take*: it reads the token
 * and rewrites the URL in the same breath. The token is worth 60 seconds
 * (`PAIRING_TTL_MS`) and one redemption, and this narrows even that.
 *
 * No `localStorage` and no `location` are touched at module scope — everything
 * comes in as an argument, which is what lets this be tested with no DOM.
 */

import { asHostPlatform, type HostPlatform } from './host-platform'

export interface StorageLike {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
}

/** Versioned: a format change must not be read back as if it were current. */
export const CREDENTIAL_KEY = 'terminaldeck.credential.v1'

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
}

/**
 * The pairing token in a URL fragment, or null.
 *
 * The shape of the token itself is not checked beyond its bounds. Its format
 * belongs to `auth.ts`, which mints it, and a regex here would be this client
 * refusing a token the desktop had just issued because someone changed the
 * alphabet. What is checked is what the protocol itself requires — non-empty,
 * at most 200 characters — plus the absence of whitespace and control
 * characters, which no encoding of a token produces and which is the shape of
 * something pasted in by hand or mangled by a messaging app.
 */
export function readPairToken(hash: string): string | null {
  const body = hash.startsWith('#') ? hash.slice(1) : hash
  if (body === '') return null
  const params = new URLSearchParams(body)
  const raw = params.get('t') ?? params.get('token')
  if (raw === null) return null
  const token = raw.trim()
  if (token === '' || token.length > 200) return null
  // Escaped rather than literal: a raw control byte in a character class is
  // invisible in an editor and survives a careless copy as a plain space.
  if (/[\s\u0000-\u001f\u007f]/.test(token)) return null
  return token
}

/**
 * A token pasted in by hand, as either the whole link or the token alone.
 *
 * Not every device this runs on has a camera pointed at the desktop — the same
 * client is meant to work from a Windows machine on the tailnet, where the QR
 * code is on a screen three feet away and the practical move is to copy the
 * link. Accepting both shapes costs one function and removes the only step of
 * pairing that needs a phone.
 */
export function readPairInput(text: string): string | null {
  const trimmed = text.trim()
  if (trimmed === '') return null
  const hash = trimmed.indexOf('#')
  if (hash !== -1) return readPairToken(trimmed.slice(hash))
  return readPairToken(`t=${encodeURIComponent(trimmed)}`)
}

export interface LocationLike {
  readonly hash: string
  readonly pathname: string
  readonly search: string
}

export interface HistoryLike {
  replaceState(data: unknown, unused: string, url: string): void
}

/**
 * Read the pairing token and remove it from the URL in one step.
 *
 * `replaceState` rather than `pushState`: pushing would leave the token one
 * back-button press away, which is exactly the history entry this is removing.
 */
export function takePairToken(location: LocationLike, history: HistoryLike): string | null {
  const token = readPairToken(location.hash)
  if (location.hash !== '') history.replaceState(null, '', `${location.pathname}${location.search}`)
  return token
}

/* ------------------------------------------------------------- storage --- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * The stored credential, or null when there is not a complete one.
 *
 * Anything half-written is treated as nothing. A credential missing its device
 * id would send the app to the session list holding something that cannot
 * authenticate, and the user would see a connection that fails forever with no
 * way back to the pair screen.
 */
export function loadCredential(storage: StorageLike): StoredCredential | null {
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

  const { token, deviceId, deviceName, pairedAt, hostPlatform } = parsed
  if (typeof token !== 'string' || token === '') return null
  if (typeof deviceId !== 'string' || deviceId === '') return null
  return {
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

/* -------------------------------------------------------------- device --- */

/**
 * A name for this phone, for the approval prompt on the desktop.
 *
 * Deliberately coarse. The person approving needs to recognise the device they
 * are holding, and "iPhone" does that; parsing a user-agent for a model number
 * is a guess dressed as a fact, and this string is display-only — `auth.ts`
 * treats it as untrusted and bounds it.
 */
export function describeDevice(userAgent: string): { name: string; platform: string } {
  const ua = userAgent.toLowerCase()
  if (ua.includes('ipad')) return { name: 'iPad', platform: 'iPadOS' }
  if (ua.includes('iphone')) return { name: 'iPhone', platform: 'iOS' }
  if (ua.includes('android')) return { name: 'Android phone', platform: 'Android' }
  if (ua.includes('windows')) return { name: 'Windows PC', platform: 'Windows' }
  if (ua.includes('mac os')) return { name: 'Mac', platform: 'macOS' }
  if (ua.includes('linux')) return { name: 'Linux', platform: 'Linux' }
  return { name: 'Browser', platform: 'unknown' }
}
