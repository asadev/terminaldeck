/**
 * What this build calls itself.
 *
 * Its own module, and that is not fussiness: the CLI bundle is nineteen
 * kilobytes and the host bundle is three hundred, and importing a value out of
 * `host.ts` to read one string would pull the entire host — node-pty, the
 * emulator, the relay — into the command a person runs to print a version
 * number.
 *
 * Two sources, in this order:
 *
 *  1. `TERMINALDECK_VERSION`, which the systemd unit sets and a developer can.
 *  2. The `package.json` written beside the bundle by the packaging script.
 *
 * Reading a `package.json` at runtime is usually how a CLI ends up reporting the
 * version of whatever project the user happened to be standing in. This one is
 * resolved from `import.meta.url`, so it is *this* package's manifest and cannot
 * be anything else — the sibling of the file doing the asking.
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const VERSION_VARIABLE = 'TERMINALDECK_VERSION'

/** What a build that was never packaged reports. Honest rather than a guess. */
export const UNPACKAGED = '0.0.0-dev'

export function hostVersion(): string {
  const stamped = process.env[VERSION_VARIABLE]
  if (stamped !== undefined && stamped !== '') return stamped
  return versionBesideBundle() ?? UNPACKAGED
}

function versionBesideBundle(): string | null {
  try {
    const manifest: unknown = JSON.parse(
      readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'package.json'), 'utf8'),
    )
    if (typeof manifest !== 'object' || manifest === null) return null
    const version = (manifest as Record<string, unknown>).version
    return typeof version === 'string' && version !== '' ? version : null
  } catch {
    // Running from source, where there is no sibling manifest. Not a failure.
    return null
  }
}
