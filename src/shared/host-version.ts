/**
 * Is the headless host on a server older than the app looking at it?
 *
 * **Here rather than in `main/servers/host.ts`**, where it was written, because
 * both sides of the desktop need it and they are on opposite sides of the
 * Electron boundary: the main process computes it for the phone's probe answer,
 * and the renderer draws the button. A renderer that reached into `main/` would
 * pull the whole server module into the window bundle.
 *
 * The Swift half is `HostProbe.updateAvailable`. Two implementations of one
 * rule, which is a cost worth naming — there is no module an Electron main
 * process and a Swift app can both read — and `host-version.test.ts` pins the
 * cases the Swift side pins, so the two fail together rather than drifting.
 */

import { BRAND } from './brand'

/**
 * Whether the host on that server is **older than this build**, and what to.
 *
 * > *"whenever there is a new update for headless… it should show the update
 * > button also next to where we install… so we can just directly update
 * > anytime directly from the connected device."*
 *
 * The same answer `HostProbe.updateAvailable` gives the phone, on the side that
 * has the same two numbers in front of it: what this app ships, and what the
 * probe just read off that server. Two implementations of one rule, which is a
 * cost worth naming — the alternative is a shared module that both an Electron
 * main process and a Swift app can read, and there is no such thing. They are
 * kept honest by `host.test.ts` pinning the cases the Swift side pins.
 *
 * Compared field by field as numbers, never as text: `'0.9.1' > '0.10.1'` is
 * true as a string and false as a version, and this product has shipped both a
 * 0.9 and a 0.10. Anything that is not a plain `x.y.z` answers null rather than
 * guessing, and a server *ahead* of this build answers null too — offering to
 * "update" a machine down to an older version is a control that makes it worse.
 */
export function hostUpdateAvailable(
  host: { command: string; version: string },
  mine: string = BRAND.version,
): string | null {
  if (host.command === '') return null
  const there = semver(host.version)
  const here = semver(mine)
  if (there === null || here === null) return null
  for (let i = 0; i < 3; i += 1) {
    if (there[i] !== here[i]) return there[i] < here[i] ? mine : null
  }
  return null
}

/** `x.y.z` as three numbers, or null. A leading `v` is tolerated. */
function semver(text: string): [number, number, number] | null {
  const parts = text.trim().replace(/^v/, '').split('.')
  if (parts.length === 0 || parts.length > 3) return null
  const out: number[] = []
  for (const part of parts) {
    if (!/^\d+$/.test(part)) return null
    out.push(Number(part))
  }
  while (out.length < 3) out.push(0)
  return [out[0]!, out[1]!, out[2]!]
}

