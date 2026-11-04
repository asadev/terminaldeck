import { createHmac, timingSafeEqual } from 'node:crypto'
import { isIP } from 'node:net'
import { RTCPeerConnection, type RTCDataChannel } from 'werift'
import type { RemoteWire, WireHandlers } from './server'
import type { IceServer } from './server-direct-turn'

export const LINK_LIMIT = { message: 4 * 1024 * 1024, packet: 200_000, candidates: 32, sdp: 32_000 } as const
export const SERVER_BLOCKED = "Can't reach your server — this network blocks the direct connection."
type Frame = Record<string, unknown> & { t: string }
const relayOut = new Set(['welcome', 'enrolled', 'device.access', 'link.peer', 'link.moved'])

export function linkFrame(text: string): Frame | null {
  try {
    const value: unknown = JSON.parse(text)
    return value !== null && typeof value === 'object' && !Array.isArray(value) &&
      't' in value && typeof value.t === 'string' ? value as Frame : null
  } catch { return null }
}

export function linkFingerprint(sdp: string): string | null {
  const found = sdp.split(/\r?\n/).filter(line => line.startsWith('a=fingerprint:'))
    .map(line => line.slice(14).trim()).filter(value => /^sha-256 /i.test(value))
  return found.length > 0 && new Set(found.map(value => value.toLowerCase())).size === 1 ? found[0] : null
}

export function linkBind(binding: Buffer, role: 'host' | 'client', fp: string): string {
  return createHmac('sha256', binding).update(`td.link.v2|${role}|${fp}`).digest('base64')
}

export function validLinkAnswer(frame: Frame, binding: Buffer): frame is Frame & { sdp: string; fp: string } {
  if (typeof frame.sdp !== 'string' || Buffer.byteLength(frame.sdp) > LINK_LIMIT.sdp ||
      typeof frame.fp !== 'string' || Buffer.byteLength(frame.fp) > 200 || linkFingerprint(frame.sdp) !== frame.fp ||
      typeof frame.bind !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(frame.bind)) return false
  const expected = Buffer.from(linkBind(binding, 'client', frame.fp), 'base64')
  const given = Buffer.from(frame.bind, 'base64')
  return given.length === expected.length && timingSafeEqual(given, expected)
}

export function usableLinkCandidate(candidate: string): boolean {
  if (Buffer.byteLength(candidate) > 2000) return false
  const words = candidate.trim().split(/\s+/)
  if (words.length < 8 || words[2].toLowerCase() !== 'udp') return false
  let address = words[4].toLowerCase()
  if (isIP(address) === 4) {
    const octets = address.split('.').map(Number)
    return octets[0] !== 0 && octets[0] !== 127 && octets[0] < 224 && address !== '255.255.255.255'
  }
  if (isIP(address) === 6) {
    address = new URL(`http://[${address}]`).hostname.slice(1, -1)
    if (address.startsWith('::ffff:')) return usableLinkCandidate(candidate.replace(words[4], address.slice(7)))
    return address !== '::' && address !== '::1' && !address.startsWith('ff')
  }
  return address.length <= 255 && /^[a-z0-9.-]+\.local$/.test(address)
}

/** The contract's binary framing, bounded before allocating the joined message. */
export class LinkJoiner {
  private parts: Buffer[] = []
  private bytes = 0
  take(data: Buffer): string | null {
    if (!data.length || data.length > LINK_LIMIT.packet) throw new Error('Bad link packet')
    const tag = data[0]
    if (tag === 123 && this.bytes === 0) return data.toString('utf8')
    if ((tag !== 1 && tag !== 2) || data.length === 1) throw new Error('Bad link fragment')
    this.bytes += data.length - 1
    if (this.bytes > LINK_LIMIT.message || this.parts.length >= 64) throw new Error('Link message too large')
    this.parts.push(data.subarray(1))
    if (tag === 1) return null
    const text = Buffer.concat(this.parts, this.bytes).toString('utf8')
    this.parts = []
    this.bytes = 0
    return text
  }
}

export function linkPackets(text: string): Buffer[] {
  const data = Buffer.from(text)
  if (data.length > LINK_LIMIT.message) throw new Error('Link message too large')
  if (data.length <= LINK_LIMIT.packet) return [data]
  const parts: Buffer[] = []
  for (let at = 0; at < data.length; at += LINK_LIMIT.packet - 1) {
    const end = Math.min(data.length, at + LINK_LIMIT.packet - 1)
    parts.push(Buffer.concat([Buffer.from([end === data.length ? 2 : 1]), data.subarray(at, end)]))
  }
  return parts
}

export interface ServerLinkOptions {
  relay: RemoteWire
  handlers: WireHandlers
  binding: Buffer
  servers(device: string): Promise<IceServer[]>
  retain(device: string): void
  release(device: string, force: boolean): void
  onClosed(): void
  /** Test-only injection; production always uses all routes. */
  policy?: 'all' | 'relay'
  offerTimeoutMs?: number
}

/** One sealed connection. Business handlers never receive signalling or relay data. */
export class ServerDirectLink implements RemoteWire {
  private peer: RTCPeerConnection | null = null
  private channels: RTCDataChannel[] = []
  private waiting: string[] = []
  private waitingBytes = 0
  private candidates: { candidate: string; sdpMid: string; sdpMLineIndex: number }[] = []
  private candidateCount = 0
  private answered = false
  private answering = false
  private moved = false
  private ended = false
  private relayGone = false
  private device: string | null = null
  private hello = false
  private timer: ReturnType<typeof setTimeout> | null = null
  private disconnected: ReturnType<typeof setTimeout> | null = null
  private heartbeat: ReturnType<typeof setInterval> | null = null
  private lastReceived = Date.now()
  private signalOrder = Promise.resolve()
  constructor(private readonly options: ServerLinkOptions) {}

  get isUp(): boolean { return this.moved && !this.ended }

  send(text: string): void {
    if (this.ended) return
    const frame = linkFrame(text)
    if (!frame) return this.fail('Bad host message')
    if ((relayOut.has(frame.t) && !(frame.t === 'device.access' && this.moved)) || (!this.device && frame.t === 'error')) {
      if (frame.t === 'welcome' && this.hello && typeof frame.deviceId === 'string' &&
          Array.isArray(frame.capabilities) && frame.capabilities.length > 0) {
        frame.capabilities = [...new Set([...frame.capabilities, 'link.dc2', 'link.only'])]
        this.device = frame.deviceId
        this.options.retain(this.device)
        this.relay(JSON.stringify(frame))
        void this.offer().catch(() => this.fail(SERVER_BLOCKED))
        return
      }
      this.relay(text)
      return
    }
    if (!this.moved) {
      this.waitingBytes += Buffer.byteLength(text)
      if (this.waitingBytes > LINK_LIMIT.message) return this.fail('Link queue too large')
      this.waiting.push(text)
      return
    }
    this.write(text)
  }

  receiveRelay(text: string): void {
    if (this.ended) return
    const frame = linkFrame(text)
    if (!frame) return this.fail('Bad relay message')
    if (frame.t === 'link.peer') {
      this.signalOrder = this.signalOrder.then(() => this.signal(frame)).catch(() => this.fail('Bad link signal'))
      return
    }
    if (frame.t === 'link.moved') return
    if (this.device || (frame.t !== 'hello' && frame.t !== 'enroll')) return this.fail('Data refused on the relay')
    if (frame.t === 'hello') {
      if (!Array.isArray(frame.capabilities) || !frame.capabilities.includes('link.dc2')) {
        this.relay(JSON.stringify({ t: 'error', code: 'version', message: 'Update this app to connect to your server directly.' }))
        return this.close(1008, 'Update this app')
      }
      this.hello = true
    }
    this.options.handlers.message(text)
  }

  /** A relay reset leaves an established link and its session attachments alone. */
  relayClosed(): boolean {
    this.relayGone = true
    if (this.isUp) return true
    this.close(1001, SERVER_BLOCKED)
    return false
  }

  close(code: number, reason = 'The direct link ended.'): void {
    if (this.ended) return
    this.ended = true
    if (this.timer) clearTimeout(this.timer)
    if (this.disconnected) clearTimeout(this.disconnected)
    if (this.heartbeat) clearInterval(this.heartbeat)
    this.waiting = []
    this.candidates = []
    this.waitingBytes = 0
    void this.peer?.close().catch(() => undefined)
    if (this.device) this.options.release(this.device, /revok|access.*(off|changed)|unpair/.test(reason))
    this.options.relay.close(code, reason)
    this.options.handlers.closed()
    this.options.onClosed()
  }

  private relay(text: string): void { if (!this.relayGone) this.options.relay.send(text) }
  private fail(why: string): void {
    if (this.ended) return
    this.relay(JSON.stringify({ t: 'link.peer', op: 'end' }))
    this.close(1001, why)
  }

  private async offer(): Promise<void> {
    if (!this.device || this.peer || this.ended) return
    const ice = await this.options.servers(this.device)
    if (this.ended) return
    const peer = new RTCPeerConnection({ iceServers: ice, iceTransportPolicy: this.options.policy ?? 'all',
      iceUseTcp: false, bundlePolicy: 'max-bundle', maxMessageSize: LINK_LIMIT.packet })
    this.peer = peer
    this.channels = ['td.rt', 'td.rel', 'td.ctl'].map((label, index) => {
      const channel = peer.createDataChannel(label, { id: index + 1, negotiated: true, ordered: true,
        ...(index === 0 ? { maxPacketLifeTime: 150 } : {}) })
      const joiner = new LinkJoiner()
      channel.stateChange.subscribe(state => {
        if (state === 'open') this.opened()
        if (state === 'closed' || state === 'closing') this.fail('The direct link ended.')
      })
      channel.error.subscribe(() => this.fail('The direct link ended.'))
      channel.onMessage.subscribe(data => {
        if (index !== 2 || typeof data === 'string') return this.fail('Bad link lane')
        try {
          const text = joiner.take(data)
          if (text !== null) this.receiveLink(text)
        } catch { this.fail('Bad link message') }
      })
      return channel
    })
    peer.iceConnectionStateChange.subscribe(state => {
      if (this.disconnected) clearTimeout(this.disconnected)
      this.disconnected = null
      if (state === 'failed' || state === 'closed') this.fail('The direct link ended.')
      if (state === 'disconnected') {
        this.disconnected = setTimeout(() => this.fail('The direct link ended.'), 5000)
        this.disconnected.unref?.()
      }
    })
    peer.connectionStateChange.subscribe(state => {
      if (state === 'failed' || state === 'closed') this.fail('The direct link ended.')
    })
    peer.onIceCandidate.subscribe(candidate => {
      if (!candidate || !usableLinkCandidate(candidate.candidate)) return
      const frame = JSON.stringify({ t: 'link.peer', op: 'cand', c: candidate.candidate,
        mid: candidate.sdpMid ?? '0', idx: candidate.sdpMLineIndex ?? 0 })
      this.relay(frame)
      if (this.moved) this.write(frame)
    })
    const description = await peer.createOffer()
    if (this.ended) return
    const fp = linkFingerprint(description.sdp)
    if (!fp || Buffer.byteLength(description.sdp) > LINK_LIMIT.sdp) return this.fail('Bad local offer')
    // Set the offer before gathering finishes. Candidates trickle while TURN is connecting.
    const applying = peer.setLocalDescription(description)
    this.timer = setTimeout(() => this.fail(SERVER_BLOCKED), this.options.offerTimeoutMs ?? 10_000)
    this.timer.unref?.()
    this.relay(JSON.stringify({ t: 'link.peer', op: 'offer', sdp: description.sdp, fp,
      bind: linkBind(this.options.binding, 'host', fp), ice, policy: this.options.policy ?? 'all' }))
    await applying
  }

  private async signal(frame: Frame): Promise<void> {
    if (this.ended) return
    if (frame.op === 'end') return this.fail(SERVER_BLOCKED)
    if (frame.op === 'answer') {
      if (!this.peer || this.answered || this.answering || !validLinkAnswer(frame, this.options.binding)) return this.fail('Bad link answer')
      const lines = frame.sdp.split(/\r?\n/).filter(line => !line.startsWith('a=candidate:') || usableLinkCandidate(line.slice(2)))
      const embedded = lines.filter(line => line.startsWith('a=candidate:'))
      if (embedded.length + this.candidateCount > LINK_LIMIT.candidates) return this.fail('Bad link candidates')
      this.candidateCount += embedded.length
      this.answering = true
      await this.peer.setRemoteDescription({ type: 'answer', sdp: lines.join('\r\n') })
      this.answered = true
      for (const candidate of this.candidates) await this.peer.addIceCandidate(candidate)
      this.candidates = []
      return
    }
    if (frame.op !== 'cand') return this.fail('Bad link signal')
    if (typeof frame.c !== 'string' || (frame.mid !== undefined && frame.mid !== null && (typeof frame.mid !== 'string' || Buffer.byteLength(frame.mid) > 32)) ||
        !Number.isInteger(frame.idx) || (frame.idx as number) < 0 || (frame.idx as number) > 64) return this.fail('Bad link candidate')
    if (!usableLinkCandidate(frame.c)) return
    if (++this.candidateCount > LINK_LIMIT.candidates) return this.fail('Too many link candidates')
    const candidate = { candidate: frame.c, sdpMid: typeof frame.mid === 'string' ? frame.mid : '0', sdpMLineIndex: frame.idx as number }
    if (this.answered) await this.peer?.addIceCandidate(candidate)
    else this.candidates.push(candidate)
  }

  private opened(): void {
    if (this.ended || this.moved || this.channels.some(channel => channel.readyState !== 'open')) return
    this.moved = true
    if (this.timer) clearTimeout(this.timer)
    this.relay('{"t":"link.moved"}')
    const waiting = this.waiting
    this.waiting = []
    this.waitingBytes = 0
    for (const text of waiting) this.write(text)
    this.lastReceived = Date.now()
    this.heartbeat = setInterval(() => {
      if (Date.now() - this.lastReceived > 40_000) this.fail('The direct link stopped answering.')
    }, 10_000)
    this.heartbeat.unref?.()
  }

  private write(text: string): void {
    if (this.ended) return
    const frame = linkFrame(text)
    // TURN's transport is encoded in the relay candidate's priority, on either side (§6).
    const pair = this.peer?.sctpTransport?.dtlsTransport.iceTransport.connection.nominated
    const tcp = pair && [pair.localCandidate, pair.remoteCandidate].some(candidate =>
      candidate.type === 'relay' && (candidate.priority >>> 24) <= 1)
    const lane = frame?.t === 'sims.video' ? (tcp || frame.key === true || frame.still === true ? 1 : 0) : 2
    const channel = this.channels[lane]
    if (!channel || channel.readyState !== 'open') return this.fail('The direct link ended.')
    if (channel.bufferedAmount > (lane === 0 ? 1_500_000 : LINK_LIMIT.message)) {
      if (lane === 0) return
      return this.fail('The direct link is full')
    }
    try { for (const packet of linkPackets(text)) channel.send(packet) }
    catch { this.fail('The direct link ended.') }
  }

  private receiveLink(text: string): void {
    const frame = linkFrame(text)
    if (!frame) return this.fail('Bad link message')
    this.lastReceived = Date.now()
    if (frame.t === 'link.peer') {
      if (frame.op === 'cand' || frame.op === 'end') {
        this.signalOrder = this.signalOrder.then(() => this.signal(frame)).catch(() => this.fail('Bad link signal'))
      }
      return
    }
    if (frame.t.startsWith('link.') || frame.t === 'hello' || frame.t === 'enroll') return
    this.options.handlers.message(text)
  }
}
