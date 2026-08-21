import { execFileSync } from 'node:child_process'
import { chmodSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { PreparedElsewhere } from '../deck-control/session-tools'
import type { AgentFact } from './facts'
import {
  MCP_FLAG,
  readArmed,
  takesAnExportLine,
  SCRATCH_PREFIX,
  WHY_NOT,
  WindowDrives,
  armScript,
  disarmScript,
  honoursMcpConfig,
  pathLine,
  subcommandsFrom,
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

/** Run the arm script for real and answer the folder it made. */
function arm(real: string, config = '{"mcpServers":{}}'): string {
  const { dir } = readArmed(
    execFileSync('sh', ['-s'], {
      input: armScript({ config, real, subcommands: subcommandsFrom(HELP) }),
      encoding: 'utf8',
    }),
  )
  made.push(dir)
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
    const dir = arm(fakeClaude(), '{"mcpServers":{"deck-control":{"type":"http"}}}')
    expect(dir.startsWith(SCRATCH_PREFIX)).toBe(true)
    expect(JSON.parse(readFileSync(join(dir, 'deck-control.json'), 'utf8'))).toEqual({
      mcpServers: { 'deck-control': { type: 'http' } },
    })
    // 0700 on the folder and 0600 on the token file, from `umask 077` rather
    // than from a chmod that runs after the bytes are already readable.
    expect(statSync(dir).mode & 0o777).toBe(0o700)
    expect(statSync(join(dir, 'deck-control.json')).mode & 0o777).toBe(0o600)
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

function drives(over: Partial<WindowDriveDeps> = {}): {
  it: WindowDrives
  deps: WindowDriveDeps
  token: ReturnType<typeof minted>
  letGoes: string[]
} {
  const token = minted()
  const letGoes: string[] = []
  const deps: WindowDriveDeps = {
    allowed: () => true,
    claudeOn: async () => claudeFact(),
    run: async () => ({ stdout: HELP, stderr: '' }),
    runScript: async () => ({ stdout: `${SCRATCH_PREFIX}abcdef\n/bin/bash` }),
    reach: async () => ({ ok: true, reach: { port: 40404, close: () => undefined } }),
    letGo: (serverId) => letGoes.push(serverId),
    mint: () => token,
    ...over,
  }
  return { it: new WindowDrives(deps), deps, token, letGoes }
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
      runScript: async () => {
        throw new Error('no space left on device')
      },
    })
    expect((await it.arm('server-1', 'shell-9')).ok).toBe(false)
    expect(token.dropped).toBe(true)
    expect(letGoes).toEqual(['server-1'])
  })

  it('refuses a folder answer that is not one of ours', async () => {
    const { it, token } = drives({ runScript: async () => ({ stdout: '/etc\n/bin/bash' }) })
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
  it('reads the folder and the shell off the end, past whatever a profile printed', () => {
    // Plenty of `.profile`s print something. The two lines that matter are the
    // last two, so they are read from the end.
    expect(readArmed('bash: warning: setlocale\n/tmp/td-drive-abc123\n/bin/bash')).toEqual({
      dir: '/tmp/td-drive-abc123',
      shell: '/bin/bash',
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
        script.includes('rm -rf')
          ? { stdout: '' }
          : { stdout: `${SCRATCH_PREFIX}abcdef\n/usr/bin/fish` },
    })

    const out = await drive.arm('server-1', 'shell-9')

    expect(out).toEqual({ ok: false, why: WHY_NOT.shell })
    expect(token.dropped).toBe(true)
    expect(letGoes).toEqual(['server-1'])
  })

  it('removes what it had already put on the server', async () => {
    const scripts: string[] = []
    const { it: drive } = drives({
      runScript: async (_serverId, script) => {
        scripts.push(script)
        return script.includes('rm -rf')
          ? { stdout: '' }
          : { stdout: `${SCRATCH_PREFIX}abcdef\n/usr/bin/fish` }
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
        return { stdout: `${SCRATCH_PREFIX}abcdef\n/bin/bash` }
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
    expect(letGoes).toEqual(['server-1', 'server-1'])
  })

  it('is idempotent, because a shell can close twice', async () => {
    const { it, letGoes } = drives()
    await it.arm('server-1', 'shell-9')
    it.disarm('shell-9')
    it.disarm('shell-9')
    expect(letGoes).toEqual(['server-1'])
  })
})
