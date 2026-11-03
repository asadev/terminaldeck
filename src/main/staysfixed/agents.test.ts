import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { STAYS_FIXED_AGENTS, STAYS_FIXED_SERVER } from '../../shared/stays-fixed'
import { agentLaunch, geminiDefaultsPath, serverSpec, tomlArray, tomlTable, TOOL_TIMEOUT_SECONDS, type AgentServerDeps } from './agents'
import { preloadUrl, type EngineHome } from './engine'
import { agentsOn, openPrefs } from './prefs'
import { configFileIn, setUpRootFor } from './where'

/**
 * How each agent is handed Stays Fixed's server, and the rules around when.
 *
 * The flags themselves were checked against the real CLIs (see `agents.ts`):
 * Codex's `-c` against codex-cli 0.159.3 in a scratch `CODEX_HOME`, Claude
 * Code's repeatable `--mcp-config` in the 2.1.287 binary, Gemini's
 * `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` and its key-by-key merge in its source.
 * What is pinned here is that this file keeps composing exactly that, and that
 * none of it writes anywhere but this app's own folder.
 */

let dir = ''
const home: EngineHome = { ok: true, dir: '/app/node_modules/staysfixed', bin: '/app/node_modules/staysfixed/bin/staysfixed.js', version: '0.15.0', versionNote: '' }

function deps(extra: Partial<AgentServerDeps> = {}): AgentServerDeps {
  return {
    home,
    executable: '/Applications/Terminal Deck.app/Contents/MacOS/Terminal Deck',
    shim: '/u/staysfixed/bin/node',
    loginPath: '/opt/homebrew/bin:/usr/bin',
    dir: join(dir, 'agents'),
    platform: 'darwin',
    env: { GEMINI_CLI_SYSTEM_DEFAULTS_PATH: join(dir, 'no-such-defaults.json') },
    ...extra,
  }
}

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-staysfixed-agents-'))
})

afterAll(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('the server every agent is given', () => {
  it('is this app run as Node, on the pinned engine, told which project it is for', () => {
    const spec = serverSpec('/work/shop', deps())
    expect(spec.command).toBe('/Applications/Terminal Deck.app/Contents/MacOS/Terminal Deck')
    expect(spec.args).toEqual(['--import', preloadUrl(), home.bin, 'mcp', '--cwd', '/work/shop'])
    expect(spec.env).toEqual({
      ELECTRON_RUN_AS_NODE: '1',
      TD_SF_EXEC_PATH: '/u/staysfixed/bin/node',
      PATH: '/opt/homebrew/bin:/usr/bin:/u/staysfixed/bin',
    })
  })

  it('reaches every agent this app runs — never only one', () => {
    for (const provider of STAYS_FIXED_AGENTS) {
      expect(agentLaunch(provider, '/work/shop', deps()), provider).not.toBeNull()
    }
    expect(agentLaunch('shell', '/work/shop', deps())).toBeNull()
    expect(agentLaunch('custom:my-agent', '/work/shop', deps())).toBeNull()
  })
})

describe('Claude Code', () => {
  it('gets one --mcp-config naming a file in this app’s own folder', () => {
    const launch = agentLaunch('claude', '/work/shop', deps())
    expect(launch?.args[0]).toBe('--mcp-config')
    const file = launch?.args[1] ?? ''
    expect(file.startsWith(join(dir, 'agents'))).toBe(true)
    const config = JSON.parse(readFileSync(file, 'utf8')) as { mcpServers: Record<string, { type: string; command: string; args: string[] }> }
    expect(Object.keys(config.mcpServers)).toEqual([STAYS_FIXED_SERVER])
    expect(config.mcpServers[STAYS_FIXED_SERVER]?.type).toBe('stdio')
    expect(config.mcpServers[STAYS_FIXED_SERVER]?.args).toContain('/work/shop')
    // And never `--strict-mcp-config`: the person's own servers stay.
    expect(launch?.args).not.toContain('--strict-mcp-config')
  })

  it('gets one file per project, so two projects never share a server', () => {
    const a = agentLaunch('claude', '/work/a', deps())?.args[1]
    const b = agentLaunch('claude', '/work/b', deps())?.args[1]
    expect(a).not.toBe(b)
  })
})

describe('Codex', () => {
  it('gets the server as `-c` overrides, with a timeout long enough for a website check', () => {
    const launch = agentLaunch('codex', '/work/shop', deps())
    const values = (launch?.args ?? []).filter((_, i) => i % 2 === 1)
    expect((launch?.args ?? []).filter((_, i) => i % 2 === 0)).toEqual(['-c', '-c', '-c', '-c'])
    expect(values[0]).toBe(`mcp_servers.${STAYS_FIXED_SERVER}.command="/Applications/Terminal Deck.app/Contents/MacOS/Terminal Deck"`)
    expect(values[1]).toBe(`mcp_servers.${STAYS_FIXED_SERVER}.args=${tomlArray(serverSpec('/work/shop', deps()).args)}`)
    expect(values[2]).toMatch(/^mcp_servers\.staysfixed\.env=\{ELECTRON_RUN_AS_NODE="1",/)
    expect(values[3]).toBe(`mcp_servers.${STAYS_FIXED_SERVER}.tool_timeout_sec=${TOOL_TIMEOUT_SECONDS}`)
    expect(launch?.env).toEqual({})
  })

  it('writes TOML that quotes what needs quoting', () => {
    expect(tomlArray(['a b', 'c"d'])).toBe('["a b","c\\"d"]')
    expect(tomlTable({ PATH: '/x', 'odd key': 'y' })).toBe('{PATH="/x","odd key"="y"}')
  })
})

describe('Gemini CLI', () => {
  it('gets the server through the system-defaults variable, adding to nothing else', () => {
    const launch = agentLaunch('gemini', '/work/shop', deps())
    expect(launch?.args).toEqual([])
    const file = launch?.env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH ?? ''
    const config = JSON.parse(readFileSync(file, 'utf8')) as { mcpServers: Record<string, { timeout: number }> }
    expect(config.mcpServers[STAYS_FIXED_SERVER]?.timeout).toBe(TOOL_TIMEOUT_SECONDS * 1000)
  })

  it('carries an existing system-defaults file into its own, so nothing somebody put there is hidden', () => {
    const theirs = join(dir, 'their-defaults.json')
    writeFileSync(theirs, JSON.stringify({ ui: { theme: 'GitHub' }, mcpServers: { company: { command: 'company-mcp' } } }))
    const launch = agentLaunch('gemini', '/work/shop', deps({ env: { GEMINI_CLI_SYSTEM_DEFAULTS_PATH: theirs } }))
    const config = JSON.parse(readFileSync(launch?.env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH ?? '', 'utf8')) as {
      ui: unknown
      mcpServers: Record<string, unknown>
    }
    expect(config.ui).toEqual({ theme: 'GitHub' })
    expect(Object.keys(config.mcpServers).sort()).toEqual(['company', STAYS_FIXED_SERVER])
    // Theirs is read, never written.
    expect(JSON.parse(readFileSync(theirs, 'utf8')).mcpServers).toEqual({ company: { command: 'company-mcp' } })
  })

  it('gives nothing rather than hide a system-defaults file it cannot read', () => {
    const theirs = join(dir, 'broken-defaults.json')
    writeFileSync(theirs, '{ "ui": { // a comment Gemini would strip\n } }')
    expect(agentLaunch('gemini', '/work/shop', deps({ env: { GEMINI_CLI_SYSTEM_DEFAULTS_PATH: theirs } }))).toBeNull()
  })

  it('looks for that file where Gemini does', () => {
    expect(geminiDefaultsPath({}, 'darwin')).toBe('/Library/Application Support/GeminiCli/system-defaults.json')
    expect(geminiDefaultsPath({}, 'linux')).toBe('/etc/gemini-cli/system-defaults.json')
    expect(geminiDefaultsPath({ GEMINI_CLI_SYSTEM_SETTINGS_PATH: '/etc/custom/settings.json' }, 'linux')).toBe('/etc/custom/system-defaults.json')
  })
})

describe('which folder is a session’s project', () => {
  it('is the nearest set-up folder at or above where the session starts, stopping at its repository', () => {
    const root = join(dir, 'mono')
    mkdirSync(join(root, '.git'), { recursive: true })
    mkdirSync(join(root, 'web', 'src'), { recursive: true })
    writeFileSync(join(root, 'staysfixed.config.js'), 'export default {}\n')
    expect(configFileIn(root)).toBe(join(root, 'staysfixed.config.js'))
    expect(setUpRootFor(join(root, 'web', 'src'))).toBe(root)

    const other = join(dir, 'other')
    mkdirSync(join(other, '.git'), { recursive: true })
    mkdirSync(join(other, 'pkg'), { recursive: true })
    expect(setUpRootFor(join(other, 'pkg'))).toBeNull()
  })

  it('does not count a records folder on its own as set up', () => {
    const records = join(dir, 'records-only')
    mkdirSync(join(records, '.staysfixed', 'v2'), { recursive: true })
    expect(configFileIn(records)).toBeNull()
  })
})

describe('the switch', () => {
  it('is off before set-up, on after, and remembers only an explicit answer', () => {
    const prefs = openPrefs(join(dir, 'prefs'))
    expect(agentsOn(prefs, '/work/shop', false)).toBe(false)
    expect(agentsOn(prefs, '/work/shop', true)).toBe(true)
    expect(prefs.agentsChoice('/work/shop')).toBeNull()
    prefs.setAgents('/work/shop', false)
    expect(agentsOn(openPrefs(join(dir, 'prefs')), '/work/shop', true)).toBe(false)
  })
})
