#!/usr/bin/env node
/**
 * Ask this container's demo host for a real pairing link, and print it as JSON.
 *
 * The broker runs this with `docker exec`, which is the whole design: the
 * container's control socket is a Unix socket in a 0700 directory owned by the
 * container's root, and the broker is the only thing that can get there. A
 * visitor cannot — they are an unprivileged uid inside a mount namespace where
 * that path is not even present. See `demo/image/demo-shell` and
 * `demo/escapes.sh`, which measures that claim rather than asserting it.
 *
 * ## Why it builds nothing
 *
 * An earlier version assembled the `terminaldeck://pair?…` link here, out of the
 * relay's url, host id, key and the token. That was a second implementation of a
 * format four programs have to agree on, and `src/shared/pairing-link.ts` says
 * in its own header why that is the wrong thing to have: "a second
 * implementation of a link format is how a QR code that scans starts failing on
 * the phone." So the host builds it, with the same function the desktop's Pair
 * panel calls, and this prints what came back.
 *
 * ## Why it is not `terminaldeck pair`
 *
 * `pair` is written for a person: it prints a code, waits, and asks whether to
 * approve. A broker has nobody to ask and no screen to read. This sends one
 * control message and exits.
 */

import { createConnection } from 'node:net'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const STATE_DIR =
  process.env.TERMINALDECK_STATE_DIR ??
  join(process.env.XDG_DATA_HOME ?? join(process.env.HOME ?? '/root', '.local', 'share'), 'terminaldeck')

/**
 * One request, one connection, exactly as `control.ts` frames it.
 *
 * Twenty lines rather than an import, because importing it would mean bundling a
 * second copy of the headless build into this container for the sake of a JSON
 * line. The *frame* is safe to restate — it is two fields and a newline, and a
 * mistake in it fails immediately and loudly. The *pairing link* was not, which
 * is why that half moved into the host.
 */
function call(cmd, args = []) {
  const { socket, token } = JSON.parse(readFileSync(join(STATE_DIR, 'host.json'), 'utf8'))
  return new Promise((resolve, reject) => {
    const connection = createConnection(socket)
    let buffer = ''
    const timer = setTimeout(() => {
      connection.destroy()
      reject(new Error(`the host did not answer "${cmd}" in ten seconds`))
    }, 10_000)
    connection.setEncoding('utf8')
    connection.on('connect', () => {
      connection.write(`${JSON.stringify({ token, cmd, args: args.map((a) => JSON.stringify(a)) })}\n`)
    })
    connection.on('data', (chunk) => {
      buffer += chunk
      const newline = buffer.indexOf('\n')
      if (newline < 0) return
      clearTimeout(timer)
      connection.destroy()
      const answer = JSON.parse(buffer.slice(0, newline))
      if (answer.ok) resolve(answer.value)
      else reject(new Error(answer.error ?? 'the host refused and did not say why'))
    })
    connection.on('error', (error) => {
      clearTimeout(timer)
      reject(error)
    })
  })
}

const answer = await call('demo:link')
if (!answer?.ok) throw new Error(answer?.message ?? 'the host would not produce a pairing link')
process.stdout.write(`${JSON.stringify(answer)}\n`)
