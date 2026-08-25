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

/*
 * **No default for `mine`, and that is a correction rather than a style choice.**
 *
 * It used to default to `BRAND.version`, which does not exist — `BRAND` in
 * `./brand.ts` carries the name, the id, the bundle id and the tagline, and has
 * never carried a version. The build did not say so because the repository's
 * root `tsconfig.json` has `include: []`, so a bare `tsc --noEmit` typechecks
 * nothing at all; the real gate is `npm run typecheck`, which runs
 * `tsconfig.node.json` and `tsconfig.web.json` and caught this along with a
 * dozen others the moment it was run.
 *
 * There is no honest module-level default to replace it with. This file is
 * imported by an Electron **main** process (which knows its version through
 * `app.getVersion()`), by a **renderer** (which is handed it), and by a headless
 * daemon (whose `hostVersion()` reads the manifest beside its bundle) — three
 * different answers with no common source, which is the same reason this rule is
 * written twice in two languages. So the caller passes it, and a caller that
 * forgets no longer compiles.
 */

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
  mine: string,
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

/**
 * `x.y.z` as three numbers, or null. A leading `v` is tolerated.
 *
 * The type says `string` and the guard is there anyway, because the one caller
 * is handed a **probe result** — a shape assembled from what a shell command
 * printed over SSH, on a host running any version this product has ever shipped.
 * A probe from a build older than the field simply has no `version` in it, and
 * TypeScript's word for what a remote machine sent is a hope rather than a
 * check. Measured: it threw here, out of a React render, which takes the whole
 * server page down over a machine being *old*.
 */
function semver(text: string): [number, number, number] | null {
  if (typeof text !== 'string') return null
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

