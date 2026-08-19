/**
 * The keys already on this computer, offered by name instead of by instruction.
 *
 * ## What this replaces, and why the old argument was half right
 *
 * `AddServer.tsx` argued for a paste box over a file picker, and the argument
 * was sound as far as it went: *"a picker puts the person in a file dialog in a
 * hidden folder they have been told never to touch, hunting for one of six
 * filenames, with no way to tell which of the two files beside each other is
 * the one that must never leave the machine."*
 *
 * That is a real description of a real `~/.ssh`. Here is one, unedited, from
 * the machine this was written on:
 *
 * ```
 * agent/            authorized_keys      authorized_keys.bak-2026-06-23-…
 * config            config.backup-…      config.bak-…   config.bak-pre-…
 * hetzner_personal  hetzner_personal.pub id_ed25519     id_ed25519_github_asad
 * id_ed25519_github_asad.pub             id_ed25519_github_imza …
 * ```
 *
 * Twenty-eight entries, four of them backups of a config file, six of them
 * public twins of the file beside them. Dropping somebody into that folder is
 * hostile. But the conclusion drawn from it — *therefore tell them to open the
 * file in a text editor* — hands the same person a harder job and no help at
 * all, for the audience §1.2 names, and it is what the walk found on screen:
 * *"Open the key file in any text editor and paste the whole thing here."*
 *
 * The third answer is the one this file implements: **the app does the
 * hunting.** It reads that folder, keeps only the files that actually are
 * private keys, and offers them by their own names. Every objection in the
 * original argument is answered by not opening a file dialog at all — no
 * hidden folder to navigate, no six filenames to choose between, and the `.pub`
 * beside each key is never in the list, because a public key does not begin
 * with the line this reads for.
 *
 * The paste box stays, and so does a real file panel, because a key downloaded
 * from a hosting company lands in Downloads as a `.pem` and belongs to neither
 * of the other two routes.
 *
 * ## It reads the file, never the name
 *
 * `id_ed25519` is a convention, not a guarantee, and there is no rule that a
 * key is called anything in particular — his standing rule 4: *"it's gonna be
 * used for all, so they might have different settings."* So the discriminator
 * is the first line of the file, which is fixed by the formats themselves, and
 * a file whose first line is not one of them is not offered whatever it is
 * called.
 *
 * ## Nothing here is read into the window until it is chosen
 *
 * {@link listKeyFiles} answers names and kinds; it never puts key material in
 * its answer. The bytes are read by {@link readKeyFile}, once, for a path that
 * this module itself offered — see {@link KeyFileOffers}, which is what stops
 * the channel from being "read any file on this computer" with the window's
 * word for it.
 */

import { readdirSync, readFileSync, statSync } from 'node:fs'
import { basename, join } from 'node:path'

/** One key found on this computer, described without being read out. */
export interface KeyFileOffer {
  /** The absolute path. Sent to the window so a chosen one can be named back. */
  path: string
  /** The file's own name, which is what a person will recognise. */
  name: string
  /** What kind of key it is, in words, read from the file's first line. */
  what: string
  /**
   * Whether opening it needs a password, or `null` when we could not tell.
   *
   * The third state is not decoration. For the OpenSSH format the answer is a
   * field inside the encoded blob and it is knowable; for an old PEM it is a
   * header line and it is knowable; for anything else this says so rather than
   * guessing, and the form asks for a passphrase after the attempt exactly as
   * it does today.
   */
  locked: boolean | null
}

/** How much of a file is read to decide what it is. A key is under 16 KB. */
const MOST_BYTES = 64 * 1024

/**
 * The first lines that mean "this is a private key", and what each is called.
 *
 * Fixed by the formats, not by convention, which is why this can be a table.
 * `PUBLIC KEY` is deliberately absent: a `.pub` file next to a key is the one
 * mistake this list exists to make impossible.
 */
const HEADS: readonly { head: string; what: string; locked: boolean | null }[] = [
  { head: '-----BEGIN OPENSSH PRIVATE KEY-----', what: 'A key made by OpenSSH', locked: null },
  { head: '-----BEGIN RSA PRIVATE KEY-----', what: 'An RSA key', locked: false },
  { head: '-----BEGIN DSA PRIVATE KEY-----', what: 'A DSA key', locked: false },
  { head: '-----BEGIN EC PRIVATE KEY-----', what: 'An elliptic-curve key', locked: false },
  { head: '-----BEGIN PRIVATE KEY-----', what: 'A key', locked: false },
  { head: '-----BEGIN ENCRYPTED PRIVATE KEY-----', what: 'A key, with a password on it', locked: true },
]

/**
 * What one file is, or null when it is not a private key at all.
 *
 * Exported for its own test: this is the whole filter, and the case that must
 * never regress is a `.pub` file being offered as a key.
 */
export function describeKey(text: string, name: string): KeyFileOffer | null {
  const trimmed = text.trimStart()
  const found = HEADS.find((row) => trimmed.startsWith(row.head))
  if (found === undefined) return null
  return {
    path: '',
    name,
    what: found.what,
    locked: found.locked === null ? opensshLocked(trimmed) : found.locked || pemLocked(trimmed),
  }
}

/**
 * Whether an old-style PEM key is encrypted.
 *
 * The header is in the clear, immediately after the first line:
 * `Proc-Type: 4,ENCRYPTED`. Measured against a key encrypted with `openssl` —
 * this is not a heuristic, it is where the format puts it.
 */
function pemLocked(text: string): boolean {
  return /^Proc-Type:\s*4,ENCRYPTED/m.test(text.slice(0, 400))
}

/**
 * Whether an OpenSSH-format key is encrypted, read out of the blob itself.
 *
 * The format is `"openssh-key-v1\0"` and then a length-prefixed string naming
 * the cipher, which is the literal `none` for a key with no password on it.
 * That is four bytes of length and four bytes of `none` about twenty bytes into
 * the base64, so the answer is in the first line of it — but the whole body is
 * decoded rather than the first line guessed at, because the base64 is wrapped
 * at 70 characters and a 15-byte magic does not land on that boundary.
 *
 * Anything malformed answers `null`: this runs over a file somebody chose, and
 * a throw here would take out the list rather than skip one row.
 */
function opensshLocked(text: string): boolean | null {
  try {
    const body = text
      .split('\n')
      .filter((line) => !line.startsWith('-----'))
      .join('')
    const raw = Buffer.from(body, 'base64')
    const magic = 'openssh-key-v1\0'
    if (raw.subarray(0, magic.length).toString('binary') !== magic) return null
    const at = magic.length
    const length = raw.readUInt32BE(at)
    if (length <= 0 || length > 64 || at + 4 + length > raw.length) return null
    return raw.subarray(at + 4, at + 4 + length).toString('utf8') !== 'none'
  } catch {
    return null
  }
}

/** Everything this module needs from the filesystem, so a test can be a table. */
export interface KeyFolderReader {
  entries(dir: string): string[]
  read(path: string): string
  /** Bytes, so something enormous is skipped rather than read into memory. */
  size(path: string): number
}

export const REAL_KEY_FOLDER: KeyFolderReader = {
  entries: (dir) => readdirSync(dir),
  read: (path) => readFileSync(path, 'utf8'),
  size: (path) => statSync(path).size,
}

/**
 * Every private key in one folder, by name, in a stable order.
 *
 * Alphabetical rather than by date, for the reason `classify.ts` gives about
 * its own cards: a list whose order depends on when files happened to be
 * touched is a list that reorders itself under somebody's cursor.
 *
 * A folder that does not exist is an empty list and not an error — a computer
 * that has never used SSH is the normal case for the person this screen is for.
 */
export function listKeyFiles(dir: string, fs: KeyFolderReader = REAL_KEY_FOLDER): KeyFileOffer[] {
  let names: string[]
  try {
    names = fs.entries(dir)
  } catch {
    return []
  }
  const found: KeyFileOffer[] = []
  for (const name of [...names].sort((a, b) => a.localeCompare(b))) {
    // Cheap exclusions first, so the common junk in this folder is never read.
    if (name.endsWith('.pub') || name.startsWith('.')) continue
    const path = join(dir, name)
    try {
      if (fs.size(path) > MOST_BYTES) continue
      const offer = describeKey(fs.read(path), name)
      if (offer !== null) found.push({ ...offer, path })
    } catch {
      // A directory, a socket, a file this account may not read. Skipped, not
      // reported: none of them is a key, and none of them is a person's problem.
    }
  }
  return found
}

/**
 * The paths this process is willing to read a key out of.
 *
 * The guard that makes the read channel narrow. Without it, `servers:key-text`
 * takes a path from the window and hands back the file — which is *"read any
 * file on this computer"* with the renderer's word for which one, and the
 * renderer is the surface that runs other people's web pages in this app.
 *
 * A path enters this set only by being offered: listed out of the key folder,
 * or chosen by the person in a native panel this process opened. Nothing the
 * window says can add one.
 */
export class KeyFileOffers {
  private readonly allowed = new Set<string>()

  /** Offer everything in a folder, and remember what was offered. */
  list(dir: string, fs: KeyFolderReader = REAL_KEY_FOLDER): KeyFileOffer[] {
    const found = listKeyFiles(dir, fs)
    for (const offer of found) this.allowed.add(offer.path)
    return found
  }

  /** Describe one file the person chose in a panel, and allow it. */
  chose(path: string, fs: KeyFolderReader = REAL_KEY_FOLDER): KeyFileOffer | null {
    try {
      if (fs.size(path) > MOST_BYTES) return null
      const offer = describeKey(fs.read(path), basename(path))
      if (offer === null) return null
      this.allowed.add(path)
      return { ...offer, path }
    } catch {
      return null
    }
  }

  /** The bytes, for a path that was offered. Anything else is refused. */
  read(path: string, fs: KeyFolderReader = REAL_KEY_FOLDER): { ok: true; key: string } | { ok: false; sentence: string } {
    if (!this.allowed.has(path)) {
      return { ok: false, sentence: 'That file was not one this app offered, so it has not been read.' }
    }
    try {
      const text = fs.read(path)
      if (describeKey(text, basename(path)) === null) {
        return { ok: false, sentence: 'That file is not a key. Choose the private key file, not the one ending in .pub.' }
      }
      return { ok: true, key: text }
    } catch {
      return { ok: false, sentence: 'That file could not be read. Check that it is still where it was.' }
    }
  }
}
