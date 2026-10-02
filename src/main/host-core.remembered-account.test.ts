import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { rememberedAccount } from './host-core'

/**
 * A tab opened on "the default" is written down as the account it actually
 * ran as.
 *
 * It was written down as null — "whatever the default is" — and everything
 * that later asked about the tab, the account switch above all, re-resolved
 * that null against whatever the default had *become*: a session signed in as
 * one login was then reasoned about as another. The spawn path cannot be run
 * here without launching a real agent CLI against the real keychain, so the
 * rule is pinned as a function, and its one call site is pinned to it.
 */
describe('what a remembered tab says it is signed in as', () => {
  it('is the account the session was resolved to, not the empty request', () => {
    expect(rememberedAccount({ profileId: 'work' }, { profileId: null })).toBe('work')
    expect(rememberedAccount({ profileId: 'system' }, { profileId: undefined })).toBe('system')
    // A session with no account at all — a shell — keeps the request as it was.
    expect(rememberedAccount({}, { profileId: null })).toBeNull()
  })

  it('is what the ledger is handed when the tab is written down', () => {
    const source = readFileSync(new URL('./host-core.ts', import.meta.url), 'utf8')
    expect(source).toContain('profileId: rememberedAccount(meta, input),')
    expect(source).not.toContain('profileId: input.profileId ?? null,')
  })
})
