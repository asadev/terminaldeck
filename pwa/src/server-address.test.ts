import { describe, expect, it } from 'vitest'
import { formatServerAddress, parseServerAddress } from '../../src/shared/server-address'
import { DIRECT, asEndpoint, hostKeyBytes } from './endpoint'

/**
 * The join between what a host prints and what this client will accept.
 *
 * `src/shared/server-address.ts` is the encoder, and it validates on the way
 * out; `asEndpoint` here is the gate on the way in, and it is the one that
 * decides whether a stored endpoint is dialled or quietly replaced by `DIRECT`.
 * Two validators, written in two files, over one format — which is safe when
 * something fails on the drift and not when nobody edits either.
 *
 * So this runs the **real** `asEndpoint` over the **real** round trip. A field
 * renamed, a key re-encoded into the alphabet the browser `Buffer` mangles, a
 * `kind` dropped: any of them turns a host printing an address into a client
 * silently talking to the machine that served the page, and every one of them
 * fails here instead.
 */

const HOST_ID = 'ABCDEFGHJKLMNPQRSTUVWXYZ23'
const KEY = Buffer.alloc(32, 7)

const PARTS = {
  url: 'wss://relay.example.org',
  hostId: HOST_ID,
  hostKey: KEY.toString('base64url'),
}

describe('an address pasted into this client', () => {
  it('is exactly the endpoint asEndpoint accepts', () => {
    const parsed = parseServerAddress(formatServerAddress(PARTS) as string)
    expect(parsed).not.toBeNull()
    // Not "looks like" — the same object, through the client's own validator,
    // which answers DIRECT for anything it will not dial.
    expect(asEndpoint(parsed)).toEqual({
      kind: 'relay',
      url: PARTS.url,
      hostId: HOST_ID,
      hostKey: PARTS.hostKey,
    })
    expect(asEndpoint(parsed)).not.toBe(DIRECT)
  })

  it('hands over a key this client can turn back into thirty-two bytes', () => {
    const parsed = parseServerAddress(formatServerAddress(PARTS) as string)
    expect(parsed).not.toBeNull()
    // The handshake is IK, so this is the byte string the client will name as
    // the responder. A key that decoded two bytes short here is a handshake
    // that fails with no reason attached.
    expect(hostKeyBytes((parsed as { hostKey: string }).hostKey)).toEqual(KEY)
  })

  it('is still the endpoint asEndpoint accepts when the host spelled its key in base64', () => {
    // A rendezvous offer carries the same 32 bytes in the standard alphabet.
    // The address normalises, so both spellings reach this client as one.
    const parsed = parseServerAddress(
      formatServerAddress({ ...PARTS, hostKey: KEY.toString('base64') }) as string,
    )
    expect(asEndpoint(parsed)).toEqual(asEndpoint(parseServerAddress(formatServerAddress(PARTS) as string)))
  })

  it('leaves this client on DIRECT when the paste was not an address', () => {
    expect(asEndpoint(parseServerAddress('paste me'))).toBe(DIRECT)
  })
})
