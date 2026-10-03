/**
 * Where this Mac may post an MCP Events delivery, and the one function that posts it.
 *
 * ## Why this file is strict
 *
 * An MCP Events subscription carries a callback address chosen by the far side.
 * ChatGPT's points at ChatGPT, but the address is only ever a string in a
 * request, and this Mac is the one that dials it. Left alone, that is a way to
 * make somebody's Mac post to their own router, their printer, a cloud
 * metadata address, or anything else only reachable from inside their network.
 *
 * So the rules are the ones OpenAI's MCP Events guide states for a server, and
 * they are enforced here, at connection time, not only when the address is
 * first seen:
 *
 *  - **HTTPS only**, and no user name or password in the address;
 *  - the host is **resolved when the connection is made**, every address it
 *    resolves to is checked, and one that is private, local, link-local,
 *    shared, reserved, multicast or documentation-only refuses the whole post —
 *    a name that answers with one public and one private address is refused,
 *    because the connection could land on either;
 *  - the connection goes to the address that was checked, while TLS still
 *    verifies the certificate against the original host name;
 *  - **no redirect is followed** — a 3xx is a failed delivery, never a second
 *    destination nobody checked.
 *
 * The poster is a parameter of `McpEvents`, so the tests can post to a receiver
 * on 127.0.0.1 without loosening any of this; `mcp-events-callback.test.ts`
 * holds the real poster to these rules.
 */

import { lookup as dnsLookup, type LookupAddress, type LookupOptions } from 'node:dns'
import { request as httpsRequest } from 'node:https'
import { BlockList, isIP } from 'node:net'

/** One delivery's whole budget: connect, TLS, send, and the answer. */
export const CALLBACK_TIMEOUT_MS = 10_000

/** The most of a receiver's answer read. A verification echo is a few dozen bytes. */
export const MAX_ANSWER_BYTES = 8 * 1024

export interface CallbackAnswer {
  status: number
  body: string
}

/** Posts one JSON body. Resolves with the answer; rejects with a {@link CallbackRefused}. */
export type CallbackPost = (url: string, headers: Record<string, string>, body: string) => Promise<CallbackAnswer>

/** The spec's `CallbackEndpointError` reasons, plus the one this file adds. */
export type CallbackFailure = 'not_public' | 'connection_refused' | 'timeout' | 'tls_error'

export class CallbackRefused extends Error {
  constructor(
    readonly reason: CallbackFailure,
    message: string,
  ) {
    super(message)
    this.name = 'CallbackRefused'
  }
}

/* --------------------------------------------------------- the addresses -- */

const V4_BLOCKED: Array<[string, number]> = [
  ['0.0.0.0', 8], // "this network"
  ['10.0.0.0', 8], // private
  ['100.64.0.0', 10], // carrier-grade NAT, shared
  ['127.0.0.0', 8], // loopback
  ['169.254.0.0', 16], // link-local, and every cloud's metadata address
  ['172.16.0.0', 12], // private
  ['192.0.0.0', 24], // IETF protocol assignments
  ['192.0.2.0', 24], // documentation
  ['192.88.99.0', 24], // 6to4 relay anycast
  ['192.168.0.0', 16], // private
  ['198.18.0.0', 15], // benchmarking
  ['198.51.100.0', 24], // documentation
  ['203.0.113.0', 24], // documentation
  ['224.0.0.0', 4], // multicast
  ['240.0.0.0', 4], // reserved, and broadcast
]

const V6_BLOCKED: Array<[string, number]> = [
  ['::', 128], // unspecified
  ['::1', 128], // loopback
  ['100::', 64], // discard
  ['2001::', 23], // IETF protocol assignments, Teredo among them
  ['2001:db8::', 32], // documentation
  ['fc00::', 7], // unique local
  ['fe80::', 10], // link-local
  ['fec0::', 10], // site-local, deprecated but still routed by some
  ['ff00::', 8], // multicast
]

const v4Blocked = new BlockList()
for (const [network, prefix] of V4_BLOCKED) v4Blocked.addSubnet(network, prefix, 'ipv4')
const v6Blocked = new BlockList()
for (const [network, prefix] of V6_BLOCKED) v6Blocked.addSubnet(network, prefix, 'ipv6')

/** Eight 16-bit groups out of any spelling of an IPv6 address, or null. */
function v6Groups(address: string): number[] | null {
  let text = address.toLowerCase()
  const zone = text.indexOf('%')
  if (zone >= 0) text = text.slice(0, zone)
  // A trailing dotted quad (`::ffff:10.0.0.1`) becomes two groups.
  const quad = /(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(text)
  if (quad) {
    const [a, b, c, d] = quad.slice(1).map(Number)
    if ([a, b, c, d].some((n) => n > 255)) return null
    text = `${text.slice(0, quad.index)}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`
  }
  const halves = text.split('::')
  if (halves.length > 2) return null
  const parse = (part: string): number[] => (part === '' ? [] : part.split(':').map((group) => parseInt(group, 16)))
  const head = parse(halves[0])
  const tail = halves.length === 2 ? parse(halves[1]) : []
  const fill = halves.length === 2 ? 8 - head.length - tail.length : 0
  const groups = [...head, ...new Array<number>(Math.max(fill, 0)).fill(0), ...tail]
  if (groups.length !== 8 || groups.some((group) => !Number.isInteger(group) || group < 0 || group > 0xffff)) return null
  return groups
}

function v4From(high: number, low: number): string {
  return `${high >> 8}.${high & 0xff}.${low >> 8}.${low & 0xff}`
}

/**
 * Is this an address on the public internet?
 *
 * IPv6 forms that carry an IPv4 address inside them — mapped (`::ffff:a.b.c.d`),
 * NAT64 (`64:ff9b::/96`) and 6to4 (`2002::/16`) — are judged by the IPv4
 * address they carry, so `::ffff:127.0.0.1` is loopback, not "some IPv6".
 */
export function isPublicAddress(address: string): boolean {
  const family = isIP(address)
  if (family === 4) return !v4Blocked.check(address, 'ipv4')
  if (family !== 6) return false
  const groups = v6Groups(address)
  if (groups === null) return false
  const [g0, g1, g2, g3, g4, g5, g6, g7] = groups
  if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0 && (g5 === 0xffff || g5 === 0)) {
    // Mapped, or the deprecated compatible form; `::` and `::1` land here too.
    if (g5 === 0 && g6 === 0) return false
    return isPublicAddress(v4From(g6, g7))
  }
  if (g0 === 0x64 && g1 === 0xff9b && g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0) {
    return isPublicAddress(v4From(g6, g7))
  }
  if (g0 === 0x2002) return isPublicAddress(v4From(g1, g2))
  const canonical = groups.map((group) => group.toString(16)).join(':')
  return !v6Blocked.check(canonical, 'ipv6')
}

/** Host names that are never on the public internet, whatever DNS says today. */
function isLocalName(host: string): boolean {
  const name = host.toLowerCase().replace(/\.$/, '')
  return (
    name === 'localhost' ||
    name.endsWith('.localhost') ||
    name.endsWith('.local') ||
    name.endsWith('.internal') ||
    name.endsWith('.home.arpa') ||
    !name.includes('.')
  )
}

/**
 * What is wrong with a callback address on sight, or null.
 *
 * The cheap half, run when a subscription arrives so the far side hears a plain
 * `InvalidParams` rather than a failed verification. The half that matters —
 * what the name resolves to — runs again on every connection, in
 * {@link publicHttpsPost}.
 */
export function callbackUrlProblem(raw: string): string | null {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    return 'The callback is not a web address.'
  }
  if (url.protocol !== 'https:') return 'The callback has to be an https:// address.'
  if (url.username !== '' || url.password !== '') return 'The callback address cannot carry a user name or password.'
  const host = url.hostname.replace(/^\[|\]$/g, '')
  if (host === '') return 'The callback address has no host.'
  if (isIP(host) !== 0) {
    return isPublicAddress(host) ? null : 'The callback has to be a public internet address.'
  }
  if (isLocalName(host)) return 'The callback has to be a public internet address.'
  return null
}

/* -------------------------------------------------------------- the post -- */

/**
 * `dns.lookup`, refusing any answer that is not entirely public.
 *
 * Shaped like Node's `lookup` option, including the `all: true` form that
 * Happy Eyeballs uses, so `https.request` connects to exactly an address this
 * function returned.
 */
export function publicLookup(
  hostname: string,
  options: LookupOptions & { all?: boolean },
  callback: (error: NodeJS.ErrnoException | null, address?: string | LookupAddress[], family?: number) => void,
): void {
  dnsLookup(hostname, { ...options, all: true }, (error: NodeJS.ErrnoException | null, list: LookupAddress[]) => {
    if (error) return callback(error)
    if (list.length === 0 || list.some((entry) => !isPublicAddress(entry.address))) {
      const refused: NodeJS.ErrnoException = new Error(`${hostname} does not resolve to a public internet address`)
      refused.code = 'ENOTPUBLIC'
      return callback(refused)
    }
    if (options.all === true) callback(null, list)
    else callback(null, list[0].address, list[0].family)
  })
}

function classify(error: unknown): CallbackRefused {
  if (error instanceof CallbackRefused) return error
  const code = (error as NodeJS.ErrnoException | null)?.code ?? ''
  const message = error instanceof Error ? error.message : String(error)
  if (code === 'ENOTPUBLIC') return new CallbackRefused('not_public', message)
  if (code === 'ETIMEDOUT' || code === 'ESOCKETTIMEDOUT') return new CallbackRefused('timeout', message)
  if (/^(ERR_TLS|ERR_SSL|CERT_|UNABLE_TO|DEPTH_ZERO|SELF_SIGNED|HOSTNAME_MISMATCH)/.test(code) || code === 'ERR_TLS_CERT_ALTNAME_INVALID') {
    return new CallbackRefused('tls_error', message)
  }
  return new CallbackRefused('connection_refused', message)
}

/**
 * The real poster: HTTPS to a public address, nothing followed, ten seconds in all.
 */
export const publicHttpsPost: CallbackPost = (raw, headers, body) =>
  new Promise<CallbackAnswer>((resolve, reject) => {
    const problem = callbackUrlProblem(raw)
    if (problem !== null) return reject(new CallbackRefused('not_public', problem))
    const url = new URL(raw)
    const host = url.hostname.replace(/^\[|\]$/g, '')
    let settled = false
    const finish = (outcome: { answer: CallbackAnswer } | { error: unknown }): void => {
      if (settled) return
      settled = true
      clearTimeout(deadline)
      if ('answer' in outcome) resolve(outcome.answer)
      else reject(classify(outcome.error))
    }
    const request = httpsRequest(
      {
        protocol: 'https:',
        hostname: host,
        port: url.port === '' ? 443 : Number(url.port),
        path: `${url.pathname}${url.search}`,
        method: 'POST',
        headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body), ...headers },
        // An IP literal is checked above and never reaches `lookup`; a name is
        // resolved here and connected to only if every answer is public.
        lookup: publicLookup as never,
        ...(isIP(host) === 0 ? { servername: host } : {}),
        // A fresh connection per post: a kept-alive socket would skip the
        // lookup, and these are rare enough that reuse buys nothing.
        agent: false,
      },
      (response) => {
        const chunks: Buffer[] = []
        let size = 0
        response.on('data', (chunk: Buffer) => {
          size += chunk.length
          if (size <= MAX_ANSWER_BYTES) chunks.push(chunk)
        })
        response.on('end', () =>
          finish({ answer: { status: response.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') } }),
        )
        response.on('error', (error) => finish({ error }))
      },
    )
    const deadline = setTimeout(() => {
      request.destroy(new CallbackRefused('timeout', `no answer within ${CALLBACK_TIMEOUT_MS / 1000} seconds`))
    }, CALLBACK_TIMEOUT_MS)
    deadline.unref?.()
    request.on('error', (error) => finish({ error }))
    request.end(body)
  })
