import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { installPaths, nodePaths, resetPaths } from '../main/platform/paths'
import { parseServerAddress } from '../shared/server-address'
import { addressAnswer, renderStatus } from './cli'
import { createHeadlessHost, type HeadlessHost } from './host'

/**
 * The address, out of a **real** host identity, on a host that is really
 * dialling out.
 *
 * Every other test of this format builds its three facts by hand, which is the
 * right shape for a format test and cannot catch the thing that actually breaks
 * a feature like this: the host produces those facts in a spelling the format
 * refuses. That has a precedent in this exact area — `RelayState.publicKey` is
 * `toString('base64url')` while a rendezvous offer is standard base64, and a
 * validator that only ever saw the one it was written against would pass every
 * suite while a real machine printed something no client accepts.
 *
 * So this starts `createHeadlessHost` with `relayEnabled`, lets
 * `loadHostIdentity` mint a genuine key pair and host id in a temp directory,
 * and asks whether the address it prints parses back into the very three fields
 * the host reported. Nothing is paired and nothing is approved; the host claims
 * a slot for a throwaway identity and the directory is deleted afterwards.
 *
 * Gated, like `relay-live.test.ts`, because it opens a socket to the deployed
 * relay:
 *
 *     TERMINALDECK_LIVE_RELAY=1 npx vitest run src/headless/address-live.test.ts
 */

const live = process.env.TERMINALDECK_LIVE_RELAY === '1'

let dir = ''
let host: HeadlessHost | null = null

beforeAll(async () => {
  if (!live) return
  dir = mkdtempSync(join(tmpdir(), 'td-address-live-'))
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  host = await createHeadlessHost({
    storageDir: dir,
    relayEnabled: true,
    // Pinned signed-out so the direct route plays no part in this: the address
    // is a relay fact and nothing else.
    readTailnet: async () => ({ ready: false, state: 'logged-out', reason: 'signed out' }),
    serve: { on: async () => ({ ok: false, message: 'not in a test' }), off: async () => undefined },
  })
}, 60_000)

afterAll(async () => {
  if (host !== null) await host.stop()
  if (dir !== '') {
    resetPaths()
    rmSync(dir, { recursive: true, force: true })
  }
})

describe.skipIf(!live)('a host that minted its own identity', () => {
  it('prints an address that parses back into the facts it reported', async () => {
    const status = await (host as HeadlessHost).status()
    const relay = status.remote.relay
    expect(relay).not.toBeNull()

    const answer = addressAnswer(relay)
    expect(answer.ok).toBe(true)
    expect(parseServerAddress(answer.ok ? answer.address : '')).toEqual({
      kind: 'relay',
      url: relay?.url,
      hostId: relay?.hostId,
      hostKey: relay?.publicKey,
    })
  }, 60_000)

  it('prints it in the status output, whether or not the link is up yet', async () => {
    // The link is usually still dialling a second after start, and the address
    // does not depend on it: all three facts are properties of the machine.
    const status = await (host as HeadlessHost).status()
    const answer = addressAnswer(status.remote.relay)
    expect(renderStatus(status, Date.now())).toContain(answer.ok ? answer.address : 'never')
  }, 60_000)
})
