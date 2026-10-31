import { shortLabel } from './browser-url'

/**
 * What to say when a page does not load.
 *
 * ## Why this is a module and not a template string
 *
 * Chromium answers a failed navigation twice: it fires `did-fail-load` with a
 * numeric code and a SHOUTING_SNAKE description, and — separately — it commits
 * its own error document into the view. Both are developer output. The recording
 * of 2026-08-16 catches the second one full-screen on Windows: a new tab opened
 * on `http://localhost:3000`, nothing was listening, and the first thing the
 * product ever showed was a red exclamation mark and "ERR_CONNECTION_REFUSED".
 *
 * The app already had the raw half too — `${errorDescription} (${errorCode})`
 * went straight into the tab's error banner, so the written UI said
 * `ERR_CONNECTION_REFUSED (-102)` underneath Chromium's page saying the same
 * thing in bigger letters.
 *
 * So the codes are translated here, once, into sentences a person can act on.
 * They name the address that failed, because "connection refused" without a host
 * is unactionable when four tabs are open, and they say what to do next where
 * there is an obvious next step.
 *
 * ## Codes, not descriptions
 *
 * The match is on the numeric code. The description is a Chromium constant name
 * that has been renamed before (`ERR_INSECURE_RESPONSE` and friends have moved
 * around), whereas `net_error_list.h` treats the numbers as permanent — they are
 * reported to servers, logged, and cross-referenced by `chrome://network-errors`.
 * Matching text would silently stop matching on an Electron upgrade and the only
 * symptom would be a vaguer sentence, which is exactly the sort of regression
 * nobody files.
 *
 * ## Unknown codes still get a sentence, and keep their evidence
 *
 * An unrecognised failure is written as prose *and* keeps the constant and the
 * number, because for the failures nobody anticipated the raw pair is the only
 * thing that will let somebody diagnose it. The rule this file follows is "never
 * show only machine output", not "never show machine output".
 */

/**
 * `-3` is `ERR_ABORTED`, which is not a failure.
 *
 * Every interrupted navigation reports it: typing a new address while the last
 * one is still loading, pressing Stop, a redirect landing elsewhere, and the
 * tab closing mid-load. Treating it as an error is how a browser ends up
 * flashing a scary message during ordinary use, so callers filter on this rather
 * than on a string.
 */
export const ERR_ABORTED = -3

/** True for the codes that mean "the user changed their mind", not "this broke". */
export function isAbortCode(code: number): boolean {
  return code === ERR_ABORTED
}

/**
 * The address, as a person would name it: `localhost:3000`, `example.com/docs`.
 *
 * Falls back to "the page" rather than to an empty string — a sentence with a
 * hole where the host should be reads as a bug in the message.
 */
function name(url: string): string {
  const label = shortLabel(url)
  return label && label !== 'New tab' ? label : 'the page'
}

/** True when the address is a loopback one, where the advice is different. */
export function isLocal(url: string): boolean {
  try {
    const host = new URL(url).hostname.toLowerCase()
    return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]'
  } catch {
    return false
  }
}

/**
 * One written sentence for a failed load.
 *
 * Long enough to be useful and short enough to read in a banner: what happened,
 * and — where there is one — the single next thing to try. The localhost cases
 * get their own wording because "check your internet connection" is nonsense
 * advice about a dev server that is simply not running yet.
 */
export function loadFailureSentence(code: number, description: string, url: string): string {
  const where = name(url)
  const local = isLocal(url)

  switch (code) {
    case -102: // ERR_CONNECTION_REFUSED
      return local
        ? `Nothing is listening on ${where}. Start the server, then reload — or pick one of the ports below.`
        : `${where} refused the connection.`
    case -105: // ERR_NAME_NOT_RESOLVED
      return `That address does not resolve — no machine is called ${where}.`
    case -137: // ERR_NAME_RESOLUTION_FAILED
      return `Could not look up ${where}. The name server did not answer.`
    case -106: // ERR_INTERNET_DISCONNECTED
      return 'This machine is offline, so nothing outside it can be opened.'
    case -109: // ERR_ADDRESS_UNREACHABLE
      return `${where} cannot be reached from this machine.`
    case -7: // ERR_TIMED_OUT
    case -118: // ERR_CONNECTION_TIMED_OUT
      return local
        ? `${where} accepted nothing before the timeout. The server may still be starting.`
        : `${where} took too long to answer.`
    case -101: // ERR_CONNECTION_RESET
      return `${where} closed the connection while the page was loading.`
    case -100: // ERR_CONNECTION_CLOSED
      return `${where} closed the connection before it sent anything.`
    case -104: // ERR_CONNECTION_FAILED
      return `Could not connect to ${where}.`
    case -324: // ERR_EMPTY_RESPONSE
      return `${where} answered with nothing at all.`
    case -310: // ERR_TOO_MANY_REDIRECTS
      return `${where} redirected in a loop that never arrived anywhere.`
    case -21: // ERR_NETWORK_CHANGED
      return 'The network changed while the page was loading. Reload to try again.'
    case -200: // ERR_CERT_COMMON_NAME_INVALID
    case -201: // ERR_CERT_DATE_INVALID
    case -202: // ERR_CERT_AUTHORITY_INVALID
    case -501: // ERR_INSECURE_RESPONSE
      return `The HTTPS certificate for ${where} is not one this can trust, so the page was not loaded.`
    case -20: // ERR_BLOCKED_BY_CLIENT
    case -27: // ERR_BLOCKED_BY_RESPONSE
      return `Loading ${where} was blocked.`
    case -6: // ERR_FILE_NOT_FOUND
      return `There is nothing at ${where}.`
    default: {
      // Prose first, evidence second — see the note at the top of the file about
      // why the raw pair stays rather than being swallowed.
      const detail = description.trim()
      return detail
        ? `${where} did not load: ${detail} (${code}).`
        : `${where} did not load (${code}).`
    }
  }
}
