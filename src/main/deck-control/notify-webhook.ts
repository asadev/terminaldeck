/**
 * Signing a notification for an AI app's webhook, and checking a signature.
 *
 * ## Why the Standard Webhooks shape and not one of our own
 *
 * The receiver is somebody else's program — a small server next to their agent,
 * a workflow tool, a cloud function — and the cheapest thing this app can do for
 * it is sign the way a library it may already have expects. Standard Webhooks
 * (standardwebhooks.com, used by several large senders) is exactly that: three
 * headers and one HMAC, with verifiers in most languages. Inventing
 * `X-Our-Signature` would make every receiver write its own, and a hand-written
 * verifier is where the timing leak and the missing replay check live.
 *
 *   webhook-id:         the notification's id — the same id `notifications.ack` takes
 *   webhook-timestamp:  unix seconds when this attempt was signed
 *   webhook-signature:  `v1,<base64 HMAC-SHA256(secret, "<id>.<timestamp>.<body>")>`
 *
 * The secret is 32 random bytes per access key, shown to the owner as
 * `whsec_<base64>` — the spec's own spelling, which its libraries take as-is.
 * It signs; it never travels. A receiver checks the signature, and rejects a
 * timestamp more than {@link REPLAY_WINDOW_SECONDS} from its own clock, which is
 * what stops a captured delivery being replayed later.
 *
 * Each retry is signed afresh with a new timestamp and the same id, so a
 * receiver de-duplicating by `webhook-id` sees one notification however many
 * attempts it took.
 */

import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto'

/** How the secret is shown and stored: the spec's prefix, then base64 of 32 bytes. */
export const SECRET_PREFIX = 'whsec_'

/** How far a receiver should let a timestamp stray from its own clock. Five minutes, the spec's own figure. */
export const REPLAY_WINDOW_SECONDS = 300

export const HEADER_ID = 'webhook-id'
export const HEADER_TIMESTAMP = 'webhook-timestamp'
export const HEADER_SIGNATURE = 'webhook-signature'

export function newWebhookSecret(): string {
  return `${SECRET_PREFIX}${randomBytes(32).toString('base64')}`
}

function secretBytes(secret: string): Buffer {
  const raw = secret.startsWith(SECRET_PREFIX) ? secret.slice(SECRET_PREFIX.length) : secret
  return Buffer.from(raw, 'base64')
}

/** The signature over one attempt, as the header carries it. */
export function signWebhook(secret: string, id: string, timestampSeconds: number, body: string): string {
  const mac = createHmac('sha256', secretBytes(secret)).update(`${id}.${timestampSeconds}.${body}`).digest('base64')
  return `v1,${mac}`
}

/** The three headers for one attempt. */
export function webhookHeaders(
  secret: string,
  id: string,
  timestampSeconds: number,
  body: string,
): Record<string, string> {
  return {
    [HEADER_ID]: id,
    [HEADER_TIMESTAMP]: String(timestampSeconds),
    [HEADER_SIGNATURE]: signWebhook(secret, id, timestampSeconds, body),
  }
}

export type VerifyResult = { ok: true } | { ok: false; why: 'missing' | 'stale' | 'mismatch' }

/**
 * What a receiver should do, written out so the test can be the documentation.
 *
 * Constant-time over every signature in the header — the spec allows several,
 * space-separated, for secret rotation — and a timestamp outside the window is
 * refused before the MAC is even computed.
 */
export function verifyWebhook(
  secret: string,
  headers: Record<string, string | undefined>,
  body: string,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): VerifyResult {
  const id = headers[HEADER_ID]
  const stamp = headers[HEADER_TIMESTAMP]
  const signatures = headers[HEADER_SIGNATURE]
  if (!id || !stamp || !signatures) return { ok: false, why: 'missing' }
  const timestamp = Number(stamp)
  if (!Number.isInteger(timestamp) || Math.abs(nowSeconds - timestamp) > REPLAY_WINDOW_SECONDS) {
    return { ok: false, why: 'stale' }
  }
  const expected = Buffer.from(signWebhook(secret, id, timestamp, body).slice(3), 'base64')
  let match = false
  for (const entry of signatures.split(' ')) {
    if (!entry.startsWith('v1,')) continue
    const offered = Buffer.from(entry.slice(3), 'base64')
    if (offered.length === expected.length && timingSafeEqual(offered, expected)) match = true
  }
  return match ? { ok: true } : { ok: false, why: 'mismatch' }
}

/**
 * Is this a URL the Mac may post to?
 *
 * `https:` anywhere, and `http:` only to this machine — a receiver on loopback
 * is a real setup (a script beside a local agent), and plain HTTP to anywhere
 * else would put every session's answer on the wire in the clear. Credentials
 * in the URL are refused: they would sit in the settings file and every log
 * line that ever printed the address.
 */
export function webhookUrlProblem(raw: string): string | null {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    return 'That is not a web address.'
  }
  if (url.username !== '' || url.password !== '') return 'Leave the user name and password out of the address.'
  if (url.protocol === 'https:') return null
  if (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) return null
  return 'Use an https:// address. Plain http:// is only allowed to this Mac (localhost).'
}
