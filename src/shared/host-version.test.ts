/**
 * The cases the Swift half pins too.
 *
 * `HostProbe.updateAvailable` in `ios/TerminalDeck/Servers/HostProbe.swift` is
 * the same rule written twice, because there is no module an Electron main
 * process and a Swift app can both read. Two implementations drift silently
 * unless something makes them fail together, so this file and
 * `HostProbeTests.swift` cover the same list — a case added here is a case to
 * add there.
 */

import { describe, expect, it } from 'vitest'
import { hostUpdateAvailable } from './host-version'

const on = (version: string) => ({ command: '/home/asad/.local/bin/terminaldeck', version })

describe('whether a server has an update waiting', () => {
  it('offers this build when the server is behind', () => {
    expect(hostUpdateAvailable(on('0.10.1'), '0.10.3')).toBe('0.10.3')
    expect(hostUpdateAvailable(on('0.9.9'), '0.10.0')).toBe('0.10.0')
  })

  /**
   * The one a string comparison gets wrong, and the reason this is not `>`.
   *
   * `'0.9.1' > '0.10.1'` is **true** as text, because `9` sorts after `1`. This
   * product has shipped both a 0.9 and a 0.10, so that is not a hypothetical
   * ordering — it is the release this app is on.
   */
  it('compares fields as numbers, not as text', () => {
    expect(hostUpdateAvailable(on('0.9.1'), '0.10.1')).toBe('0.10.1')
    expect(hostUpdateAvailable(on('0.10.1'), '0.9.1')).toBeNull()
  })

  it('says nothing when the two are level', () => {
    expect(hostUpdateAvailable(on('0.10.3'), '0.10.3')).toBeNull()
  })

  /**
   * A phone on an older TestFlight build than the server it is looking at is a
   * real case, and offering to "update" that server *down* to this build would
   * be a control that makes the machine worse.
   */
  it('says nothing when the server is ahead', () => {
    expect(hostUpdateAvailable(on('0.11.0'), '0.10.3')).toBeNull()
  })

  it('says nothing when there is no host to update', () => {
    expect(hostUpdateAvailable({ command: '', version: '' }, '0.10.3')).toBeNull()
    expect(hostUpdateAvailable({ command: '', version: '0.1.0' }, '0.10.3')).toBeNull()
  })

  /**
   * A host that prints something unexpected is not told it is behind on the
   * strength of a parse this code got wrong. Silence is the safe answer: the
   * cost is a missing button, and the cost of guessing is an install somebody
   * did not ask for.
   */
  it('says nothing rather than guessing at anything that is not x.y.z', () => {
    for (const odd of ['', 'unknown', '0.10.1-rc.1', '2026.08.24.1', 'v', '0.a.1', '-1.0.0']) {
      expect(hostUpdateAvailable(on(odd), '0.10.3'), odd).toBeNull()
    }
  })

  /** `--version` has carried a leading `v` on some builds. */
  it('tolerates a leading v on either side', () => {
    expect(hostUpdateAvailable(on('v0.10.1'), '0.10.3')).toBe('0.10.3')
  })

  /** A short version is padded rather than refused: `0.10` is `0.10.0`. */
  it('pads a short version', () => {
    expect(hostUpdateAvailable(on('0.10'), '0.10.3')).toBe('0.10.3')
    expect(hostUpdateAvailable(on('1'), '0.10.3')).toBeNull()
  })
})
