import { execFile } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { createServer, type Server } from 'node:http'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { prependShim, removeOpenShim, shimDir, shimScript, writeOpenShim } from './open-shim'

/**
 * The generated script, executed for real.
 *
 * Reading the text and asserting on it would pass for a script with a syntax
 * error in it, and this one goes on the PATH of **every** session in the app —
 * including every session belonging to somebody who never asked for this
 * feature. The three cases that matter most are the ones that must behave as if
 * none of this existed (`open .`, `open -a Xcode f.swift`, `open report.pdf`),
 * and the only way to know they do is to run them.
 *
 * A fake opener rather than `/usr/bin/open`: the point is to record the argv
 * the shim passed through, and the real one would launch Finder on a CI box.
 */

const made: string[] = []

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'open-shim-'))
  made.push(dir)
  return dir
}

/**
 * A directory short enough to hold a unix socket.
 *
 * `sun_path` is 104 bytes on macOS. `tmpdir()` is 48 of them on this machine,
 * which leaves room — but a sandboxed or CI run can set `TMPDIR` to something
 * far longer (one such directory on this machine is 96 bytes on its own, and
 * curl there answers *"Unix socket path too long"* and the shim correctly falls
 * through to the real opener). That would be the right behaviour reached for a
 * reason the test never intended, so the socket cases pick a short path
 * outright. `hook-server.ts` guards the same limit for the same reason, with a
 * sentence rather than an errno.
 */
function socketScratch(): string {
  const dir = mkdtempSync('/tmp/td-shim-')
  made.push(dir)
  return dir
}

/** A stand-in for `/usr/bin/open` that writes its argv, one argument per line. */
function fakeOpener(dir: string): { path: string; log: string; argv(): string[] } {
  const log = join(dir, 'argv.log')
  const path = join(dir, 'fake-open')
  writeFileSync(path, `#!/bin/sh\nfor a in "$@"; do printf '%s\\n' "$a" >> '${log}'; done\nexit 0\n`)
  chmodSync(path, 0o755)
  return {
    path,
    log,
    argv: () => (existsSync(log) ? readFileSync(log, 'utf8').split('\n').filter(Boolean) : []),
  }
}

interface Ran {
  stdout: string
  stderr: string
  status: number
}

/**
 * Run the script, and **never** synchronously.
 *
 * `execFileSync` blocks this thread, and the stub endpoint below is an
 * `http.Server` in this same process: with the event loop stopped it can never
 * accept the connection, so curl waits out its own `--max-time` and the shim
 * falls through to the real opener. That is the correct behaviour for a reason
 * the test never intended, and it made three cases fail while proving nothing —
 * three seconds apiece, which is what the ten-second run time was.
 */
function run(script: string, args: string[], env: Record<string, string> = {}): Promise<Ran> {
  return new Promise((settle) => {
    execFile(
      '/bin/sh',
      [script, ...args],
      { encoding: 'utf8', env: { ...process.env, ...env } },
      (error, stdout, stderr) => {
        const status = error ? ((error as { code?: number }).code ?? 1) : 0
        settle({ stdout, stderr, status })
      },
    )
  })
}

afterEach(() => {
  for (const dir of made) removeOpenShim(dir)
  made.length = 0
})

/**
 * Windows has neither half of what these need.
 *
 * `writeOpenShim` returns null on win32 — deliberately, and there is a test
 * below asserting exactly that — so there is no script to execute; and a CI
 * runner has no `sh` to execute it with either. Running them there fails on the
 * absence of a feature that was never meant to be present, which is the same
 * shape as the Mac-only tests that have blocked two releases of this app.
 *
 * `skipIf` rather than deleting or rewriting them: on macOS and Linux these are
 * the only proof that `open .`, `open -a Xcode f.swift` and `open report.pdf`
 * still behave as though none of this existed, and that is the property the
 * whole shim lives or dies by.
 */
const onWindows = process.platform === 'win32'

describe.skipIf(onWindows)('the script hands everything that is not a http(s) URL straight through', () => {
  /**
   * Rules 1 to 3, which are the entire safety case. A shim that swallows
   * `open .` breaks every session in the app for people who never asked for
   * this feature, and it breaks it silently — the command exits 0 and no window
   * appears.
   */
  const cases: Array<{ what: string; argv: string[] }> = [
    { what: 'a folder', argv: ['.'] },
    { what: 'an application and a file', argv: ['-a', 'Xcode', 'file.swift'] },
    { what: 'a reveal', argv: ['-R', 'file.txt'] },
    { what: 'a document', argv: ['report.pdf'] },
    { what: 'nothing at all', argv: [] },
    { what: 'a scheme that is not the web', argv: ['vscode://file/x'] },
    { what: 'two URLs at once', argv: ['https://a.example', 'https://b.example'] },
  ]

  for (const { what, argv } of cases) {
    it(`${what} reaches the real opener with its arguments untouched`, async () => {
      const dir = scratch()
      const opener = fakeOpener(dir)
      const script = join(dir, 'open')
      // A config path that does not exist: if any of these ever reached the
      // socket branch, curl would be asked for a file that is not there, and
      // the assertion below would see the fallback line as well as the argv.
      writeFileSync(script, shimScript(opener.path, join(dir, 'nope.conf')))

      const ran = await run(script, argv)

      expect(ran.status, ran.stderr).toBe(0)
      expect(opener.argv()).toEqual(argv)
      // Not one word printed. These commands are used inside scripts and their
      // output is read; a chatty `open .` is a behaviour change of its own.
      expect(ran.stdout).toBe('')
    })
  }
})

describe.skipIf(onWindows)('a http(s) URL', () => {
  let server: Server | null = null

  afterEach(async () => {
    const running = server
    server = null
    if (running) await new Promise<void>((done) => running.close(() => done()))
  })

  it('lands in the app and says which window, without touching the real opener', async () => {
    const dir = socketScratch()
    const opener = fakeOpener(dir)
    const socket = join(dir, 'hook.sock')

    const seen: Array<{ url: string; session: string | undefined }> = []
    server = createServer((req, res) => {
      let body = ''
      req.on('data', (chunk: Buffer) => {
        body += chunk.toString('utf8')
      })
      req.on('end', () => {
        seen.push({ url: body, session: req.headers['x-terminaldeck-session'] as string | undefined })
        res.writeHead(200, { 'content-type': 'text/plain' })
        res.end('tab\nOpened in B2 — Terminal Deck.\n')
      })
    })
    await new Promise<void>((listening) => server?.listen(socket, listening))

    const config = join(dir, 'endpoint.conf')
    writeFileSync(config, `unix-socket = "${socket}"\nheader = "x-terminaldeck-token: t"\n`)
    const script = join(dir, 'open')
    writeFileSync(script, shimScript(opener.path, config))

    const ran = await run(script, ['https://example.com/a?b=c'], {
      TERMINALDECK_SESSION_ID: 'session-7',
    })

    expect(ran.status, ran.stderr).toBe(0)
    expect(ran.stdout.trim()).toBe('Opened in B2 — Terminal Deck.')
    // The URL is sent raw, so nothing has to escape a quote or a backslash that
    // a URL may legally contain — the quoting bug that would lose an address.
    expect(seen).toEqual([{ url: 'https://example.com/a?b=c', session: 'session-7' }])
    expect(opener.argv(), 'the app took it, so the machine must not open it too').toEqual([])
  })

  it('reaches the real opener and says so when nothing is listening', async () => {
    const dir = scratch()
    const opener = fakeOpener(dir)
    const script = join(dir, 'open')
    writeFileSync(script, shimScript(opener.path, join(dir, 'gone.conf')))

    const ran = await run(script, ['https://example.com/'])

    expect(ran.status, ran.stderr).toBe(0)
    expect(opener.argv()).toEqual(['https://example.com/'])
    // Never exit 0 having said nothing: Claude maps exit 0 to success, and a
    // silent one here would have the model believing a page it cannot see is on
    // screen somewhere.
    expect(ran.stdout).toContain('default browser')
  })

  it('reaches the real opener when the app answers something else', async () => {
    const dir = socketScratch()
    const opener = fakeOpener(dir)
    const socket = join(dir, 'hook.sock')

    server = createServer((_req, res) => {
      res.writeHead(200, { 'content-type': 'text/plain' })
      res.end('system\nNo Terminal Deck session here — opened in your default browser.\n')
    })
    await new Promise<void>((listening) => server?.listen(socket, listening))

    const config = join(dir, 'endpoint.conf')
    writeFileSync(config, `unix-socket = "${socket}"\n`)
    const script = join(dir, 'open')
    writeFileSync(script, shimScript(opener.path, config))

    const ran = await run(script, ['https://example.com/'])

    expect(ran.status, ran.stderr).toBe(0)
    expect(opener.argv()).toEqual(['https://example.com/'])
    expect(ran.stdout).toContain('No Terminal Deck session here')
  })
})

describe('the opener is never resolved through PATH', () => {
  /**
   * The single highest-severity line in this design. PATH now *begins* with the
   * shim directory, so a lookup inside the script would find the script, which
   * would exec the script, for ever, in every session, on every URL.
   */
  it('bakes in an absolute path and looks nothing up', () => {
    const text = shimScript('/usr/bin/open', '/tmp/x.conf')
    // Assigned exactly once, to a literal absolute path, and never from a
    // lookup. Asserted on the assignments rather than on the word "which",
    // which appears half a dozen times in the script's own prose.
    const assignments = [...text.matchAll(/^REAL_OPENER=(.*)$/gm)].map((match) => match[1])
    expect(assignments).toEqual(["'/usr/bin/open'"])
    expect(text).not.toMatch(/command -v/)
    expect(text).not.toMatch(/`/)
    expect(text).not.toMatch(/\$\(\s*(which|type|command)\b/)
  })

  it.skipIf(onWindows)('does not exec itself when its own directory is first on PATH', async () => {
    const dir = scratch()
    const opener = fakeOpener(dir)
    const shim = join(dir, 'shim')
    mkdirSync(shim, { recursive: true })
    const script = join(shim, 'open')
    writeFileSync(script, shimScript(opener.path, join(dir, 'gone.conf')))
    chmodSync(script, 0o755)

    // Invoked by bare name, through a PATH whose first entry is the shim — the
    // exact arrangement a session runs in.
    const ran = await run(script, ['.'], { PATH: `${shim}:${process.env.PATH ?? ''}` })

    expect(ran.status, ran.stderr).toBe(0)
    expect(opener.argv()).toEqual(['.'])
  })
})

describe('the directory itself', () => {
  it('is written on start and gone after shutdown', () => {
    const dir = scratch()
    const shim = writeOpenShim(dir, join(dir, 'endpoint.conf'), 'darwin')
    // Skipped rather than failed where there is no `/usr/bin/open` to bake in:
    // this suite runs on Linux in CI, where the opener is `xdg-open` and may not
    // be installed at all. The cases above cover the script itself everywhere.
    if (!shim) return
    expect(existsSync(join(shimDir(dir), 'open'))).toBe(true)
    removeOpenShim(dir)
    expect(existsSync(shimDir(dir))).toBe(false)
  })

  it('is not written on Windows, rather than written and useless', () => {
    const dir = scratch()
    expect(writeOpenShim(dir, join(dir, 'endpoint.conf'), 'win32')).toBeNull()
    expect(existsSync(shimDir(dir))).toBe(false)
  })

  it('goes on the front of a PATH exactly once', () => {
    // `delimiter` rather than a literal ':' — `prependShim` splits on node's
    // own separator, which is ';' on Windows, so a hard-coded colon made this
    // assert about a PATH that platform never produces.
    const d = delimiter
    expect(prependShim(`/usr/bin${d}/bin`, '/data/shim')).toBe(`/data/shim${d}/usr/bin${d}/bin`)
    // Prepending a PATH that already names it must not produce two entries: the
    // sandbox plan turns every PATH entry into a read+exec root, and a duplicate
    // there is a duplicate rule for the same directory.
    expect(prependShim(`/data/shim${d}/usr/bin`, '/data/shim')).toBe(`/data/shim${d}/usr/bin`)
    expect(prependShim('/usr/bin', null)).toBe('/usr/bin')
  })
})
