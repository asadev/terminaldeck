import { execFileSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { HOOK_MARKER } from '../hooks'
import { TOKEN_HEADER } from '../hook-server'
import {
  BELONG_EVENTS,
  HOOK_CONFIG_FILE,
  OPENER_NAMES,
  POSTER_FILE,
  SETTINGS_FILE,
  SETTINGS_FLAG,
  belongFiles,
  honoursSettings,
  hookConfig,
  openerScript,
  plainEnough,
  posterScript,
  settingsFile,
  type BelongInput,
} from './window-belong'

/**
 * These are shell scripts that go on somebody's `PATH`, so this file **runs
 * them**.
 *
 * `window-drive.test.ts` states the argument and it applies here twice over:
 * reading the generated text and asserting substrings would pass on a script
 * with an unbalanced quote in it, and the failure of *this* one is not a missing
 * feature — it is every `open` in that terminal behaving strangely. The one
 * thing that cannot be exercised locally is the far side of the tunnel, so
 * `curl` is a stand-in that records exactly what it was handed.
 */

const made: string[] = []

afterEach(() => {
  for (const dir of made.splice(0)) rmSync(dir, { recursive: true, force: true })
})

/** A scratch folder shaped like the one a server would have made. */
function scratch(): string {
  // Forward-slash spelling: this dir is interpolated into #!/bin/sh scripts and
  // handed to `sh`; Git Bash reads a `/`-path cleanly, and node's fs still does
  // too. mktemp under the host temp dir, never a hardcoded `/tmp` node may lack.
  const dir = mkdtempSync(join(tmpdir(), 'td-belong-')).replace(/\\/g, '/')
  made.push(dir)
  mkdirSync(join(dir, 'bin'), { recursive: true })
  return dir
}

/**
 * A `curl` that answers from a file and writes down what it was given.
 *
 * The two things worth recording are the argv — which carries the session
 * header, the endpoint and the config file — and stdin, because a hook that does
 * not drain the pipe the CLI is writing into is an EPIPE in somebody's session.
 */
function fakeCurl(dir: string, over: { reply?: string; status?: number } = {}): string {
  const path = join(dir, 'fake-curl')
  writeFileSync(join(dir, 'reply'), over.reply ?? '')
  writeFileSync(
    path,
    `#!/bin/sh
for a in "$@"; do printf '%s\\n' "$a"; done > '${dir}/argv'
cat > '${dir}/stdin'
${over.status === undefined ? '' : `exit ${over.status}`}
cat '${dir}/reply'
`,
    'utf8',
  )
  chmodSync(path, 0o755)
  return path.replace(/\\/g, '/')
}

/** A real opener that says it ran and repeats its arguments. */
function fakeOpener(dir: string): string {
  const path = join(dir, 'real-opener')
  writeFileSync(path, '#!/bin/sh\nprintf \'REAL\\n\'\nfor a in "$@"; do printf \'%s\\n\' "$a"; done\n', 'utf8')
  chmodSync(path, 0o755)
  return path.replace(/\\/g, '/')
}

function input(dir: string, over: Partial<BelongInput> = {}): BelongInput {
  return {
    dir,
    // A plausible absolute path for the cases that only read the generated text.
    // Anything that actually *runs* a script passes a `fakeCurl`, which writes
    // its own reply file and would clobber another one's.
    curl: '/usr/bin/true',
    port: 40405,
    sessionId: 'server-1 shell-9',
    token: 'abcdef0123456789',
    openers: {},
    pages: null,
    hooks: true,
    ...over,
  }
}

/** Put one generated script on disk, executable, and answer its path. */
function place(dir: string, path: string, body: string): string {
  const file = join(dir, path)
  mkdirSync(join(file, '..'), { recursive: true })
  writeFileSync(file, body, 'utf8')
  chmodSync(file, 0o755)
  return file
}

/** Run a script and answer stdout, stderr and status without throwing. */
function call(
  file: string,
  args: readonly string[],
  stdin = '',
): { out: string; err: string; status: number } {
  try {
    const out = execFileSync('sh', [file.replace(/\\/g, '/'), ...args], {
      encoding: 'utf8',
      input: stdin,
      stdio: 'pipe',
    })
    return { out, err: '', status: 0 }
  } catch (error) {
    const failure = error as { stdout?: string; stderr?: string; status?: number }
    return { out: failure.stdout ?? '', err: failure.stderr ?? '', status: failure.status ?? -1 }
  }
}

/* ------------------------------------------------------------ the reading -- */

describe('what the server’s own help says', () => {
  it('reads the flag out of it rather than out of a version number', () => {
    expect(honoursSettings('  --settings <file-or-json>   Path to a settings JSON file')).toBe(true)
    expect(honoursSettings('Usage: claude\n  --model <model>\n')).toBe(false)
  })

  it('is not fooled by the neighbouring flag that is not this one', () => {
    // `--setting-sources` is a different flag and a real one. A server whose
    // help lists only that must not be handed `--settings`, which it would then
    // fail on at every invocation.
    expect(honoursSettings('  --setting-sources <sources>  user, project, local\n')).toBe(false)
  })
})

describe('what it is willing to put in a script', () => {
  it('takes the shapes that actually turn up and refuses the rest', () => {
    expect(plainEnough('/usr/bin/curl')).toBe(true)
    expect(plainEnough('server-1 shell-9')).toBe(true)
    expect(plainEnough('/tmp/td-drive-abcdef')).toBe(true)
    for (const bad of ['', "/usr/bin/o'clock", '/usr/bin/$(id)', '/usr/bin/`id`', '/a\\b', '/a\nb']) {
      expect(plainEnough(bad)).toBe(false)
    }
  })

  it('writes nothing at all rather than something half-quoted', () => {
    const dir = scratch()
    expect(belongFiles(input(dir, { curl: "/usr/bin/o'clock" }))).toEqual([])
    expect(belongFiles(input(dir, { sessionId: '$(rm -rf /)' }))).toEqual([])
    expect(belongFiles(input(dir, { token: 'not hex' }))).toEqual([])
    expect(belongFiles(input(dir, { port: 0 }))).toEqual([])
    expect(belongFiles(input(dir, { dir: 'relative/path' }))).toEqual([])
  })
})

/* -------------------------------------------------------------- the token -- */

// Skipped on Windows: belongFiles builds the Linux-server shim manifest and needs
// a `/`-absolute server scratch dir, which the Windows client's `scratch()` (a
// `C:\...` path) is not — so the shim's assertions run on POSIX hosts.
describe.skipIf(process.platform === 'win32')('the token, and the one file it is in', () => {
  it('goes in a curl config and never on a command line', () => {
    const dir = scratch()
    const files = belongFiles(input(dir))
    const holding = files.filter((file) => file.body.includes('abcdef0123456789'))
    // A command line is in that machine's process list, where anybody signed in
    // can read it. One file, read by `-K` at call time.
    expect(holding.map((file) => file.path)).toEqual([HOOK_CONFIG_FILE])
    expect(hookConfig('abcdef0123456789')).toContain(`header = "${TOKEN_HEADER}: abcdef0123456789"`)
  })
})

/* --------------------------------------------------------------- the hooks -- */

describe('the settings layer the wrapper names', () => {
  it('installs the three events that are answered, and nothing else', () => {
    const parsed = JSON.parse(settingsFile('/tmp/td-drive-abcdef')) as {
      hooks: Record<string, { hooks: { command: string; timeout: number }[] }[]>
    }
    // One key. `--settings` is an additional layer over that account's own, and
    // this app has no business having an opinion about their model or their
    // permissions.
    expect(Object.keys(parsed)).toEqual(['hooks'])
    expect(Object.keys(parsed.hooks).sort()).toEqual([...BELONG_EVENTS].sort())
    for (const event of BELONG_EVENTS) {
      const entry = parsed.hooks[event][0].hooks[0]
      expect(entry.command).toBe(`/tmp/td-drive-abcdef/${POSTER_FILE} ${event} ${HOOK_MARKER}`)
      expect(entry.timeout).toBe(5)
    }
  })

  it('tags every entry as ours', () => {
    expect(settingsFile('/tmp/td-drive-abcdef').split(HOOK_MARKER).length - 1).toBe(
      BELONG_EVENTS.length,
    )
  })

  // Skipped on Windows: belongFiles needs a `/`-absolute server scratch dir (the
  // Linux-server shim); the literal-input siblings above stay cross-platform.
  it.skipIf(process.platform === 'win32')('is not written at all for a claude that cannot be given it', () => {
    const dir = scratch()
    const paths = belongFiles(input(dir, { hooks: false })).map((file) => file.path)
    expect(paths).not.toContain(SETTINGS_FILE)
    expect(paths).not.toContain(POSTER_FILE)
    // The shim is a PATH entry and a `curl`; it does not care what the CLI takes.
    for (const name of OPENER_NAMES) expect(paths).toContain(`bin/${name}`)
  })
})

describe('the script the hooks run', () => {
  it('posts the event, keeps the answer, and drains the pipe', () => {
    const dir = scratch()
    const at = place(dir, POSTER_FILE, posterScript(input(dir, { curl: fakeCurl(dir, { reply: '{"ok":1}' }) })))

    const answer = call(at, ['SessionStart'], '{"session_id":"x"}')

    expect(answer.status).toBe(0)
    // The body reaches the model through this, so it must not be discarded the
    // way three of the five local commands discard theirs.
    expect(answer.out).toBe('{"ok":1}')
    // The CLI writes the event into this process and blocks; a client that exits
    // without reading is an EPIPE hook failure in somebody's terminal.
    expect(readFileSync(join(dir, 'stdin'), 'utf8')).toBe('{"session_id":"x"}')
    const argv = readFileSync(join(dir, 'argv'), 'utf8')
    expect(argv).toContain('http://127.0.0.1:40405/hook/claude/SessionStart')
    expect(argv).toContain('server-1 shell-9')
    // The wrapper names the config with `/` on the server; argv carries it verbatim.
    expect(argv).toContain(`${dir}/${HOOK_CONFIG_FILE}`)
  })

  it('is silent and successful when nothing answers', () => {
    const dir = scratch()
    const at = place(dir, POSTER_FILE, posterScript(input(dir, { curl: fakeCurl(dir, { status: 7 }) })))

    const answer = call(at, ['PostToolUse'], '{}')

    // A hook that fires while the app is gone, or while the tunnel is down, must
    // be silence rather than an error inside somebody's session.
    expect(answer.status).toBe(0)
    expect(answer.out).toBe('')
  })

  it('refuses a word it was not given by the settings file', () => {
    const dir = scratch()
    const at = place(dir, POSTER_FILE, posterScript(input(dir)))

    expect(call(at, ['../../etc/passwd'], '{}').status).toBe(0)
    expect(existsSync(join(dir, 'argv'))).toBe(false)
  })
})

/* ---------------------------------------------------------------- the open -- */

describe('the open shim, run', () => {
  function shim(dir: string, over: { real?: string; reply?: string; status?: number } = {}): string {
    const curl = fakeCurl(dir, { reply: over.reply, status: over.status })
    return place(dir, 'bin/open', openerScript('open', over.real ?? '', input(dir, { curl })))
  }

  it('lands a URL in the app and prints which window', () => {
    const dir = scratch()
    const at = shim(dir, { real: fakeOpener(dir), reply: 'tab\nOpened in B1.\n' })

    const answer = call(at, ['https://example.com/a?b=1'])

    expect(answer.status).toBe(0)
    expect(answer.out).toBe('Opened in B1.\n')
    // The real opener was never reached — the page is in the app, not on the
    // server, which is the whole of the complaint this fixes.
    expect(answer.out).not.toContain('REAL')
    expect(readFileSync(join(dir, 'stdin'), 'utf8')).toBe('https://example.com/a?b=1')
    expect(readFileSync(join(dir, 'argv'), 'utf8')).toContain('http://127.0.0.1:40405/open')
  })

  it('falls through to this server and says so, rather than dropping the link', () => {
    const dir = scratch()
    const at = shim(dir, { real: fakeOpener(dir), status: 7 })

    const answer = call(at, ['https://example.com/'])

    // The local shim says "your default browser", which is true where the person
    // is sitting. Here the fallback opens the page on the server, so it says so.
    expect(answer.out).toContain('opening it on this server instead')
    expect(answer.out).toContain('REAL')
    expect(answer.status).toBe(0)
  })

  it('hands everything that is not one http(s) URL straight to the real opener', () => {
    const dir = scratch()
    const at = shim(dir, { real: fakeOpener(dir), reply: 'tab\nOpened in B1.\n' })

    for (const args of [[], ['.'], ['-a', 'Xcode', 'f.swift'], ['report.pdf'], ['mailto:a@b.c']]) {
      const answer = call(at, args)
      expect(answer.out.split('\n')[0]).toBe('REAL')
      expect(answer.out.split('\n').slice(1).filter((line) => line !== '')).toEqual(args)
    }
    // And the app was never asked about any of them.
    expect(existsSync(join(dir, 'argv'))).toBe(false)
  })

  it('says what the shell would have said when the name never existed here', () => {
    const dir = scratch()
    // `open` is not a standard Linux command, which is the ordinary case for
    // this branch and the reason it is a live path rather than a defensive one.
    const at = shim(dir, { real: '' })

    const answer = call(at, ['.'])

    expect(answer.err.trim()).toBe('open: not found')
    expect(answer.status).toBe(127)
  })

  it('never exits 0 having opened nothing', () => {
    const dir = scratch()
    const at = shim(dir, { real: '', status: 7 })

    const answer = call(at, ['https://example.com/'])

    // Claude maps exit 0 to success and the model will believe it. A URL that
    // could not be placed anywhere has to fail loudly.
    expect(answer.status).toBe(127)
    expect(answer.out).toContain('opening it on this server instead')
  })

  it('never looks its own opener up on the PATH it is first on', () => {
    const dir = scratch()
    const body = openerScript('open', '/usr/bin/xdg-open', input(dir))
    // A lookup here would find this script, which would exec this script, for
    // ever, on every URL, in every terminal on that server.
    expect(body).toContain("REAL='/usr/bin/xdg-open'")
    expect(body).not.toContain('command -v')
  })

  // Skipped on Windows: belongFiles needs a `/`-absolute server scratch dir (the
  // Linux-server shim); the run-through-`sh` siblings above stay cross-platform.
  it.skipIf(process.platform === 'win32')('is written for every opener name, each falling back to its own', () => {
    const dir = scratch()
    const files = belongFiles(
      input(dir, { openers: { open: '', 'xdg-open': '/usr/bin/xdg-open' } }),
    )
    for (const name of OPENER_NAMES) {
      const file = files.find((entry) => entry.path === `bin/${name}`)
      expect(file?.executable).toBe(true)
      expect(file?.body).toContain(`${name}: not found`)
    }
    expect(files.find((entry) => entry.path === 'bin/xdg-open')?.body).toContain(
      "REAL='/usr/bin/xdg-open'",
    )
    expect(files.find((entry) => entry.path === 'bin/open')?.body).toContain("REAL=''")
  })
})

// Skipped on Windows: belongFiles needs a `/`-absolute server scratch dir; the
// Linux-server shim's document manifest is asserted on POSIX hosts.
describe.skipIf(process.platform === 'win32')('the documents', () => {
  it('rides along when there are hooks to read them, and not otherwise', () => {
    const dir = scratch()
    const pages = { 'INDEX.md': '# index', 'browser-windows.md': '# windows' }
    const withHooks = belongFiles(input(dir, { pages })).map((file) => file.path)
    expect(withHooks).toContain('context/INDEX.md')
    expect(withHooks).toContain('context/browser-windows.md')

    // No hooks means nothing will ever hand an agent the map that names them, so
    // writing the documents would be leaving files on somebody's machine that
    // nothing can reach.
    const without = belongFiles(input(dir, { pages, hooks: false })).map((file) => file.path)
    expect(without.some((path) => path.startsWith('context/'))).toBe(false)
  })
})

describe('the flag itself', () => {
  it('is spelled once', () => {
    expect(SETTINGS_FLAG).toBe('--settings')
  })
})
