import { describe, expect, it, vi } from 'vitest'
import type { DevPortDetail } from './dev-ports'
import {
  commandFor,
  createDevServers,
  findDevScript,
  latestLine,
  packageManagerFor,
  portsInOutput,
  type DevScript,
  type DevServerState,
  type ProjectIo,
  type SessionOpened,
} from './dev-server'

/**
 * The tests that matter here are the ones about what "ready" is allowed to mean.
 *
 * Everything else in this file is ordinary — a JSON reader, a regex, a state
 * machine — and would survive being rewritten badly. The four that would not are
 * grouped under "ready is a port that accepted a connection": a scan alone must
 * never produce `ready`, a port that was already up must never produce it, a
 * line of output must never produce it, and a dial that fails must leave the
 * thing honestly unfinished. Those are the ones a future change is most likely
 * to "simplify" into a lie, because every one of them would make the feature
 * feel faster.
 */

/* ----------------------------------------------------------------- fixtures */

/**
 * A fake filesystem: paths to contents, and the set of paths that exist.
 *
 * The keys below are written with forward slashes because they are easier to
 * read that way, and the lookup folds separators so they keep matching on
 * Windows.
 *
 * That fold is not cosmetic. `findDevScript` builds its paths with `node:path`'s
 * `join`, which is correct — on Windows it produces `\p\package.json`, which is
 * what a real Windows folder looks like. The fixture keys are `/p/package.json`,
 * so every lookup missed, `findDevScript` answered `null` for every project, and
 * ten tests failed on `windows-latest` while passing on every Mac. It took a
 * release build to find, which is exactly the class of bug the CRLF work was
 * about: a test that encodes one platform's spelling and calls it the answer.
 */
function io(files: Record<string, string>): ProjectIo {
  const norm = (path: string): string => path.replace(/\\/g, '/')
  const table = new Map(Object.entries(files).map(([path, body]) => [norm(path), body]))
  return {
    readFile: (path) => table.get(norm(path)) ?? null,
    exists: (path) => table.has(norm(path)),
  }
}

/**
 * A clock the test drives.
 *
 * `sleep` advances the clock and yields a real event-loop turn, so the watcher's
 * ninety-second timeout costs microseconds and no test waits on a wall clock.
 */
function clock() {
  let at = 0
  return {
    now: () => at,
    sleep: (ms: number) =>
      new Promise<void>((resolve) => {
        at += ms
        setImmediate(resolve)
      }),
  }
}

/** Let the module's own promise chain run to a standstill. */
async function settle(turns = 4000): Promise<void> {
  for (let i = 0; i < turns; i += 1) await new Promise((resolve) => setImmediate(resolve))
}

const DEV: DevScript = { script: 'dev', manager: 'pnpm', fromLockfile: true, command: 'pnpm run dev' }

interface Harness {
  /** Ports the OS reports as listening. Mutate it to bring a server "up". */
  listening: Set<number>
  /** Ports a dial will actually be accepted on. Not the same set, on purpose. */
  accepting: Set<number>
  /** Session id → what it has printed. */
  output: Map<string, string>
  /** Session ids still running. */
  running: Set<string>
  typed: Array<{ sessionId: string; data: string }>
  dialled: Array<{ port: number; host: string }>
  states: DevServerState[]
  servers: ReturnType<typeof createDevServers>
  open: (folder: string) => Promise<SessionOpened>
  opens: string[]
}

function harness(options: { script?: DevScript | null; refuse?: string } = {}): Harness {
  const { now, sleep } = clock()
  const listening = new Set<number>()
  const accepting = new Set<number>()
  const output = new Map<string, string>()
  const running = new Set<string>()
  const typed: Array<{ sessionId: string; data: string }> = []
  const dialled: Array<{ port: number; host: string }> = []
  const states: DevServerState[] = []
  const opens: string[] = []
  let nextSession = 0

  const servers = createDevServers({
    now,
    sleep,
    scan: async (): Promise<readonly DevPortDetail[]> =>
      [...listening].map((port) => ({
        port,
        process: 'node',
        guessed: false,
        // A dev server this app started is still the project's server, not one
        // of this app's own listeners — `ours` is about who holds the socket.
        ours: false,
        families: { v4: true, v6: false },
      })),
    dial: async (port, host) => {
      dialled.push({ port, host })
      return accepting.has(port)
    },
    type: (sessionId, data) => {
      typed.push({ sessionId, data })
    },
    read: (sessionId) => output.get(sessionId) ?? '',
    alive: (sessionId) => running.has(sessionId),
    findScript: () => (options.script === undefined ? DEV : options.script),
  })
  servers.onChange((state) => states.push(state))

  const open = async (folder: string): Promise<SessionOpened> => {
    opens.push(folder)
    if (options.refuse) return { ok: false, message: options.refuse }
    nextSession += 1
    const sessionId = `s${nextSession}`
    running.add(sessionId)
    // A shell prints a prompt the moment it starts, which is the signal the
    // module waits for before typing.
    output.set(sessionId, '$ ')
    return { ok: true, sessionId }
  }

  return { listening, accepting, output, running, typed, dialled, states, servers, open, opens }
}

/* ------------------------------------------------------- finding the command */

describe('findDevScript reads the project rather than guessing', () => {
  it('finds dev, and builds the command from the lockfile that is there', () => {
    const found = findDevScript(
      '/p',
      io({ '/p/package.json': '{"scripts":{"dev":"vite"}}', '/p/pnpm-lock.yaml': '' }),
    )
    expect(found).toEqual({ script: 'dev', manager: 'pnpm', fromLockfile: true, command: 'pnpm run dev' })
  })

  it('offers nothing when there is no package.json', () => {
    expect(findDevScript('/p', io({}))).toBeNull()
  })

  it('offers nothing when the package.json does not parse', () => {
    expect(findDevScript('/p', io({ '/p/package.json': '{ not json' }))).toBeNull()
  })

  it('offers nothing when there are no scripts at all', () => {
    expect(findDevScript('/p', io({ '/p/package.json': '{"name":"x"}' }))).toBeNull()
  })

  it('offers nothing when none of the conventional names is declared', () => {
    // The whole point: `build` and `test` exist, and neither is a dev server.
    // Running one because a button had to do something is the failure this
    // returns null to avoid.
    const source = '{"scripts":{"build":"tsc","test":"vitest","deploy":"./ship.sh"}}'
    expect(findDevScript('/p', io({ '/p/package.json': source }))).toBeNull()
  })

  it('treats a declared-but-empty script as not declared', () => {
    const source = '{"scripts":{"dev":"   ","start":"node server.js"}}'
    expect(findDevScript('/p', io({ '/p/package.json': source }))?.script).toBe('start')
  })

  it('prefers dev, then start, then serve', () => {
    const all = '{"scripts":{"serve":"http-server","start":"node .","dev":"vite"}}'
    expect(findDevScript('/p', io({ '/p/package.json': all }))?.script).toBe('dev')
    const two = '{"scripts":{"serve":"http-server","start":"node ."}}'
    expect(findDevScript('/p', io({ '/p/package.json': two }))?.script).toBe('start')
    const one = '{"scripts":{"serve":"http-server"}}'
    expect(findDevScript('/p', io({ '/p/package.json': one }))?.script).toBe('serve')
  })
})

describe('the package manager comes from the lockfile on disk', () => {
  const cases: Array<[string, string]> = [
    ['pnpm-lock.yaml', 'pnpm'],
    ['yarn.lock', 'yarn'],
    ['bun.lockb', 'bun'],
    ['bun.lock', 'bun'],
    ['package-lock.json', 'npm'],
    ['npm-shrinkwrap.json', 'npm'],
  ]
  for (const [file, manager] of cases) {
    it(`${file} means ${manager}`, () => {
      expect(packageManagerFor('/p', io({ [`/p/${file}`]: '' }))).toEqual({ manager, fromLockfile: true })
    })
  }

  it('a stale package-lock.json does not beat a pnpm-lock.yaml', () => {
    // The realistic mixed case: a repository that moved to pnpm and never
    // deleted the old lockfile. Reading the most specific evidence first is what
    // makes one check enough.
    const both = io({ '/p/pnpm-lock.yaml': '', '/p/package-lock.json': '' })
    expect(packageManagerFor('/p', both).manager).toBe('pnpm')
  })

  it('falls back to npm and says that it was a fallback', () => {
    expect(packageManagerFor('/p', io({}))).toEqual({ manager: 'npm', fromLockfile: false })
  })

  it('spells out `run` for every manager, so a script cannot shadow a subcommand', () => {
    // `yarn add` is yarn's own command; a project with a script called `add`
    // would otherwise have this run yarn instead of the project.
    expect(commandFor('yarn', 'add')).toBe('yarn run add')
    expect(commandFor('bun', 'dev')).toBe('bun run dev')
    expect(commandFor('npm', 'serve')).toBe('npm run serve')
  })
})

/* --------------------------------------------------------- reading the output */

describe('portsInOutput only ever produces candidates to dial', () => {
  it('reads the URL Vite prints', () => {
    expect(portsInOutput('  ➜  Local:   http://localhost:5173/')).toEqual([5173])
  })

  it('reads the URL Next prints', () => {
    expect(portsInOutput('- Local:        http://127.0.0.1:3000')).toEqual([3000])
  })

  it('reads an IPv6 URL', () => {
    expect(portsInOutput('Server running at http://[::1]:4321/')).toEqual([4321])
  })

  it('reads the frameworks that print a number instead of a URL', () => {
    expect(portsInOutput('Listening on port 8080')).toEqual([8080])
    expect(portsInOutput('ready on port 4000')).toEqual([4000])
  })

  it('drops anything that is not a port number', () => {
    expect(portsInOutput('http://localhost:99999/ and port 0')).toEqual([])
  })

  it('does not repeat a port a server printed twice', () => {
    expect(portsInOutput('http://localhost:3000\nhttp://localhost:3000')).toEqual([3000])
  })
})

describe('latestLine is the server talking, not this app', () => {
  it('takes the last line that has something on it', () => {
    expect(latestLine('one\ntwo\n\n  \n')).toBe('two')
  })

  it('strips the escapes a spinner paints with', () => {
    // Written as \x1b escapes rather than pasted control bytes: a pasted ESC is
    // invisible in a diff, so a test that lost one would go on passing while
    // stripping nothing at all.
    expect(latestLine('\x1b[32mcompiling\x1b[0m')).toBe('compiling')
    expect(latestLine('building\x1b[2K\x1b[1G')).toBe('building')
  })

  it('caps a line that would otherwise be a page', () => {
    expect(latestLine('x'.repeat(5000))?.length).toBe(200)
  })

  it('has nothing to say about output that is only whitespace', () => {
    expect(latestLine('\n\n   \n')).toBeNull()
  })
})

/* -------------------------------------------- ready is a real TCP connection */

describe('ready is a port that accepted a connection', () => {
  it('does not report ready from a port scan alone', async () => {
    const h = harness()
    // The measured Windows case: the OS lists the port and every dial to it is
    // refused. `accepting` is deliberately left empty.
    await h.servers.start('/p', h.open)
    h.listening.add(5173)
    await settle()
    const final = h.servers.status('/p')
    expect(final.status).toBe('failed')
    expect(final.port).toBeUndefined()
    // It did try — this is a failure to connect, not a failure to look.
    expect(h.dialled.some((d) => d.port === 5173)).toBe(true)
  })

  it('does not report ready from a line of output alone', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.output.set('s1', '$ pnpm run dev\n  ➜  Local:   http://localhost:5173/\n')
    await settle()
    expect(h.servers.status('/p').status).toBe('failed')
    expect(h.dialled.some((d) => d.port === 5173)).toBe(true)
  })

  it('reports ready once something accepts, and names the port it proved', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.output.set('s1', '$ pnpm run dev\n  ➜  Local:   http://localhost:5173/\n')
    h.listening.add(5173)
    h.accepting.add(5173)
    await settle()
    const final = h.servers.status('/p')
    expect(final.status).toBe('ready')
    expect(final.port).toBe(5173)
    expect(final.url).toBe('http://localhost:5173')
    expect(final.sessionId).toBe('s1')
  })

  it('never credits a port that was already listening before the button was pressed', async () => {
    const h = harness()
    // Somebody else's server, up and accepting, on the number this project's log
    // happens to mention. Without the pre-start snapshot this is a false ready
    // against a stranger's process.
    h.listening.add(3000)
    h.accepting.add(3000)
    await h.servers.start('/p', h.open)
    h.output.set('s1', 'ready on port 3000')
    await settle()
    expect(h.servers.status('/p').status).toBe('failed')
    expect(h.dialled.some((d) => d.port === 3000)).toBe(false)
  })

  it('finds a server that prints nothing, from the scan', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.output.set('s1', '$ pnpm run dev\n')
    h.listening.add(4200)
    h.accepting.add(4200)
    await settle()
    expect(h.servers.status('/p').port).toBe(4200)
  })
})

/* ------------------------------------------------------- the rest of the states */

describe('the states a client has to be able to tell apart', () => {
  it('offers nothing at all for a folder with no dev script', async () => {
    const h = harness({ script: null })
    expect(h.servers.status('/p')).toEqual({ folder: '/p', status: 'no-dev-script' })
    const outcome = await h.servers.start('/p', h.open)
    expect(outcome.status).toBe('no-dev-script')
    // The load-bearing assertion: nothing was run. A button that was never
    // offered, pressed anyway, must not invent a command.
    expect(h.opens).toEqual([])
    expect(h.typed).toEqual([])
  })

  it('idle carries the command it would run, so the client can show it', () => {
    const h = harness()
    expect(h.servers.status('/p')).toEqual({
      folder: '/p',
      status: 'idle',
      script: 'dev',
      command: 'pnpm run dev',
    })
  })

  it('answers starting immediately and types the command into the session', async () => {
    const h = harness()
    const first = await h.servers.start('/p', h.open)
    expect(first.status).toBe('starting')
    expect(first.sessionId).toBe('s1')
    await settle(50)
    expect(h.typed).toEqual([{ sessionId: 's1', data: 'pnpm run dev\r' }])
  })

  it('surfaces the server’s own latest line while it is starting', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.output.set('s1', '$ pnpm run dev\nCompiling /app ...\n')
    await settle(60)
    const note = h.states.filter((s) => s.status === 'starting').map((s) => s.note)
    expect(note).toContain('Compiling /app ...')
  })

  it('does not resend the note when the line has not changed', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.output.set('s1', 'building\n')
    await settle(200)
    const notes = h.states.filter((s) => s.note === 'building')
    expect(notes.length).toBe(1)
  })

  it('fails, keeping the session, when the command exits without listening', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.output.set('s1', 'Error: Cannot find module ‘vite’\n')
    h.running.delete('s1')
    await settle()
    const final = h.servers.status('/p')
    expect(final.status).toBe('failed')
    expect(final.message).toContain('pnpm run dev')
    // The session id is kept on purpose: the error is in it, and that is the
    // only useful thing on screen.
    expect(final.sessionId).toBe('s1')
  })

  it('fails honestly on a timeout and says the command is still running', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.output.set('s1', 'still building\n')
    await settle()
    const final = h.servers.status('/p')
    expect(final.status).toBe('failed')
    expect(final.message).toContain('still running')
    // Not killed. Nothing here stops the session.
    expect(h.running.has('s1')).toBe(true)
  })

  it('passes a refusal from the opener through unchanged', async () => {
    const h = harness({ refuse: 'This Mac is not offering that folder to this device.' })
    const outcome = await h.servers.start('/p', h.open)
    expect(outcome.status).toBe('failed')
    expect(outcome.message).toBe('This Mac is not offering that folder to this device.')
    expect(h.typed).toEqual([])
  })

  it('a second press while it is starting does not start a second server', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    const again = await h.servers.start('/p', h.open)
    expect(again.status).toBe('starting')
    expect(h.opens).toEqual(['/p'])
  })

  it('a press while it is ready answers ready and starts nothing', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.listening.add(5173)
    h.accepting.add(5173)
    await settle()
    expect(h.servers.status('/p').status).toBe('ready')
    const again = await h.servers.start('/p', h.open)
    expect(again.status).toBe('ready')
    expect(h.opens).toEqual(['/p'])
  })
})

describe('the state follows the session, because the session is the truth', () => {
  it('goes back to idle when a ready session is killed, with nothing wired', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.listening.add(5173)
    h.accepting.add(5173)
    await settle()
    expect(h.servers.status('/p').status).toBe('ready')

    // The user closed the tab. Nothing called `noteExit`.
    h.running.delete('s1')
    const after = h.servers.status('/p')
    expect(after.status).toBe('idle')
    // And crucially the address is gone: a `url` left behind here would be this
    // module advertising a server that is not there.
    expect(after.url).toBeUndefined()
    expect(after.port).toBeUndefined()
  })

  it('pushes the change straight away when noteExit is wired', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.listening.add(5173)
    h.accepting.add(5173)
    await settle()
    h.states.length = 0
    h.running.delete('s1')
    h.servers.noteExit('s1')
    expect(h.states.map((s) => s.status)).toEqual(['idle'])
  })

  it('restarting after a failure drops the old sentence and the old session', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.running.delete('s1')
    await settle()
    expect(h.servers.status('/p').status).toBe('failed')

    const again = await h.servers.start('/p', h.open)
    expect(again.status).toBe('starting')
    expect(again.sessionId).toBe('s2')
    expect(again.message).toBeUndefined()
  })

  it('treats a trailing separator as the same project', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    expect(h.servers.status('/p/').status).toBe('starting')
  })
})

describe('two projects at once', () => {
  it('both reach ready — one folder starting does not abandon the other', async () => {
    // The shared-run-token bug: with one counter for the module, starting the
    // second project made the first project's watcher believe it had been
    // superseded, and its row sat on `starting` until the app was restarted.
    // Two checkouts running at once is the ordinary case on this machine.
    const h = harness()
    await h.servers.start('/a', h.open)
    await h.servers.start('/b', h.open)
    h.output.set('s1', 'Local: http://localhost:5173/')
    h.output.set('s2', 'Local: http://localhost:5174/')
    h.listening.add(5173)
    h.listening.add(5174)
    h.accepting.add(5173)
    h.accepting.add(5174)
    await settle()
    expect(h.servers.status('/a').port).toBe(5173)
    expect(h.servers.status('/b').port).toBe(5174)
  })
})

describe('dispose stops the watchers', () => {
  it('writes nothing after it has been disposed', async () => {
    const h = harness()
    await h.servers.start('/p', h.open)
    h.servers.dispose()
    const seen = vi.fn()
    h.servers.onChange(seen)
    h.listening.add(5173)
    h.accepting.add(5173)
    await settle(200)
    expect(seen).not.toHaveBeenCalled()
  })
})
