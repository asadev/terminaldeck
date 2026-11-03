import { describe, expect, it } from 'vitest'
import { CallbackRefused, callbackUrlProblem, isPublicAddress, publicHttpsPost, publicLookup } from './mcp-events-callback'

/**
 * Where this Mac will post an MCP Events delivery: the public internet, over
 * HTTPS, and nowhere else.
 *
 * The callback address comes from the far side, so these are the rules that
 * keep a subscription from turning somebody's Mac into a way to reach their own
 * router or a cloud metadata address. Nothing here dials out: every refusal
 * below happens before a connection is attempted, or at the lookup.
 */

describe('which addresses are public', () => {
  it('refuses every private, local, shared, reserved and documentation range', () => {
    const notPublic = [
      '0.0.0.0',
      '10.1.2.3',
      '100.64.0.1',
      '127.0.0.1',
      '169.254.169.254',
      '172.16.0.1',
      '172.31.255.255',
      '192.0.2.1',
      '192.168.1.1',
      '198.18.0.1',
      '198.51.100.7',
      '203.0.113.9',
      '224.0.0.1',
      '255.255.255.255',
      '::',
      '::1',
      'fc00::1',
      'fd12:3456::1',
      'fe80::1',
      'ff02::1',
      '2001:db8::1',
      '2001::1',
      '::ffff:127.0.0.1',
      '::ffff:7f00:1',
      '::ffff:10.0.0.1',
      '64:ff9b::a00:1',
      '2002:c0a8:101::1',
      'not an address',
    ]
    for (const address of notPublic) expect(isPublicAddress(address), address).toBe(false)
  })

  it('lets real internet addresses through, including the IPv4 inside a mapped or NAT64 form', () => {
    for (const address of ['8.8.8.8', '1.1.1.1', '104.18.32.47', '2606:4700::6810:84e5', '2a00:1450:4001::200e', '::ffff:8.8.8.8', '64:ff9b::808:808']) {
      expect(isPublicAddress(address), address).toBe(true)
    }
  })
})

describe('what a callback address may look like', () => {
  it('takes only https, no credentials, and no host that is local by name or by number', () => {
    expect(callbackUrlProblem('https://callbacks.chatgpt.com/mcp/events/abc')).toBeNull()
    expect(callbackUrlProblem('https://8.8.8.8/hook')).toBeNull()
    for (const bad of [
      'http://callbacks.chatgpt.com/x',
      'ftp://example.com/x',
      'https://user:pass@example.com/x',
      'https://localhost/x',
      'https://api.localhost/x',
      'https://printer.local/x',
      'https://metadata.google.internal/x',
      'https://router/x',
      'https://127.0.0.1/x',
      'https://[::1]/x',
      'https://169.254.169.254/latest/meta-data',
      'not a url',
    ]) {
      expect(callbackUrlProblem(bad), bad).not.toBeNull()
    }
  })
})

describe('the real poster', () => {
  it('refuses a local or plain-http callback before it connects to anything', async () => {
    for (const bad of ['http://example.com/x', 'https://127.0.0.1:9/x', 'https://[::1]:9/x', 'https://localhost:9/x', 'https://10.0.0.1/x']) {
      const error = await publicHttpsPost(bad, {}, '{}').then(
        () => null,
        (refused: unknown) => refused,
      )
      expect(error, bad).toBeInstanceOf(CallbackRefused)
      expect((error as CallbackRefused).reason).toBe('not_public')
    }
  })

  it('refuses at the lookup a name that resolves to a private address', async () => {
    // `localhost` resolves from the hosts file, so this needs no network.
    const outcome = await new Promise<{ code: string | undefined }>((resolve) => {
      publicLookup('localhost', {}, (error) => resolve({ code: error?.code }))
    })
    expect(outcome.code).toBe('ENOTPUBLIC')
  })
})
