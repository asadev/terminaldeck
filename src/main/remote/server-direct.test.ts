import { afterEach, describe, expect, it, vi } from 'vitest'
import { RTCPeerConnection } from 'werift'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createRelayClient } from './relay-client'
import { loadHostIdentity } from './host-identity'
import { ServerDirectTurn, type IceServer } from './server-direct-turn'
import { LINK_LIMIT, LinkJoiner, SERVER_BLOCKED, ServerDirectLink, linkBind, linkFingerprint, linkFrame, linkPackets, usableLinkCandidate, validLinkAnswer } from './server-direct'

const binding = Buffer.from(Array.from({ length: 32 }, (_, index) => index + 1))
const cleanups: (() => void | Promise<void>)[] = []
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup() })

function setup(options: { timeout?: number; forge?: boolean; noAnswer?: boolean; ice?: IceServer[]; policy?: 'all' | 'relay'; serversReady?: Promise<IceServer[]> } = {}) {
  const relay: string[] = []
  const app: string[] = []
  const client = new RTCPeerConnection({ iceServers: options.ice ?? [], iceUseTcp: false, iceTransportPolicy: options.policy ?? 'all', maxMessageSize: LINK_LIMIT.packet })
  const channels = ['td.rt', 'td.rel', 'td.ctl'].map((label, index) => client.createDataChannel(label,
    { id: index + 1, ordered: true, negotiated: true, ...(index === 0 ? { maxPacketLifeTime: 150 } : {}) }))
  const joiner = new LinkJoiner()
  const messages: string[] = []
  channels[2].onMessage.subscribe(data => {
    if (typeof data === 'string') throw new Error('Host sent text rather than binary')
    const text = joiner.take(data)
    if (text) messages.push(text)
  })
  let closed = 0
  let error: unknown
  let signals = Promise.resolve()
  const host = new ServerDirectLink({
    binding, servers: () => options.serversReady ?? Promise.resolve(options.ice ?? []), retain: vi.fn(), release: vi.fn(), onClosed: vi.fn(), policy: options.policy,
    offerTimeoutMs: options.timeout ?? 10_000,
    relay: { send(text) {
      relay.push(text)
      const frame = linkFrame(text)
      signals = signals.then(async () => {
        if (frame?.op === 'offer' && !options.noAnswer) {
          await client.setRemoteDescription({ type: 'offer', sdp: String(frame.sdp) })
          const answer = await client.createAnswer()
          const applying = client.setLocalDescription(answer)
          const fp = linkFingerprint(answer.sdp)!
          host.receiveRelay(JSON.stringify({ t: 'link.peer', op: 'answer', sdp: answer.sdp, fp,
            bind: options.forge ? Buffer.alloc(32).toString('base64') : linkBind(binding, 'client', fp) }))
          await applying
        } else if (frame?.op === 'cand') {
          await client.addIceCandidate({ candidate: String(frame.c), sdpMid: String(frame.mid), sdpMLineIndex: Number(frame.idx) })
        }
      }).catch(reason => { error = reason })
    }, close() {} },
    handlers: { message(text) {
      app.push(text)
      if (linkFrame(text)?.t === 'hello') host.send(JSON.stringify({ t: 'welcome', protocol: 1, deviceId: 'test-device', capabilities: ['sessions'] }))
      else host.send(text)
    }, closed() { closed++ } }
  })
  client.onIceCandidate.subscribe(candidate => {
    if (candidate) host.receiveRelay(JSON.stringify({ t: 'link.peer', op: 'cand', c: candidate.candidate,
      mid: candidate.sdpMid ?? '0', idx: candidate.sdpMLineIndex ?? 0 }))
  })
  cleanups.push(async () => { host.close(1000); await client.close(); await signals })
  const hello = () => host.receiveRelay('{"t":"hello","capabilities":["link.dc2","link.only"]}')
  return { host, client, channels, relay, messages, app, hello, closed: () => closed, error: () => error }
}

describe('server direct bounds', () => {
  it('matches both fingerprint binding vectors', () => {
    expect(linkBind(binding, 'host', 'sha-256 AA:BB')).toBe('scKcVc9ozTpB99xM6cQvWCtHQ7CxovvMN0YjRlukFdk=')
    expect(linkBind(binding, 'client', 'sha-256 AA:BB')).toBe('L1LUTQY2W5fwKdSXV5AvGovxRTLYtyUQSNUX7Pfj5f8=')
  })
  it('rejects forged, mixed and oversized fingerprints', () => {
    const fp = 'sha-256 AA:BB'
    const frame = { t: 'link.peer', sdp: `a=fingerprint:${fp}\r\n`, fp, bind: linkBind(binding, 'client', fp) }
    expect(validLinkAnswer(frame, binding)).toBe(true)
    expect(validLinkAnswer({ ...frame, bind: 'bad' }, binding)).toBe(false)
    expect(validLinkAnswer({ ...frame, sdp: frame.sdp + 'a=fingerprint:sha-256 CC:DD\r\n' }, binding)).toBe(false)
    expect(validLinkAnswer({ ...frame, sdp: 'x'.repeat(32_001) }, binding)).toBe(false)
  })
  it('rejects loopback, unspecified, multicast, ICE-TCP and malformed addresses', () => {
    const candidate = (ip: string, protocol = 'udp') => `candidate:1 1 ${protocol} 100 ${ip} 5000 typ host`
    for (const ip of ['127.0.0.1', '0.0.0.0', '224.1.2.3', '255.255.255.255', '::1', '0:0::1', '::', 'ff02::1', '::ffff:127.0.0.1', '::ffff:7f00:1']) expect(usableLinkCandidate(candidate(ip)), ip).toBe(false)
    expect(usableLinkCandidate(candidate('192.168.1.10'))).toBe(true)
    expect(usableLinkCandidate(candidate('fd00::1'))).toBe(true)
    expect(usableLinkCandidate(candidate('test.local'))).toBe(true)
    expect(usableLinkCandidate(candidate('example.com'))).toBe(false)
    expect(usableLinkCandidate(candidate('192.168.1.10', 'tcp'))).toBe(false)
    expect(usableLinkCandidate('x'.repeat(2001))).toBe(false)
  })
  it('joins the full four MiB, refuses oversize, interleaving and tiny-fragment floods', () => {
    const text = JSON.stringify({ t: 'test', data: 'a'.repeat(LINK_LIMIT.message - 22) })
    expect(Buffer.byteLength(text)).toBe(LINK_LIMIT.message)
    const joiner = new LinkJoiner()
    let whole: string | null = null
    for (const part of linkPackets(text)) whole = joiner.take(part)
    expect(whole).toBe(text)
    expect(() => linkPackets(text + ' ')).toThrow()
    expect(() => new LinkJoiner().take(Buffer.alloc(200_001))).toThrow()
    const mixed = new LinkJoiner()
    mixed.take(Buffer.from([1, 123]))
    expect(() => mixed.take(Buffer.from('{}'))).toThrow()
    const tiny = new LinkJoiner()
    for (let index = 0; index < 64; index++) tiny.take(Buffer.from([1, 123]))
    expect(() => tiny.take(Buffer.from([1, 123]))).toThrow()
  })
})

describe('server direct link', () => {
  it('carries fragmented packets above the library default in both directions', async () => {
    const f = setup()
    f.hello()
    await vi.waitFor(() => expect(f.host.isUp).toBe(true), { timeout: 10_000 })
    const text = JSON.stringify({ t: 'test', data: 'x'.repeat(600_000) })
    for (const packet of linkPackets(text)) f.channels[2].send(packet)
    await vi.waitFor(() => expect(f.messages).toContain(text), { timeout: 10_000 })
    expect(f.app).toContain(text)
    expect(f.relay.every(value => ['welcome', 'link.peer', 'link.moved'].includes(linkFrame(value)?.t ?? ''))).toBe(true)
  }, 20_000)

  it('starts its deadline at the offer after TURN is ready', async () => {
    let supply!: (ice: IceServer[]) => void
    const serversReady = new Promise<IceServer[]>(resolve => { supply = resolve })
    const f = setup({ timeout: 75, noAnswer: true, serversReady })
    f.hello()
    await new Promise(resolve => setTimeout(resolve, 100))
    expect(f.closed()).toBe(0)
    expect(f.relay.some(text => linkFrame(text)?.op === 'offer')).toBe(false)
    supply([])
    await vi.waitFor(() => expect(f.closed()).toBe(1))
    expect(f.relay.some(text => linkFrame(text)?.op === 'offer')).toBe(true)
  })

  it('queues all data, opens all three lanes, carries ordered data, survives relay loss and fail-stops on drop', async () => {
    const f = setup()
    f.hello()
    for (let index = 0; index < 300; index++) f.host.send(JSON.stringify({ t: 'test', index }))
    await vi.waitFor(() => { expect(f.error()).toBeUndefined(); expect(f.host.isUp).toBe(true); expect(f.messages).toHaveLength(300) }, { timeout: 12_000 })
    expect(f.messages.map(text => linkFrame(text)?.index)).toEqual(Array.from({ length: 300 }, (_, index) => index))
    expect(f.relay.map(text => linkFrame(text)?.t).every(type => ['welcome', 'link.peer', 'link.moved'].includes(String(type)))).toBe(true)
    expect(f.host.relayClosed()).toBe(true)
    const before = f.relay.length
    for (const packet of linkPackets('{"t":"ping"}')) f.channels[2].send(packet)
    await vi.waitFor(() => expect(f.messages.at(-1)).toBe('{"t":"ping"}'))
    expect(f.relay).toHaveLength(before)
    f.channels[2].close()
    await vi.waitFor(() => expect(f.closed()).toBe(1))
  }, 20_000)

  it('refuses a forged answer', async () => {
    const f = setup({ forge: true })
    f.hello()
    await vi.waitFor(() => expect(f.closed()).toBe(1), { timeout: 10_000 })
    expect(f.host.isUp).toBe(false)
    expect(f.messages).toHaveLength(0)
  }, 15_000)

  it('ends a blocked link without sending queued data through the relay', async () => {
    const f = setup({ timeout: 75, noAnswer: true })
    f.hello()
    f.host.send('{"t":"sessions","sessions":[]}')
    await vi.waitFor(() => expect(f.closed()).toBe(1))
    expect(f.relay.some(text => linkFrame(text)?.t === 'sessions')).toBe(false)
    expect(SERVER_BLOCKED).toBe("Can't reach your server — this network blocks the direct connection.")
  })

  it('refuses old clients and business data on the relay', async () => {
    const old = setup()
    old.host.receiveRelay('{"t":"hello","capabilities":[]}')
    expect(old.closed()).toBe(1)
    expect(linkFrame(old.relay[0])?.code).toBe('version')
    const f = setup({ noAnswer: true })
    f.hello()
    f.host.receiveRelay('{"t":"input","data":"never run this"}')
    expect(f.closed()).toBe(1)
    expect(f.app.map(text => linkFrame(text)?.t)).toEqual(['hello'])
  })

  it('bounds queued data before the link opens', () => {
    const f = setup({ noAnswer: true })
    f.hello()
    f.host.send(JSON.stringify({ t: 'test', data: 'x'.repeat(LINK_LIMIT.message) }))
    expect(f.closed()).toBe(1)
  })
})

// Opt-in uses a brand-new relay identity and per-test device. No installed app, key or session is read.
describe.runIf(process.env.SERVER_DIRECT_LIVE_TURN === '1')('server direct Cloudflare TURN', () => {
  it('exchanges binary data with both ends forced through TURN over UDP, TCP and TLS', async () => {
    const state = mkdtempSync(join(tmpdir(), 'server-direct-28-turn-'))
    const identity = loadHostIdentity(state)
    const relay = createRelayClient({ url: 'wss://relay.terminaldeck.dev', identity, isKnownDevice: () => false, watchdogMs: 0 })
    const turn = new ServerDirectTurn('wss://relay.terminaldeck.dev', identity.hostSecret, () => relay.state().connected)
    cleanups.push(async () => { await turn.stop(); await relay.stop(); rmSync(state, { recursive: true, force: true }) })
    relay.start(() => false)
    await vi.waitFor(() => expect(relay.state().connected).toBe(true), { timeout: 25_000 })
    turn.retain('server-direct-28-test')
    const ice = await turn.servers('server-direct-28-test')
    for (const protocol of ['udp', 'tcp', 'tls']) {
      const picked = ice.map(server => ({ ...server, urls: server.urls.filter(url => protocol === 'tls'
        ? url.startsWith('turns:') : url.startsWith('turn:') && (protocol === 'tcp' ? url.includes('transport=tcp') : !url.includes('transport=tcp'))) }))
        .filter(server => server.urls.length > 0)
      expect(picked.length, `Worker must supply TURN ${protocol}`).toBeGreaterThan(0)
      const f = setup({ ice: picked, policy: 'relay', timeout: 30_000 })
      f.hello()
      await vi.waitFor(() => { expect(f.error()).toBeUndefined(); expect(f.host.isUp, protocol).toBe(true) }, { timeout: 30_000 })
      for (const packet of linkPackets(JSON.stringify({ t: 'ping', protocol }))) f.channels[2].send(packet)
      await vi.waitFor(() => expect(linkFrame(f.messages.at(-1) ?? '')?.protocol).toBe(protocol))
      expect(f.relay.every(text => ['welcome', 'link.peer', 'link.moved'].includes(linkFrame(text)?.t ?? ''))).toBe(true)
      f.host.close(1000)
      await f.client.close()
    }
  }, 130_000)
})
