import { readFileSync } from 'node:fs'
import { createServer, type Server } from 'node:http'
import { afterAll, describe, expect, it } from 'vitest'
import { Client } from 'ssh2'
import {
  armScript,
  disarmScript,
  readScouted,
  scoutScript,
  subcommandsFrom,
  wrapperScript,
} from './window-drive'
import { openWindowReach, type ReverseConnection } from './window-reach'

/**
 * The one test that opens a real port on a real server and answers it here.
 *
 * Opt-in, because a test that needs a machine on the public internet has no
 * business failing a build on a train — the same gate `reach.live.test.ts`
 * uses, and the same three variables:
 *
 *     TERMINALDECK_LIVE_SSH=178.105.239.176 \
 *     TERMINALDECK_LIVE_SSH_USER=root \
 *     TERMINALDECK_LIVE_SSH_KEY=~/.ssh/hetzner_personal \
 *       npx vitest run src/main/servers/window-reach.live.test.ts
 *
 * ## What this proves that the unit tests cannot
 *
 * `window-reach.test.ts` puts a fake connection at the far end, which proves
 * this module's own decisions. What it cannot prove is anything about a
 * **stranger's sshd**: that `forwardIn` with a bind port of zero really is
 * answered with a port number, that OpenSSH's default really does bind that
 * port to loopback and nothing else, that the `ss` on somebody's Ubuntu prints
 * the column this app parses, and that a request made *on that machine* really
 * does arrive on a socket here. Those are facts about OpenSSH and about
 * somebody's actual box, and the only way to establish them is to ask one.
 *
 * It also pins the header that made the whole feature answer 403 for an
 * afternoon: the request arrives carrying the **far end's** port in `Host`, so
 * `deck-control/server.ts` matching its own port number refused every one of
 * them. That is asserted here rather than reasoned about, because it is a fact
 * about what a client on the other side of a tunnel actually sends.
 *
 * ## What it does to the machine
 *
 * It opens a port for a few seconds and closes it, and it writes one `mktemp -d`
 * scratch folder under `/tmp` which it then removes. Nothing is installed,
 * nothing is restarted, and nothing outside that folder is written — the
 * standing instruction about this box is read-only on services, and this obeys
 * it.
 */

const host = process.env.TERMINALDECK_LIVE_SSH ?? ''
const username = process.env.TERMINALDECK_LIVE_SSH_USER ?? 'root'
const keyPath = (process.env.TERMINALDECK_LIVE_SSH_KEY ?? '').replace(/^~/, process.env.HOME ?? '~')
const live = host !== '' && keyPath !== ''

const clients: Client[] = []
const servers: Server[] = []

afterAll(() => {
  for (const client of clients.splice(0)) client.end()
  for (const server of servers.splice(0)) server.close()
})

async function dial(): Promise<Client> {
  const client = new Client()
  clients.push(client)
  await new Promise<void>((resolve, reject) => {
    client.once('ready', resolve)
    client.once('error', reject)
    client.connect({
      host,
      port: 22,
      username,
      privateKey: readFileSync(keyPath),
      // A live test against a box whose identity this suite has no record of.
      // The app's own check is `connection.ts`'s and is proved in
      // `host-key-checked.test.ts`; this is not that test.
      hostVerifier: (_key, verify) => verify(true),
    })
  })
  return client
}

/** One command on that machine, with an optional script on its standard input. */
function exec(client: Client, command: string, input: string | null = null): Promise<string> {
  return new Promise((resolve, reject) => {
    client.exec(command, (error, channel) => {
      if (error) return reject(error)
      let out = ''
      channel.on('data', (chunk: Buffer) => {
        out += chunk.toString()
      })
      channel.stderr.on('data', (chunk: Buffer) => {
        out += chunk.toString()
      })
      channel.on('close', () => resolve(out))
      // Through standard input, exactly as `ServerConnections.runScript` does
      // and for the reason it gives: a command line appears in that machine's
      // process list, where anybody signed into it can read it.
      if (input !== null) channel.end(input)
    })
  })
}

/** A stand-in for `deck-control`, so the bytes have somewhere real to land. */
async function endpointHere(): Promise<number> {
  const server = createServer((request, response) => {
    response.writeHead(200, { 'content-type': 'text/plain' })
    response.end(`host=${request.headers.host} path=${request.url}`)
  })
  servers.push(server)
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  return (server.address() as { port: number }).port
}

describe.skipIf(!live)('a real server’s own loopback, answered from here', () => {
  it('opens a port there, proves where it landed, and carries a request back', async () => {
    const client = await dial()
    const localPort = await endpointHere()

    const opened = await openWindowReach(client as unknown as ReverseConnection, {
      local: { port: localPort },
      runScript: (script) => exec(client, 'sh -s', script).then((stdout) => ({ stdout })),
    })

    expect(opened.ok, opened.ok ? '' : opened.message).toBe(true)
    if (!opened.ok) return
    const { reach } = opened

    /*
     * Bound to loopback and to nothing else, read off that machine's own `ss`.
     *
     * This is the sentence the whole security case rests on, checked against
     * the thing it is a claim about rather than against OpenSSH's documentation.
     */
    // The **local address** column only. `ss` prints the peer beside it as
    // `0.0.0.0:*`, which is a wildcard about who may connect and not about
    // where this is bound — reading the whole line would fail on every healthy
    // machine.
    const listening = (
      await exec(client, `ss -H -tln | awk '$4 ~ /:${reach.port}$/ {print $4}'`)
    ).trim()
    expect(listening).toBe(`127.0.0.1:${reach.port}`)

    const answered = await exec(client, `curl -s --max-time 5 http://127.0.0.1:${reach.port}/mcp`)
    expect(answered).toContain('path=/mcp')
    /*
     * And the header that made this answer 403 for an afternoon.
     *
     * A client on that machine addresses `127.0.0.1:<its port>`, so the `Host`
     * it sends carries a number this endpoint has never bound. `hostIsLocal` in
     * `deck-control/server.ts` used to match its own port against it and refuse
     * every forwarded request; it now checks the literal, which is the whole of
     * the DNS-rebind defence, and lets the number be whatever the far end
     * dialled.
     */
    expect(answered).toContain(`host=127.0.0.1:${reach.port}`)

    reach.close()
    const after = await exec(
      client,
      `curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:${reach.port}/mcp || printf refused`,
    )
    expect(after).toContain('refused')
  }, 60_000)

  it('lands the wrapper and the config where a person’s `claude` would find them', async () => {
    const client = await dial()

    // A stand-in for that account's `claude`, so nothing has to be installed on
    // somebody's machine to prove the wrapper reaches one.
    const stand = await exec(
      client,
      'sh -s',
      [
        'd=$(mktemp -d /tmp/td-live-XXXXXX) || exit 1',
        "cat > \"$d/claude\" <<'TD_FAKE'",
        '#!/bin/sh',
        'for a in "$@"; do printf \'%s\\n\' "$a"; done',
        'TD_FAKE',
        'chmod 700 "$d/claude"',
        'printf %s "$d"',
      ].join('\n'),
    )
    const standIn = stand.trim()

    try {
      /*
       * Inside the `try`, not above it.
       *
       * A failed assertion here leaked a scratch folder on somebody else's
       * machine once already — the folder exists the moment `mktemp` answers,
       * so every line after that answer belongs where the removal can still
       * run.
       */
      expect(standIn.startsWith('/tmp/td-live-')).toBe(true)
      const armed = readScouted(await exec(client, 'sh -s', scoutScript()))
      expect(armed.dir.startsWith('/tmp/td-drive-')).toBe(true)
      await exec(
        client,
        'sh -s',
        armScript({
          dir: armed.dir,
          files: [
            {
              path: 'deck-control.json',
              body: '{"mcpServers":{"deck-control":{"type":"http"}}}',
            },
            {
              path: 'bin/claude',
              body: wrapperScript({
                real: `${standIn}/claude`,
                subcommands: subcommandsFrom('Commands:\n  mcp   Configure MCP\n  update  Update\n'),
                config: `${armed.dir}/deck-control.json`,
                settings: null,
              }),
              executable: true,
            },
          ],
        }),
      )
      // `curl` is what the whole belonging half rides on, so a real machine is
      // the only place the scout's answer for it can be checked against the
      // machine itself.
      expect(armed.curl).toBe((await exec(client, 'command -v curl || true')).trim())
      // `$SHELL` is exported by sshd out of that account's passwd entry, which
      // is where the answer to "can this terminal take an `export` line" comes
      // from. A real machine is the only place that can be checked.
      expect(armed.shell).not.toBe('')

      // 0700 on the folder and 0600 on the token file, from `umask 077` rather
      // than from a chmod that runs after the bytes are already readable.
      const modes = await exec(
        client,
        `stat -c '%a' ${armed.dir} ${armed.dir}/deck-control.json ${armed.dir}/bin/claude`,
      )
      expect(modes.split('\n').slice(0, 3)).toEqual(['700', '600', '700'])

      // The wrapper, run the way a shell with it first on PATH would run it.
      const prompted = await exec(client, `${armed.dir}/bin/claude 'fix the build'`)
      expect(prompted.split('\n').filter((line) => line !== '')).toEqual([
        '--mcp-config',
        `${armed.dir}/deck-control.json`,
        'fix the build',
      ])
      // And a subcommand, which would fail on an unknown option, untouched.
      const sub = await exec(client, `${armed.dir}/bin/claude mcp list`)
      expect(sub.split('\n').filter((line) => line !== '')).toEqual(['mcp', 'list'])

      await exec(client, 'sh -s', disarmScript(armed.dir))
      expect(await exec(client, `test -d ${armed.dir} && printf still || printf gone`)).toContain('gone')
    } finally {
      await exec(client, 'sh -s', `case "${standIn}" in /tmp/td-live-??????) rm -rf "${standIn}" ;; esac`)
    }
  }, 60_000)
})
