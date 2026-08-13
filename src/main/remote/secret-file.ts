/**
 * Writing a file that must not be half-written and must not be readable.
 *
 * Two files under the remote-access directory hold something an attacker wants:
 * `remote-auth.json`, which is the list of devices allowed to reach a shell, and
 * `relay-identity.json`, which holds this Mac's X25519 private key. Both have
 * the same two requirements, and both used to be one hand-rolled copy of this
 * dance — the second copy is how the two eventually disagree about which of the
 * steps below were the important ones.
 *
 * They are all important, and each is here because of a specific way the
 * obvious version fails:
 *
 *  - **A leftover temp file is removed rather than written through.** `w`
 *    follows a symlink, and this is where credential hashes and a private key
 *    land. `wx` after the unlink means the open either creates the file or
 *    fails.
 *  - **The write is looped.** A single `write` is allowed to come up short — on
 *    a full disk it reports the bytes it managed rather than failing — and a
 *    trust file that stops halfway is one that will not parse on the next start.
 *  - **The bytes are fsynced before the name moves.** `rename` is atomic in
 *    ordering, not in durability: on APFS the directory entry can land while the
 *    bytes behind it are still in cache, so a power cut straight after a revoke
 *    can come back up with the device still trusted. That is the one failure
 *    these files promise does not happen.
 *  - **The mode is set explicitly, twice.** `mode` on `open` applies only when
 *    the file is created and is masked by umask.
 *  - **The directory is fsynced too**, for the same reason as the file, and its
 *    failure is ignored because not every filesystem lets a directory be synced.
 *  - **The temp name carries the pid.** Two windows writing at once must not
 *    rename each other's half-written file into place.
 */

import {
  chmodSync,
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  renameSync,
  unlinkSync,
  writeSync,
} from 'node:fs'

/**
 * Replace `file` with `contents`, atomically, 0600.
 *
 * Throws rather than reporting failure: every caller here is writing something
 * whose loss changes who can reach this machine, and a write the caller believes
 * and the disk does not is the failure that puts a revoked device back on the
 * shell after the next restart.
 */
export function writeSecretFile(dir: string, file: string, contents: string): void {
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  const tmp = `${file}.${process.pid}.tmp`
  try {
    try {
      unlinkSync(tmp)
    } catch {
      /* nothing there, which is the normal case */
    }
    const fd = openSync(tmp, 'wx', 0o600)
    try {
      const bytes = Buffer.from(contents, 'utf8')
      for (let written = 0; written < bytes.length; ) {
        written += writeSync(fd, bytes, written, bytes.length - written)
      }
      fsyncSync(fd)
    } finally {
      closeSync(fd)
    }
    chmodSync(tmp, 0o600)
    renameSync(tmp, file)
    chmodSync(file, 0o600)
    try {
      const handle = openSync(dir, 'r')
      try {
        fsyncSync(handle)
      } finally {
        closeSync(handle)
      }
    } catch {
      /* not every filesystem lets a directory be synced; the file already is */
    }
  } catch (err) {
    try {
      unlinkSync(tmp)
    } catch {
      /* never created, or already gone */
    }
    throw err
  }
}
