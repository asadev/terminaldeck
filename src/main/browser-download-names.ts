import { join } from 'node:path'

/**
 * What a file that arrives from the network may be called on this disk.
 *
 * Split out of `browser-downloads.ts` rather than copied, because there are now
 * two places where bytes come off a socket and land in a folder — a person
 * clicking a link, and `browser-asset-fetch.ts` pulling sixty thousand images —
 * and a second implementation of these two rules would be a second answer to
 * *"is `../../.ssh/authorized_keys` a filename"*. It is imported by both and
 * re-exported from `browser-downloads.ts`, so every caller that already had it
 * from there still does.
 *
 * Pure, and with no Electron in it, which is the other half of why it moved: the
 * asset fetch is driven in its tests by a real HTTP server with no Electron
 * anywhere near it, and it needs these rules.
 */

/**
 * Characters that are never part of a name somebody chose.
 *
 * A NUL truncates a path at the syscall boundary, so a name carrying one is a
 * different string on screen from the file it actually makes. The rest are
 * unprintable and would draw as nothing in a row. `uploads.ts` refuses the same
 * set on the wire, one layer out.
 */
const CONTROL_CHARS_G = /[\u0000-\u001f\u007f]/g

/**
 * How many `name (2)`, `name (3)` variants are tried before a stamped name.
 *
 * A hundred, which is well past what any folder legitimately holds under one
 * name and small enough that the loop is free. This used to be spelled
 * `MAX_DOWNLOAD_ROWS` — a cap on how many rows a *panel* keeps, which had no
 * business deciding what a file may be called.
 */
export const MAX_NAME_VARIANTS = 100

/**
 * One path component, safe on both platforms, never empty.
 *
 * Deliberately not `safeName` from `remote/uploads.ts`: that one is about a name
 * off a network and this one is about a name off an HTTP header. The failure
 * they prevent is the same, so if either grows a case the other should be read
 * at the same time.
 *
 * `Content-Disposition` is attacker input, and so is the last segment of an
 * asset URL. `../../.ssh/authorized_keys` is a perfectly valid string for both,
 * which is why the separators go before anything else does.
 */
export function downloadName(suggested: string): string {
  const flat = suggested
    .replace(CONTROL_CHARS_G, '')
    .replace(/[\\/]/g, ' ')
    // Reserved on Windows, and meaningless in a filename on either platform.
    .replace(/[:*?"<>|]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    // A leading dot hides the file on Unix; a trailing dot or space is silently
    // dropped by Windows, which turns "a." and "a" into the same file. Spaces
    // go with the dots at the front, or `../../x` — whose separators became
    // spaces two lines up — would come out with one still leading.
    .replace(/^[. ]+/, '')
    .replace(/[. ]+$/, '')
  if (flat === '') return 'download'
  return flat.length > 120 ? flat.slice(0, 120) : flat
}

/**
 * A path in `dir` that nothing is using, given the name the server suggested.
 *
 * `report.pdf`, then `report (2).pdf` — Chrome's own rule, and the same shape
 * `attach-bring-in.ts` uses one folder over.
 *
 * Exported, and taking its own `exists`, so the rule can be tested without a
 * disk: it is the one piece of this a mistake in would overwrite somebody's
 * file.
 */
export function freeDownloadPath(
  dir: string,
  suggested: string,
  exists: (path: string) => boolean,
  taken: ReadonlySet<string> = new Set(),
): string {
  const name = downloadName(suggested)
  const dot = name.lastIndexOf('.')
  const stem = dot > 0 ? name.slice(0, dot) : name
  const extension = dot > 0 ? name.slice(dot) : ''
  for (let n = 1; n <= MAX_NAME_VARIANTS; n += 1) {
    const candidate = join(dir, n === 1 ? name : `${stem} (${n})${extension}`)
    if (!exists(candidate) && !taken.has(candidate)) return candidate
  }
  // Every ordinary variant is taken. A stamped name always terminates, and a
  // download that lands under an ugly name is better than one that is refused.
  return join(dir, `${stem} (${Date.now()})${extension}`)
}
