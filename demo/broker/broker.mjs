#!/usr/bin/env node
/**
 * The broker — the only network-facing thing we wrote for the demo box.
 *
 * A reviewer opens <https://terminaldeck.dev/review> on their iPhone and taps
 * one button. That page calls this, and this starts a container, asks it for a
 * real pairing code, and hands back a `terminaldeck://pair?…` link the app is
 * already registered to open. Sixty seconds later the code is dead, as every
 * code in this product is; the reviewer is by then paired and attached.
 *
 * ## Why a container each, rather than one host everybody shares
 *
 * Because `server.ts` sends `sessions: options.sessions.list()` on `welcome` and
 * on every `sessions` request with no device filter, and `SessionFanout` lets
 * several devices watch and type into the same pty. That is correct for the
 * product — every device is the owner's, and driving the session on your desk
 * from your phone is the headline feature — and it means two reviewers sharing a
 * host would see, and be able to type into, each other's sessions. Filtering the
 * list per device would be a real product decision about a real feature, taken
 * under schedule pressure, for the benefit of strangers. One container each
 * costs nothing and needs no product change at all.
 *
 * It is also what makes the reset structural rather than hopeful. The container
 * is destroyed; there is no cleanup script, which matters because a cleanup
 * script is a thing that runs on the machine the stranger was standing on.
 *
 * ## Nothing here polls
 *
 * Readiness is a line the container prints on stdout, which arrives as a `data`
 * event. The end of a visit is the child process exiting, which arrives as an
 * `exit` event. The twenty-minute cap is a `setTimeout`, which is a deadline
 * rather than a question asked repeatedly. The standing rule in this repository
 * is events, not polling, and a broker that looped asking Docker what was still
 * running would have broken it in the one place it is easiest to get away with.
 *
 * ## What it deliberately does not have
 *
 * No database, no persistence, no admin endpoint, no way to name a container
 * from outside, and no way to run anything in one. If this process dies every
 * visitor is disconnected and the containers end themselves on their own
 * deadlines; that is the worst it can do.
 */

import { spawn, execFile } from 'node:child_process'
import { createServer } from 'node:http'
import { randomBytes } from 'node:crypto'

/* ------------------------------------------------------------------ config -- */

const PORT = Number(process.env.DEMO_BROKER_PORT ?? 8787)
const HOST = process.env.DEMO_BROKER_BIND ?? '127.0.0.1'
const IMAGE = process.env.DEMO_IMAGE ?? 'terminaldeck-demo:latest'
const NETWORK = process.env.DEMO_NETWORK ?? 'td-demo'

/**
 * Four at once, and the number is a fact about the machine rather than a guess.
 *
 * The box is a CX23: 2 vCPU and 4 GB. Each container is capped at 512 MB and
 * three quarters of a core, which leaves the host its own headroom at four. Past
 * that the page says the demo is busy and to try again in a minute, which is a
 * true sentence about a small machine — and a truthful refusal is a better
 * answer than a queue nobody has built.
 */
const MAX_SLOTS = Number(process.env.DEMO_MAX_SLOTS ?? 4)

/** The container's own cap is twenty minutes; this is the backstop behind it. */
const REAP_AFTER_MS = Number(process.env.DEMO_REAP_MS ?? 22 * 60_000)

/** How long to wait for a container to say it is up before giving up on it. */
const READY_TIMEOUT_MS = 45_000

/**
 * Who may call this from a browser.
 *
 * The review page is served from the marketing site so that its uptime is not
 * this box's uptime, which means every allocation is a cross-origin request and
 * the list has to be explicit. `app.terminaldeck.dev` is here for the browser
 * demo that shares this machine; it is not linked from anywhere yet.
 */
const ORIGINS = new Set([
  'https://terminaldeck.dev',
  'https://www.terminaldeck.dev',
  'https://app.terminaldeck.dev',
])

/**
 * The flags every visitor's container is started with.
 *
 * In one place and printed by `--print-run-flags`, because `demo/escapes.sh`
 * measures the confinement against *these* flags. A test that constructed its
 * own would be measuring a container nobody runs.
 *
 * Line by line, since every one of them is load-bearing:
 *
 *  - `--rm` — the reset. The filesystem, the trust store, the pairing state and
 *    anything backgrounded go when the process does.
 *  - `--cap-drop ALL` then four back. `SYS_ADMIN` is what lets `demo-shell`
 *    build its mount namespace; `SETUID`/`SETGID` are what let it drop to the
 *    visitor afterwards; `CHOWN` is for laying out their home. The visitor holds
 *    none of them: `setpriv --bounding-set=-all` empties the bounding set before
 *    their shell starts, which is the line CONFINEMENT.md measured as the
 *    difference between a boundary and a decoration.
 *  - `--security-opt apparmor=unconfined` — measured, not chosen. Docker's
 *    default AppArmor profile permits `umount` and not `mount`, so with it on,
 *    `unshare --mount` fails at "cannot change root filesystem propagation" and
 *    the bind-mount half of the confinement cannot be built at all. The cost is
 *    bounded by the daemon running with `userns-remap`, which makes this
 *    container's root host uid 100000 — an account that owns nothing.
 *  - `--security-opt no-new-privileges` — nothing the visitor execs can gain
 *    privileges, including through a setuid binary the image happens to carry.
 *  - `--read-only` with three tmpfs mounts. The only writable bytes in the
 *    container are the visitor's home, `/tmp` and `/run`, all of them RAM and
 *    all of them size-capped.
 *  - `--memory`, `--cpus`, `--pids-limit` — a fork bomb, a `yes > file` and a
 *    `while true` are each bounded by the kernel rather than by our hoping.
 *  - `--network td-demo` — the network the egress rules in `demo/provision.sh`
 *    are written against. Everything outbound is dropped except the relay.
 */
function runFlags(name) {
  return [
    'run',
    '--rm',
    '--name', name,
    '--hostname', 'terminaldeck-demo',
    '--network', NETWORK,
    '--cap-drop', 'ALL',
    '--cap-add', 'SYS_ADMIN',
    '--cap-add', 'SETUID',
    '--cap-add', 'SETGID',
    '--cap-add', 'CHOWN',
    '--security-opt', 'apparmor=unconfined',
    '--security-opt', 'no-new-privileges',
    '--read-only',
    '--tmpfs', '/home:rw,nosuid,nodev,size=64m,mode=0755',
    '--tmpfs', '/tmp:rw,nosuid,nodev,size=32m,mode=1777',
    '--tmpfs', '/run:rw,nosuid,nodev,size=8m,mode=0755',
    '--tmpfs', '/root:rw,nosuid,nodev,size=32m,mode=0700',
    '--memory', '512m',
    '--memory-swap', '512m',
    '--cpus', '0.75',
    '--pids-limit', '192',
    '--ulimit', 'nofile=1024:1024',
    '--ulimit', 'fsize=33554432',
    '--stop-timeout', '5',
    IMAGE,
  ]
}

if (process.argv.includes('--print-run-flags')) {
  process.stdout.write(`${runFlags('NAME').join('\n')}\n`)
  process.exit(0)
}

/* ------------------------------------------------------------------- slots -- */

/** @type {Map<string, {name: string, child: import('node:child_process').ChildProcess, startedAt: number, reaper: NodeJS.Timeout}>} */
const slots = new Map()

const log = (message, detail) =>
  process.stdout.write(`${new Date().toISOString()} ${message}${detail ? ` ${JSON.stringify(detail)}` : ''}\n`)

/**
 * Start one visitor's machine and wait for it to say it is up.
 *
 * The readiness signal is a line the demo host prints on its own stdout. Reading
 * it is how this avoids asking Docker the same question in a loop — and it is
 * also a stronger signal than the container being "running", because the line is
 * only printed after the control socket is listening, which is the thing the
 * next step needs.
 */
async function allocate() {
  const slot = randomBytes(9).toString('base64url')
  const name = `td-demo-${slot.toLowerCase().replace(/[^a-z0-9]/g, '')}`

  const child = spawn('docker', runFlags(name), { stdio: ['ignore', 'pipe', 'pipe'] })
  const reaper = setTimeout(() => {
    log('reaping a slot that outlived its deadline', { slot, name })
    execFile('docker', ['kill', name], () => undefined)
  }, REAP_AFTER_MS)
  // The container ends itself long before this; if it did not, the process would
  // hold a slot forever and nothing else here would notice.
  reaper.unref()

  slots.set(slot, { name, child, startedAt: Date.now(), reaper })

  child.on('exit', (code) => {
    clearTimeout(reaper)
    slots.delete(slot)
    log('a slot was given back', { slot, name, code, held: Date.now() - (slots.get(slot)?.startedAt ?? 0) })
  })

  const ready = await new Promise((resolve) => {
    let seen = ''
    const timer = setTimeout(() => resolve(false), READY_TIMEOUT_MS)
    const watch = (chunk) => {
      seen += chunk.toString('utf8')
      // The sentence `demo.ts` prints from the relay's own connect event —
      // *not* when the process starts. A container that is running and not yet
      // dialled would answer `machines:code` with "this host is not on the
      // relay", which is what the first real allocation over the public endpoint
      // did.
      if (seen.includes('demo host') && seen.includes('on the relay')) {
        clearTimeout(timer)
        resolve(true)
      }
    }
    child.stdout.on('data', watch)
    child.stderr.on('data', (chunk) => {
      // Kept, and logged: a container that dies during startup is the failure a
      // reviewer would experience as the page hanging, and its reason is here.
      log('container stderr', { name, text: chunk.toString('utf8').trim().slice(0, 400) })
    })
    child.once('exit', () => {
      clearTimeout(timer)
      resolve(false)
    })
  })

  if (!ready) {
    execFile('docker', ['kill', name], () => undefined)
    throw new Error('the demo machine did not come up')
  }
  return { slot, name }
}

/**
 * Ask a running container for a pairing link.
 *
 * Separate from {@link allocate} because the page has a "get a new one" button:
 * a code lives sixty seconds, a reviewer reading the page may take longer than
 * that, and minting a second code is a control message rather than a second
 * container. The code is the product's — `machines:code` on the container's own
 * control socket, which also publishes the relay rendezvous beacon for its life.
 */
function mint(name) {
  return new Promise((resolve, reject) => {
    execFile(
      'docker',
      ['exec', name, 'node', '/usr/local/bin/demo-code'],
      { timeout: 15_000, maxBuffer: 64 * 1024 },
      (error, stdout, stderr) => {
        // `execFile`'s timeout hides stdout on the error object, which has cost
        // this project a day before: the reason is on stderr and has to be
        // carried explicitly or a slow container looks like an empty one.
        if (error) return reject(new Error(`${error.message}${stderr ? `: ${stderr.trim()}` : ''}`))
        try {
          resolve(JSON.parse(stdout))
        } catch {
          reject(new Error(`the container answered with something that is not a pairing link: ${stdout.slice(0, 200)}`))
        }
      },
    )
  })
}

/* -------------------------------------------------------------- rate limit -- */

/**
 * One allocation per address every twenty seconds, ten in an hour.
 *
 * Not a defence against a determined attacker — anybody with a botnet has as
 * many addresses as they like — and it is not pretending to be one. It is a
 * defence against the ordinary case: a page left open reloading, a script
 * somebody wrote in an afternoon, a crawler that follows every button. The real
 * bound is `MAX_SLOTS`, which is enforced by the machine having only so much
 * memory.
 */
const seen = new Map()
function tooOften(address, now) {
  const history = (seen.get(address) ?? []).filter((at) => now - at < 3_600_000)
  seen.set(address, history)
  if (seen.size > 4096) seen.clear()
  if (history.length >= 10) return 'ten machines in an hour is enough from one address'
  if (history.length > 0 && now - history[history.length - 1] < 20_000) {
    return 'one machine at a time, please — try again in a moment'
  }
  history.push(now)
  return null
}

/* ------------------------------------------------------------------ server -- */

function send(res, status, body, origin) {
  const text = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    ...(origin ? { 'access-control-allow-origin': origin, vary: 'Origin' } : {}),
  })
  res.end(text)
}

const server = createServer((req, res) => {
  const origin = req.headers.origin && ORIGINS.has(req.headers.origin) ? req.headers.origin : null
  // Behind Caddy, so the caller's address is the forwarded one. Falls back to
  // the socket, which on this box is always the proxy — a rate limit keyed on
  // the proxy is useless rather than wrong, and saying so here is cheaper than
  // discovering it from a log.
  const address = (req.headers['x-forwarded-for'] ?? '').toString().split(',')[0].trim() || req.socket.remoteAddress || '?'

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'access-control-allow-origin': origin ?? 'https://terminaldeck.dev',
      'access-control-allow-methods': 'POST, GET, OPTIONS',
      'access-control-allow-headers': 'content-type',
      'access-control-max-age': '600',
      vary: 'Origin',
    })
    res.end()
    return
  }

  const url = new URL(req.url ?? '/', 'http://demo')

  if (req.method === 'GET' && url.pathname === '/healthz') {
    send(res, 200, { ok: true, slots: MAX_SLOTS, inUse: slots.size, free: MAX_SLOTS - slots.size }, origin)
    return
  }

  if (req.method === 'POST' && url.pathname === '/allocate') {
    const limited = tooOften(address, Date.now())
    if (limited) return send(res, 429, { ok: false, reason: 'rate-limited', message: limited }, origin)
    if (slots.size >= MAX_SLOTS) {
      return send(res, 503, {
        ok: false,
        reason: 'busy',
        message: 'All the demo machines are in use. They are handed back automatically — try again in a minute.',
      }, origin)
    }
    allocate()
      .then(async ({ slot, name }) => {
        const code = await mint(name)
        log('a visitor was given a machine', { slot, name, address })
        send(res, 200, { ok: true, slot, ...code }, origin)
      })
      .catch((error) => {
        log('could not give out a machine', { address, error: String(error && error.message) })
        send(res, 502, {
          ok: false,
          reason: 'unavailable',
          message: 'The demo machine did not start. This is our fault, not yours — please try again.',
        }, origin)
      })
    return
  }

  if (req.method === 'POST' && url.pathname === '/code') {
    let body = ''
    req.on('data', (chunk) => {
      body += chunk
      if (body.length > 4096) req.destroy()
    })
    req.on('end', () => {
      let slot = null
      try {
        slot = JSON.parse(body).slot
      } catch {
        return send(res, 400, { ok: false, reason: 'malformed' }, origin)
      }
      const held = typeof slot === 'string' ? slots.get(slot) : undefined
      if (!held) {
        return send(res, 404, {
          ok: false,
          reason: 'gone',
          message: 'That demo machine has already been handed back. Ask for a new one.',
        }, origin)
      }
      mint(held.name).then(
        (code) => send(res, 200, { ok: true, slot, ...code }, origin),
        (error) => {
          log('could not mint a second code', { slot, error: String(error && error.message) })
          send(res, 502, { ok: false, reason: 'unavailable' }, origin)
        },
      )
    })
    return
  }

  send(res, 404, { ok: false, reason: 'no-such-thing' }, origin)
})

server.listen(PORT, HOST, () => {
  log('broker listening', { host: HOST, port: PORT, image: IMAGE, slots: MAX_SLOTS })
})

/*
 * Take every visitor's machine down on the way out.
 *
 * `--rm` containers whose parent process is gone keep running; systemd
 * restarting this broker would otherwise leave orphans holding memory that the
 * new process does not know about, and the slot count would drift away from
 * reality until somebody rebooted the box.
 */
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => {
    log('stopping', { signal, holding: slots.size })
    for (const { name } of slots.values()) execFile('docker', ['kill', name], () => undefined)
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 5_000).unref()
  })
}
