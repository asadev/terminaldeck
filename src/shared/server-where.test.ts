import { describe, expect, it } from 'vitest'
import { DEFAULT_SSH_PORT, serverAddress, serverWhere } from './server-where'

/**
 * The one rule about printing a port, pinned where it is written.
 *
 * The bug being guarded is not "the port is missing" — it is *"the app told
 * somebody where a machine is, and it was not there."* A person reads an
 * address off this app and types it into `ssh`, a browser, or a colleague's
 * chat window; `192.0.2.11` for a server on 2222 fails in all three, and fails
 * silently in the worst way, because port 22 on that IP may well answer as a
 * different machine.
 *
 * Both halves are tested, and the second is the one a careless fix loses.
 */

describe('where a server is, as one line', () => {
  it('prints the port a person would have to type, and only then', () => {
    // The whole finding, in two lines. His Office PC is the first.
    expect(serverAddress({ address: '192.0.2.11', port: 2222 })).toBe('192.0.2.11:2222')
    expect(serverAddress({ address: '192.0.2.11', port: 22 })).toBe('192.0.2.11')
  })

  it('says nothing about the usual port, however it arrived', () => {
    /*
     * Three ways a server ends up on 22 — the field absent because the main
     * process is older than it, the field absent because nobody typed one, and
     * an explicit 22 — and all three are the same *place*, so all three draw
     * the same line. `:22` on every row would be a character that is true of
     * almost every server and therefore tells a reader nothing, while making
     * the rare row that matters harder to pick out.
     */
    expect(serverAddress({ address: 'example.com' })).toBe('example.com')
    expect(serverAddress({ address: 'example.com', port: undefined })).toBe('example.com')
    expect(serverAddress({ address: 'example.com', port: DEFAULT_SSH_PORT })).toBe('example.com')
  })

  it('brackets an IPv6 literal, because the bare form cannot be read', () => {
    // `2001:db8::1:2222` is not an address anything can parse — the colon is
    // already the separator inside it. `store.ts` strips the brackets on the
    // way in (`normaliseAddress`), so this is the side that puts them back.
    expect(serverAddress({ address: '2001:db8::1', port: 2222 })).toBe('[2001:db8::1]:2222')
    expect(serverAddress({ address: '2001:db8::1' })).toBe('2001:db8::1')
    // And it does not double them for an address that kept its own.
    expect(serverAddress({ address: '[2001:db8::1]', port: 2222 })).toBe('[2001:db8::1]:2222')
  })

  it('treats a number nothing could be listening on as no number at all', () => {
    /*
     * `store.ts` refuses these on the way in, so one arriving here came from a
     * hand-edited file or a build that lied. The bare address is the honest
     * answer: it at least names a machine. `example.com:0` names nowhere and
     * would be pasted into a terminal by somebody who trusted this screen.
     */
    for (const port of [0, -1, 65_536, 22.5, Number.NaN]) {
      expect(serverAddress({ address: 'example.com', port }), String(port)).toBe('example.com')
    }
  })
})

describe('the line under a server’s name', () => {
  it('reads as a sentence, and carries the port with it', () => {
    expect(serverWhere({ username: 'admin', address: '192.0.2.11', port: 2222 })).toBe(
      'admin at 192.0.2.11:2222',
    )
    expect(serverWhere({ username: 'admin', address: 'example.com' })).toBe('admin at example.com')
  })

  it('drops the "at" rather than leaving a hole in front of it', () => {
    // A stored server can have an empty username. " at example.com" reads as a
    // value that failed to load; the address alone reads as a question that was
    // never asked.
    expect(serverWhere({ username: '', address: 'example.com', port: 2222 })).toBe(
      'example.com:2222',
    )
  })
})
