import { spawn } from 'node:child_process'
import {
  chmodSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { BRAND } from '../shared/brand'
import { startHookServer, stopHookServer, type HookEvent } from './hook-server'
import {
  HOOK_MARKER,
  HOOK_PROVIDERS,
  applyInstall,
  applyRemove,
  backupPathFor,
  detectIndent,
  hookCommand,
  installHooks,
  isOurs,
  ownerOf,
  readStatus,
  removeHooks,
  syncInstalledHooks,
  writeAtomic,
  type HookContext,
} from './hooks'

/**
 * These tests exist because this feature writes to the user's real config. The
 * happy path is the least interesting part: what has to hold is that a file
 * containing somebody else's hooks comes back byte-identical in those parts
 * after we install and then uninstall, that a file we cannot parse is never
 * rewritten, and that a 0600 file stays 0600.
 *
 * The fixtures are trimmed copies of the shapes actually found on this machine:
 * a Claude settings.json carrying Vibeyard's hooks and unrelated top-level keys,
 * a Gemini settings.json whose hook entries carry `name`, and a Codex hooks.json
 * that holds nothing but hooks.
 */

/**
 * Two POSIX facts this file leans on, and what each means off POSIX.
 *
 * **File modes.** Windows has no mode bits behind `chmod` — a file written
 * 0o600 reads back as 0o666 there, synthesised from the read-only attribute
 * (measured on Windows 11). "Stays 0600" is a claim that cannot be made or
 * broken on that platform, so it is skipped rather than softened.
 *
 * **A shell to run the hook in.** The command this module writes is POSIX
 * through and through: `/usr/bin/curl`, `|| true`, single-quoted arguments and
 * a trailing `#` comment, none of which is `cmd.exe` syntax. There is no
 * Windows form of it yet, and no `/bin/sh` to run the POSIX one with —
 * `spawn('/bin/sh')` fails ENOENT there, which is exactly how these three
 * cases failed. Running them under Git Bash instead would prove something
 * about Git Bash; it would not prove anything about the shell a provider CLI
 * actually uses on Windows. See the note in `hooks.ts`.
 */
const ON_WINDOWS = process.platform === 'win32'

let root: string
let context: HookContext

/**
 * A stand-in endpoint whose address does not move, which is the point.
 *
 * `socketPath` and `configPath` are the only two values that reach a hook
 * command now, and both are stable for the life of an install. The token is on
 * the endpoint because `hook-server.ts` still mints one; it just never reaches
 * the command, and one of the tests below asserts exactly that.
 */
const ENDPOINT = {
  socketPath: '/tmp/terminaldeck-test/hook.sock',
  configPath: '/tmp/terminaldeck-test/hook-endpoint.conf',
  token: 'a'.repeat(48),
}

/** An install written by another copy of the app — a different data directory. */
const OTHER_COPY = {
  socketPath: '/tmp/terminaldeck-other/hook.sock',
  configPath: '/tmp/terminaldeck-other/hook-endpoint.conf',
  token: 'old',
}

/**
 * A short, fixed-width unique suffix.
 *
 * `Math.random().toString(36).slice(2)` was here, and it is why this file failed
 * roughly every other run on this Mac and passed on its own every time it was
 * re-run to check. That expression has no fixed length — it is however many
 * base-36 digits the double happened to need, usually eleven and sometimes
 * thirteen — and one of the tests below opens a real unix socket inside this
 * directory. macOS puts `tmpdir()` at
 * `/var/folders/xx/…………………………………/T/`, 49 bytes of it, so the whole path landed
 * within a byte or two of the 100-byte ceiling `hook-server.ts` enforces and
 * crossed it whenever the random part came out long. A flake in a release gate
 * is worse than a failure: it teaches whoever is watching to run it again.
 *
 * Eight characters, always, padded rather than trimmed — `toString(36)` of a
 * small number is short, and slicing a long one is what produced the collision
 * risk this is guarding against in the first place.
 */
const shortUnique = (): string =>
  Math.floor(Math.random() * 36 ** 8)
    .toString(36)
    .padStart(8, '0')

beforeEach(() => {
  root = join(tmpdir(), `td-hooks-${process.pid}-${shortUnique()}`)
  mkdirSync(root, { recursive: true })
  context = { home: root, backupDir: join(root, 'backups'), endpoint: ENDPOINT }
})

afterEach(() => rmSync(root, { recursive: true, force: true }))

/* ---------------------------------------------------------------- fixtures -- */

/** A hook belonging to another tool installed on the same machine. */
const VIBEYARD_STATUS_HOOK = {
  type: 'command',
  command:
    "sh -c 'mkdir -p /tmp/vibeyard && echo SessionStart:waiting > /tmp/vibeyard/$CLAUDE_IDE_SESSION_ID.status # vibeyard-hook'",
}

const VIBEYARD_EVENT_HOOK = {
  type: 'command',
  command: '/usr/bin/python3 "/Users/apple/.vibeyard/run/claude_event_Stop.py" "# vibeyard-hook"',
}

function claudeSettings(): string {
  return `${JSON.stringify(
    {
      cleanupPeriodDays: 3650,
      permissions: { allow: ['mcp__example__*'], defaultMode: 'bypassPermissions' },
      hooks: {
        SessionStart: [{ matcher: '', hooks: [VIBEYARD_STATUS_HOOK] }],
        Stop: [{ matcher: '', hooks: [VIBEYARD_EVENT_HOOK] }],
      },
      statusLine: { type: 'command', command: '/Users/apple/.vibeyard/run/statusline.sh' },
      effortLevel: 'xhigh',
    },
    null,
    2,
  )}\n`
}

function writeClaude(body = claudeSettings(), mode = 0o600): string {
  const file = join(root, '.claude', 'settings.json')
  mkdirSync(join(root, '.claude'), { recursive: true })
  writeFileSync(file, body, 'utf8')
  chmodSync(file, mode)
  return file
}

function readJson(file: string): Record<string, unknown> {
  return JSON.parse(readFileSync(file, 'utf8')) as Record<string, unknown>
}

/** Every hook entry in a file, flattened, so foreign ones can be counted. */
function allEntries(data: Record<string, unknown>): Array<Record<string, unknown>> {
  const hooks = (data.hooks ?? {}) as Record<string, unknown>
  const out: Array<Record<string, unknown>> = []
  for (const value of Object.values(hooks)) {
    if (!Array.isArray(value)) continue
    for (const group of value) {
      const entries = (group as { hooks?: unknown[] }).hooks
      if (Array.isArray(entries)) out.push(...(entries as Array<Record<string, unknown>>))
    }
  }
  return out
}

/* ------------------------------------------------------------- ownership -- */

describe('ownership', () => {
  it('claims only entries carrying our marker', () => {
    expect(isOurs({ type: 'command', command: `curl ... ${HOOK_MARKER}` })).toBe(true)
    expect(isOurs(VIBEYARD_STATUS_HOOK)).toBe(false)
    expect(isOurs({ type: 'command' })).toBe(false)
    expect(isOurs('not an object')).toBe(false)
  })

  it('reads the owner out of a foreign marker', () => {
    expect(ownerOf(VIBEYARD_STATUS_HOOK)).toBe('vibeyard')
    expect(ownerOf({ type: 'command', command: 'echo hi' })).toBe(null)
  })

  it('builds a command that consumes stdin, tags itself and cannot fail the session', () => {
    const command = hookCommand('claude', 'Stop', ENDPOINT)
    expect(command).toContain('--data-binary @-')
    expect(command).toContain('http://localhost/hook/claude/Stop')
    expect(command).toContain('|| true')
    expect(command.endsWith(HOOK_MARKER)).toBe(true)
  })

  /**
   * The staleness fix, pinned as a property of the string itself.
   *
   * Every launch used to mint a new port and a new token and write both into
   * this command, so every launch invalidated every installed hook: all three
   * providers reported "Needs reinstalling" forever and lifecycle events —
   * session-finished among them — silently stopped arriving. Nothing here may
   * ever go back to interpolating a per-run value, so the command is compared
   * across two endpoints that differ only in their tokens.
   */
  it('is identical for two runs of the same install, and carries no token', () => {
    const laterRun = { ...ENDPOINT, token: 'b'.repeat(48) }
    expect(hookCommand('claude', 'Stop', laterRun)).toBe(hookCommand('claude', 'Stop', ENDPOINT))
    expect(hookCommand('claude', 'Stop', ENDPOINT)).not.toContain(ENDPOINT.token)
    // The token is read from here at call time instead, so it never lands in a
    // provider config — two of the three are mode 0644.
    expect(hookCommand('claude', 'Stop', ENDPOINT)).toContain(`-K '${ENDPOINT.configPath}'`)
  })

  /**
   * The command goes into a config file and is run by the user's shell on every
   * tool call. Nothing that reaches it is attacker-controlled today, which is
   * exactly why this is worth pinning: the day the token generator changes,
   * the failure would be silent and total.
   */
  it.skipIf(ON_WINDOWS)('cannot be broken out of by a value that carries a quote', async () => {
    const command = hookCommand('claude', 'Stop', {
      ...ENDPOINT,
      configPath: "/tmp/x'; touch /tmp/terminaldeck-hook-injection; echo '",
    })
    // The probe goes on its own line: the command ends with a shell comment, so
    // anything appended after it on the same line is never reached.
    const child = spawn('/bin/sh', ['-c', `${command}\necho DONE`], { stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    child.stdout.on('data', (chunk: Buffer) => {
      stdout += chunk.toString()
    })
    child.stdin.end('{}')
    await new Promise((resolve) => child.on('close', resolve))

    expect(stdout.trim()).toBe('DONE')
    expect(() => statSync('/tmp/terminaldeck-hook-injection')).toThrow()
  })
})

/* ---------------------------------------------------------- pure transforms -- */

describe('applyInstall', () => {
  it('adds our entries without disturbing a foreign hook in the same event', () => {
    const before = JSON.parse(claudeSettings()) as Record<string, unknown>
    const after = applyInstall(before, HOOK_PROVIDERS.claude, ENDPOINT)

    const hooks = after.hooks as Record<string, unknown[]>
    const sessionStart = hooks.SessionStart
    expect(sessionStart).toHaveLength(2)
    // The foreign group is the same object shape it arrived as.
    expect(sessionStart[0]).toEqual({ matcher: '', hooks: [VIBEYARD_STATUS_HOOK] })
    expect(isOurs((sessionStart[1] as { hooks: unknown[] }).hooks[0])).toBe(true)
  })

  it('is idempotent — installing twice leaves one entry per event', () => {
    const once = applyInstall({}, HOOK_PROVIDERS.claude, ENDPOINT)
    const twice = applyInstall(once, HOOK_PROVIDERS.claude, ENDPOINT)
    expect(allEntries(twice).filter(isOurs)).toHaveLength(HOOK_PROVIDERS.claude.events.length)
  })

  it('replaces an install pointing at another copy of the app', () => {
    const old = applyInstall({}, HOOK_PROVIDERS.claude, OTHER_COPY)
    const fresh = applyInstall(old, HOOK_PROVIDERS.claude, ENDPOINT)
    const commands = allEntries(fresh)
      .filter(isOurs)
      .map((entry) => entry.command as string)
    expect(commands.every((command) => command.includes(ENDPOINT.configPath))).toBe(true)
    expect(commands.some((command) => command.includes(OTHER_COPY.configPath))).toBe(false)
  })

  it('cleans up an event an older version installed and this one does not', () => {
    const before = {
      hooks: { RetiredEvent: [{ matcher: '', hooks: [{ type: 'command', command: `old ${HOOK_MARKER}` }] }] },
    }
    const after = applyInstall(before, HOOK_PROVIDERS.claude, ENDPOINT)
    // Not left behind as an empty array — that is litter in somebody's config.
    expect((after.hooks as Record<string, unknown>).RetiredEvent).toBeUndefined()
  })

  it('leaves non-event keys in a Gemini hooks object alone', () => {
    // Gemini legally stores `enabled`, `disabled` and `notifications` in here.
    const before = { hooks: { enabled: true, notifications: { level: 'all' } } }
    const after = applyInstall(before, HOOK_PROVIDERS.gemini, ENDPOINT)
    const hooks = after.hooks as Record<string, unknown>
    expect(hooks.enabled).toBe(true)
    expect(hooks.notifications).toEqual({ level: 'all' })
  })

  it('gives Gemini entries a name and Claude entries none', () => {
    const gemini = allEntries(applyInstall({}, HOOK_PROVIDERS.gemini, ENDPOINT))[0]
    expect(gemini.name).toBeDefined()
    // Claude's command-hook schema does not document `name`; do not invent it.
    const claude = allEntries(applyInstall({}, HOOK_PROVIDERS.claude, ENDPOINT))[0]
    expect(claude.name).toBeUndefined()
  })

  it('uses seconds for Claude and milliseconds for Gemini', () => {
    expect(allEntries(applyInstall({}, HOOK_PROVIDERS.claude, ENDPOINT))[0].timeout).toBe(5)
    expect(allEntries(applyInstall({}, HOOK_PROVIDERS.gemini, ENDPOINT))[0].timeout).toBe(5000)
  })
})

describe('applyRemove', () => {
  it('reports nothing removed when the file was never ours', () => {
    const before = JSON.parse(claudeSettings()) as Record<string, unknown>
    const { data, removed } = applyRemove(before)
    expect(removed).toBe(0)
    // Unchanged means the very same object, so no write is even attempted.
    expect(data).toBe(before)
  })

  it('drops the hooks key entirely when we were the only thing in it', () => {
    const installed = applyInstall({ theme: 'dark' }, HOOK_PROVIDERS.claude, ENDPOINT)
    const { data } = applyRemove(installed)
    expect(data.hooks).toBeUndefined()
    expect(data.theme).toBe('dark')
  })

  it('keeps a matcher group that still holds somebody else’s hook', () => {
    const before = {
      hooks: {
        Stop: [
          {
            matcher: '',
            sequential: true,
            hooks: [VIBEYARD_EVENT_HOOK, { type: 'command', command: `x ${HOOK_MARKER}` }],
          },
        ],
      },
    }
    const { data, removed } = applyRemove(before)
    expect(removed).toBe(1)
    const group = (data.hooks as Record<string, unknown[]>).Stop[0]
    // `sequential` is not a key we wrote and not one we may drop.
    expect(group).toEqual({ matcher: '', sequential: true, hooks: [VIBEYARD_EVENT_HOOK] })
  })

  it('leaves an already-empty group we did not empty', () => {
    const before = { hooks: { Stop: [{ matcher: '', hooks: [] }, { matcher: '', hooks: [{ type: 'command', command: `x ${HOOK_MARKER}` }] }] } }
    const { data } = applyRemove(before)
    expect((data.hooks as Record<string, unknown[]>).Stop).toEqual([{ matcher: '', hooks: [] }])
  })
})

/* ------------------------------------------------------------- round trip -- */

describe('install and remove against a real settings file', () => {
  it('returns a foreign install byte-identical after a full round trip', () => {
    const file = writeClaude()
    const original = readFileSync(file, 'utf8')

    expect(installHooks(context, 'claude').ok).toBe(true)
    const installed = readJson(file)
    // Their hooks are still there, and so is everything else in the file.
    expect(allEntries(installed).filter((entry) => !isOurs(entry))).toEqual([
      VIBEYARD_STATUS_HOOK,
      VIBEYARD_EVENT_HOOK,
    ])
    expect(installed.statusLine).toEqual({
      type: 'command',
      command: '/Users/apple/.vibeyard/run/statusline.sh',
    })
    expect(installed.permissions).toEqual({ allow: ['mcp__example__*'], defaultMode: 'bypassPermissions' })

    expect(removeHooks(context, 'claude').ok).toBe(true)
    expect(readFileSync(file, 'utf8')).toBe(original)
  })

  it.skipIf(ON_WINDOWS)('preserves the file mode, so a 0600 config does not become world-readable', () => {
    const file = writeClaude(claudeSettings(), 0o600)
    installHooks(context, 'claude')
    expect(statSync(file).mode & 0o777).toBe(0o600)
  })

  it('preserves the indent width the file already used', () => {
    const file = writeClaude(`${JSON.stringify({ hooks: {} }, null, 4)}\n`)
    installHooks(context, 'claude')
    const raw = readFileSync(file, 'utf8')
    expect(detectIndent(raw)).toBe('    ')
    expect(raw.endsWith('\n')).toBe(true)
  })

  it('creates the file when the provider has never been configured', () => {
    const result = installHooks(context, 'gemini')
    expect(result.ok).toBe(true)
    const file = join(root, '.gemini', 'settings.json')
    expect(allEntries(readJson(file)).filter(isOurs)).toHaveLength(HOOK_PROVIDERS.gemini.events.length)
    // A file we created holds a token, so it starts owner-only.
    if (!ON_WINDOWS) expect(statSync(file).mode & 0o777).toBe(0o600)
  })

  it('backs the original up once, before the first write, and never again', () => {
    const file = writeClaude()
    const original = readFileSync(file, 'utf8')
    const backup = backupPathFor(context, 'claude')

    installHooks(context, 'claude')
    expect(readFileSync(backup, 'utf8')).toBe(original)

    // A second install must not overwrite the pristine copy with a modified one.
    installHooks(context, 'claude')
    expect(readFileSync(backup, 'utf8')).toBe(original)
  })

  it('refuses to rewrite a file it cannot parse', () => {
    const file = writeClaude('{ "hooks": { /* a comment makes this JSONC */ } }')
    const before = readFileSync(file, 'utf8')
    const result = installHooks(context, 'claude')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('not valid JSON')
    expect(readFileSync(file, 'utf8')).toBe(before)
  })

  it('refuses a hooks key that is not an object', () => {
    const file = writeClaude(`${JSON.stringify({ hooks: [] }, null, 2)}\n`)
    const before = readFileSync(file, 'utf8')
    expect(installHooks(context, 'claude').ok).toBe(false)
    expect(readFileSync(file, 'utf8')).toBe(before)
  })

  it('does not touch a file that has none of our hooks when removing', () => {
    const file = writeClaude()
    const before = readFileSync(file, 'utf8')
    const result = removeHooks(context, 'claude')
    expect(result.ok).toBe(true)
    expect(result.message).toContain('not modified')
    expect(readFileSync(file, 'utf8')).toBe(before)
    // Nothing was written, so nothing was backed up either.
    expect(() => statSync(backupPathFor(context, 'claude'))).toThrow()
  })

  it('removes entries from events it no longer installs', () => {
    const file = writeClaude(
      `${JSON.stringify(
        { hooks: { RetiredEvent: [{ matcher: '', hooks: [{ type: 'command', command: `old ${HOOK_MARKER}` }] }] } },
        null,
        2,
      )}\n`,
    )
    const result = removeHooks(context, 'claude')
    expect(result.ok).toBe(true)
    expect(readJson(file).hooks).toBeUndefined()
  })

  /**
   * A dotfiles-managed config is a symlink, and rename() replaces the *name*.
   * Writing over the link left a plain file where the link had been: the CLI
   * read our copy, the user's repo still held the old one, and every edit they
   * made in their dotfiles from then on silently stopped reaching the CLI.
   */
  it('writes through a symlinked settings file instead of replacing the link', () => {
    const store = join(root, 'dotfiles')
    mkdirSync(store, { recursive: true })
    mkdirSync(join(root, '.claude'), { recursive: true })
    const real = join(store, 'claude-settings.json')
    writeFileSync(real, claudeSettings(), 'utf8')
    chmodSync(real, 0o600)
    const link = join(root, '.claude', 'settings.json')
    symlinkSync(real, link)

    expect(installHooks(context, 'claude').ok).toBe(true)

    // Still a link, and the file the user actually manages is the one that grew
    // the hooks.
    expect(lstatSync(link).isSymbolicLink()).toBe(true)
    expect(allEntries(readJson(real)).filter(isOurs)).toHaveLength(HOOK_PROVIDERS.claude.events.length)
    if (!ON_WINDOWS) expect(statSync(real).mode & 0o777).toBe(0o600)

    // And removal has to find its way back through the link too.
    expect(removeHooks(context, 'claude').ok).toBe(true)
    expect(lstatSync(link).isSymbolicLink()).toBe(true)
    expect(readFileSync(real, 'utf8')).toBe(claudeSettings())
  })

  /**
   * The temp name used to be pid + millisecond, which two writes inside one
   * millisecond share — `wx` then fails the second for a reason no user could
   * act on. Timing makes that hard to force, so what this pins is the part that
   * is always checkable: repeated writes converge and leave no litter beside
   * the user's config.
   */
  it('rewrites repeatedly without colliding or leaving temp files behind', () => {
    const file = join(root, '.claude', 'settings.json')
    mkdirSync(join(root, '.claude'), { recursive: true })
    for (let i = 0; i < 40; i++) writeAtomic(file, `{"n":${i}}`, 0o600)
    expect(readFileSync(file, 'utf8')).toBe('{"n":39}')
    expect(readdirSync(join(root, '.claude'))).toEqual(['settings.json'])
  })

  it('refuses to install with no endpoint rather than writing a dead address', () => {
    const file = writeClaude()
    const before = readFileSync(file, 'utf8')
    const result = installHooks({ ...context, endpoint: null }, 'claude')
    expect(result.ok).toBe(false)
    expect(readFileSync(file, 'utf8')).toBe(before)
  })
})

/* ----------------------------------------------------------------- status -- */

describe('readStatus', () => {
  it('reports none for a file with only foreign hooks, and names the owner', () => {
    writeClaude()
    const status = readStatus(context, 'claude')
    expect(status.state).toBe('none')
    expect(status.foreignHooks).toBe(2)
    expect(status.foreignOwners).toEqual(['vibeyard'])
    // The panel renders the foreign line from these fields; the message must
    // not repeat it, or every row states the same fact twice.
    expect(status.message).not.toContain('vibeyard')
  })

  it('reports complete once installed against the live endpoint', () => {
    writeClaude()
    installHooks(context, 'claude')
    const status = readStatus(context, 'claude')
    expect(status.state).toBe('complete')
    expect(status.installedEvents).toEqual(HOOK_PROVIDERS.claude.events)
    expect(status.missingEvents).toEqual([])
    expect(status.backupPath).not.toBe(null)
  })

  it('reports stale when the install points at another copy of the app', () => {
    writeClaude()
    installHooks({ ...context, endpoint: OTHER_COPY }, 'claude')
    const status = readStatus(context, 'claude')
    expect(status.state).toBe('stale')
    expect(status.staleEvents).toEqual(HOOK_PROVIDERS.claude.events)
    expect(status.message).toContain('somewhere other than this copy')
  })

  /**
   * The regression this whole change is about, at the level a user meets it.
   *
   * Reinstall, then read the status back as if the app had been restarted — a
   * second run of the same install, which differs only in its token. Before,
   * this answered `stale` for all ten events every single time, which is why
   * the Hooks page never left "Needs reinstalling" and why nothing downstream
   * of a hook ever fired.
   */
  it('is still complete after a restart, because only the token changed', () => {
    writeClaude()
    installHooks(context, 'claude')
    const nextRun = { ...context, endpoint: { ...ENDPOINT, token: 'c'.repeat(48) } }
    const status = readStatus(nextRun, 'claude')
    expect(status.state).toBe('complete')
    expect(status.staleEvents).toEqual([])
  })

  it('reports partial when only some events are installed', () => {
    const file = join(root, '.claude', 'settings.json')
    mkdirSync(join(root, '.claude'), { recursive: true })
    writeFileSync(
      file,
      JSON.stringify({
        hooks: {
          Stop: [{ matcher: '', hooks: [{ type: 'command', command: hookCommand('claude', 'Stop', ENDPOINT) }] }],
        },
      }),
      'utf8',
    )
    expect(readStatus(context, 'claude').state).toBe('partial')
  })

  it('reports error rather than throwing on an unparseable file', () => {
    writeClaude('not json at all')
    const status = readStatus(context, 'claude')
    expect(status.state).toBe('error')
    expect(status.message).toContain('left untouched')
  })

  it('reports a missing file as none, not as an error', () => {
    const status = readStatus(context, 'codex')
    expect(status.state).toBe('none')
    expect(status.fileExists).toBe(false)
    expect(status.message).toContain('does not exist yet')
  })
})

/* ------------------------------------------------------------ integration -- */

describe('the command we write actually works', () => {
  afterEach(() => stopHookServer())

  /**
   * The command is a string that a shell we do not control will run, and every
   * bug it can have — a quoting mistake, a curl flag that does not exist, a
   * failure to read stdin — is invisible to a test that only inspects the
   * string. So run the real thing through /bin/sh against the real endpoint,
   * exactly the way a provider CLI does: payload on stdin, session id in the
   * environment.
   */
  /** Run a hook command the way a provider CLI does: stdin in, env set. */
  async function runHook(command: string, payload: string): Promise<{ code: number; stderr: string }> {
    const child = spawn('/bin/sh', ['-c', command], {
      env: { ...process.env, [BRAND.sessionEnvVar]: 'session-from-env' },
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    let stderr = ''
    child.stderr.on('data', (chunk: Buffer) => {
      stderr += chunk.toString()
    })
    child.stdin.end(payload)
    const code = await new Promise<number>((resolve) => child.on('close', resolve))
    return { code, stderr }
  }

  it.skipIf(ON_WINDOWS)('posts stdin to the endpoint when run through a shell', async () => {
    const seen: HookEvent[] = []
    const endpoint = await startHookServer({ dir: root, onEvent: (event) => seen.push(event) })
    const command = hookCommand('claude', 'PostToolUse', endpoint)

    const run = await runHook(command, JSON.stringify({ session_id: 'cli-42', tool_name: 'Write' }))

    // Exit 0 always: a hook that fails must never fail the user's turn.
    expect(run.code).toBe(0)
    expect(seen).toHaveLength(1)
    expect(seen[0]).toMatchObject({
      provider: 'claude',
      event: 'PostToolUse',
      sessionId: 'session-from-env',
      cliSessionId: 'cli-42',
      toolName: 'Write',
    })
  })

  /**
   * The whole point of this change, proved the only way it can honestly be
   * proved: write the command once, restart the endpoint, and run **the very
   * same string** — no reinstall, no repair, nothing touched in between.
   *
   * The second run mints a different token and rewrites the config file the
   * command reads, so this also proves the indirection works rather than merely
   * that the path happens to be the same. Before this change the second half of
   * this test could not pass at all: the command carried a port from the first
   * run, and after the restart that port belonged to nobody.
   */
  it.skipIf(ON_WINDOWS)('still reaches the endpoint after a restart, unchanged', async () => {
    const first: HookEvent[] = []
    const before = await startHookServer({ dir: root, onEvent: (event) => first.push(event) })
    const command = hookCommand('claude', 'Stop', before)
    expect((await runHook(command, '{"session_id":"first"}')).code).toBe(0)
    expect(first).toHaveLength(1)

    await stopHookServer()

    const second: HookEvent[] = []
    const after = await startHookServer({ dir: root, onEvent: (event) => second.push(event) })
    // A genuinely new run: same address, different secret.
    expect(after.socketPath).toBe(before.socketPath)
    expect(after.token).not.toBe(before.token)
    // And the command that was written for the first run is byte-identical.
    expect(hookCommand('claude', 'Stop', after)).toBe(command)

    const run = await runHook(command, '{"session_id":"second"}')
    expect(run.code).toBe(0)
    expect(run.stderr).toBe('')
    expect(second).toHaveLength(1)
    expect(second[0]).toMatchObject({ provider: 'claude', event: 'Stop', cliSessionId: 'second' })
  })

  it.skipIf(ON_WINDOWS)('exits cleanly and silently when the app is not listening', async () => {
    // Nothing has ever run here, so neither the socket nor the config exists —
    // which is exactly the state a quit app leaves behind.
    const command = hookCommand('claude', 'Stop', {
      socketPath: join(root, 'never', 'hook.sock'),
      configPath: join(root, 'never', 'hook-endpoint.conf'),
      token: 'x',
    })
    const run = await runHook(command, '{}')

    expect(run.code).toBe(0)
    // Anything on stderr becomes hook-failure noise in the user's session.
    expect(run.stderr).toBe('')
  })
})

describe('syncInstalledHooks', () => {
  it('re-points a stale install and leaves an uninstalled provider alone', () => {
    writeClaude()
    installHooks({ ...context, endpoint: OTHER_COPY }, 'claude')

    const statuses = syncInstalledHooks(context)
    const claude = statuses.find((status) => status.id === 'claude')
    const codex = statuses.find((status) => status.id === 'codex')

    expect(claude?.state).toBe('complete')
    expect(codex?.state).toBe('none')
    // Nothing was created for the provider that had no hooks.
    expect(() => statSync(join(root, '.codex', 'hooks.json'))).toThrow()
  })
})
