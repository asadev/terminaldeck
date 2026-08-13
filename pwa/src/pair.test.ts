import { describe, expect, it } from 'vitest'
import {
  CREDENTIAL_KEY,
  clearCredential,
  describeDevice,
  loadCredential,
  readPairToken,
  saveCredential,
  takePairToken,
  type StorageLike,
} from './pair'

function memoryStorage(initial: Record<string, string> = {}): StorageLike & { data: Record<string, string> } {
  const data = { ...initial }
  return {
    data,
    getItem: (key) => (key in data ? data[key] : null),
    setItem: (key, value) => {
      data[key] = value
    },
    removeItem: (key) => {
      delete data[key]
    },
  }
}

describe('reading the token off the QR URL', () => {
  it('accepts the fragment the desktop encodes', () => {
    expect(readPairToken('#t=Kf3-9_aZ')).toBe('Kf3-9_aZ')
    expect(readPairToken('#token=Kf3-9_aZ')).toBe('Kf3-9_aZ')
    expect(readPairToken('t=Kf3-9_aZ')).toBe('Kf3-9_aZ')
  })

  it('keeps the characters base64url actually uses', () => {
    // A stricter pattern here would reject a token the desktop had just minted,
    // which is a client refusing a change it does not get a vote on.
    expect(readPairToken('#t=abc-DEF_123.xyz')).toBe('abc-DEF_123.xyz')
  })

  it('answers null when there is no token', () => {
    expect(readPairToken('')).toBeNull()
    expect(readPairToken('#')).toBeNull()
    expect(readPairToken('#session=abc')).toBeNull()
    expect(readPairToken('#t=')).toBeNull()
  })

  it('rejects whitespace and control characters', () => {
    // The shape of something retyped by hand or mangled by a chat app, not of
    // anything `auth.ts` mints.
    expect(readPairToken('#t=abc def')).toBeNull()
    expect(readPairToken('#t=abc\u0000def')).toBeNull()
    expect(readPairToken('#t=abc\tdef')).toBeNull()
    expect(readPairToken('#t=abc\ndef')).toBeNull()
  })

  it('rejects a token longer than the protocol accepts', () => {
    expect(readPairToken(`#t=${'a'.repeat(200)}`)).toHaveLength(200)
    expect(readPairToken(`#t=${'a'.repeat(201)}`)).toBeNull()
  })
})

describe('taking the token out of the URL', () => {
  it('reads it and removes it in the same step', () => {
    const replaced: string[] = []
    const token = takePairToken(
      { hash: '#t=secret-token', pathname: '/', search: '' },
      { replaceState: (_data, _unused, url) => replaced.push(url) },
    )
    expect(token).toBe('secret-token')
    // Not one back-button press away, not in a screenshot of the address bar.
    expect(replaced).toEqual(['/'])
  })

  it('keeps the rest of the URL intact', () => {
    const replaced: string[] = []
    takePairToken(
      { hash: '#t=x', pathname: '/deck', search: '?theme=dark' },
      { replaceState: (_data, _unused, url) => replaced.push(url) },
    )
    expect(replaced).toEqual(['/deck?theme=dark'])
  })

  it('leaves the URL alone when there was no fragment', () => {
    const replaced: string[] = []
    expect(
      takePairToken({ hash: '', pathname: '/', search: '' }, { replaceState: (_d, _u, url) => replaced.push(url) }),
    ).toBeNull()
    expect(replaced).toEqual([])
  })
})

describe('the stored credential', () => {
  const credential = { token: 'dev-1.c2VjcmV0', deviceId: 'dev-1', deviceName: 'iPhone', pairedAt: 1_700_000_000_000 }

  it('round-trips', () => {
    const storage = memoryStorage()
    saveCredential(storage, credential)
    expect(loadCredential(storage)).toEqual(credential)
    expect(Object.keys(storage.data)).toEqual([CREDENTIAL_KEY])
  })

  it('is gone after clearing', () => {
    const storage = memoryStorage()
    saveCredential(storage, credential)
    clearCredential(storage)
    expect(loadCredential(storage)).toBeNull()
  })

  it('treats anything half-written as nothing', () => {
    // A credential without its device id cannot authenticate, and sending the
    // app to the session list holding one strands the user on a screen that
    // fails forever with no route back to pairing.
    expect(loadCredential(memoryStorage({ [CREDENTIAL_KEY]: 'not json' }))).toBeNull()
    expect(loadCredential(memoryStorage({ [CREDENTIAL_KEY]: '"a string"' }))).toBeNull()
    expect(loadCredential(memoryStorage({ [CREDENTIAL_KEY]: '{"deviceId":"dev-1"}' }))).toBeNull()
    expect(loadCredential(memoryStorage({ [CREDENTIAL_KEY]: '{"token":""}' }))).toBeNull()
    expect(loadCredential(memoryStorage())).toBeNull()
  })

  it('fills in a name rather than showing an empty one', () => {
    const storage = memoryStorage({ [CREDENTIAL_KEY]: '{"token":"a.b","deviceId":"a"}' })
    expect(loadCredential(storage)?.deviceName).toBe('This device')
    expect(loadCredential(storage)?.pairedAt).toBe(0)
  })

  it('reads as unpaired when storage itself refuses', () => {
    // Safari in private mode throws on access rather than returning null.
    const hostile: StorageLike = {
      getItem: () => {
        throw new Error('SecurityError')
      },
      setItem: () => {
        throw new Error('QuotaExceededError')
      },
      removeItem: () => {
        throw new Error('SecurityError')
      },
    }
    expect(loadCredential(hostile)).toBeNull()
    // And saving must not take the session down with it — the credential in
    // memory still works for as long as the app is open.
    expect(() => saveCredential(hostile, credential)).not.toThrow()
    expect(() => clearCredential(hostile)).not.toThrow()
  })
})

describe('naming the device for the approval prompt', () => {
  it('recognises the phones this is built for', () => {
    expect(describeDevice('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)')).toEqual({
      name: 'iPhone',
      platform: 'iOS',
    })
    expect(describeDevice('Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)').name).toBe('iPad')
    expect(describeDevice('Mozilla/5.0 (Linux; Android 15; Pixel 9)').name).toBe('Android phone')
    expect(describeDevice('Mozilla/5.0 (Windows NT 10.0; Win64; x64)').name).toBe('Windows PC')
  })

  it('falls back to something honest rather than guessing', () => {
    expect(describeDevice('')).toEqual({ name: 'Browser', platform: 'unknown' })
  })
})
