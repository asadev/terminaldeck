/**
 * Reading the two version numbers this client now has: its own, and the one the
 * host put on the `welcome`.
 *
 * ## Why this exists at all
 *
 * `welcome.appVersion` and `welcome.hostKind` are new — see the fields in
 * `src/main/remote/protocol.ts`. Until they arrived a browser paired to a
 * machine had no way to know what build it was talking to; `version.ts` says so
 * in as many words and predicts this file: *"If a `welcome` frame ever grows an
 * app version, that is a second line here and a deliberate one."*
 *
 * The one thing the client does with the pair of numbers is decide whether to
 * say a single sentence — *update this server from a desktop* — and that
 * sentence is only honest when this client's build is genuinely ahead of the
 * host's. There is deliberately no button under it: nothing on this protocol
 * carries an update verb, because replacing a host stays on the SSH and desktop
 * plane. So this module compares and labels; it never acts.
 *
 * ## This runs in a browser
 *
 * Like `protocol.ts` and everything else under `pwa/src`, it may use no node
 * built-in. It needs none: version comparison is arithmetic over strings.
 */

/** Split a version into its release numbers and its prerelease identifiers. */
function splitVersion(version: string): { release: number[]; prerelease: string[] } {
  // Build metadata takes no part in precedence (semver §10), and the leading
  // `v` some tags carry is not part of the number.
  const withoutBuild = version.trim().replace(/^v/, '').split('+')[0]
  const [releasePart, ...prereleaseParts] = withoutBuild.split('-')
  const release = releasePart.split('.').map((part) => {
    const n = Number.parseInt(part, 10)
    return Number.isFinite(n) ? n : 0
  })
  const prerelease = prereleaseParts
    .join('-')
    .split('.')
    .filter((p) => p !== '')
  return { release, prerelease }
}

/**
 * Semver precedence, enough of it: -1, 0 or 1.
 *
 * The same subset `src/main/updates/install-update.ts` implements and for the
 * same reason it is written out rather than imported — that copy pulls in the
 * whole updater, this one may not touch node at all, and neither may depend on a
 * `semver` package this project does not declare. What both implement is the
 * part that decides ordering: numeric release segments compared left to right, a
 * missing segment treated as zero, and a prerelease sorting *below* the release
 * it belongs to.
 */
export function compareVersions(a: string, b: string): number {
  const left = splitVersion(a)
  const right = splitVersion(b)

  const length = Math.max(left.release.length, right.release.length)
  for (let i = 0; i < length; i += 1) {
    const l = left.release[i] ?? 0
    const r = right.release[i] ?? 0
    if (l !== r) return l < r ? -1 : 1
  }

  // 1.0.0-beta precedes 1.0.0; a release with no prerelease wins.
  if (left.prerelease.length === 0 && right.prerelease.length === 0) return 0
  if (left.prerelease.length === 0) return 1
  if (right.prerelease.length === 0) return -1

  const idents = Math.max(left.prerelease.length, right.prerelease.length)
  for (let i = 0; i < idents; i += 1) {
    const l = left.prerelease[i]
    const r = right.prerelease[i]
    if (l === undefined) return -1
    if (r === undefined) return 1
    if (l === r) continue
    const ln = /^\d+$/.test(l) ? Number.parseInt(l, 10) : null
    const rn = /^\d+$/.test(r) ? Number.parseInt(r, 10) : null
    if (ln !== null && rn !== null) return ln < rn ? -1 : 1
    // Numeric identifiers always have lower precedence than alphanumeric ones.
    if (ln !== null) return -1
    if (rn !== null) return 1
    return l < r ? -1 : 1
  }
  return 0
}

/**
 * A version this client can actually reason about.
 *
 * `''` is what an older host sends and what this client holds before a socket is
 * up; `'unknown'` is what `version.ts` reports when nothing stamped the build —
 * both are honest non-answers rather than numbers, and comparing against them
 * would manufacture a verdict out of nothing. A real version has at least one
 * digit somewhere, which both of those lack.
 */
function isRealVersion(version: string): boolean {
  return version !== '' && version !== 'unknown' && /\d/.test(version)
}

/**
 * Whether this client's build is ahead of the host's — the one question the
 * *update this server from a desktop* sentence hangs on.
 *
 * Default-closed: unless both numbers are real and the client's is strictly the
 * greater, the answer is no. A client that cannot read one of the two says
 * nothing rather than nudging on a guess — the same direction every unreadable
 * field on this wire is dropped in.
 */
export function clientIsAhead(clientVersion: string, hostVersion: string): boolean {
  if (!isRealVersion(clientVersion) || !isRealVersion(hostVersion)) return false
  return compareVersions(clientVersion, hostVersion) > 0
}

/**
 * What to call the shell at the other end, in one word beside its version.
 *
 * A headless host is a `server` — what a person installed and what they call it
 * — and a desktop is a `desktop`. Null is the host never having said, which is a
 * build older than the field, and it gets no noun rather than a guessed one.
 */
export function hostKindNoun(kind: 'desktop' | 'headless' | null): string | null {
  if (kind === 'headless') return 'server'
  if (kind === 'desktop') return 'desktop'
  return null
}

/**
 * The one line that names the host's build, and its kind when it said one.
 *
 * `version 0.10.0 · server`, or just `version 0.10.0` from a host that predates
 * `hostKind`. Empty version yields the empty string — the caller draws nothing
 * for a host that never reported one rather than a row with a blank in it.
 */
export function hostVersionLine(hostVersion: string, kind: 'desktop' | 'headless' | null): string {
  if (hostVersion === '') return ''
  const noun = hostKindNoun(kind)
  return noun === null ? `version ${hostVersion}` : `version ${hostVersion} · ${noun}`
}
