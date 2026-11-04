/** Test entry only: a separate Node process, no daemon, accounts, sessions or files. */
import { createInterface } from 'node:readline'
import { ServerDirectLink, linkFrame } from '../main/remote/server-direct'

const emit = (frame: Record<string, unknown>): void => { process.stdout.write(`${JSON.stringify(frame)}\n`) }
let quitting = false
const finish = (ok: boolean): void => {
  if (quitting) return
  quitting = true
  clearTimeout(deadline)
  input.close()
  link.close(1000, 'Probe finished')
  emit({ t: 'probe.finished', ok })
  // werift owns sockets and scheduled work; the fixture has a bounded lifetime.
  setTimeout(() => process.exit(ok ? 0 : 1), 50)
}

const link = new ServerDirectLink({
  binding: Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1)),
  relay: {
    send: text => {
      const frame = linkFrame(text)
      if (frame) emit(frame)
    },
    close: () => { if (!quitting) emit({ t: 'probe.closed' }) }
  },
  handlers: {
    message: text => {
      const frame = linkFrame(text)
      if (frame?.t === 'hello') {
        link.send(JSON.stringify({ t: 'welcome', deviceId: 'server-direct-28-test', capabilities: ['sessions'], sessions: [] }))
      } else if (frame?.t === 'ping') {
        link.send(JSON.stringify({ t: 'pong', rid: frame.rid }))
      }
    },
    closed: () => { if (!quitting) emit({ t: 'probe.closed' }) }
  },
  servers: async () => [],
  retain: () => {},
  release: () => {},
  onClosed: () => {},
  offerTimeoutMs: 20_000
})

const input = createInterface({ input: process.stdin })
const deadline = setTimeout(() => finish(false), 45_000)
input.on('line', text => {
  if (quitting) return
  const frame = linkFrame(text)
  if (!frame || Buffer.byteLength(text) > 96 * 1024) return finish(false)
  if (frame.t === 'probe.dropRelay') {
    const kept = link.relayClosed()
    emit({ t: 'probe.relayDropped', kept, up: link.isUp })
  } else if (frame.t === 'probe.stop') {
    finish(true)
  } else {
    link.receiveRelay(text)
  }
})
input.on('close', () => { if (!quitting) finish(false) })
process.on('uncaughtException', () => finish(false))
process.on('unhandledRejection', () => finish(false))
emit({ t: 'probe.ready' })
