import { timingSafeEqual } from 'node:crypto'
import { RTCPeerConnection, type RTCDataChannel } from 'werift'
import type { GuestChannel, GuestHandlers } from './machines/dial'
import type { IceServer } from './server-direct-turn'
import { LINK_LIMIT, LinkJoiner, linkBind, linkFingerprint, linkFrame, linkPackets, usableLinkCandidate } from './server-direct'

type Frame = NonNullable<ReturnType<typeof linkFrame>>
type Candidate = { candidate: string; sdpMid: string; sdpMLineIndex: number }

export interface ServerGuestOptions {
  relay: GuestChannel
  handlers: GuestHandlers
  binding: Buffer
  welcomeWaitMs?: number
  offerWaitMs?: number
  markerWaitMs?: number
}

/** A joining server uses the same authenticated answerer as phones and desktop guests. */
export class ServerDirectGuest implements GuestChannel {
  private active = false
  private welcomed = false
  private hostOnly = false
  private hostMoved = false
  private moved = false
  private ended = false
  private relayGone = false
  private peer: RTCPeerConnection | null = null
  private channels: RTCDataChannel[] = []
  private waiting: string[] = []
  private waitingBytes = 0
  private held: string[] = []
  private heldBytes = 0
  private candidates: Candidate[] = []
  private candidateCount = 0
  private remoteSet = false
  private policy = 'all'
  private timer: ReturnType<typeof setTimeout> | null = null
  private disconnected: ReturnType<typeof setTimeout> | null = null
  private heartbeat: ReturnType<typeof setInterval> | null = null
  private lastPong = Date.now()
  private pingAt = 0
  private pongTimer: ReturnType<typeof setTimeout> | null = null
  private ownCandidates = 0
  private pendingSignals = 0
  private holdTimer: ReturnType<typeof setTimeout> | null = null
  private noun = 'server'
  private get blocked(): string { return `Can't reach your ${this.noun} — this network blocks the direct connection.` }
  private signalOrder = Promise.resolve()

  constructor(private readonly options: ServerGuestOptions) {}
  get isUp(): boolean { return this.moved && !this.ended }
  get open(): boolean { return !this.ended && (this.isUp || this.options.relay.open) }

  send(text: string): void {
    if (this.ended) return
    const frame = linkFrame(text)
    if (!this.active) {
      if (frame?.t === 'hello') {
        this.active = true
        const caps = Array.isArray(frame.capabilities) ? frame.capabilities.filter((cap): cap is string => typeof cap === 'string') : []
        frame.capabilities = [...new Set([...caps, 'link.dc2', 'link.only'])]
        this.relay(JSON.stringify(frame))
      } else this.relay(text)
      return
    }
    if (!frame) return this.fail('Bad machine message')
    if (!this.moved) {
      const bytes = Buffer.byteLength(text)
      if (this.waiting.length >= 1024 || this.waitingBytes + bytes > LINK_LIMIT.message) return this.fail('Too much waited for the direct link.')
      this.waiting.push(text)
      this.waitingBytes += bytes
      return
    }
    this.write(text)
  }

  receiveRelay(text: string): void {
    if (this.ended) return
    if (!this.active) { this.options.handlers.message(text); return }
    const frame = linkFrame(text)
    if (!frame) return this.fail('Bad relay message')
    if (frame.t === 'link.peer') { this.queueSignal(frame); return }
    if (frame.t === 'link.moved') { this.hostMoved = true; this.releaseHeld(); return }
    if (frame.t === 'welcome' && !this.welcomed) {
      // Code redemption has no business channel: the caller saves the receipt and closes this socket.
      if (typeof frame.token === 'string') { this.options.handlers.message(text); return }
      this.noun = frame.hostKind === 'headless' || frame.hostPlatform === 'linux' ? 'server' :
        frame.hostPlatform === 'win32' ? 'PC' : frame.hostPlatform === 'darwin' ? 'Mac' : 'machine'
      const caps = Array.isArray(frame.capabilities) ? frame.capabilities : []
      if (!caps.includes('link.dc2') && !caps.includes('link.only')) return this.close(`Update that ${this.noun} to connect directly.`)
      this.welcomed = true
      this.hostOnly = caps.includes('link.only')
      if (caps.includes('link.dc2')) this.deadline(this.options.welcomeWaitMs ?? 12_000)
      this.options.handlers.message(text)
      return
    }
    if ((!this.welcomed && (frame.t === 'error' || frame.t === 'enrolled')) || (!this.moved && frame.t === 'device.access')) {
      this.options.handlers.message(text)
      return
    }
    // An old dc2 host may finish its own pre-marker messages on the relay (§11.5).
    if (this.welcomed && !this.hostOnly && !this.hostMoved) this.options.handlers.message(text)
  }

  relayClosed(reason: string): void {
    this.relayGone = true
    if (this.ended || this.isUp) return
    this.close(this.active && this.welcomed ? this.blocked : reason)
  }

  close(reason = 'The direct link ended.'): void {
    if (this.ended) return
    this.ended = true
    if (this.timer) clearTimeout(this.timer)
    if (this.disconnected) clearTimeout(this.disconnected)
    if (this.heartbeat) clearInterval(this.heartbeat)
    if (this.pongTimer) clearTimeout(this.pongTimer)
    if (this.holdTimer) clearTimeout(this.holdTimer)
    this.waiting = []; this.held = []; this.candidates = []
    this.waitingBytes = 0; this.heldBytes = 0
    void this.peer?.close().catch(() => undefined)
    this.options.relay.close()
    this.options.handlers.closed(reason)
  }

  private relay(text: string): void { if (!this.relayGone) this.options.relay.send(text) }
  private fail(reason: string): void {
    if (this.ended) return
    if (this.active) this.relay('{"t":"link.peer","op":"end"}')
    this.close(reason)
  }
  private deadline(ms: number): void {
    if (this.timer) clearTimeout(this.timer)
    this.timer = setTimeout(() => this.fail(this.blocked), ms)
    this.timer.unref?.()
  }
  private queueSignal(frame: Frame): void {
    if (++this.pendingSignals > 64) return this.fail(this.blocked)
    this.signalOrder = this.signalOrder.then(() => this.signal(frame)).catch(() => this.fail(this.blocked))
      .finally(() => { this.pendingSignals-- })
  }

  private async signal(frame: Frame): Promise<void> {
    if (this.ended) return
    if (frame.op === 'end') return this.fail(this.moved ? 'The direct link ended.' : this.blocked)
    if (frame.op === 'offer') {
      if (!this.welcomed || this.peer || !validServerOffer(frame, this.options.binding)) return this.fail(this.blocked)
      if (frame.policy !== undefined && !['all', 'nohost', 'relay'].includes(String(frame.policy))) return this.fail(this.blocked)
      this.policy = typeof frame.policy === 'string' ? frame.policy : 'all'
      this.deadline(this.options.offerWaitMs ?? 15_000)
      const ice = readServerIce(frame.ice)
      if (ice === null) return this.fail(this.blocked)
      const peer = new RTCPeerConnection({ iceServers: ice, iceTransportPolicy: this.policy === 'relay' ? 'relay' : 'all',
        iceUseTcp: false, bundlePolicy: 'max-bundle', maxMessageSize: LINK_LIMIT.packet })
      this.peer = peer
      this.channels = ['td.rt', 'td.rel', 'td.ctl'].map((label, index) => {
        const channel = peer.createDataChannel(label, { id: index + 1, negotiated: true, ordered: true,
          ...(index === 0 ? { maxPacketLifeTime: 150 } : {}) })
        const joiner = new LinkJoiner()
        channel.stateChange.subscribe(state => {
          if (state === 'open' && index === 2) this.opened()
          if (state === 'closed' || state === 'closing') this.fail(this.moved ? 'The direct link ended.' : this.blocked)
        })
        channel.error.subscribe(() => this.fail(this.moved ? 'The direct link ended.' : this.blocked))
        channel.onMessage.subscribe(data => {
          if (typeof data === 'string') return this.fail('Bad link packet')
          try {
            const text = joiner.take(data)
            if (text !== null) this.receiveLink(text, index)
          } catch { this.fail('Bad link message') }
        })
        return channel
      })
      peer.iceConnectionStateChange.subscribe(state => {
        if (this.disconnected) clearTimeout(this.disconnected)
        this.disconnected = null
        if (state === 'closed' || state === 'failed') this.fail(this.moved ? 'The direct link ended.' : this.blocked)
        if (state === 'disconnected') {
          this.disconnected = setTimeout(() => this.fail('The direct link ended.'), 5000)
          this.disconnected.unref?.()
        }
      })
      peer.connectionStateChange.subscribe(state => {
        if (state === 'closed' || state === 'failed') this.fail(this.moved ? 'The direct link ended.' : this.blocked)
      })
      let sentAnswer = false
      const early: string[] = []
      peer.onIceCandidate.subscribe(candidate => {
        if (!candidate || !this.acceptCandidate(candidate.candidate) || ++this.ownCandidates > LINK_LIMIT.candidates) return
        const text = JSON.stringify({ t: 'link.peer', op: 'cand', c: candidate.candidate,
          mid: candidate.sdpMid ?? '0', idx: candidate.sdpMLineIndex ?? 0 })
        if (!sentAnswer) { if (early.length < LINK_LIMIT.candidates) early.push(text); return }
        this.relay(text)
        if (this.moved && this.hostOnly) this.write(text)
      })
      const lines = frame.sdp.split(/\r?\n/).filter(line => !line.startsWith('a=candidate:') || this.acceptCandidate(line.slice(2)))
      const count = lines.filter(line => line.startsWith('a=candidate:')).length
      if (count + this.candidateCount > LINK_LIMIT.candidates) return this.fail(this.blocked)
      this.candidateCount += count
      await peer.setRemoteDescription({ type: 'offer', sdp: lines.join('\r\n') })
      if (this.ended) return
      this.remoteSet = true
      for (const candidate of this.candidates) await peer.addIceCandidate(candidate)
      this.candidates = []
      const answer = await peer.createAnswer()
      const fp = linkFingerprint(answer.sdp)
      if (!fp || Buffer.byteLength(answer.sdp) > LINK_LIMIT.sdp || this.ended) return this.fail(this.blocked)
      const applying = peer.setLocalDescription(answer)
      this.relay(JSON.stringify({ t: 'link.peer', op: 'answer', sdp: answer.sdp, fp,
        bind: linkBind(this.options.binding, 'client', fp) }))
      sentAnswer = true
      for (const text of early) this.relay(text)
      void applying.catch(() => this.fail(this.blocked))
      return
    }
    if (frame.op !== 'cand' || typeof frame.c !== 'string' ||
        frame.mid !== undefined && frame.mid !== null && (typeof frame.mid !== 'string' || Buffer.byteLength(frame.mid) > 32) ||
        !Number.isInteger(frame.idx) || (frame.idx as number) < 0 || (frame.idx as number) > 64) return this.fail(this.blocked)
    if (!this.acceptCandidate(frame.c)) return
    if (++this.candidateCount > LINK_LIMIT.candidates) return this.fail(this.blocked)
    const candidate = { candidate: frame.c, sdpMid: typeof frame.mid === 'string' ? frame.mid : '0', sdpMLineIndex: frame.idx as number }
    if (this.remoteSet) await this.peer?.addIceCandidate(candidate)
    else this.candidates.push(candidate)
  }

  private acceptCandidate(candidate: string): boolean {
    return usableLinkCandidate(candidate) && !(this.policy === 'nohost' && / typ host(?: |$)/.test(candidate)) &&
      !(this.policy === 'relay' && !/ typ relay(?: |$)/.test(candidate))
  }

  private opened(): void {
    if (this.ended || this.moved) return
    this.moved = true
    if (this.timer) clearTimeout(this.timer)
    this.relay('{"t":"link.moved"}')
    const waiting = this.waiting
    this.waiting = []; this.waitingBytes = 0
    for (const text of waiting) this.write(text)
    this.releaseHeld()
    if (!this.hostOnly && !this.hostMoved) this.startHoldTimer()
    this.lastPong = Date.now()
    this.heartbeat = setInterval(() => {
      this.pingAt = Date.now()
      this.write('{"t":"ping"}')
      this.pongTimer = setTimeout(() => {
        if (this.lastPong < this.pingAt) this.fail('The direct link stopped answering.')
      }, 10_000)
      this.pongTimer.unref?.()
    }, 25_000)
    this.heartbeat.unref?.()
  }

  private write(text: string): void {
    if (this.ended) return
    const channel = this.channels[2]
    if (channel?.readyState !== 'open' || channel.bufferedAmount > LINK_LIMIT.message) return this.fail('The direct link ended.')
    try { for (const packet of linkPackets(text)) channel.send(packet) }
    catch { this.fail('The direct link ended.') }
  }

  private receiveLink(text: string, lane: number): void {
    if (this.ended) return
    const frame = linkFrame(text)
    if (!frame) return this.fail('Bad link message')
    if (lane !== 2) { if (frame.t === 'sims.video') this.options.handlers.message(text); return }
    if (frame.t.startsWith('link.')) {
      if (this.hostOnly && frame.t === 'link.peer' && (frame.op === 'cand' || frame.op === 'end')) this.queueSignal(frame)
      return
    }
    if (frame.t === 'pong') {
      this.lastPong = Date.now()
      if (this.pongTimer) clearTimeout(this.pongTimer)
      this.pongTimer = null
      this.options.handlers.message(text)
      return
    }
    if (!this.hostOnly && !this.hostMoved) {
      const bytes = Buffer.byteLength(text)
      if (this.held.length >= 1024 || this.heldBytes + bytes > LINK_LIMIT.message) return this.fail('Too much waited for the direct link.')
      this.held.push(text); this.heldBytes += bytes
      this.startHoldTimer()
      return
    }
    this.options.handlers.message(text)
  }

  private startHoldTimer(): void {
    if (this.holdTimer) return
    this.holdTimer = setTimeout(() => this.fail('The other machine did not finish opening its direct link.'), this.options.markerWaitMs ?? 5000)
    this.holdTimer.unref?.()
  }

  private releaseHeld(): void {
    if (!this.moved || !this.hostMoved) return
    if (this.holdTimer) clearTimeout(this.holdTimer)
    this.holdTimer = null
    const held = this.held
    this.held = []; this.heldBytes = 0
    for (const text of held) this.options.handlers.message(text)
  }
}

export function validServerOffer(frame: Frame, binding: Buffer): frame is Frame & { sdp: string; fp: string } {
  if (typeof frame.sdp !== 'string' || Buffer.byteLength(frame.sdp) > LINK_LIMIT.sdp ||
      typeof frame.fp !== 'string' || Buffer.byteLength(frame.fp) > 200 || linkFingerprint(frame.sdp) !== frame.fp ||
      typeof frame.bind !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(frame.bind)) return false
  const expected = Buffer.from(linkBind(binding, 'host', frame.fp), 'base64')
  const given = Buffer.from(frame.bind, 'base64')
  return given.length === expected.length && timingSafeEqual(given, expected)
}

export function readServerIce(value: unknown): IceServer[] | null {
  if (!Array.isArray(value) || value.length > 8) return null
  const servers: IceServer[] = []
  for (const row of value) {
    if (row === null || typeof row !== 'object' || !('urls' in row)) return null
    const item = row as Record<string, unknown>
    const urls = typeof item.urls === 'string' ? [item.urls] : item.urls
    if (!Array.isArray(urls) || urls.length < 1 || urls.length > 8 ||
        !urls.every((url): url is string => typeof url === 'string' && Buffer.byteLength(url) <= 2048 && /^(stun|stuns|turn|turns):/.test(url))) return null
    if (item.username !== undefined && (typeof item.username !== 'string' || Buffer.byteLength(item.username) > 256) ||
        item.credential !== undefined && (typeof item.credential !== 'string' || Buffer.byteLength(item.credential) > 256)) return null
    servers.push({ urls, ...(typeof item.username === 'string' ? { username: item.username } : {}),
      ...(typeof item.credential === 'string' ? { credential: item.credential } : {}) })
  }
  return servers
}
