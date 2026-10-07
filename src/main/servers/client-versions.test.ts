import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { PROTOCOL_VERSION } from '../remote/protocol'

/**
 * What has to hold between the Mac's version and the phones' for installs and
 * pairing to keep working.
 *
 * A phone installs the headless host by fetching
 * `releases/download/v<its own version>/terminaldeck-<its own version>.tgz`
 * (`ServerScripts.hostPackage` on both phones). This test began as "every client
 * claims package.json's version", after a phone left a version behind fetched a
 * release that predated what it needed and the install reported success while
 * the connection then failed — iOS stuck at 0.10.0 against a 0.10.1 repo, then
 * Android at 0.10.0 and again at 0.10.1.
 *
 * From 0.19.0 the Mac ships on its own (Mac-only releases; the phones keep
 * their version until they ship again), so "the same number everywhere" is no
 * longer the rule. What actually protects installs and pairing is:
 *
 *  - **Both phones name the same version**, so they install the same host.
 *  - **No phone is ahead of the Mac.** A phone naming a version that has not
 *    been released fetches a release that does not exist.
 *  - **A phone's version is a release that was cut** (it has a CHANGELOG entry).
 *  - **Pairing never compares app versions.** Every side checks one protocol
 *    number (the host refuses a mismatch); the app versions only feed the
 *    phone's "this server is older" sentence. So that number must be the same in
 *    the desktop, both phones and the Swift host, and a Mac ahead of a phone pairs.
 *
 * When the phones ship again, `scripts/ios/preflight.sh` still requires iOS's
 * MARKETING_VERSION to equal package.json, and that release must build the
 * server package for that version (a Mac-only release carries the previous
 * one's tarball over under its own name).
 */
const ROOT = join(__dirname, '..', '..', '..')
const read = (p: string): string => readFileSync(join(ROOT, p), 'utf8')

const parts = (version: string): number[] => version.split('.').map(Number)
const notAhead = (phone: string, mac: string): boolean => {
  const [a, b] = [parts(phone), parts(mac)]
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i]
  return true
}

describe('the Mac and the phones agree on what keeps installs and pairing working', () => {
  const version = JSON.parse(read('package.json')).version as string
  const ios = /MARKETING_VERSION:\s*"([^"]+)"/.exec(read('ios/project.yml'))?.[1]
  const android = /versionName\s*=\s*"([^"]+)"/.exec(read('android/app/build.gradle.kts'))?.[1]

  it('is a three-part version, and package-lock.json says the same', () => {
    expect(version).toMatch(/^\d+\.\d+\.\d+$/)
    const lock = JSON.parse(read('package-lock.json')) as { version: string; packages: Record<string, { version: string }> }
    expect(lock.version).toBe(version)
    expect(lock.packages[''].version).toBe(version)
  })

  it('both phones declare a three-part version, and the same one', () => {
    expect(ios, 'MARKETING_VERSION is no longer declared in ios/project.yml').toMatch(/^\d+\.\d+\.\d+$/)
    expect(android, 'versionName is no longer declared in android/app/build.gradle.kts').toMatch(/^\d+\.\d+\.\d+$/)
    expect(android).toBe(ios)
  })

  it('no phone is ahead of the Mac', () => {
    expect(notAhead(ios!, version), `iOS ${ios} is ahead of package.json ${version}`).toBe(true)
    expect(notAhead(android!, version), `Android ${android} is ahead of package.json ${version}`).toBe(true)
  })

  it('the phones name a release that was cut', () => {
    const changelog = read('CHANGELOG.md')
    expect(changelog, `CHANGELOG.md has no [${ios}] — the phones would fetch a release that was never made`).toContain(`## [${ios}]`)
  })

  it('pairing checks one protocol number, and it is the same on every side', () => {
    const iosProtocol = Number(/static let protocolVersion = (\d+)/.exec(read('ios/TerminalDeck/Protocol/WireProtocol.swift'))?.[1])
    const androidProtocol = Number(/const val VERSION = (\d+)/.exec(read('android/app/src/main/java/dev/terminaldeck/android/protocol/Protocol.kt'))?.[1])
    expect(iosProtocol).toBe(PROTOCOL_VERSION)
    expect(androidProtocol).toBe(PROTOCOL_VERSION)
    const swift = ['BackendRemoteHost.swift', 'BackendRemoteGuest.swift', 'BackendRemoteGuestChannel.swift']
      .map((file) => read(`macos/TerminalDeckNative/Sources/TerminalDeckBackend/${file}`)).join('\n')
    const said = [...swift.matchAll(/"protocol", \.number\((\d+)\)/g)].map((m) => Number(m[1]))
    const checked = [...swift.matchAll(/\["protocol"\]\.number == (\d+)/g)].map((m) => Number(m[1]))
    expect(said.length, 'the Swift host no longer says its protocol number where this test looks').toBeGreaterThan(0)
    expect(checked.length, 'the Swift host no longer checks the protocol number where this test looks').toBeGreaterThan(0)
    expect(new Set([...said, ...checked])).toEqual(new Set([PROTOCOL_VERSION]))
  })
})
