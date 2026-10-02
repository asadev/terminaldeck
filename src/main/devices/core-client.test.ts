import { mkdtempSync, rmSync } from 'node:fs'
import { createServer, type Server, type Socket } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { CoreClient, EngineError, PROTOCOL_VERSION } from './core-client'
import { encodeFrame, FRAME, FrameReader } from './frames'

/**
 * A fake engine on a real Unix socket.
 *
 * It speaks the protocol the way `simview-core` was measured to on this Mac:
 * the first request must be `hello` with the token, a screenshot is a response
 * followed by a separate PNG frame with no id, and a preview is JPEG frames
 * between responses. What it answers to each method is up to the test.
 */

interface Fake {
  path: string
  server: Server
  requests: Array<{ method: string; params: Record<string, unknown>; protocolVersion: unknown }>
  socket(): Socket
  close(): void
}

const TOKEN = 'a'.repeat(64)

function fakeEngine(answer: (method: string, params: Record<string, unknown>, socket: Socket, id: string) => void): Promise<Fake> {
  const folder = mkdtempSync(join(tmpdir(), 'tdsim-test-'))
  const path = join(folder, 'core.sock')
  const requests: Fake['requests'] = []
  let last: Socket | null = null
  const server = createServer((socket) => {
    last = socket
    const reader = new FrameReader()
    let authed = false
    socket.on('data', (chunk) => {
      for (const frame of reader.push(chunk)) {
        const request = JSON.parse(frame.payload.toString()) as {
          id: string
          method: string
          params: Record<string, unknown>
          protocolVersion: unknown
        }
        requests.push({ method: request.method, params: request.params, protocolVersion: request.protocolVersion })
        if (!authed) {
          if (request.method !== 'hello' || request.params.token !== TOKEN) {
            socket.destroy()
            return
          }
          authed = true
        }
        answer(request.method, request.params, socket, request.id)
      }
    })
  })
  return new Promise((resolve) => {
    server.listen(path, () =>
      resolve({
        path,
        server,
        requests,
        socket: () => last as Socket,
        close: () => {
          server.close()
          rmSync(folder, { recursive: true, force: true })
        },
      }),
    )
  })
}

function reply(socket: Socket, id: string, body: Record<string, unknown>): void {
  socket.write(encodeFrame(FRAME.response, Buffer.from(JSON.stringify({ id, ...body }))))
}

const HELLO = { protocolVersion: 4, codec: 'mjpeg', maxFrameRate: 30, server: 'fake', capabilities: {} }

let fake: Fake | null = null
let client: CoreClient | null = null
afterEach(async () => {
  await client?.close().catch(() => undefined)
  client = null
  fake?.close()
  fake = null
})

describe('talking to the device engine', () => {
  it('authenticates first, asking for JPEG pictures only', async () => {
    fake = await fakeEngine((method, _params, socket, id) => reply(socket, id, { result: method === 'hello' ? HELLO : {} }))
    client = await CoreClient.attach(fake.path, TOKEN, { maxWidth: 1600, maxHeight: 1600 })
    expect(fake.requests[0].method).toBe('hello')
    expect(fake.requests[0].protocolVersion).toBe(PROTOCOL_VERSION)
    expect(fake.requests[0].params).toMatchObject({ token: TOKEN, codecs: ['mjpeg'], maxWidth: 1600, maxHeight: 1600 })
  })

  it('pairs each answer with its own request, whatever order they come back in', async () => {
    const held: Array<() => void> = []
    fake = await fakeEngine((method, params, socket, id) => {
      if (method === 'hello') return reply(socket, id, { result: HELLO })
      held.push(() => reply(socket, id, { result: { echo: params.n } }))
      // Answer the second before the first.
      if (held.length === 2) {
        held[1]()
        held[0]()
      }
    })
    client = await CoreClient.attach(fake.path, TOKEN)
    const [a, b] = await Promise.all([client.request('one', { n: 1 }), client.request('two', { n: 2 })])
    expect(a).toEqual({ echo: 1 })
    expect(b).toEqual({ echo: 2 })
  })

  it('turns an engine refusal into an error that keeps its code', async () => {
    fake = await fakeEngine((method, _params, socket, id) => {
      if (method === 'hello') return reply(socket, id, { result: HELLO })
      reply(socket, id, { error: { code: 'DEVICE_NOT_AVAILABLE', message: 'Device is offline', recoverable: true } })
    })
    client = await CoreClient.attach(fake.path, TOKEN)
    const failure = await client.request('capture.start').catch((error: unknown) => error)
    expect(failure).toBeInstanceOf(EngineError)
    expect((failure as EngineError).code).toBe('DEVICE_NOT_AVAILABLE')
    expect((failure as EngineError).recoverable).toBe(true)
  })

  it('hands every JPEG to the listeners', async () => {
    fake = await fakeEngine((method, _params, socket, id) => {
      reply(socket, id, { result: method === 'hello' ? HELLO : { enabled: true } })
      if (method === 'capture.preview') {
        socket.write(encodeFrame(FRAME.jpeg, Buffer.from('frame-1')))
        socket.write(encodeFrame(FRAME.jpeg, Buffer.from('frame-2')))
      }
    })
    client = await CoreClient.attach(fake.path, TOKEN)
    const seen: string[] = []
    client.onJpeg((jpeg) => seen.push(jpeg.toString()))
    await client.request('capture.preview', { enabled: true })
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect(seen).toEqual(['frame-1', 'frame-2'])
  })

  it('matches a screenshot to the PNG that follows its answer, one at a time', async () => {
    let shots = 0
    fake = await fakeEngine((method, _params, socket, id) => {
      if (method === 'hello') return reply(socket, id, { result: HELLO })
      shots += 1
      const n = shots
      reply(socket, id, { result: { frameId: String(n), width: 100 * n, height: 200 * n, byteLength: 3 } })
      // The picture after the answer, in a separate write — the order the
      // engine uses, and the reason the two cannot be in flight together.
      setTimeout(() => socket.write(encodeFrame(FRAME.png, Buffer.from(`png-${n}`))), 10)
    })
    client = await CoreClient.attach(fake.path, TOKEN)
    const [first, second] = await Promise.all([client.screenshot(), client.screenshot()])
    expect(first.png.toString()).toBe('png-1')
    expect(first.width).toBe(100)
    expect(second.png.toString()).toBe('png-2')
    expect(second.height).toBe(400)
  })

  it('says it is closed, and fails what was waiting, when the engine goes away', async () => {
    fake = await fakeEngine((method, _params, socket, id) => {
      if (method === 'hello') return reply(socket, id, { result: HELLO })
      // Never answer; hang up instead.
      socket.destroy()
    })
    client = await CoreClient.attach(fake.path, TOKEN)
    const reasons: string[] = []
    client.onClose((reason) => reasons.push(reason))
    await expect(client.request('capture.start')).rejects.toThrow()
    expect(client.isClosed).toBe(true)
    expect(reasons).toHaveLength(1)
    await expect(client.request('anything')).rejects.toThrow(/not running/)
  })

  it('is refused by an engine given the wrong token', async () => {
    fake = await fakeEngine((method, _params, socket, id) => reply(socket, id, { result: method === 'hello' ? HELLO : {} }))
    await expect(CoreClient.attach(fake.path, 'b'.repeat(64))).rejects.toThrow()
  })
})
