import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Every client claims the same version as the package that releases it.
 *
 * Not tidiness. A phone installs the headless host by fetching
 * `releases/download/v<its own version>/terminaldeck-<its own version>.tgz`, so
 * a client left a version behind fetches a release that predates whatever it
 * needs and the install reports success while the connection then fails. That
 * has now happened twice — iOS stuck at 0.10.0 against a 0.10.1 repo, then
 * Android stuck at 0.10.0 and again at 0.10.1 — and both times every step of
 * the flow said it had worked. `scripts/ios/preflight.sh` catches the iOS half
 * before a build; nothing caught Android, so this does, on every ordinary run.
 */
const ROOT = join(__dirname, '..', '..', '..')
const read = (p: string): string => readFileSync(join(ROOT, p), 'utf8')

describe('the clients agree with package.json about what version this is', () => {
  const version = JSON.parse(read('package.json')).version as string

  it('is a three-part version', () => {
    expect(version).toMatch(/^\d+\.\d+\.\d+$/)
  })

  it('iOS MARKETING_VERSION matches', () => {
    const found = /MARKETING_VERSION:\s*"([^"]+)"/.exec(read('ios/project.yml'))
    expect(found, 'MARKETING_VERSION is no longer declared in ios/project.yml').not.toBeNull()
    expect(found?.[1]).toBe(version)
  })

  it('Android versionName matches', () => {
    const found = /versionName\s*=\s*"([^"]+)"/.exec(read('android/app/build.gradle.kts'))
    expect(found, 'versionName is no longer declared in android/app/build.gradle.kts').not.toBeNull()
    expect(found?.[1]).toBe(version)
  })
})
