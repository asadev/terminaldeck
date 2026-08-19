import { describe, expect, it, vi } from 'vitest'
import {
  askWhetherItForwards,
  createSshTunnelHost,
  deadPort,
  whyNot,
  WILL_NOT_FORWARD,
  type ForwardChannel,
  type ForwardResult,
  type Forwarder,
} from './forward'
import type { ServerMessage } from '../remote/protocol'

/**
 * The half of the tunnel that stands where a second copy of this app would.
 *
 * Everything here is asserted against the **frames**, not against a socket,
 * because the frames are the contract: `localhost-reach.ts` is the other half
 * and it cannot tell a relay from an SSH connection. A change that broke this
 * conversation would leave a browser tab loading forever with every type
 * checking clean, which is the failure this file exists to make loud.
 */

/** A channel that records what was done to it, in the order it was done. */
function fakeChannel() {
  const listeners = new Map<string, ((value: never) => void)[]>()
  const written: Buffer[] = []
  const acts: string[] = []
  const channel: ForwardChannel = {
    on(event: string, listener: (value: never) => void) {
      const list = listeners.get(event) ?? []
      list.push(listener)
      listeners.set(event, list)
      return channel
    },
    write(chunk: Buffer, callback: () => void) {
      written.push(chunk)
      callback()
      return true
    },
    end: () => void acts.push('end'),
    destroy: () => void acts.push('destroy'),
    pause: () => void acts.push('pause'),
    resume: () => void acts.push('resume'),
  }
  return {
    channel,
    written,
    acts,
    emit(event: string, value?: unknown): void {
      for (const listener of listeners.get(event) ?? []) (listener as (v: unknown) => void)(value)
    },
  }
}

function hostWith(forward: Forwarder) {
  const sent: ServerMessage[] = []
  const host = createSshTunnelHost({ forward, send: (message) => void sent.push(message), name: 'the box' })
  return { host, sent }
}

const opens = (channel: ForwardChannel): ForwardResult => ({ ok: true, channel })

describe('picking a port with nothing on it', () => {
  it('never picks one the server said is listening', () => {
    expect(deadPort([1, 2, 3])).toBe(4)
    expect(deadPort([])).toBe(1)
    // The real answer from the test box: nothing there binds port 1, so the
    // question costs no running service a single byte.
    expect(deadPort([22, 80, 443, 6001, 6002, 8000, 8080, 53])).toBe(1)
  })
})

describe('asking a server whether it will forward at all', () => {
  it('reads a refused connection as yes — the server tried, which is the question', async () => {
    const forward = vi.fn<Forwarder>(async () => ({
      ok: false,
      refusal: 'unreachable',
      message: 'Connection refused',
    }))
    expect(await askWhetherItForwards(forward)).toEqual({ known: 'yes' })
    // Measured against the real box: `forwardOut` to 127.0.0.1:1 answers
    // reason 2, "Connection refused". That is a server that forwards.
    expect(forward).toHaveBeenCalledWith('127.0.0.1', 1)
  })

  it('reads an opened channel as yes, and does not leave it open', async () => {
    const { channel, acts } = fakeChannel()
    expect(await askWhetherItForwards(async () => opens(channel))).toEqual({ known: 'yes' })
    expect(acts).toEqual(['destroy'])
  })

  it('says no when the server refuses both the empty port and a real one', async () => {
    const forward = vi.fn<Forwarder>(async () => ({
      ok: false,
      refusal: 'prohibited',
      message: 'administratively prohibited',
    }))
    expect(await askWhetherItForwards(forward, { listening: [8000] })).toEqual({
      known: 'no',
      why: WILL_NOT_FORWARD,
    })
  })

  /**
   * The trap that makes one probe not enough.
   *
   * `PermitOpen` names an allow-list, and on such a server every address
   * outside it is refused with the same code as `AllowTcpForwarding no`. A
   * single probe of an empty port would therefore report "this server refuses"
   * about a server that forwards the one port somebody actually wants, and the
   * row would be greyed out over a working feature.
   */
  it('does not believe a refusal about an empty port when a real one is allowed', async () => {
    const { channel } = fakeChannel()
    const asked: number[] = []
    const forward: Forwarder = async (_host, port) => {
      asked.push(port)
      return port === 8000
        ? opens(channel)
        : { ok: false, refusal: 'prohibited', message: 'administratively prohibited' }
    }
    expect(await askWhetherItForwards(forward, { listening: [8000] })).toEqual({ known: 'yes' })
    expect(asked).toEqual([1, 8000])
  })

  it('asks the second question only of a port the server said is listening', async () => {
    const asked: number[] = []
    const forward: Forwarder = async (_host, port) => {
      asked.push(port)
      return { ok: false, refusal: 'prohibited', message: 'no' }
    }
    await askWhetherItForwards(forward, { listening: [] })
    // One question, because there is no real port to ask a fair second one
    // about. Never a made-up port: that would be this app scanning somebody's
    // server to find out what it may open.
    expect(asked).toEqual([1])
  })

  it('answers cannot — not no — when the reason could not be read', async () => {
    const answer = await askWhetherItForwards(async () => ({
      ok: false,
      refusal: 'unknown',
      message: 'That connection is gone.',
    }))
    // The third state, kept. `no` disables the row; `cannot` does not, because
    // not knowing whether a server refuses is not knowing that it does.
    expect(answer).toEqual({ known: 'cannot', why: 'That connection is gone.' })
  })
})

describe('opening a port', () => {
  it('proves the address before saying it is open, and tries both loopbacks', async () => {
    const { channel, acts } = fakeChannel()
    const asked: string[] = []
    const { host, sent } = hostWith(async (address) => {
      asked.push(address)
      return address === '::1'
        ? opens(channel)
        : { ok: false, refusal: 'unreachable', message: 'refused' }
    })
    host.handle({ t: 'tunnel.open', id: 't1', port: 5173 })
    await vi.waitFor(() => expect(sent).toHaveLength(1))
    expect(sent[0]).toEqual({ t: 'tunnel.opened', id: 't1', port: 5173 })
    expect(asked).toEqual(['127.0.0.1', '::1'])
    // The proving channel is closed again — it existed to answer a question.
    expect(acts).toEqual(['destroy'])
    expect(host.openPorts()).toEqual([5173])
  })

  it('turns nothing-listening into one sentence rather than a browser error page', async () => {
    const { host, sent } = hostWith(async () => ({
      ok: false,
      refusal: 'unreachable',
      message: 'refused',
    }))
    host.handle({ t: 'tunnel.open', id: 't1', port: 5173 })
    await vi.waitFor(() => expect(sent).toHaveLength(1))
    expect(sent[0]).toEqual({
      t: 'tunnel.closed',
      id: 't1',
      message: 'Nothing is answering on port 5173 on the box.',
    })
    expect(host.openPorts()).toEqual([])
  })

  it('stops after the first loopback when the server refuses to forward at all', async () => {
    const asked: string[] = []
    const { host, sent } = hostWith(async (address) => {
      asked.push(address)
      return { ok: false, refusal: 'prohibited', message: 'administratively prohibited' }
    })
    host.handle({ t: 'tunnel.open', id: 't1', port: 5173 })
    await vi.waitFor(() => expect(sent).toHaveLength(1))
    // One question, not two: a server that will not forward refuses both
    // addresses, and the second is a round trip spent confirming the first.
    expect(asked).toEqual(['127.0.0.1'])
    expect(sent[0]).toMatchObject({ t: 'tunnel.closed', message: WILL_NOT_FORWARD })
  })

  it('lets a close cancel an open that has not finished', async () => {
    // A holder rather than a bare `let`: TypeScript narrows a variable assigned
    // only inside a callback to `never` at every later use, which makes the
    // call below uncallable for a reason that has nothing to do with the test.
    const pending: { settle: ((result: ForwardResult) => void) | null } = { settle: null }
    const { channel, acts } = fakeChannel()
    const { host, sent } = hostWith(
      () => new Promise<ForwardResult>((resolve) => (pending.settle = resolve)),
    )
    host.handle({ t: 'tunnel.open', id: 't1', port: 5173 })
    await vi.waitFor(() => expect(pending.settle).not.toBeNull())
    host.handle({ t: 'tunnel.close', id: 't1' })
    pending.settle?.(opens(channel))
    await vi.waitFor(() => expect(sent).toHaveLength(1))
    // Answered once, as closed — never as opened afterwards, which would leave
    // a tunnel nobody wants holding a channel on somebody's server.
    expect(sent).toEqual([{ t: 'tunnel.closed', id: 't1', message: 'Closed here.' }])
    expect(acts).toEqual(['destroy'])
    expect(host.openPorts()).toEqual([])
  })
})

describe('carrying bytes', () => {
  async function opened() {
    const proof = fakeChannel()
    const stream = fakeChannel()
    let first = true
    const { host, sent } = hostWith(async () => {
      if (first) {
        first = false
        return opens(proof.channel)
      }
      return opens(stream.channel)
    })
    host.handle({ t: 'tunnel.open', id: 't1', port: 8000 })
    await vi.waitFor(() => expect(sent).toHaveLength(1))
    host.handle({ t: 'net.open', ch: 'c1', tunnel: 't1' })
    await vi.waitFor(() => expect(stream.written).toBeDefined())
    return { host, sent, stream }
  }

  it('writes the browser’s bytes to the server and acknowledges what it took', async () => {
    const { host, sent, stream } = await opened()
    host.handle({ t: 'net.data', ch: 'c1', data: Buffer.from('GET / HTTP/1.1').toString('base64') })
    await vi.waitFor(() => expect(stream.written).toHaveLength(1))
    expect(stream.written[0].toString()).toBe('GET / HTTP/1.1')
    // From the write callback, so the window measures what the connection has
    // actually taken rather than what this process called `write` on.
    expect(sent).toContainEqual({ t: 'net.ack', ch: 'c1', bytes: 14 })
  })

  /**
   * The defect the end-to-end test found, pinned somewhere it fails in
   * milliseconds.
   *
   * `forwardOut` is a request and a reply on the SSH connection: nothing exists
   * to write into until the far end answers. A browser writes its request the
   * instant its socket connects, so `net.open` and the first `net.data` arrive
   * one round trip *before* the channel can exist. An earlier version of this
   * file held a do-nothing channel in that gap; every request landed on it and
   * vanished, and the page hung forever with a clean typecheck and a green unit
   * suite behind it.
   */
  it('holds the browser’s request until the channel exists, rather than dropping it', async () => {
    const proof = fakeChannel()
    const stream = fakeChannel()
    const pending: { settle: ((result: ForwardResult) => void) | null } = { settle: null }
    let first = true
    const { host, sent } = hostWith((address, port) => {
      if (first) {
        first = false
        return Promise.resolve(opens(proof.channel))
      }
      expect([address, port]).toEqual(['127.0.0.1', 8000])
      return new Promise<ForwardResult>((resolve) => (pending.settle = resolve))
    })
    host.handle({ t: 'tunnel.open', id: 't1', port: 8000 })
    await vi.waitFor(() => expect(sent).toHaveLength(1))

    host.handle({ t: 'net.open', ch: 'c1', tunnel: 't1' })
    // The whole request, arriving while the channel request is still in flight.
    host.handle({ t: 'net.data', ch: 'c1', data: Buffer.from('GET /a').toString('base64') })
    host.handle({ t: 'net.data', ch: 'c1', data: Buffer.from(' HTTP/1.1').toString('base64') })
    await vi.waitFor(() => expect(pending.settle).not.toBeNull())
    expect(stream.written).toEqual([])

    pending.settle?.(opens(stream.channel))
    await vi.waitFor(() => expect(stream.written).toHaveLength(2))
    // In order. Out of order here would be a corrupted request body rather than
    // a lost one, which is worse.
    expect(Buffer.concat(stream.written).toString()).toBe('GET /a HTTP/1.1')
    expect(sent).toContainEqual({ t: 'net.ack', ch: 'c1', bytes: 6 })
    expect(sent).toContainEqual({ t: 'net.ack', ch: 'c1', bytes: 9 })
  })

  it('sends what the server answers back as tunnel frames', async () => {
    const { sent, stream } = await opened()
    stream.emit('data', Buffer.from('HTTP/1.1 200 OK'))
    expect(sent).toContainEqual({
      t: 'net.data',
      ch: 'c1',
      data: Buffer.from('HTTP/1.1 200 OK').toString('base64'),
    })
  })

  /**
   * The Windows failure, in the one place it could have been rebuilt.
   *
   * `destroy()` throws away everything Node accepted from `write()` and has not
   * handed to the kernel — measured elsewhere in this repo at 66.8 MB of a
   * 64 MB write lost — and what is queued on *this* side is the browser's own
   * bytes on their way to the server: a form post, a file upload. Discarding
   * them makes an upload arrive short, the server waits for the rest of a
   * `Content-Length` it will never get, and the page hangs rather than failing.
   */
  it('flushes to the server when the browser finishes its request', async () => {
    const { host, stream } = await opened()
    host.handle({ t: 'net.close', ch: 'c1' })
    expect(stream.acts).toEqual(['end'])
  })

  it('discards when the connection is going down anyway', async () => {
    const { host, stream } = await opened()
    host.closeAll()
    expect(stream.acts).toEqual(['destroy'])
  })

  it('tells the browser when the server has finished answering', async () => {
    const { sent, stream } = await opened()
    stream.emit('end')
    expect(sent).toContainEqual({ t: 'net.close', ch: 'c1' })
    // Once, not twice: 'close' follows 'end' on every stream that ends.
    stream.emit('close')
    expect(sent.filter((message) => message.t === 'net.close')).toHaveLength(1)
  })
})

describe('the sentences', () => {
  it('sends a refusal, an empty port and an unknown to three different places', () => {
    expect(whyNot('prohibited', 8000, 'the box')).toBe(WILL_NOT_FORWARD)
    expect(whyNot('unreachable', 8000, 'the box')).toBe('Nothing is answering on port 8000 on the box.')
    expect(whyNot('unknown', 8000, 'the box')).toBe('the box could not be asked about port 8000 just now.')
  })

  it('never describes the mechanism to somebody who does not already know it', () => {
    for (const sentence of [
      WILL_NOT_FORWARD,
      whyNot('unreachable', 8000, 'the box'),
      whyNot('unknown', 8000, 'the box'),
    ]) {
      expect(sentence).not.toMatch(/ssh|tunnel|forward|tcp|socket|daemon|sudo/i)
    }
  })
})
