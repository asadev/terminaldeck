/**
 * The server transport, exercised inside the runtime that actually ships it.
 *
 * ## Why this file exists at all
 *
 * `npm test` runs vitest, and vitest runs under whatever `node` is on the path.
 * That Node links OpenSSL. The product links **BoringSSL**, by way of Electron.
 * This repository has already lost a whole feature to that difference once —
 * every sealed-channel handshake threw silently in the app while thousands of
 * tests stayed green, because BoringSSL has no ChaCha of any kind and the suite
 * never once loaded the runtime it ships on. `scripts/check-electron-crypto.mjs`
 * exists because of it, and its header says so at length.
 *
 * The risk is live here rather than theoretical. The test server offers
 * `chacha20-poly1305@openssh.com` **first** in its cipher list. A client that
 * carried its own cipher implementations would negotiate it and then fail to
 * perform it. `ssh2` does not, and the reason is worth pinning rather than
 * trusting: it builds its default cipher list and then filters that list
 * through the runtime's own `crypto.getCiphers()`. Same module, two runtimes:
 *
 *     node      … aes128-gcm, aes256-gcm, aes128-ctr, aes192-ctr, aes256-ctr,
 *                 chacha20-poly1305@openssh.com
 *     electron  … aes128-gcm, aes256-gcm, aes128-ctr, aes192-ctr, aes256-ctr
 *
 * It drops the cipher it cannot perform, by itself, with no configuration. That
 * is the single strongest reason this library was chosen, and a green vitest
 * run cannot report on it.
 *
 * ## Two halves
 *
 * The **offline** half asserts the cipher list under Electron: non-empty, and
 * containing no ChaCha. It needs no network and no credentials, so it runs
 * anywhere this app builds.
 *
 * The **live** half dials a real server and is opt-in, because a check that
 * needs somebody else's machine to be switched on is a check that will
 * eventually fail for a reason that has nothing to do with this code. It is
 * what proves the parts a fake socket cannot: that the fingerprint we compute
 * is the one other tools print, that a pty is real, and that a resize is
 * applied with its arguments the right way round.
 *
 * Run it through `scripts/check-servers-transport.mjs`, which bundles this with
 * the repository's own esbuild and executes it under `ELECTRON_RUN_AS_NODE=1`.
 */

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { ServerConnections, fingerprintOf } from './connection'
import { PROBE_SCRIPT, parseProbe } from './probe.sh'
import { ServerStore } from './store'
import type { ServerCredential, ServerCredentials } from './credentials'
import { valueOf } from './facts'

interface Check {
  name: string
  ok: boolean
  detail: string
}

const checks: Check[] = []

function record(name: string, ok: boolean, detail: string): void {
  checks.push({ name, ok, detail })
}

/* ------------------------------------------------------------- offline -- */

/**
 * What the library will actually offer, read from its own constants.
 *
 * Reached through `require` rather than an import because it is an internal
 * path with no type declaration, and because this file is bundled — a static
 * import of a deep path would be inlined and stop reflecting the installed
 * package.
 */
function offeredCiphers(): string[] {
  const req = eval('require') as (id: string) => { DEFAULT_CIPHER: string[] }
  return [...req('ssh2/lib/protocol/constants.js').DEFAULT_CIPHER]
}

function checkCiphers(): void {
  const ciphers = offeredCiphers()
  record(
    'the runtime leaves this app some cipher it can perform',
    ciphers.length > 0,
    ciphers.join(', ') || '(empty)',
  )
  const chacha = ciphers.filter((name) => name.toLowerCase().includes('chacha'))
  record(
    'no cipher is offered that this runtime cannot perform',
    chacha.length === 0,
    chacha.length === 0 ? 'no ChaCha offered' : `offered anyway: ${chacha.join(', ')}`,
  )
}

/* ---------------------------------------------------------------- live -- */

/**
 * A credential store that never touches disk and never touches Electron.
 *
 * `credentials.ts` imports `safeStorage`, which does not exist under
 * `ELECTRON_RUN_AS_NODE` — the whole module is deliberately absent there. The
 * shape below is the only part of it a connection uses.
 */
function heldCredential(credential: ServerCredential): ServerCredentials {
  return {
    read: () => credential,
    kindOf: () => credential.kind,
    available: () => true,
    isHeldForSessionOnly: () => true,
  } as unknown as ServerCredentials
}

async function checkLive(address: string, username: string, privateKey: string): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'td-servers-probe-'))
  try {
    const store = new ServerStore(dir)
    const server = store.add({ name: 'the test server', address, username })
    const connections = new ServerConnections(
      store,
      heldCredential({ kind: 'key', privateKey, passphrase: null }),
    )

    const started = Date.now()
    await connections.acquire(server.id)
    record('a key signs in', true, `${Date.now() - started} ms`)

    const recorded = store.get(server.id)?.hostKey ?? null
    record(
      'the identity was recorded on the first connection',
      recorded !== null && recorded.fingerprint.startsWith('SHA256:'),
      recorded === null ? 'nothing recorded' : `${recorded.algorithm} ${recorded.fingerprint}`,
    )

    const who = await connections.run(server.id, ['id', '-un'])
    record(
      'a command runs and comes back',
      who.code === 0 && who.stdout.trim() === username,
      `exit ${String(who.code)}, said "${who.stdout.trim()}"`,
    )

    // A command whose argument contains a space, a quote and a dollar sign —
    // the three things a naive command builder gets wrong, and the reason
    // `run` takes the parts rather than a line.
    const awkward = `a b'c$d`
    const echoed = await connections.run(server.id, ['printf', '%s', awkward])
    record(
      'an argument survives being sent',
      echoed.stdout === awkward,
      `sent ${JSON.stringify(awkward)}, got ${JSON.stringify(echoed.stdout)}`,
    )

    const probeStarted = Date.now()
    const facts = await connections.probe(server.id)
    const probeMs = Date.now() - probeStarted
    record(
      'the probe answers',
      facts.os.known === 'yes' && facts.init.known === 'yes',
      `${probeMs} ms — ${describe(facts.os)} / init ${describe(facts.init)} / ` +
        `containers ${describe(facts.containerRuntime)} / web ${describe(facts.webServer)}`,
    )
    const listeners = valueOf(facts.listeners) ?? []
    record(
      'each listening port names what owns it',
      listeners.length > 0 && listeners.some((one) => one.unit !== ''),
      listeners
        .slice(0, 4)
        .map((one) => `${one.port}→${one.unit || '(unnamed)'}`)
        .join(', '),
    )

    // The pty, and the argument order of the resize. Both sizes are
    // deliberately not square: a square window would pass either way round.
    const shell = await connections.shell(server.id, { cols: 100, rows: 30 })
    const said = collect(shell)
    shell.write('printf "A%s %s\\n" "$(tput cols)" "$(tput lines)"\n')
    await waitFor(() => /A\d+ \d+/.test(said()), 8_000)
    const first = /A(\d+) (\d+)/.exec(said())
    record(
      'the terminal is a real one, at the size asked for',
      first !== null && first[1] === '100' && first[2] === '30',
      first === null ? said().slice(-120) : `${first[1]} columns by ${first[2]} rows`,
    )

    shell.resize({ cols: 137, rows: 41 })
    shell.write('printf "B%s %s\\n" "$(tput cols)" "$(tput lines)"\n')
    await waitFor(() => /B\d+ \d+/.test(said()), 8_000)
    const second = /B(\d+) (\d+)/.exec(said())
    record(
      'a resize arrives with its arguments the right way round',
      second !== null && second[1] === '137' && second[2] === '41',
      second === null ? said().slice(-120) : `${second[1]} columns by ${second[2]} rows`,
    )
    shell.close()

    // The identity check, driven by corrupting what was recorded. This is the
    // path with no button on it, so it has to be provoked rather than waited
    // for.
    store.forgetHostKey(server.id)
    store.rememberHostKey(server.id, 'ssh-ed25519', 'SHA256:notthisonenotthisonenotthisone')
    connections.closeAll()
    const changed = new ServerConnections(
      store,
      heldCredential({ kind: 'key', privateKey, passphrase: null }),
    )
    let refused = 'it connected anyway'
    try {
      await changed.acquire(server.id)
    } catch (error) {
      refused = (error as { kind?: string }).kind ?? 'threw something else'
    }
    record(
      'a changed identity stops the connection',
      refused === 'identity-changed',
      refused,
    )

    connections.closeAll()
    changed.closeAll()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function describe(fact: { known: string; value?: unknown; why?: string }): string {
  if (fact.known === 'yes') return String(fact.value)
  if (fact.known === 'no') return 'none'
  return `cannot — ${String(fact.why)}`
}

function collect(shell: { onData(listener: (chunk: string) => void): () => void }): () => string {
  let seen = ''
  shell.onData((chunk) => {
    seen += chunk
  })
  return () => seen
}

/**
 * Wait for something to become true, or give up.
 *
 * A poll, and the one place in this feature that is allowed to be: it is a test
 * waiting on another computer's output, not a running app asking a server how
 * it is. It exists here rather than in `connection.ts` for exactly that reason.
 */
async function waitFor(condition: () => boolean, limitMs: number): Promise<void> {
  const until = Date.now() + limitMs
  while (Date.now() < until) {
    if (condition()) return
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
}

/* ----------------------------------------------------------- refusals -- */

/**
 * The four ways a connection is refused, and the sentence each produces.
 *
 * Provoked rather than waited for. Every one of these is a real thing that
 * happens to a person on their first attempt — a typo in the address, a port
 * that answers with something that is not a server, a password that is wrong —
 * and the sentence is the entire product at that moment. A wrong sentence here
 * sends somebody off to change a password that was already correct.
 */
async function checkRefusals(address: string, username: string): Promise<void> {
  await expectRefusal(
    'a typo in the address says so',
    'no-such-address',
    'nothing.here.invalid',
    22,
    username,
    { kind: 'password', password: 'x' },
  )
  /*
   * Port 80 does not say *"that is not a server"*, and it must not.
   *
   * Measured, both shapes, against the library itself: a web server on 80 and
   * an OpenSSH server that is dropping pre-authentication connections under
   * `MaxStartups` produce the **byte-identical** failure —
   * `level: 'protocol'`, `Connection lost before handshake`. Nothing in the
   * signal separates them, so the sentence may not claim to. It names what was
   * seen and offers the cheap thing first.
   */
  await expectRefusal(
    'a port that closes without saying anything says exactly that',
    'said-nothing',
    address,
    80,
    username,
    { kind: 'password', password: 'x' },
  )
  await expectRefusal(
    'a wrong password says so, without guessing which half was wrong',
    'sign-in-refused',
    address,
    22,
    username,
    { kind: 'password', password: 'certainly-not-the-password' },
  )
  await expectRefusal(
    'a closed port says so',
    'no-answer',
    address,
    47_351,
    username,
    { kind: 'password', password: 'x' },
  )
}

async function expectRefusal(
  name: string,
  expected: string,
  address: string,
  port: number,
  username: string,
  credential: ServerCredential,
): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'td-servers-refusal-'))
  try {
    const store = new ServerStore(dir)
    const server = store.add({ name: 'x', address, port, username })
    const connections = new ServerConnections(store, heldCredential(credential))
    let got = 'it connected'
    let sentence = ''
    try {
      await connections.acquire(server.id)
    } catch (error) {
      got = (error as { kind?: string }).kind ?? 'threw something else'
      sentence = (error as { sentence?: string }).sentence ?? String(error)
    }
    connections.closeAll()
    record(name, got === expected, `${got}${sentence === '' ? '' : ` — "${sentence}"`}`)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

/* ----------------------------------------------------- an ordinary account -- */

/**
 * The same probe, run by somebody who is not the administrator.
 *
 * This is the case rule 4 is about, and it is the one that cannot be checked
 * from an administrator's account: an ordinary sign-in answers
 * `present-no-permission` about containers and `sudo-password` about privilege,
 * and both are the third state doing its job. A two-state model records the
 * first as "this server runs no containers", on a machine whose containers are
 * the point of it.
 */
async function checkOrdinaryAccount(
  address: string,
  username: string,
  password: string,
): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), 'td-servers-ordinary-'))
  try {
    const store = new ServerStore(dir)
    const server = store.add({ name: 'the test server', address, username })
    const connections = new ServerConnections(store, heldCredential({ kind: 'password', password }))
    const started = Date.now()
    await connections.acquire(server.id)
    record('a password signs in', true, `${Date.now() - started} ms`)

    const raw = await connections.runScript(server.id, PROBE_SCRIPT)
    if (process.env.TD_PROBE_DUMP !== undefined && process.env.TD_PROBE_DUMP !== '') {
      writeFileSync(process.env.TD_PROBE_DUMP, raw.stdout)
    }
    const facts = parseProbe(raw.stdout, server.id, Date.now())
    record(
      'an ordinary account says what it cannot tell, rather than saying no',
      facts.containerRuntime.known === 'cannot' && facts.privilege.known === 'yes',
      `containers ${describe(facts.containerRuntime)} / privilege ${describe(facts.privilege)}`,
    )
    connections.closeAll()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

/* ---------------------------------------------------------------- main -- */

async function main(): Promise<void> {
  checkCiphers()

  const address = process.env.TD_PROBE_ADDRESS ?? ''
  const username = process.env.TD_PROBE_USER ?? ''
  const privateKey = process.env.TD_PROBE_KEY ?? ''
  const password = process.env.TD_PROBE_PASSWORD ?? ''
  if (address !== '' && username !== '' && privateKey !== '') {
    try {
      await checkLive(address, username, privateKey)
      await checkRefusals(address, username)
    } catch (error) {
      record('the live checks ran', false, String((error as Error).message ?? error))
    }
  } else if (address !== '' && username !== '' && password !== '') {
    try {
      await checkOrdinaryAccount(address, username, password)
    } catch (error) {
      record('the live checks ran', false, String((error as Error).message ?? error))
    }
  } else {
    process.stdout.write('[servers] live checks skipped — no server given\n')
  }

  let failed = 0
  for (const check of checks) {
    if (!check.ok) failed += 1
    process.stdout.write(`${check.ok ? 'PASS' : 'FAIL'}  ${check.name}\n        ${check.detail}\n`)
  }
  process.stdout.write(`\n[servers] ${checks.length - failed}/${checks.length} passed\n`)
  process.exit(failed === 0 ? 0 : 1)
}

void main()

// Referenced so the bundler keeps it; the fingerprint helper is asserted
// against `ssh-keyscan` by the script that runs this file.
export { fingerprintOf }
