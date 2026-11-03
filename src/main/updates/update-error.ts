/**
 * What to say when an update check or download fails.
 *
 * ## Why this is a module and not a `String(error)`
 *
 * `electron-updater`'s GitHub provider builds its error message by appending
 * **the entire Atom feed it just fetched** to the sentence. On a Windows box
 * whose network changed mid-request, a real user saw this in the panel:
 *
 *     Cannot parse releases feed: Error: Unable to find latest version on
 *     GitHub (…/releases/latest), please ensure a production release exists:
 *     Error: net::ERR_NETWORK_CHANGED at SimpleURLLoaderWrapper.<anonymous>
 *     (node:electron/js2c/browser_init:2:135010) … at async NsisUpdater
 *     .doCheckForUpdates (C:\Users\…\electron-updater\out\AppUpdater.js:402:24)
 *     XML: <?xml version="1.0" encoding="UTF-8"?><feed …><entry><content
 *     type="html">&lt;h3&gt;Install&lt;/h3&gt; …
 *
 * — a stack trace across four node_modules frames, a Windows user's home
 * directory, and the whole release-notes HTML twice-escaped, in a box the size
 * of the window. The panel was doing what it was told: print the error.
 *
 * Two separate faults, which is why there are two fields on the result.
 *
 * ## `text` — never the raw message
 *
 * The raw message is a diagnostic written for whoever wrote `electron-updater`.
 * It is not addressed to the person at the keyboard, and it names a cause they
 * cannot act on. What they can act on is *whether it is worth trying again*,
 * which is one short sentence. Anything past the first line, anything that
 * looks like a stack frame, and anything from the first angle bracket of an
 * embedded document onward is dropped rather than shortened — a truncated XML
 * feed is not more useful than no XML feed.
 *
 * ## `transient` — because most of these are not failures at all
 *
 * `ERR_NETWORK_CHANGED` is what Chromium reports when the network moved under a
 * request: a laptop waking, Wi-Fi handing off, a VPN coming up. It means "ask
 * again", not "this is broken". A background check that hits one should retry
 * and, if the network is still moving, say nothing at all — nobody asked it to
 * check, so nobody needs to be told it could not. Only a check the user pressed
 * for reports a transient failure, because there a silent no-op looks like a
 * dead button.
 */

/**
 * Chromium and libuv network codes that mean "the network moved", not "the
 * update is broken".
 *
 * Deliberately a list of the ones that are genuinely retryable rather than
 * every `ERR_` Chromium defines: a certificate failure and a refused connection
 * are also network errors, and retrying either just fails again more slowly.
 */
const TRANSIENT = [
  'ERR_NETWORK_CHANGED',
  'ERR_INTERNET_DISCONNECTED',
  'ERR_NAME_NOT_RESOLVED',
  'ERR_NAME_RESOLUTION_FAILED',
  'ERR_NETWORK_IO_SUSPENDED',
  'ERR_CONNECTION_RESET',
  'ERR_CONNECTION_CLOSED',
  'ERR_CONNECTION_ABORTED',
  'ERR_CONNECTION_TIMED_OUT',
  'ERR_TIMED_OUT',
  'ERR_ADDRESS_UNREACHABLE',
  'ERR_EMPTY_RESPONSE',
  'ENOTFOUND',
  'EAI_AGAIN',
  'ECONNRESET',
  'ETIMEDOUT',
  'ENETDOWN',
  'ENETUNREACH',
  'EHOSTUNREACH',
]

/** Longest message the panel will ever be handed. */
const MAX_TEXT = 120

export interface UpdateFailure {
  /** One short sentence. Safe to render: no stack, no feed, no file paths. */
  text: string
  /** Worth trying again, and not worth interrupting anyone over. */
  transient: boolean
}

/** The raw message, however the failure was thrown. */
function rawMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim() !== '') return error.message.trim()
  if (typeof error === 'string') return error.trim()
  if (error !== null && typeof error === 'object') {
    const message = (error as { message?: unknown }).message
    if (typeof message === 'string' && message.trim() !== '') return message.trim()
  }
  const text = String(error).trim()
  return text === '[object Object]' ? '' : text
}

/**
 * The first network code named anywhere in the message.
 *
 * Searched rather than parsed: the code arrives at a different depth depending
 * on how many wrappers re-threw it, and the whole point of this module is that
 * the shape of that message is not ours to rely on.
 */
function networkCode(message: string): string | null {
  const upper = message.toUpperCase()
  return TRANSIENT.find((code) => upper.includes(code)) ?? null
}

/**
 * The message with everything that is not a sentence removed.
 *
 * Order matters: the embedded document is cut before the line split, because
 * `electron-updater` puts `XML: <?xml …` on the *same* line as the sentence.
 */
function firstSentence(message: string): string {
  let text = message

  // An embedded document — `XML: <?xml …`, an HTML body, a JSON dump.
  const document = text.search(/(\bXML:\s*)?<\?xml|<html|<feed\b/i)
  if (document !== -1) text = text.slice(0, document)

  // Stack frames, which `electron-updater` joins onto the message with " at ".
  const frame = text.search(/\s+at\s+\S+\s*\(/)
  if (frame !== -1) text = text.slice(0, frame)

  text = (text.split('\n')[0] ?? '').trim()

  // The provider prefixes its own sentence onto the underlying one with ": ",
  // repeatedly. The last clause is the cause; the ones before it are wrappers.
  text = text.replace(/\s*Error:\s*/gi, ' ').replace(/\s+/g, ' ').trim()

  if (text.length > MAX_TEXT) text = `${text.slice(0, MAX_TEXT - 1).trimEnd()}…`
  return text
}

/**
 * Turn any thrown value into something the panel can print.
 *
 * Never throws, and never returns an empty string — a failure with nothing to
 * say still has to say something, or the panel renders a headline over a blank.
 */
export function describeUpdateError(error: unknown): UpdateFailure {
  const message = rawMessage(error)

  if (networkCode(message) !== null) {
    return { text: 'No connection to the update server.', transient: true }
  }

  const upper = message.toUpperCase()
  if (upper.includes('RATE LIMIT') || upper.includes('HTTP 429') || upper.includes('STATUS CODE 429')) {
    return { text: 'GitHub is rate-limiting this machine. Try again later.', transient: true }
  }
  if (upper.includes('ENOSPC') || upper.includes('NO SPACE LEFT')) {
    return { text: 'Not enough disk space for the update.', transient: false }
  }
  if (upper.includes('EACCES') || upper.includes('EPERM')) {
    return { text: 'The app could not write the update.', transient: false }
  }

  const text = firstSentence(message)
  return { text: text === '' ? 'The update check failed.' : text, transient: false }
}
