/**
 * What a plugin's code *is*: one hash over every file in its folder.
 *
 * A grant is keyed by this hash, so "allowed" always means "allowed for these
 * exact bytes". The plugin that was read when the person said yes is the only
 * one the yes covers; an update, an edit or a file dropped in afterwards makes a
 * different hash, and the grant does not carry across. That is the constraint
 * `deck-control/consent.ts` sets for any standing permission — *keyed to a hash
 * of the thing, so that editing it revokes it* — applied to code.
 *
 * ## What is refused rather than hashed
 *
 * **A link.** A symlink's bytes are somewhere else, so hashing the link would
 * pin a name while the code it points at changes freely. A plugin folder with
 * one in it is refused, by name.
 *
 * **Anything past the limits.** Thousands of files or tens of megabytes is not
 * a plugin a person placed by hand, and reading it all on every look at the
 * Settings pane would be the cost. Refused with the number that was crossed.
 *
 * ## What is skipped
 *
 * `.DS_Store`, and only that. Finder writes one into any folder a person opens,
 * and a grant that vanished because somebody *looked* at the plugin would be a
 * permission system that punishes reading. Node never loads it.
 */

import { createHash } from 'node:crypto'
import { lstatSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

export interface FolderLimits {
  maxFiles: number
  maxBytes: number
  maxDepth: number
}

export const DEFAULT_FOLDER_LIMITS: FolderLimits = Object.freeze({
  maxFiles: 5000,
  maxBytes: 64 * 1024 * 1024,
  maxDepth: 24,
})

const SKIPPED = new Set(['.DS_Store'])

export type FolderHash = { ok: true; hash: string; files: number; bytes: number } | { ok: false; why: string }

class TooMuch extends Error {}

/**
 * The hash of a folder: SHA-256 over every file's path, size and own SHA-256,
 * in path order.
 *
 * Paths are `/`-separated and relative, so the same folder hashes the same
 * wherever it sits — moving `<userData>` does not revoke anything.
 */
export function hashPluginFolder(dir: string, limits: FolderLimits = DEFAULT_FOLDER_LIMITS): FolderHash {
  const entries: { path: string; bytes: number; digest: string }[] = []
  let total = 0
  const walk = (abs: string, rel: string, depth: number): void => {
    if (depth > limits.maxDepth) throw new TooMuch(`it is nested more than ${limits.maxDepth} folders deep`)
    for (const name of readdirSync(abs).sort()) {
      if (SKIPPED.has(name)) continue
      const full = join(abs, name)
      const path = rel === '' ? name : `${rel}/${name}`
      const stat = lstatSync(full)
      if (stat.isSymbolicLink()) throw new TooMuch(`${path} is a link, and a plugin’s files must be its own`)
      if (stat.isDirectory()) {
        walk(full, path, depth + 1)
        continue
      }
      if (!stat.isFile()) throw new TooMuch(`${path} is not an ordinary file`)
      if (entries.length + 1 > limits.maxFiles) throw new TooMuch(`it has more than ${limits.maxFiles} files`)
      total += stat.size
      if (total > limits.maxBytes) throw new TooMuch(`it is larger than ${Math.round(limits.maxBytes / (1024 * 1024))} MB`)
      entries.push({ path, bytes: stat.size, digest: createHash('sha256').update(readFileSync(full)).digest('hex') })
    }
  }
  try {
    walk(dir, '', 0)
  } catch (error) {
    if (error instanceof TooMuch) return { ok: false, why: error.message }
    return { ok: false, why: `its files could not be read (${error instanceof Error ? error.message : String(error)})` }
  }
  const hash = createHash('sha256')
  for (const entry of entries) hash.update(`${entry.path}\0${entry.bytes}\0${entry.digest}\n`)
  return { ok: true, hash: hash.digest('hex'), files: entries.length, bytes: total }
}
