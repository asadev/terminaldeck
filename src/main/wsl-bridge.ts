/**
 * The way a session inside a WSL distribution reaches this app's tool endpoint
 * when `127.0.0.1` over there is not `127.0.0.1` over here — which is the
 * default configuration, and therefore most people's.
 *
 * ## The resistance this exists to delete
 *
 * Asad, 2026-08-21, on what the app is for:
 *
 * > *"i want it to be with no resistance — people just install and do some
 * > clicks and everything works fine"*
 *
 * The answer this replaces was a sentence. `session-verbs.ts` told a session in
 * a Linux folder that its browser verbs were missing and that
 * `networkingMode=mirrored` in `.wslconfig` plus `wsl --shutdown` was what would
 * bring them back. Every clause of it was true, and it was still a defect: it
 * asks a person to leave the app, find a file most people have never opened, know
 * what a networking mode is, and restart the distribution their work is running
 * in. Measured on his own machine that last part is worse than an inconvenience —
 * his `.wslconfig` carries his own note warning himself not to shut WSL down
 * mid-work.
 *
 * So the question was not *how do we phrase it better*. It was **what path is
 * there that needs no edit, no restart and no administrator**, and there is one.
 *
 * ## Why the network was the wrong thing to fix
 *
 * Under WSL's default NAT networking the distribution has a private address on a
 * Hyper-V switch, and the Windows host is reachable only at the default gateway
 * — an address `deck-control/server.ts` deliberately does not listen on. Making
 * *that* work means a second listener on a non-loopback interface plus an
 * inbound Windows Defender Firewall rule, and a firewall rule needs elevation.
 * A feature that quietly depends on an administrator action nobody took is the
 * dead control this app keeps being about, so that route stays unbuilt and
 * `isLoopback` stays exactly as narrow as it has always been.
 *
 * ## What is used instead: the pipe that is already there
 *
 * WSL runs Windows executables from inside a distribution — binfmt_misc, on by
 * default, the same mechanism that makes `explorer.exe .` work in a Linux shell.
 * A Windows process started that way inherits the Linux caller's stdin and
 * stdout as ordinary pipes. That is a two-way channel from inside the
 * distribution to the Windows side which needs **no** network, no port, no
 * firewall rule, no `.wslconfig` and no restart, and it is available on every
 * default install.
 *
 * MCP has a transport shaped exactly like that channel: **stdio**. So a session
 * inside a distribution is not given an HTTP URL it cannot reach. It is given a
 * stdio MCP server whose command is this app's own executable, reached at
 * `/mnt/c/…`, run as plain Node (`ELECTRON_RUN_AS_NODE`, the same trick this
 * repository's own `check-electron-crypto.mjs` and `check-servers-transport.mjs`
 * already use), running {@link WSL_BRIDGE_SOURCE}. The bridge speaks
 * newline-delimited JSON-RPC to the CLI on one side and plain loopback HTTP to
 * `deck-control/server.ts` on the other, and it is a Windows process on the
 * Windows machine, so the socket it opens is `127.0.0.1` in the only sense that
 * endpoint has ever accepted.
 *
 * ## Nothing was widened, and this is the sentence to check that against
 *
 * `isLoopback` in `server.ts` is untouched, `hostIsLocal` is untouched, no
 * second listener exists, and no interface was allowed that was not allowed
 * before. The connection arrives from a process running on Windows as this
 * account, on this machine's loopback — the same class of caller as the copilot
 * itself. This is not a per-interface allowance and not a looser rule; it is the
 * existing rule, reached from a process that satisfies it.
 *
 * ## And the token is now on the side that can keep it
 *
 * A side effect worth stating, because it moves in the safe direction. The HTTP
 * config a WSL session used to be handed carried this app's bearer token in a
 * file the distribution had to read. The stdio config carries no token at all:
 * it names a script and a path, and the bridge — a Windows process — reads the
 * token from a file `remote/secret-file.ts` wrote with an ACL naming this
 * account alone. The secret never crosses the boundary.
 *
 * ## Why the script is a string here rather than a file in the repository
 *
 * The precedent is `servers/probe.sh.ts`, and the reason is the same: this text
 * has to exist at a path a *different* operating system can name at runtime, so
 * it is written to `<userData>` when it is needed. Shipping it as an asset would
 * mean a second thing the packager has to be told about and a second way for a
 * build to be missing a file at the moment somebody needs it.
 *
 * Two constraints on editing it, both of them load-bearing:
 *
 *  - **No backticks and no `${` inside the source**, because it lives in a
 *    template literal. There is a test that fails if either appears.
 *  - **Nothing but JSON-RPC on stdout.** stdio MCP is a framed protocol on that
 *    stream; a stray `console.log` corrupts the session rather than logging to
 *    it. Everything diagnostic goes to stderr, which the CLI collects.
 */

import { writeSecretFile } from './remote/secret-file'
import { join } from 'node:path'

/* ------------------------------------------------------------------- names -- */

/**
 * What the file is called where it lands.
 *
 * One copy per run rather than one per launch: it is the same bytes for every
 * session, it is read by a Windows process, and the folder it sits in is wiped
 * and re-protected when `createSessionTools` starts.
 */
export const WSL_BRIDGE_FILE = 'wsl-mcp-bridge.js'

/**
 * The two environment variables the bridge is started with, and why there are
 * two of them.
 *
 * `ELECTRON_RUN_AS_NODE` is what makes this app's executable behave as plain
 * Node rather than starting a second copy of the app. It is set **inside the
 * distribution**, by the CLI, on a Linux process — and a Linux variable does not
 * cross into a Windows process unless `WSLENV` names it. That is the whole of
 * the second entry: without it the variable is set on the wrong side of the
 * boundary and the executable starts an app window instead of a bridge.
 */
export const WSL_BRIDGE_ENV: Readonly<Record<string, string>> = Object.freeze({
  ELECTRON_RUN_AS_NODE: '1',
  WSLENV: 'ELECTRON_RUN_AS_NODE',
})

/** The argument that asks the bridge to prove the chain rather than serve it. */
export const WSL_BRIDGE_PROBE = '--probe'

/* ------------------------------------------------------------------ source -- */

/**
 * The bridge, as it is written to disk.
 *
 * CommonJS and dependency-free on purpose. It is executed by whatever Node this
 * app's Electron carries, from a folder under `<userData>` that has no
 * `package.json` above it, so `require` is the resolution that cannot be wrong.
 *
 * ### What it has to get right
 *
 * `server.ts` is **stateless** — `sessionIdGenerator: undefined`,
 * `enableJsonResponse: true` — which is what makes a pump sufficient instead of
 * an MCP implementation. There is no session id to carry, no `GET` stream to
 * hold open and no resumption. One POST per message, one answer, done.
 *
 * The two headers that are not optional: `content-type: application/json`, and
 * an `accept` naming **both** `application/json` and `text/event-stream`. The
 * MCP SDK's server transport refuses a POST that does not accept both, and the
 * refusal is a 406 that would look exactly like a broken endpoint.
 *
 * ### The part that is about honesty rather than protocol
 *
 * Every failure becomes a JSON-RPC error addressed to the request that caused
 * it. A bridge that swallowed a 403 would leave the CLI waiting for an answer
 * that is never coming, which is this app's own worst failure shape wearing a
 * different hat: a control that looks wired and answers nothing. A refusal is
 * returned as a refusal, in words, with the status code in it.
 */
export const WSL_BRIDGE_SOURCE = `'use strict'
/*
 * Terminal Deck — the stdio bridge a session inside WSL is launched with.
 *
 * Written by src/main/wsl-bridge.ts and replaced on every run. Editing this
 * copy changes nothing: it is overwritten the next time the app starts.
 *
 * Usage:
 *   <node> wsl-mcp-bridge.js <endpoint-url> <token-file>
 *   <node> wsl-mcp-bridge.js --probe <endpoint-url>
 */
const http = require('node:http')
const fs = require('node:fs')

const PROBE_TIMEOUT_MS = 4000
const REQUEST_TIMEOUT_MS = 300000

function note(text) {
  // stderr, always: stdout carries the protocol.
  try { process.stderr.write('[terminal-deck bridge] ' + text + '\\n') } catch (_) { /* gone */ }
}

/* The unauthenticated GET the probe makes, whose answer proves the whole chain. */
function probe(url) {
  let req
  try {
    req = http.request(url, { method: 'GET' }, onProbeAnswer)
  } catch (error) {
    // A URL this cannot even parse is a reach of none, and silence is how that
    // is spelled: the caller is matching on a fingerprint, not on an exit code.
    note('cannot address ' + url + ': ' + (error && error.message))
    return
  }
  req.setTimeout(PROBE_TIMEOUT_MS, function () { req.destroy() })
  req.on('error', function () { /* silence is the answer: nothing was reached */ })
  req.end()
}

function onProbeAnswer(res) {
  let text = ''
  res.setEncoding('utf8')
  res.on('data', function (chunk) { text += chunk })
  res.on('end', function () { process.stdout.write(text) })
}

function post(url, headers, body) {
  return new Promise(function (resolve, reject) {
    const req = http.request(url, { method: 'POST', headers: headers }, function (res) {
      let text = ''
      res.setEncoding('utf8')
      res.on('data', function (chunk) { text += chunk })
      res.on('end', function () {
        resolve({
          status: res.statusCode || 0,
          type: String(res.headers['content-type'] || ''),
          text: text,
        })
      })
    })
    req.setTimeout(REQUEST_TIMEOUT_MS, function () {
      req.destroy(new Error('no answer in ' + REQUEST_TIMEOUT_MS + 'ms'))
    })
    req.on('error', reject)
    req.end(body)
  })
}

/** Every JSON-RPC message in an answer, whichever of the two shapes it came in. */
function messagesFrom(answer) {
  if (answer.status === 202 || answer.text === '') return []
  if (answer.type.indexOf('text/event-stream') >= 0) {
    const found = []
    const lines = answer.text.split('\\n')
    for (let i = 0; i < lines.length; i += 1) {
      const line = lines[i].trim()
      if (line.slice(0, 5) !== 'data:') continue
      try { found.push(JSON.parse(line.slice(5).trim())) } catch (_) { /* not a frame */ }
    }
    return found
  }
  let parsed
  try { parsed = JSON.parse(answer.text) } catch (_) { return [] }
  return Array.isArray(parsed) ? parsed : [parsed]
}

/** The ids that are owed an answer — requests only, never notifications. */
function idsAwaiting(sent) {
  const list = Array.isArray(sent) ? sent : [sent]
  const ids = []
  for (let i = 0; i < list.length; i += 1) {
    const one = list[i]
    if (one && typeof one === 'object' && one.method !== undefined && one.id !== undefined && one.id !== null) {
      ids.push(one.id)
    }
  }
  return ids
}

function main(url, tokenFile) {
  let token = ''
  try {
    token = String(fs.readFileSync(tokenFile, 'utf8')).trim()
  } catch (error) {
    note('cannot read the token this app wrote for it: ' + (error && error.message))
    process.exit(1)
    return
  }
  if (token === '') {
    note('the token file this app wrote is empty')
    process.exit(1)
    return
  }

  /* Echoed back on every later request, the way a real client does. */
  let protocol = ''

  function out(message) {
    try { process.stdout.write(JSON.stringify(message) + '\\n') } catch (_) { /* the CLI went */ }
  }

  function fail(ids, message) {
    for (let i = 0; i < ids.length; i += 1) {
      out({ jsonrpc: '2.0', id: ids[i], error: { code: -32001, message: message } })
    }
  }

  function send(line) {
    let sent
    try { sent = JSON.parse(line) } catch (_) {
      note('ignored a line that was not JSON')
      return
    }
    const ids = idsAwaiting(sent)
    const headers = {
      'content-type': 'application/json',
      // Both, or the MCP server transport answers 406 before reading a byte.
      accept: 'application/json, text/event-stream',
      authorization: 'Bearer ' + token,
      'content-length': String(Buffer.byteLength(line, 'utf8')),
    }
    if (protocol !== '') headers['mcp-protocol-version'] = protocol
    let answering
    try {
      answering = post(url, headers, line)
    } catch (error) {
      // A throw on the way out — an unaddressable URL — must become an answer
      // too. An uncaught one here would take the bridge down mid-session and
      // leave the CLI waiting on a request nobody is holding any more.
      fail(ids, 'Could not address Terminal Deck on this machine (' + ((error && error.message) || 'bad address') + ').')
      return
    }
    answering.then(
      function (answer) {
        if (answer.status >= 400) {
          fail(ids, 'Terminal Deck refused this call (HTTP ' + answer.status + '). Its control endpoint is running, ' +
            'but this session is not being accepted by it. Starting the session again is what re-mints its token.')
          return
        }
        const messages = messagesFrom(answer)
        for (let i = 0; i < messages.length; i += 1) {
          const message = messages[i]
          if (message && message.result && typeof message.result.protocolVersion === 'string') {
            protocol = message.result.protocolVersion
          }
          out(message)
        }
      },
      function (error) {
        fail(ids, 'Could not reach Terminal Deck on this machine (' + ((error && error.message) || 'no answer') +
          '). The app may have been closed since this session started.')
      },
    )
  }

  let buffered = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', function (chunk) {
    buffered += chunk
    for (;;) {
      const cut = buffered.indexOf('\\n')
      if (cut < 0) break
      const line = buffered.slice(0, cut).trim()
      buffered = buffered.slice(cut + 1)
      if (line !== '') send(line)
    }
  })
  process.stdin.on('end', function () { process.exit(0) })
  process.stdin.on('error', function () { process.exit(0) })
  process.stdout.on('error', function () { process.exit(0) })
}

const argv = process.argv.slice(2)
if (argv[0] === '--probe' && argv.length >= 2) probe(argv[1])
else if (argv[0] !== '--probe' && argv.length >= 2) main(argv[0], argv[1])
else {
  note('started with no endpoint to reach; nothing to do')
  process.exit(1)
}
`

/* ------------------------------------------------------------------- guard -- */

/**
 * Was this process started to *be* the bridge, by an executable that did not
 * honour `ELECTRON_RUN_AS_NODE`?
 *
 * ## The failure this closes, which no probe can catch
 *
 * The bridge is this app's own executable, and the only thing standing between
 * "a Node process running a script" and "a second copy of this app" is one
 * environment variable crossing the WSL boundary. `wsl-reach.ts` proves that it
 * does — but it proves it by setting the variable itself, in a shell it wrote.
 * The launch a session actually makes sets it a different way: in the `env` map
 * of an MCP server entry, applied by the CLI. If a CLI ever ignored that map,
 * every WSL session would start a second instance of this app instead of a
 * bridge, and the probe would have said everything was fine.
 *
 * A second instance is not a small thing here. It contends for `state.json`,
 * for port 8443 and for the relay identity — the whole argument is beside
 * `requestSingleInstanceLock` in `index.ts` — and it is asked for once per
 * session, silently, on somebody's Windows machine.
 *
 * So this is checked before the lock is even requested, and the answer is to
 * leave immediately. Requesting the lock would fire `second-instance` in the
 * real app and pop its window onto the screen, which is the visible half of the
 * same bug. What the CLI gets instead is a process that exited with a sentence
 * on stderr, which is an honest failure it will report rather than a control
 * that looks wired and answers nothing.
 */
export function startedAsWslBridge(argv: readonly string[]): boolean {
  // From the second entry: the first is the executable's own path, and an app
  // installed into a folder somebody named after this file would otherwise
  // refuse to start at all.
  return argv.slice(1).some((one) => one.endsWith(WSL_BRIDGE_FILE))
}

/* ------------------------------------------------------------------ writing -- */

/**
 * Put the bridge where a distribution can name it, and answer that path.
 *
 * The path answered is the **Windows** one, because that is what the bridge is
 * handed as an argument — it is a Windows process and its argv is not
 * translated by anything on the way across. The *command* is the other spelling
 * and is worked out from what the distribution itself reported; see
 * `wsl-reach.ts`, which is the only caller that composes both.
 *
 * Written through `writeSecretFile` although it is not a secret. What it is
 * instead is a script this app executes, and the ACL that writer puts on the
 * folder is what stops another account on the machine replacing the file
 * between now and the moment a CLI runs it. Null rather than a throw when the
 * write failed: a session must not fail to start over a feature that is merely
 * absent, and the caller reads null as "no bridge", which is the honest
 * sentence rather than a config file naming a script that is not there.
 */
export function writeWslBridge(dir: string): string | null {
  const file = join(dir, WSL_BRIDGE_FILE)
  try {
    writeSecretFile(dir, file, WSL_BRIDGE_SOURCE)
    return file
  } catch (error) {
    console.error('[wsl] could not write the bridge a distribution would run:', error)
    return null
  }
}
