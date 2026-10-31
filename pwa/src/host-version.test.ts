import { describe, expect, it } from 'vitest'
import { clientIsAhead, compareVersions, hostKindNoun, hostVersionLine } from './host-version'

/**
 * The comparator behind the one sentence this client says about the gap between
 * its build and the host's — *update this server from a desktop* — and the label
 * beside the version number. Both are display; neither acts.
 */

describe('compareVersions', () => {
  it('orders release segments left to right, missing treated as zero', () => {
    expect(compareVersions('0.10.0', '0.9.9')).toBe(1)
    expect(compareVersions('0.9.9', '0.10.0')).toBe(-1)
    expect(compareVersions('1.0.0', '1.0.0')).toBe(0)
    expect(compareVersions('1.2', '1.2.0')).toBe(0)
    expect(compareVersions('2', '1.9.9')).toBe(1)
  })

  it('sorts a prerelease below the release it belongs to', () => {
    expect(compareVersions('1.0.0-rc.1', '1.0.0')).toBe(-1)
    expect(compareVersions('1.0.0', '1.0.0-rc.1')).toBe(1)
    expect(compareVersions('1.0.0-rc.2', '1.0.0-rc.1')).toBe(1)
  })

  it('ignores a leading v and build metadata', () => {
    expect(compareVersions('v1.2.3', '1.2.3')).toBe(0)
    expect(compareVersions('1.2.3+build.9', '1.2.3+build.1')).toBe(0)
  })
})

describe('clientIsAhead — the whole of when the update sentence shows', () => {
  it('is true only when the client build is strictly greater', () => {
    expect(clientIsAhead('0.10.0', '0.9.0')).toBe(true)
    expect(clientIsAhead('1.0.0', '1.0.0-rc.1')).toBe(true)
  })

  it('is false when the client is equal or behind', () => {
    expect(clientIsAhead('0.10.0', '0.10.0')).toBe(false)
    expect(clientIsAhead('0.9.0', '0.10.0')).toBe(false)
  })

  it('is false — never a guess — when either number is not a real version', () => {
    // '' is what an older host sends and what this client holds before a socket
    // is up; 'unknown' is version.ts's honest non-answer. Comparing against
    // either would manufacture a verdict, so the answer is no and the sentence
    // stays off the screen.
    expect(clientIsAhead('', '0.9.0')).toBe(false)
    expect(clientIsAhead('0.10.0', '')).toBe(false)
    expect(clientIsAhead('unknown', '0.9.0')).toBe(false)
    expect(clientIsAhead('0.10.0', 'unknown')).toBe(false)
    expect(clientIsAhead('unknown', 'unknown')).toBe(false)
  })
})

describe('hostKindNoun', () => {
  it('calls a headless host a server and a desktop a desktop', () => {
    expect(hostKindNoun('headless')).toBe('server')
    expect(hostKindNoun('desktop')).toBe('desktop')
  })

  it('gives no noun for a kind that was never said', () => {
    expect(hostKindNoun(null)).toBeNull()
  })
})

describe('hostVersionLine', () => {
  it('names the version and the kind when both are known', () => {
    expect(hostVersionLine('0.10.0', 'headless')).toBe('version 0.10.0 · server')
    expect(hostVersionLine('1.2.3', 'desktop')).toBe('version 1.2.3 · desktop')
  })

  it('names only the version when the kind was never said', () => {
    expect(hostVersionLine('0.10.0', null)).toBe('version 0.10.0')
  })

  it('is empty for a host that reported no version, so the caller draws nothing', () => {
    expect(hostVersionLine('', 'headless')).toBe('')
    expect(hostVersionLine('', null)).toBe('')
  })
})
