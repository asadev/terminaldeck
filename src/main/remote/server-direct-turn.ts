export interface IceServer {
  urls: string[]
  username?: string
  credential?: string
}

interface Login {
  servers: IceServer[]
  expiresAtMs: number
  login: string
}

interface Device {
  links: number
  epoch: number
  issued: number
  cached?: Login
  pending?: Promise<Login | undefined>
  pendingEpoch?: number
  grace?: ReturnType<typeof setTimeout>
  retries: Set<ReturnType<typeof setTimeout>>
  withdrawing: Set<Promise<void>>
}

export interface ServerDirectTurnDependencies {
  fetch?: typeof fetch
  now?: () => number
  graceMs?: number
  timeoutMs?: number
  retryWaitsMs?: number[]
}

const STUN = 'stun:stun.cloudflare.com:3478'
const REUSE_MARGIN_MS = 10 * 60 * 1_000
const DEVICE_ID = /^[A-Za-z0-9_-]{1,64}$/
const LOGIN_ID = /^[0-9a-f]{32}$/

/** One TURN login per approved device; credentials never pass between devices. */
export class ServerDirectTurn {
  private readonly devices = new Map<string, Device>()
  private readonly request: typeof fetch
  private readonly now: () => number
  private readonly graceMs: number
  private readonly timeoutMs: number
  private readonly retryWaitsMs: number[]
  private readonly secret: string
  private stopped = false

  constructor(
    private readonly url: string,
    hostSecret: Buffer,
    private readonly connected: () => boolean,
    deps: ServerDirectTurnDependencies = {}
  ) {
    this.request = deps.fetch ?? fetch
    this.now = deps.now ?? Date.now
    this.graceMs = deps.graceMs ?? 2 * 60 * 1_000
    this.timeoutMs = deps.timeoutMs ?? 3_000
    this.retryWaitsMs = deps.retryWaitsMs ?? [5_000, 30_000, 120_000]
    this.secret = hostSecret.toString('base64url')
  }

  async servers(device: string): Promise<IceServer[]> {
    if (!DEVICE_ID.test(device) || this.stopped || !this.connected()) return this.stun()
    const row = this.device(device)
    const epoch = row.epoch
    // A force withdrawal must finish before a newly approved connection can mint its login.
    await Promise.all(row.withdrawing)
    if (this.stopped || epoch !== row.epoch || !this.connected()) return this.stun()
    if (row.cached && row.cached.expiresAtMs - this.now() > REUSE_MARGIN_MS) {
      return this.withStun(row.cached.servers)
    }
    if (row.pending) {
      const pendingEpoch = row.pendingEpoch
      const login = await row.pending
      if (this.stopped || epoch !== row.epoch) return this.stun()
      // An earlier ask withdrawn during flight finishes before its replacement starts.
      if (pendingEpoch !== epoch) return this.servers(device)
      return login ? this.withStun(login.servers) : this.stun()
    }
    this.clearRetries(row)
    row.issued += 1
    row.pendingEpoch = epoch
    const pending = this.ask(device, row, epoch)
    row.pending = pending
    try {
      const login = await pending
      return login ? this.withStun(login.servers) : this.stun()
    } finally {
      if (row.pending === pending) {
        row.pending = undefined
        row.pendingEpoch = undefined
      }
    }
  }

  retain(device: string): void {
    if (this.stopped || !DEVICE_ID.test(device)) return
    const row = this.device(device)
    row.links += 1
    if (row.grace) clearTimeout(row.grace)
    row.grace = undefined
  }

  async release(device: string, force = false): Promise<void> {
    if (!DEVICE_ID.test(device) || this.stopped) return
    const row = this.device(device)
    if (force) {
      row.epoch += 1
      row.links = 0
      row.cached = undefined
      if (row.grace) clearTimeout(row.grace)
      row.grace = undefined
      this.clearRetries(row)
      await this.withdraw(device, row, undefined)
      return
    }
    row.links = Math.max(0, row.links - 1)
    if (row.links || row.grace) return
    row.grace = setTimeout(() => {
      row.grace = undefined
      if (row.links || this.stopped) return
      row.epoch += 1
      const login = row.cached
      row.cached = undefined
      if (login) void this.withdraw(device, row, login.login)
    }, this.graceMs)
    row.grace.unref?.()
  }

  /** Await before closing the relay socket. Late mint replies are withdrawn by their own login id. */
  async stop(): Promise<void> {
    this.stopped = true
    const work: Promise<unknown>[] = []
    for (const [device, row] of this.devices) {
      row.epoch += 1
      if (row.grace) clearTimeout(row.grace)
      row.grace = undefined
      this.clearRetries(row)
      const held = row.cached
      row.cached = undefined
      if (held) work.push(this.withdraw(device, row, held.login, false))
      work.push(...row.withdrawing)
      if (row.pending) work.push(row.pending)
    }
    let timer: ReturnType<typeof setTimeout> | undefined
    await Promise.race([
      Promise.allSettled(work),
      new Promise<void>(resolve => { timer = setTimeout(resolve, this.timeoutMs) })
    ])
    if (timer) clearTimeout(timer)
  }

  private device(device: string): Device {
    let row = this.devices.get(device)
    if (!row) {
      row = { links: 0, epoch: 0, issued: 0, retries: new Set(), withdrawing: new Set() }
      this.devices.set(device, row)
    }
    return row
  }

  private async ask(device: string, row: Device, epoch: number): Promise<Login | undefined> {
    const response = await this.post('/v1/turn', { device, ttl: 3_600 }, async value => {
      const late = this.parseLogin(value, device)
      if (late) await this.withdraw(device, row, late.login, !this.stopped)
    })
    const login = this.parseLogin(response, device)
    if (!login) return undefined
    if (this.stopped || row.epoch !== epoch) {
      await this.withdraw(device, row, login.login, !this.stopped)
      return undefined
    }
    row.cached = login
    return login
  }

  private async withdraw(device: string, row: Device, login?: string, retry = true): Promise<void> {
    const issued = row.issued
    const attempt = async (index: number): Promise<void> => {
      const response = await this.post('/v1/turn/revoke', { device, ...(login ? { login } : {}) })
      if (this.object(response)?.ok === true || !retry || this.stopped || row.issued !== issued) return
      const wait = this.retryWaitsMs[index]
      if (wait === undefined) return
      const timer = setTimeout(() => {
        row.retries.delete(timer)
        if (row.issued === issued && !this.stopped) void this.withdrawRetry(row, () => attempt(index + 1))
      }, wait)
      timer.unref?.()
      row.retries.add(timer)
    }
    await this.withdrawRetry(row, () => attempt(0))
  }

  private async withdrawRetry(row: Device, operation: () => Promise<void>): Promise<void> {
    const running = operation()
    row.withdrawing.add(running)
    try { await running } finally { row.withdrawing.delete(running) }
  }

  private clearRetries(row: Device): void {
    for (const timer of row.retries) clearTimeout(timer)
    row.retries.clear()
  }

  private async post(path: string, body: Record<string, string | number>, late?: (value: unknown) => Promise<void>): Promise<unknown> {
    const abort = new AbortController()
    let timer: ReturnType<typeof setTimeout> | undefined
    let timedOut = false
    try {
      const target = new URL(this.url)
      target.protocol = target.protocol === 'ws:' || target.protocol === 'http:' ? 'http:' : 'https:'
      target.pathname = path
      target.search = ''
      target.hash = ''
      const request = this.request(target, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-deck-host-secret': this.secret },
        body: JSON.stringify(body),
        signal: abort.signal,
        redirect: 'error',
        credentials: 'omit'
      }).then(async response => {
        if (response.status !== 200) return undefined
        const value = await this.readResponse(response)
        if (timedOut) {
          await late?.(value)
          return undefined
        }
        return value
      }).catch(() => undefined)
      return await Promise.race([
        request,
        new Promise<undefined>(resolve => {
          timer = setTimeout(() => {
            timedOut = true
            abort.abort()
            resolve(undefined)
          }, this.timeoutMs)
          timer.unref?.()
        })
      ])
    } catch {
      return undefined
    } finally {
      if (timer) clearTimeout(timer)
    }
  }

  private parseLogin(value: unknown, device: string): Login | undefined {
    const body = this.object(value)
    if (!body || body.ok !== true || body.device !== device || typeof body.login !== 'string' || !LOGIN_ID.test(body.login)) return undefined
    if (!Array.isArray(body.iceServers)) return undefined
    const servers: IceServer[] = []
    for (const value of body.iceServers.slice(0, 8)) {
      const server = this.object(value)
      if (!server) continue
      const given: unknown[] = Array.isArray(server.urls) ? server.urls : [server.urls]
      const urls = given.filter((url): url is string => typeof url === 'string' && url.length <= 2_048 && /^(stun|turn|turns):/.test(url)).slice(0, 16)
      if (!urls.length) continue
      servers.push({ urls, ...(typeof server.username === 'string' ? { username: server.username } : {}), ...(typeof server.credential === 'string' ? { credential: server.credential } : {}) })
    }
    if (!servers.length || typeof body.expiresAtMs !== 'number' || !Number.isFinite(body.expiresAtMs) || body.expiresAtMs <= this.now()) return undefined
    return { servers, expiresAtMs: body.expiresAtMs, login: body.login }
  }

  private object(value: unknown): Record<string, unknown> | undefined {
    return typeof value === 'object' && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : undefined
  }

  private stun(): IceServer[] { return [{ urls: [STUN] }] }

  private withStun(servers: IceServer[]): IceServer[] {
    const copy = servers.slice(0, 8).map(server => ({ ...server, urls: [...server.urls] }))
    return copy.some(server => server.urls.includes(STUN)) ? copy : [...this.stun(), ...copy.slice(0, 7)]
  }

  private async readResponse(response: Response): Promise<unknown> {
    if (!response.body) return undefined
    const reader = response.body.getReader()
    const chunks: Uint8Array[] = []
    let bytes = 0
    while (true) {
      const part = await reader.read()
      if (part.done) break
      bytes += part.value.byteLength
      if (bytes > 65_536) {
        void reader.cancel().catch(() => {})
        return undefined
      }
      chunks.push(part.value)
    }
    return JSON.parse(Buffer.concat(chunks, bytes).toString('utf8')) as unknown
  }
}
