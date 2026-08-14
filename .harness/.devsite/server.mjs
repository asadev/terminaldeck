/**
 * A dev server for the tunnel to carry, with no dependencies.
 *
 * Three things a page needs before "it loaded" means anything: the document, a
 * **same-origin fetch** that comes back, and a **WebSocket** that stays open.
 * The last one is the whole reason the tunnel is a byte pipe rather than an HTTP
 * proxy, and it is the one a screenshot cannot prove — so this answers all three
 * and the page prints what happened.
 *
 * The WebSocket upgrade is written out by hand rather than pulled from `ws`,
 * which this repository does not depend on. It is thirty lines: the RFC 6455
 * handshake is a SHA-1 of the client's key and a fixed GUID, and a text frame
 * under 126 bytes is two header bytes and the payload. Nothing here has to read
 * a frame, only send them.
 */

import { createHash } from 'node:crypto'
import { createServer } from 'node:http'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const page = readFileSync(resolve(here, 'index.html'))
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

const server = createServer((request, response) => {
  if (request.url === '/__probe.json') {
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ served: new Date().toISOString().slice(11, 19) }))
    return
  }
  response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
  response.end(page)
})

/** One unmasked text frame. Server frames are never masked. */
function textFrame(text) {
  const body = Buffer.from(text, 'utf8')
  if (body.length > 125) throw new Error('this probe only sends short frames')
  return Buffer.concat([Buffer.from([0x81, body.length]), body])
}

server.on('upgrade', (request, socket) => {
  const key = request.headers['sec-websocket-key']
  if (!key) {
    socket.destroy()
    return
  }
  const accept = createHash('sha1').update(key + GUID).digest('base64')
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  )
  socket.write(textFrame('hello'))
  // A heartbeat, so the socket is visibly *alive* rather than merely opened —
  // which is the difference between a tunnel that carried an upgrade and one
  // that is carrying a conversation.
  const tick = setInterval(() => {
    if (socket.destroyed) return clearInterval(tick)
    socket.write(textFrame(`tick ${new Date().toISOString().slice(11, 19)}`))
  }, 5000)
  socket.on('close', () => clearInterval(tick))
  socket.on('error', () => clearInterval(tick))
})

server.listen(3210, '127.0.0.1', () => process.stdout.write('dev server on 127.0.0.1:3210\n'))
