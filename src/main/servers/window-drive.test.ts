import { execFileSync } from 'node:child_process'
import { chmodSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { PreparedElsewhere } from '../deck-control/session-tools'
import type { AgentFact } from './facts'
import {
  OPENER_NAMES,
  SETTINGS_FILE,
  SETTINGS_FLAG,
  type ScratchFile,
} from './window-belong'
import {
  MCP_FLAG,
  SCOUT_MARK,
  readScouted,
  takesAnExportLine,
  SCRATCH_PREFIX,
  WHY_NOT,
  WindowDrives,
  armScript,
  disarmScript,
  honoursMcpConfig,
  pathLine,
  scoutScript,
  subcommandsFrom,
  wrapperScript,
  type WindowDriveDeps,
} from './window-drive'

/**
 * The wrapper is a shell script that goes on somebody's `PATH`, so most of this
 * file **runs it**.
 *
 * Reading the generated text and asserting substrings would pass on a script
 * with an unbalanced quote in it, and the failure of such a script is not a
 * missing feature — it is every `claude` in that terminal refusing to start.
 * `sh` is on the machine this suite runs on, `mktemp -d` behaves the same way
 * there, and the whole arrangement is a few files under `/tmp`, so the honest
 * test is to execute it against a stand-in `claude` that prints its own argv.
 */

/** Real `claude --help`, trimmed to the two things this module reads. */
const HELP = `Usage: claude [options] [command] [prompt]

Options:
  --mcp-config <configs...>            Load MCP servers from JSON files or
                                       strings (space-separated)
  -p, --print                          Print response and exit
  --settings <file-or-json>            Path to a settings JSON file or a JSON
                                       string to load additional settings from

Commands:
  agents [options]                     Manage background agents
  doctor                               Check the health of your installation
  mcp                                  Configure and manage MCP servers
  plugin|plugins                       Manage plugins
  update                               Update to the latest version
`

const made: string[] = []

afterEach(() => {
  for (const dir of made.splice(0)) rmSync(dir, { recursive: true, force: true })
  vi.restoreAllMocks()
})

/**
 * A `claude` that answers with exactly the arguments it was handed.
 *
 * One line per argument, so a test can tell `--mcp-config /a /b` from
 * `"--mcp-config /a /b"` — which is the difference between a flag and a prompt.
 */
function fakeClaude(): string {
  const dir = mkdtempSync(join(tmpdir(), 'td-fake-claude-'))
  made.push(dir)
  const path = join(dir, 'claude')
  writeFileSync(path, '#!/bin/sh\nfor a in "$@"; do printf \'%s\\n\' "$a"; done\n', 'utf8')
  chmodSync(path, 0o755)
  return path
}

/** Run one script on this machine's own `sh`, the way the far end would. */
function run(script: string): string {
  return execFileSync('sh', ['-s'], { input: script, encoding: 'utf8' })
}

/**
 * Scout for real, then write for real, and answer the folder.
 *
 * Both halves, because they are two round trips in the app and the second one is
 * composed out of the first one's answer — a helper that skipped the scout would
 * be testing a folder path this suite invented rather than the one `mktemp`
 * chose.
 */
function arm(
  real: string,
  over: { config?: string; settings?: string | null; extra?: readonly ScratchFile[] } = {},
): string {
  const dir = readScouted(run(scoutScript())).dir
  made.push(dir)
  run(
    armScript({
      dir,
      files: [
        { path: 'deck-control.json', body: over.config ?? '{"mcpServers":{}}' },
        ...(over.extra ?? []),
        {
          path: 'bin/claude',
          body: wrapperScript({
            real,
            subcommands: subcommandsFrom(HELP),
            config: `${dir}/deck-control.json`,
            settings: over.settings === undefined ? null : over.settings,
          }),
          executable: true,
        },
      ],
    }),
  )
  return dir
}

/** Invoke the wrapper the way a shell with it first on PATH would. */
function callWrapper(dir: string, args: readonly string[]): string[] {
  return execFileSync(join(dir, 'bin', 'claude'), args, { encoding: 'utf8' })
    .split('\n')
    .filter((line) => line !== '')
}

describe('what the server’s own help says', () => {
  it('reads the flag out of it rather than out of a version number', () => {
    expect(honoursMcpConfig(HELP)).toBe(true)
    expect(honoursMcpConfig(HELP.replace('--mcp-config <configs...>', '--model <model>'))).toBe(false)
  })

  it('takes the subcommands, both spellings of an alias, and nothing else', () => {
    expect(subcommandsFrom(HELP)).toEqual([
      'agents',
      'doctor',
      'mcp',
      'plugin',
      'plugins',
      'update',
    ])
  })

  it('answers nothing at all for help with no Commands block', () => {
    expect(subcommandsFrom('Usage: claude\n\nOptions:\n  -p, --print  Print\n')).toEqual([])
  })

  it('does not mistake an option line or a wrapped description for a subcommand', () => {
    // `--mcp-config` starts with a hyphen and `Load MCP servers` is capitalised,
    // so neither can match; a bare word inside the Options block is not reached
    // at all because the block is found by its heading.
    expect(subcommandsFrom(HELP)).not.toContain('load')
    expect(subcommandsFrom(HELP)).not.toContain('strings')
  })
})

describe('the wrapper, run', () => {
  it('adds the flag to a bare invocation', () => {
    const dir = arm(fakeClaude())
    expect(callWrapper(dir, [])).toEqual([MCP_FLAG, join(dir, 'deck-control.json')])
  })

  it('adds it to a prompt, and keeps the prompt one argument', () => {
    const dir = arm(fakeClaude())
    expect(callWrapper(dir, ['fix the build please'])).toEqual([
      MCP_FLAG,
      join(dir, 'deck-control.json'),
      'fix the build please',
    ])
  })

  it('adds it in front of flags the person passed', () => {
    const dir = arm(fakeClaude())
    expect(callWrapper(dir, ['-p', 'hello'])).toEqual([
      MCP_FLAG,
      join(dir, 'deck-control.json'),
      '-p',
      'hello',
    ])
  })

  it('leaves every subcommand this server listed completely alone', () => {
    const dir = arm(fakeClaude())
    // A subcommand handed `--mcp-config` fails on an unknown option, so the one
    // thing that must never happen here is the flag appearing.
    for (const word of ['mcp', 'doctor', 'update', 'plugins']) {
      expect(callWrapper(dir, [word, 'list'])).toEqual([word, 'list'])
    }
  })

  it('treats a word that only looks like a subcommand as a prompt', () => {
    const dir = arm(fakeClaude())
    expect(callWrapper(dir, ['deploy'])).toEqual([
      MCP_FLAG,
      join(dir, 'deck-control.json'),
      'deploy',
    ])
  })

  it('survives a path with a quote in it, which is what would brick a terminal', () => {
    const dir = mkdtempSync(join(tmpdir(), "td-fake-o'clock-"))
    made.push(dir)
    const path = join(dir, 'claude')
    writeFileSync(path, '#!/bin/sh\nprintf ok\n', 'utf8')
    chmodSync(path, 0o755)
    const armed = arm(path)
    expect(execFileSync(join(armed, 'bin', 'claude'), [], { encoding: 'utf8' })).toBe('ok')
  })
})

describe('what it leaves on the server', () => {
  it('writes the config where the wrapper names it, and only for this account', () => {
    const dir = arm(fakeClaude(), { config: '{"mcpServers":{"deck-control":{"type":"http"}}}' })
    expect(dir.startsWith(SCRATCH_PREFIX)).toBe(true)
    expect(JSON.parse(readFileSync(join(dir, 'deck-control.json'), 'utf8'))).toEqual({
      mcpServers: { 'deck-control': { type: 'http' } },
    })
    // 0700 on the folder and 0600 on the token file, from `umask 077` rather
    // than from a chmod that runs after the bytes are already readable.
    expect(statSync(dir).mode & 0o777).toBe(0o700)
    expect(statSync(join(dir, 'deck-control.json')).mode & 0o777).toBe(0o600)
  })

  it('answers with this machine’s own programs, absolutely, and never a bare word', () => {
    const answer = readScouted(run(scoutScript()))
    made.push(answer.dir)

    expect(answer.dir.startsWith(SCRATCH_PREFIX)).toBe(true)
    // Resolved by `command -v` while this folder is nowhere near any PATH, which
    // is the whole of `open-shim.ts`'s rule about run-time lookups: the shim
    // must never find itself. Compared against the same question asked outside.
    expect(answer.curl).toBe(
      execFileSync('sh', ['-c', 'command -v curl || true'], { encoding: 'utf8' }).trim(),
    )
    // macOS has `/usr/bin/open` and no `xdg-open`; a Linux box is the other way
    // round. Either way, whatever came back is an absolute path or nothing —
    // never the bare word `command -v` prints for a builtin.
    for (const found of Object.values(answer.openers)) {
      if (found !== '') expect(found.startsWith('/')).toBe(true)
    }
    expect(Object.keys(answer.openers)).toEqual([...OPENER_NAMES])
  })

  it('takes exactly its own folder back, and refuses any other path', () => {
    const dir = arm(fakeClaude())
    expect(() =>
      execFileSync('sh', ['-s'], { input: disarmScript('/tmp'), encoding: 'utf8' }),
    ).toThrow()
    execFileSync('sh', ['-s'], { input: disarmScript(dir), encoding: 'utf8' })
    expect(() => readFileSync(join(dir, 'deck-control.json'), 'utf8')).toThrow()
  })

  it('says what it is, in the line it types into the terminal', () => {
    const line = pathLine('/tmp/td-drive-abc123')
    expect(line.startsWith("export PATH='/tmp/td-drive-abc123/bin':$PATH")).toBe(true)
    expect(line).toContain('#')
    expect(line.endsWith('\n')).toBe(true)
  })
})

/* ----------------------------------------------------------- the decision -- */

function claudeFact(path = '/usr/bin/claude'): AgentFact {
  return { id: 'claude', path, version: '2.0.0', signedIn: 'yes', account: null }
}

function minted(): PreparedElsewhere & { dropped: boolean; bound: string[] } {
  const it = {
    dropped: false,
    bound: [] as string[],
    configFor: (url: string) => JSON.stringify({ url }),
    started: (sessionId: string, machineId: string) => {
      it.bound.push(`${machineId}/${sessionId}`)
    },
    drop: () => {
      it.dropped = true
    },
  }
  return it
}

/**
 * What a scout answers, as the far end would print it.
 *
 * A helper rather than a literal at nine call sites, because the shape grew once
 * — it was two lines and is now a mark and six — and a suite that spelled it out
 * everywhere is a suite that pins the old shape in eight places and the new one
 * in none.
 */
function scoutedLines(
  over: Partial<{ dir: string; shell: string; curl: string; openers: Record<string, string> }> = {},
): string {
  const openers = over.openers ?? { 'xdg-open': '/usr/bin/xdg-open' }
  return [
    SCOUT_MARK,
    over.dir ?? `${SCRATCH_PREFIX}abcdef`,
    over.shell ?? '/bin/bash',
    over.curl ?? '/usr/bin/curl',
    ...OPENER_NAMES.map((name) => openers[name] ?? ''),
  ].join('\n')
}

function drives(over: Partial<WindowDriveDeps> = {}): {
  it: WindowDrives
  deps: WindowDriveDeps
  token: ReturnType<typeof minted>
  letGoes: string[]
  written: string[]
} {
  const token = minted()
  const letGoes: string[] = []
  const written: string[] = []
  const deps: WindowDriveDeps = {
    allowed: () => true,
    claudeOn: async () => claudeFact(),
    run: async () => ({ stdout: HELP, stderr: '' }),
    runScript: async (_serverId, script) => {
      written.push(script)
      return { stdout: script.includes('mktemp') ? scoutedLines() : '' }
    },
    reach: async (_serverId, kind) => ({
      ok: true,
      reach: { port: kind === 'control' ? 40404 : 40405, close: () => undefined },
    }),
    letGo: (serverId, kind) => letGoes.push(`${serverId}/${kind}`),
    mint: () => token,
    hookEndpoint: () => ({ token: 'abc123' }),
    remoteContext: () => ({
      pages: { 'INDEX.md': '# index' },
      mapFor: (dir) => `read ${dir}/INDEX.md`,
    }),
    ...over,
  }
  return { it: new WindowDrives(deps), deps, token, letGoes, written }
}

describe('who gets the verbs', () => {
  it('binds the token to the server, not to this computer', async () => {
    const { it, token } = drives()
    const out = await it.arm('server-1', 'server-1 shell-9')
    expect(out.ok).toBe(true)
    // `<machineId>/<sessionId>` — the binding map keys a window
    // `<serverId>\0<shellId>`, so the server has to stand in for the machine.
    expect(token.bound).toEqual(['server-1/server-1 shell-9'])
  })

  it('answers with the line to type, naming the folder the server made', async () => {
    const { it } = drives()
    const out = await it.arm('server-1', 'shell-9')
    expect(out.ok && out.line).toContain(`${SCRATCH_PREFIX}abcdef/bin`)
  })

  it('refuses before asking the server anything when the switch is off', async () => {
    const asked = vi.fn()
    const { it } = drives({ allowed: () => false, claudeOn: asked })
    const out = await it.arm('server-1', 'shell-9')
    expect(out).toEqual({ ok: false, why: WHY_NOT['not-allowed'] })
    expect(asked).not.toHaveBeenCalled()
    expect(it.whyNot('shell-9')).toBe(WHY_NOT['not-allowed'])
  })

  it('names the agents it cannot reach when there is no claude', async () => {
    const { it } = drives({ claudeOn: async () => null })
    const out = await it.arm('server-1', 'shell-9')
    expect(out).toEqual({ ok: false, why: WHY_NOT.agent })
    expect(WHY_NOT.agent).toContain('Codex')
    expect(WHY_NOT.agent).toContain('Gemini')
  })

  it('refuses a claude too old for the flag rather than wrapping it', async () => {
    const { it } = drives({ run: async () => ({ stdout: 'Usage: claude\n', stderr: '' }) })
    expect(await it.arm('server-1', 'shell-9')).toEqual({ ok: false, why: WHY_NOT.flag })
  })

  it('gives the token back when the port could not be opened', async () => {
    const { it, token, letGoes } = drives({
      reach: async () => ({ ok: false, message: 'that server will not forward.' }),
    })
    const out = await it.arm('server-1', 'shell-9')
    expect(out).toEqual({ ok: false, why: 'that server will not forward.' })
    expect(token.dropped).toBe(true)
    // Nothing was taken, so nothing is let go of — a stray release here would
    // close a port a *different* shell on that server is using.
    expect(letGoes).toEqual([])
  })

  it('gives the token back and lets go of the port when the files would not land', async () => {
    const { it, token, letGoes } = drives({
      runScript: async (_serverId, script) => {
        if (script.includes('mktemp')) return { stdout: scoutedLines() }
        throw new Error('no space left on device')
      },
    })
    expect((await it.arm('server-1', 'shell-9')).ok).toBe(false)
    expect(token.dropped).toBe(true)
    // Both reaches, because by the time the files are written this shell is
    // holding a reference to each of them.
    expect(letGoes).toEqual(['server-1/control', 'server-1/hooks'])
  })

  it('refuses a folder answer that is not one of ours', async () => {
    const { it, token } = drives({
      runScript: async () => ({ stdout: scoutedLines({ dir: '/etc' }) }),
    })
    expect((await it.arm('server-1', 'shell-9')).ok).toBe(false)
    expect(token.dropped).toBe(true)
  })

  it('says nothing about a shell it never armed', async () => {
    const { it } = drives()
    expect(it.whyNot('a shell nobody opened')).toBeNull()
    await it.arm('server-1', 'shell-9')
    expect(it.whyNot('shell-9')).toBeNull()
  })
})

describe('the shell the person is dropped into', () => {
  it('reads the answers past whatever a profile printed, by the mark', () => {
    // Plenty of `.profile`s print something before a script's own output, so the
    // answers are found by the mark rather than by counting from either end.
    expect(readScouted(`bash: warning: setlocale\n${scoutedLines()}`)).toEqual({
      dir: `${SCRATCH_PREFIX}abcdef`,
      shell: '/bin/bash',
      curl: '/usr/bin/curl',
      openers: { open: '', 'xdg-open': '/usr/bin/xdg-open', 'sensible-browser': '' },
    })
  })

  it('answers with nothing at all when the mark never arrived', () => {
    expect(readScouted('permission denied\n')).toEqual({
      dir: '',
      shell: '',
      curl: '',
      openers: { open: '', 'xdg-open': '', 'sensible-browser': '' },
    })
  })

  it('takes the Bourne family, by syntax rather than by popularity', () => {
    for (const shell of ['/bin/sh', '/bin/bash', '/usr/bin/zsh', '/bin/dash', '/bin/ash', '/bin/ksh']) {
      expect(takesAnExportLine(shell)).toBe(true)
    }
    // An account whose passwd entry names none gets `/bin/sh`.
    expect(takesAnExportLine('')).toBe(true)
  })

  it('refuses the two where the line would print an error instead', () => {
    // `fish` has no `export` builtin and `csh` spells it `setenv`. A line
    // written the wrong way is an error in a terminal somebody is working in,
    // which is worse than a capability they never had.
    expect(takesAnExportLine('/usr/bin/fish')).toBe(false)
    expect(takesAnExportLine('/bin/csh')).toBe(false)
    expect(takesAnExportLine('/bin/tcsh')).toBe(false)
  })

  it('gives back the token, the port and the folder when the shell cannot take it', async () => {
    const { it: drive, token, letGoes } = drives({
      runScript: async (_serverId, script) =>
        script.includes('mktemp') ? { stdout: scoutedLines({ shell: '/usr/bin/fish' }) } : { stdout: '' },
    })

    const out = await drive.arm('server-1', 'shell-9')

    expect(out).toEqual({ ok: false, why: WHY_NOT.shell })
    expect(token.dropped).toBe(true)
    // Refused before either reach was widened to the hook endpoint, so there is
    // exactly one reference to hand back.
    expect(letGoes).toEqual(['server-1/control'])
  })

  it('removes what it had already put on the server', async () => {
    const scripts: string[] = []
    const { it: drive } = drives({
      runScript: async (_serverId, script) => {
        scripts.push(script)
        return script.includes('mktemp') ? { stdout: scoutedLines({ shell: '/usr/bin/fish' }) } : { stdout: '' }
      },
    })

    await drive.arm('server-1', 'shell-9')
    await new Promise((resolve) => setTimeout(resolve, 0))

    // A config file holding a live-looking token, left in `/tmp` on somebody's
    // machine because this app changed its mind, is not an acceptable trace.
    expect(scripts.some((script) => script.includes('rm -rf'))).toBe(true)
  })
})

describe('taking it away', () => {
  it('drops the token before it tries to remove the folder', async () => {
    const order: string[] = []
    const { it, token } = drives({
      runScript: async (_serverId, script) => {
        if (script.includes('rm -rf')) order.push('removed')
        return { stdout: script.includes('mktemp') ? scoutedLines() : '' }
      },
    })
    await it.arm('server-1', 'shell-9')
    const drop = token.drop
    token.drop = () => {
      order.push('dropped')
      drop()
    }
    it.disarm('shell-9')
    // A removal that failed on the far end must never leave a live token behind
    // a config file that is still readable.
    expect(order[0]).toBe('dropped')
  })

  it('takes every shell on one server down when the switch goes off', async () => {
    const { it, letGoes } = drives()
    await it.arm('server-1', 'shell-a')
    await it.arm('server-1', 'shell-b')
    await it.arm('server-2', 'shell-c')
    it.revoke('server-1')
    expect(it.whyNot('shell-a')).toBe(WHY_NOT['not-allowed'])
    expect(it.whyNot('shell-b')).toBe(WHY_NOT['not-allowed'])
    expect(it.whyNot('shell-c')).toBeNull()
    expect(letGoes).toEqual([
      'server-1/control',
      'server-1/hooks',
      'server-1/control',
      'server-1/hooks',
    ])
  })

  it('is idempotent, because a shell can close twice', async () => {
    const { it, letGoes } = drives()
    await it.arm('server-1', 'shell-9')
    it.disarm('shell-9')
    it.disarm('shell-9')
    expect(letGoes).toEqual(['server-1/control', 'server-1/hooks'])
  })
})

/* ----------------------------------------------------- belonging, on top -- */

/**
 * The second half: the `open` shim, the hooks and the documents.
 *
 * Its failures are silent by design — a server with no `curl` still gets a
 * terminal and still gets the browser verbs — so what is pinned here is that the
 * silence is *honest*: nothing is written that would half-work, and
 * `belonging()` says exactly what was managed rather than what was hoped.
 */
describe('what a server session is told about where it is', () => {
  it('adds the settings flag only when there is a settings file', () => {
    const bare = arm(fakeClaude())
    expect(callWrapper(bare, [])).toEqual([MCP_FLAG, join(bare, 'deck-control.json')])

    const dir = arm(fakeClaude(), {
      settings: `${SCRATCH_PREFIX}placeholder/${SETTINGS_FILE}`,
      extra: [{ path: SETTINGS_FILE, body: '{"hooks":{}}' }],
    })
    // The wrapper was written naming a file that is not there, which is the one
    // shape that would stop `claude` starting — so it tests before it uses it.
    expect(callWrapper(dir, [])).toEqual([MCP_FLAG, join(dir, 'deck-control.json')])

    const real = arm(fakeClaude(), {
      settings: undefined,
    })
    expect(callWrapper(real, [])).not.toContain(SETTINGS_FLAG)
  })

  it('uses the settings file when it is actually there', () => {
    const dir = readScouted(run(scoutScript())).dir
    made.push(dir)
    run(
      armScript({
        dir,
        files: [
          { path: 'deck-control.json', body: '{}' },
          { path: SETTINGS_FILE, body: '{"hooks":{}}' },
          {
            path: 'bin/claude',
            body: wrapperScript({
              real: fakeClaude(),
              subcommands: subcommandsFrom(HELP),
              config: `${dir}/deck-control.json`,
              settings: `${dir}/${SETTINGS_FILE}`,
            }),
            executable: true,
          },
        ],
      }),
    )
    expect(callWrapper(dir, ['-p', 'hi'])).toEqual([
      MCP_FLAG,
      join(dir, 'deck-control.json'),
      SETTINGS_FLAG,
      join(dir, SETTINGS_FILE),
      '-p',
      'hi',
    ])
  })

  it('hands the session a map naming the documents on that server', async () => {
    const { it } = drives()
    await it.arm('server-1', 'shell-9')
    expect(it.belonging('shell-9')).toEqual({
      map: `read ${SCRATCH_PREFIX}abcdef/context/INDEX.md`,
      opensInApp: true,
    })
  })

  it('says nothing at all about a shell it never armed', async () => {
    const { it } = drives()
    expect(it.belonging('shell-9')).toBeNull()
  })

  it('still opens pages here when the claude on that server is too old for hooks', async () => {
    const noSettings = HELP.replace('--settings <file-or-json>', '--seatings <file>')
    const { it, written } = drives({ run: async () => ({ stdout: noSettings, stderr: '' }) })

    const out = await it.arm('server-1', 'shell-9')

    expect(out.ok).toBe(true)
    // The shim is a PATH entry and a `curl`; it has nothing to do with the CLI's
    // version, so requirement one survives a CLI that cannot take the flag.
    expect(it.belonging('shell-9')).toEqual({ map: null, opensInApp: true })
    const files = written.join('\n')
    for (const name of OPENER_NAMES) expect(files).toContain(`bin/${name}`)
    expect(files).not.toContain(SETTINGS_FILE)
    expect(files).not.toContain(SETTINGS_FLAG)
  })

  it('arranges none of it on a server with no curl, and claims none of it', async () => {
    const { it, written, letGoes } = drives({
      runScript: async (_serverId, script) => ({
        stdout: script.includes('mktemp') ? scoutedLines({ curl: '' }) : '',
      }),
    })

    const out = await it.arm('server-1', 'shell-9')

    // The terminal still opens and still gets the browser verbs.
    expect(out.ok).toBe(true)
    expect(it.belonging('shell-9')).toBeNull()
    // Nothing that needs a `curl` was written, and the hook endpoint was never
    // even asked for a port.
    expect(written.join('\n')).not.toContain('bin/open')
    it.disarm('shell-9')
    expect(letGoes).toEqual(['server-1/control'])
  })

  it('writes nothing of it when the hook endpoint is not running', async () => {
    const { it, written } = drives({ hookEndpoint: () => null })
    expect((await it.arm('server-1', 'shell-9')).ok).toBe(true)
    expect(it.belonging('shell-9')).toBeNull()
    expect(written.join('\n')).not.toContain('bin/xdg-open')
  })

  it('writes nothing of it when that server will not open a second port', async () => {
    const { it, written, letGoes } = drives({
      reach: async (_serverId, kind) =>
        kind === 'control'
          ? { ok: true, reach: { port: 40404, close: () => undefined } }
          : { ok: false, message: 'no second forward.' },
    })
    expect((await it.arm('server-1', 'shell-9')).ok).toBe(true)
    expect(it.belonging('shell-9')).toBeNull()
    expect(written.join('\n')).not.toContain('bin/open')
    // A reach that failed handed its own reference back, so nothing is released
    // for it here.
    it.disarm('shell-9')
    expect(letGoes).toEqual(['server-1/control'])
  })

  it('refuses to write a file whose path it cannot vouch for', () => {
    expect(() =>
      armScript({ dir: `${SCRATCH_PREFIX}abcdef`, files: [{ path: 'bin/$(id)', body: 'x' }] }),
    ).toThrow()
    expect(() =>
      armScript({ dir: `${SCRATCH_PREFIX}abcdef`, files: [{ path: 'a', body: 'TD_FILE_0' }] }),
    ).toThrow()
  })
})
