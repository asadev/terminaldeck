/**
 * What a task agent could be pointed at on this Mac: the tools it can be asked
 * about or blocked from, and the skills installed for its account — for the
 * coding agent it runs on. Codex reads its own skill folders (below); Gemini
 * and an added agent have none this app knows how to find, so their pickers
 * offer only what is saved.
 *
 * Read from disk only — no agent is started to ask. Claude Code's own tools come
 * from `shared/agent-tools.ts`, because the CLI lists them only when it runs; its
 * MCP servers come from the same configuration Claude Code reads
 * (`mcp-client.ts`'s `loadServers`), for the account's own folder and each
 * project folder given. Skills are the `SKILL.md` folders Claude Code loads: the
 * account's `skills/`, each project's `.claude/skills/`, and those of installed
 * plugins (named `plugin:skill`).
 */

import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { familyOf } from '../../shared/agent-capabilities'
import { CLAUDE_TOOLS, mcpServerTool } from '../../shared/agent-tools'
import { loadServers } from '../mcp-client'

export interface InventoryChoice {
  /** What is saved: a tool name (`mcp__server` for a whole server) or a skill name. */
  value: string
  label: string
  /** Where it was found, in a few words. */
  where: string
}

export interface AgentInventory {
  tools: InventoryChoice[]
  skills: InventoryChoice[]
}

export interface InventoryInput {
  /** Which coding agent; null or absent for the app's default, read as Claude Code. */
  provider?: string | null
  /** The account's folder: Claude Code's, or Codex's `CODEX_HOME`. */
  configDir: string
  /** The agent's own install: Claude Code then reads `~/.claude.json`, not one inside `configDir`. */
  system: boolean
  /** Project folders whose `.mcp.json` and `.claude/skills` count too. */
  projects: readonly string[]
  env?: NodeJS.ProcessEnv
  /** The home folder, for Codex's `~/.agents/skills`. */
  home?: string
}

/** `deck-control/server.ts`'s `SERVER_NAME`, the app's own tools in every session; a test keeps the two equal. */
export const APP_SERVER_NAME = 'deck-control'

const MAX_LISTED = 300
/** A `SKILL.md` front matter is at its top; more than this is not read. */
const HEAD_BYTES = 4096

export function agentInventory(input: InventoryInput): AgentInventory {
  const family = familyOf(input.provider ?? null)
  if (family === 'codex') return codexInventory(input)
  if (family !== 'claude') return { tools: [], skills: [] }
  const base = { ...(input.env ?? process.env) }
  delete base.CLAUDE_CONFIG_DIR
  const env = input.system ? base : { ...base, CLAUDE_CONFIG_DIR: input.configDir }

  const tools: InventoryChoice[] = CLAUDE_TOOLS.map((tool) => ({ value: tool.name, label: `${tool.name} — ${tool.label}`, where: 'Claude Code' }))
  const seen = new Set(tools.map((tool) => tool.value))
  const addTool = (choice: InventoryChoice): void => {
    if (seen.has(choice.value) || tools.length >= MAX_LISTED) return
    seen.add(choice.value)
    tools.push(choice)
  }
  const app = mcpServerTool(APP_SERVER_NAME)
  if (app !== null) addTool({ value: app, label: `${APP_SERVER_NAME} — Terminal Deck's own tools`, where: 'this app' })
  for (const project of [null, ...input.projects]) {
    let servers: ReturnType<typeof loadServers> = []
    try {
      servers = loadServers(project, env)
    } catch {
      continue
    }
    for (const server of servers) {
      const value = mcpServerTool(server.name)
      if (value !== null) addTool({ value, label: `${server.name} — every tool of this MCP server`, where: `MCP, ${server.scope}` })
    }
  }

  const skills: InventoryChoice[] = []
  const named = new Set<string>()
  const addSkills = (dir: string, where: string, prefix: string): void => {
    for (const found of skillsIn(dir)) {
      const value = `${prefix}${found.name}`
      if (named.has(value) || skills.length >= MAX_LISTED) continue
      named.add(value)
      skills.push({ value, label: found.description === null ? value : `${value} — ${found.description}`, where })
    }
  }
  addSkills(join(input.configDir, 'skills'), 'account', '')
  for (const project of input.projects) addSkills(join(project, '.claude', 'skills'), 'project', '')
  for (const plugin of pluginsIn(input.configDir)) addSkills(join(plugin.path, 'skills'), `plugin ${plugin.name}`, `${plugin.name}:`)

  return { tools, skills }
}

/**
 * Codex's own: the MCP servers in its `config.toml`, and the skills in the
 * folders it was measured reading (0.159.3, `codex debug prompt-input` with an
 * empty CODEX_HOME and HOME) — `$CODEX_HOME/skills` with its bundled
 * `.system`, `~/.agents/skills`, and each project's `.agents/skills`. Its
 * built-in tools are not listed: Codex prints no list of them to read.
 */
function codexInventory(input: InventoryInput): AgentInventory {
  const tools: InventoryChoice[] = []
  for (const name of codexServers(join(input.configDir, 'config.toml'))) {
    const value = mcpServerTool(name)
    if (value !== null && !tools.some((tool) => tool.value === value) && tools.length < MAX_LISTED) {
      tools.push({ value, label: `${name} — every tool of this MCP server`, where: 'Codex config' })
    }
  }
  const skills: InventoryChoice[] = []
  const named = new Set<string>()
  const add = (dir: string, where: string): void => {
    for (const found of skillsIn(dir)) {
      if (named.has(found.name) || skills.length >= MAX_LISTED) continue
      named.add(found.name)
      skills.push({ value: found.name, label: found.description === null ? found.name : `${found.name} — ${found.description}`, where })
    }
  }
  add(join(input.configDir, 'skills'), 'account')
  add(join(input.home ?? homedir(), '.agents', 'skills'), 'home')
  for (const project of input.projects) add(join(project, '.agents', 'skills'), 'project')
  add(join(input.configDir, 'skills', '.system'), 'built in')
  return { tools, skills }
}

/** `[mcp_servers.<name>]` table names from a Codex `config.toml`; a line read, never the whole TOML. */
function codexServers(file: string): string[] {
  let text: string
  try {
    text = readFileSync(file, 'utf8')
  } catch {
    return []
  }
  const names: string[] = []
  for (const match of text.matchAll(/^\s*\[mcp_servers\.(?:"([^"]+)"|([A-Za-z0-9_-]+))\]\s*$/gm)) {
    const name = match[1] ?? match[2]
    if (name !== undefined && !names.includes(name)) names.push(name)
  }
  return names
}

function skillsIn(dir: string): Array<{ name: string; description: string | null }> {
  let entries: string[]
  try {
    entries = readdirSync(dir).sort()
  } catch {
    return []
  }
  const out: Array<{ name: string; description: string | null }> = []
  for (const entry of entries) {
    const file = join(dir, entry, 'SKILL.md')
    if (!existsSync(file)) continue
    const head = readHead(file)
    const name = frontMatter(head, 'name') ?? entry
    if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$/.test(name)) continue
    const description = frontMatter(head, 'description')
    out.push({ name, description: description === null ? null : shortened(description, 60) })
  }
  return out
}

/** A menu line, not a paragraph: cut at a word and marked. */
function shortened(text: string, max: number): string {
  if (text.length <= max) return text
  const cut = text.slice(0, max)
  const space = cut.lastIndexOf(' ')
  return `${(space > max / 2 ? cut.slice(0, space) : cut).replace(/[\s,.;:]+$/, '')}…`
}

function pluginsIn(configDir: string): Array<{ name: string; path: string }> {
  try {
    const raw = JSON.parse(readFileSync(join(configDir, 'plugins', 'installed_plugins.json'), 'utf8')) as { plugins?: unknown }
    const plugins = typeof raw.plugins === 'object' && raw.plugins !== null ? (raw.plugins as Record<string, unknown>) : {}
    return Object.entries(plugins).flatMap(([id, installs]) => {
      const first = Array.isArray(installs) ? (installs[0] as { installPath?: unknown } | undefined) : undefined
      const name = id.split('@')[0]
      return typeof first?.installPath === 'string' && name !== '' ? [{ name, path: first.installPath }] : []
    })
  } catch {
    return []
  }
}

function readHead(file: string): string {
  try {
    return readFileSync(file, 'utf8').slice(0, HEAD_BYTES)
  } catch {
    return ''
  }
}

/** One `key: value` from a `---` front matter block, or null. */
export function frontMatter(head: string, key: string): string | null {
  const block = /^---\r?\n([\s\S]*?)\r?\n---/.exec(head)
  if (block === null) return null
  const line = new RegExp(`^${key}:\\s*(.+)$`, 'm').exec(block[1])
  if (line === null) return null
  const value = line[1].trim().replace(/^["']|["']$/g, '')
  return value === '' ? null : value
}
