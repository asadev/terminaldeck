import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { agentInventory, APP_SERVER_NAME, frontMatter } from './agent-inventory'
import { SERVER_NAME } from '../deck-control/server'
import { CLAUDE_TOOLS } from '../../shared/agent-tools'

let dir = ''
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-inventory-'))
})
afterEach(() => rmSync(dir, { recursive: true, force: true }))

function skill(root: string, folder: string, head: string): void {
  mkdirSync(join(root, folder), { recursive: true })
  writeFileSync(join(root, folder, 'SKILL.md'), head)
}

describe('what a task agent can be pointed at', () => {
  it('lists Claude Code tools, the app server, configured MCP servers, and installed skills — read from disk only', () => {
    const account = join(dir, 'account')
    const project = join(dir, 'project')
    mkdirSync(account, { recursive: true })
    mkdirSync(project, { recursive: true })
    writeFileSync(join(account, '.claude.json'), JSON.stringify({ mcpServers: { github: { command: 'gh-mcp' } } }))
    writeFileSync(join(project, '.mcp.json'), JSON.stringify({ mcpServers: { 'db tools': { command: 'db' } } }))
    skill(join(account, 'skills'), 'review', '---\nname: code-review\ndescription: Review a diff\n---\nbody')
    skill(join(account, 'skills'), 'plain', 'no front matter')
    mkdirSync(join(account, 'skills', 'not-a-skill'))
    skill(join(project, '.claude', 'skills'), 'deploy', '---\nname: "ship-it"\n---')
    const plugin = join(dir, 'plugin-install')
    skill(join(plugin, 'skills'), 'lint', '---\nname: lint\n---')
    mkdirSync(join(account, 'plugins'))
    writeFileSync(join(account, 'plugins', 'installed_plugins.json'), JSON.stringify({ version: 2, plugins: { 'tidy@market': [{ installPath: plugin }] } }))

    const found = agentInventory({ configDir: account, system: false, projects: [project], env: {} })
    const tools = found.tools.map((tool) => tool.value)
    expect(tools.slice(0, CLAUDE_TOOLS.length)).toEqual(CLAUDE_TOOLS.map((tool) => tool.name))
    expect(tools).toContain('mcp__deck-control')
    expect(tools).toContain('mcp__github')
    // A server name Claude Code spells differently is offered the way it names the tools.
    expect(tools).toContain('mcp__db_tools')
    expect(found.skills.map((one) => one.value)).toEqual(['plain', 'code-review', 'ship-it', 'tidy:lint'])
    expect(found.skills.find((one) => one.value === 'code-review')?.label).toBe('code-review — Review a diff')
    skill(join(account, 'skills'), 'long', `---\nname: long\ndescription: ${'word '.repeat(40)}\n---`)
    const long = agentInventory({ configDir: account, system: false, projects: [], env: {} }).skills.find((one) => one.value === 'long')
    expect(long?.label.length).toBeLessThanOrEqual('long — '.length + 61)
    expect(long?.label.endsWith('…')).toBe(true)
  })

  it('answers with Claude Code tools alone where nothing is configured', () => {
    const found = agentInventory({ configDir: join(dir, 'none'), system: false, projects: [join(dir, 'missing')], env: {} })
    expect(found.skills).toEqual([])
    expect(found.tools.every((tool) => tool.where === 'Claude Code' || tool.value === 'mcp__deck-control')).toBe(true)
  })

  it('names the app server as the server does', () => {
    expect(APP_SERVER_NAME).toBe(SERVER_NAME)
    expect(frontMatter('---\nname: x\n---', 'description')).toBeNull()
  })
})

describe('for the coding agent that runs it', () => {
  it('Codex: its own MCP servers and the skill folders it reads, never Claude Code’s tools', () => {
    const codexHome = join(dir, 'codex-home')
    const home = join(dir, 'home')
    const project = join(dir, 'project')
    mkdirSync(codexHome, { recursive: true })
    writeFileSync(join(codexHome, 'config.toml'), 'model = "x"\n[mcp_servers.github]\ncommand = "gh"\n[mcp_servers."db tools"]\ncommand = "db"\n[mcp_servers.github.env]\nA = "1"\n')
    skill(join(codexHome, 'skills'), 'alpha', '---\nname: alpha\ndescription: From the account\n---')
    skill(join(codexHome, 'skills', '.system'), 'imagegen', '---\nname: imagegen\n---')
    skill(join(home, '.agents', 'skills'), 'delta', '---\nname: delta\n---')
    skill(join(project, '.agents', 'skills'), 'gamma', '---\nname: gamma\n---')
    // Claude Code's folders are not Codex's.
    skill(join(project, '.claude', 'skills'), 'claude-only', '---\nname: claude-only\n---')

    const found = agentInventory({ provider: 'codex', configDir: codexHome, system: true, projects: [project], home, env: {} })
    expect(found.tools.map((tool) => tool.value)).toEqual(['mcp__github', 'mcp__db_tools'])
    expect(found.tools.some((tool) => CLAUDE_TOOLS.some((claude) => claude.name === tool.value))).toBe(false)
    expect(found.skills.map((one) => [one.value, one.where])).toEqual([
      ['alpha', 'account'],
      ['delta', 'home'],
      ['gamma', 'project'],
      ['imagegen', 'built in'],
    ])
  })

  it('Gemini or an added agent: nothing this app can read, so only what is saved is offered', () => {
    for (const provider of ['gemini', 'custom:aider']) {
      expect(agentInventory({ provider, configDir: join(dir, 'x'), system: true, projects: [], env: {} })).toEqual({ tools: [], skills: [] })
    }
  })
})

