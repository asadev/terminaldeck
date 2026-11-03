import { createHash } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import { decodeHex, directorySuffixes, readShimCall, slotForService, splitWords } from './keychain-requests'

/**
 * The commands are the ones in the shipped CLI (`@anthropic-ai/claude-code`
 * 2.1.287, read with `strings`): the shell-string read, the argv read, the
 * `security -i` write with `-X <hex>` on stdin, the argv write, the delete and
 * the lock check. Each is fed through exactly as the shim would receive it.
 */

const USER = 'imatch'
const hex = (text: string): string => Buffer.from(text, 'utf8').toString('hex')

describe('which keychain services are an agent login', () => {
  it('keeps the variant in the slot, and hands the directory hash back beside it', () => {
    expect(slotForService('Claude Code-credentials')).toEqual({ slot: 'keychain:Claude Code-credentials', suffix: null })
    expect(slotForService('Claude Code-credentials-70e2e799')).toEqual({
      slot: 'keychain:Claude Code-credentials',
      suffix: '70e2e799',
    })
    expect(slotForService('Claude Code-staging-oauth-credentials-8e404012')).toEqual({
      slot: 'keychain:Claude Code-staging-oauth-credentials',
      suffix: '8e404012',
    })
    expect(slotForService('Claude Code-70e2e799')).toEqual({ slot: 'keychain:Claude Code', suffix: '70e2e799' })
  })

  it('names the directory hash the way the shipped CLI does', () => {
    const sha = (text: string): string => createHash('sha256').update(text).digest('hex')
    const dir = '/Users/x/Library/Application Support/terminaldeck/profiles/work'
    expect(directorySuffixes(dir, sha)).toEqual(new Set([sha(dir).slice(0, 8)]))
    // A decomposed accent and its composed form are one folder to a person.
    expect(directorySuffixes('/p/Cafe\u0301', sha).has(sha('/p/Caf\u00e9').slice(0, 8))).toBe(true)
  })

  it('leaves everything else alone — the device keys, a signing identity, anything a person asks for', () => {
    expect(slotForService('Claude Code-device-keys')).toBeNull()
    expect(slotForService('Apple Development: Someone')).toBeNull()
    expect(slotForService('Claude Code-credentials-NOTHEX!!')).toBeNull()
    expect(slotForService('gemini-cli-oauth')).toBeNull()
  })
})

describe('reading what the CLI sends', () => {
  it('reads the lookup, whichever way it was spelled', () => {
    expect(
      readShimCall(['find-generic-password', '-a', USER, '-w', '-s', 'Claude Code-credentials-70e2e799'], ''),
    ).toEqual({
      kind: 'ours',
      requests: [{ op: 'find', slot: 'keychain:Claude Code-credentials', suffix: '70e2e799', wantsPassword: true }],
    })
  })

  it('reads the `security -i` write, decoding the hex the CLI uses to keep the token out of argv', () => {
    const login = '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-X"}}'
    const stdin = `add-generic-password -U -a "${USER}" -s "Claude Code-credentials-70e2e799" -X "${hex(login)}"\n`
    expect(readShimCall(['-i'], stdin)).toEqual({
      kind: 'ours',
      requests: [{ op: 'add', slot: 'keychain:Claude Code-credentials', suffix: '70e2e799', value: login }],
    })
  })

  it('reads the argv write the CLI falls back to for a long login', () => {
    const login = 'x'.repeat(5000)
    expect(
      readShimCall(
        ['add-generic-password', '-U', '-a', USER, '-s', 'Claude Code-credentials-70e2e799', '-X', hex(login)],
        '',
      ),
    ).toEqual({
      kind: 'ours',
      requests: [{ op: 'add', slot: 'keychain:Claude Code-credentials', suffix: '70e2e799', value: login }],
    })
  })

  it('reads the delete and the lock check', () => {
    expect(readShimCall(['delete-generic-password', '-a', USER, '-s', 'Claude Code-credentials-1a2b3c4d'], '')).toEqual({
      kind: 'ours',
      requests: [{ op: 'delete', slot: 'keychain:Claude Code-credentials', suffix: '1a2b3c4d' }],
    })
    expect(readShimCall(['show-keychain-info'], '')).toEqual({ kind: 'ours', requests: [{ op: 'locked?' }] })
  })

  it('passes anything that is not a login through, whole — including a mixed `-i` batch', () => {
    expect(readShimCall(['find-identity', '-v', '-p', 'codesigning'], '')).toEqual({ kind: 'pass' })
    expect(readShimCall(['find-generic-password', '-a', USER, '-w', '-s', 'Claude Code-device-keys'], '')).toEqual({
      kind: 'pass',
    })
    const mixed =
      `add-generic-password -U -a "${USER}" -s "Claude Code-credentials" -X "${hex('a')}"\n` +
      `add-generic-password -U -a "${USER}" -s "Claude Code-device-keys" -X "${hex('b')}"\n`
    expect(readShimCall(['-i'], mixed)).toEqual({ kind: 'pass' })
    // `show-keychain-info <a keychain>` names a keychain; that is somebody's own question.
    expect(readShimCall(['show-keychain-info', 'login.keychain-db'], '')).toEqual({ kind: 'pass' })
  })

  it('never keeps a write it cannot decode', () => {
    expect(
      readShimCall(['add-generic-password', '-U', '-a', USER, '-s', 'Claude Code-credentials', '-X', 'zz'], ''),
    ).toEqual({ kind: 'pass' })
    // `-w` with nothing after it is security's "prompt me" — nothing to keep.
    expect(readShimCall(['add-generic-password', '-a', USER, '-s', 'Claude Code-credentials', '-w'], '')).toEqual({
      kind: 'pass',
    })
  })
})

describe('the small parsers underneath', () => {
  it('splits quoted words the way `security -i` does', () => {
    expect(splitWords('add-generic-password -U -a "a b" -s "x\\"y" -X "00"')).toEqual([
      'add-generic-password',
      '-U',
      '-a',
      'a b',
      '-s',
      'x"y',
      '-X',
      '00',
    ])
  })

  it('decodes even-length hex only', () => {
    expect(decodeHex(hex('héllo'))).toBe('héllo')
    expect(decodeHex('abc')).toBeNull()
    expect(decodeHex('')).toBeNull()
  })
})
