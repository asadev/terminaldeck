/**
 * "2h ago", in the one spelling the whole window uses.
 *
 * Extracted because two surfaces now date the same kind of thing — an artifact
 * row and a past-session hit in the palette — and they were about to get two
 * copies of this function, which is how "3d ago" on one page becomes "3 days
 * ago" on the next.
 *
 * `now` is a parameter rather than a `Date.now()` inside, so a test can pin the
 * answer and a list of fifty rows reads one clock instead of fifty.
 */

const MINUTE = 60_000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

export function relativeTime(at: number, now: number): string {
  if (!at) return ''
  const delta = now - at
  // A clock skew, or a file whose timestamp is in the future. "in 3m ago" is
  // worse than saying nothing sharper than "just now".
  if (delta < MINUTE) return 'just now'
  if (delta < HOUR) return `${Math.round(delta / MINUTE)}m ago`
  if (delta < DAY) return `${Math.round(delta / HOUR)}h ago`
  if (delta < 30 * DAY) return `${Math.round(delta / DAY)}d ago`
  return new Date(at).toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  })
}

/** Bytes as a person reads them. Deliberately 1024-based — this is file size. */
export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}
