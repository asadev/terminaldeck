import type { VaultCipher } from './store'

/**
 * A `safeStorage` stand-in for the vault's tests, behaving like the real one in
 * the one way that matters: what reaches the disk is not the plaintext, and a
 * blob it did not make does not open.
 *
 * The marker is checked on the way back in, so a file this cipher did not write
 * — another OS user's, another machine's — is unreadable here exactly as it
 * would be for real.
 */
export function fakeCipher(state: { available: boolean } = { available: true }): VaultCipher {
  const MARK = Buffer.from('fake-v1:')
  return {
    available: () => state.available,
    encrypt: (plain) => {
      // Reversed bytes behind a marker: not the plaintext, and trivially undone.
      const bytes = Buffer.from(plain, 'utf8').reverse()
      return Buffer.concat([MARK, bytes])
    },
    decrypt: (blob) => {
      if (!blob.subarray(0, MARK.length).equals(MARK)) throw new Error('not our ciphertext')
      return Buffer.from(blob.subarray(MARK.length)).reverse().toString('utf8')
    },
  }
}

/** A Claude Code credential in the shape the CLI writes it. Fake values only. */
export function claudeLogin(token: string, plan = 'max', expiresAt = 4_102_444_800_000): string {
  return JSON.stringify({
    claudeAiOauth: {
      accessToken: `sk-ant-oat01-${token}`,
      refreshToken: `sk-ant-ort01-${token}`,
      expiresAt,
      scopes: ['user:inference', 'user:profile'],
      subscriptionType: plan,
    },
  })
}
