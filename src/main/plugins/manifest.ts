/**
 * A plugin's `terminaldeck.json`, read through the store's own grammar.
 *
 * ## Why this is not an eighth store kind
 *
 * `store-manifest.ts` rests on one sentence: *a manifest names a kind, and this
 * app's own compiled code decides what running that kind means.* A plugin is
 * the one thing that sentence cannot cover — its code is what running it means
 * — so it is not a kind the community store lists, and nothing in the store
 * path can deliver one. `store-install.ts` refuses every kind it does not
 * install (`NOT_YET`), and a plugin is not even a kind it has a name for. The
 * only way a plugin reaches this machine is a person putting its folder under
 * `<userData>/plugins/` themselves; nothing here ever downloads one.
 *
 * What it *does* share with the store is the file and its rules, so a person
 * who has read one manifest can read the other: the same file name, the same
 * format number, the same header (`id`, `name`, `summary`, `version`) with the
 * same limits, and the same refusal of any key this build does not know, named
 * in the message. Where a store item has `kind` and `install`, a plugin has one
 * `plugin` block:
 *
 *     {
 *       "terminaldeck": 1,
 *       "id": "word-count",
 *       "name": "Word count",
 *       "summary": "Counts the words in your tasks.",
 *       "version": "1.0.0",
 *       "plugin": {
 *         "main": "index.js",
 *         "runtime": "node",
 *         "capabilities": ["tasks.read", "tools.contribute"],
 *         "tools": [{ "name": "count", "title": "Count words", "tier": "read",
 *                     "description": "…", "inputSchema": { "type": "object", "properties": {} } }]
 *       }
 *     }
 *
 * `main` is a path inside the folder and `runtime` is `node` and nothing else —
 * the same shape a store `hooks` item has, and for the same reason: the manifest
 * says *which file*, and this app decides how a file is run.
 *
 * ## The tier a plugin wears
 *
 * Three — "Runs a program on this machine" — whatever it asks for. It is the
 * floor `KIND_TIER_FLOOR` gives hooks and MCP servers, the two store kinds that
 * are also a program this app starts, and a plugin is exactly that.
 */

import { readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import {
  KIND_TIER_FLOOR,
  MANIFEST_FORMAT,
  MANIFEST_GRAMMAR,
  MAX_MANIFEST_BYTES,
  STORE_MANIFEST_FILE,
  type StoreTier,
} from '../../shared/store-manifest'
import {
  PLUGIN_CAPABILITIES,
  PLUGIN_TOOL_TIERS,
  type PluginCapability,
  type PluginToolTier,
} from '../../shared/plugins'

const { SAFE_ID, VERSION, isRecord, onlyKeys, text, oneOf, list, insidePath, fail, isRefusal } = MANIFEST_GRAMMAR

/** The tier every plugin wears. See the header. */
export const PLUGIN_TIER: StoreTier = KIND_TIER_FLOOR.mcp

/** How many tools one plugin may give the assistant. */
export const MAX_PLUGIN_TOOLS = 8

/**
 * A tool's name: what follows `plugin_<id>_` on the wire.
 *
 * Sixteen characters, and the number is a sum rather than a taste:
 * `catalogue.test.ts` holds every tool to `[a-zA-Z0-9_-]{1,64}`, because that is
 * what reaches the model's API as `mcp__deck-control__<wire>`, and
 * `plugin_` (7) + an id of at most 40 + `_` (1) + 16 is exactly 64.
 * `manifest.test.ts` builds the longest one there can be and checks it.
 */
export const TOOL_NAME = /^[a-z][a-z0-9_]{0,15}$/

/** How large one tool's input schema may be, as JSON. */
const MAX_SCHEMA_BYTES = 8 * 1024

/** The schema words `deck-control/schema.ts` enforces, plus the ones it ignores harmlessly. */
const SCHEMA_KEYS = ['type', 'properties', 'required', 'enum', 'items', 'additionalProperties', 'description'] as const

export interface PluginToolManifest {
  name: string
  title: string
  description: string
  tier: PluginToolTier
  inputSchema: Record<string, unknown>
}

export interface PluginManifest {
  terminaldeck: typeof MANIFEST_FORMAT
  id: string
  name: string
  summary: string
  version: string
  /** A path inside the folder. */
  main: string
  runtime: 'node'
  capabilities: PluginCapability[]
  tools: PluginToolManifest[]
}

export type PluginManifestParse = { ok: true; manifest: PluginManifest } | { ok: false; why: string }

/** What a contributed tool is called on the wire. One spelling, used by the manifest check and the catalogue. */
export function pluginToolWire(pluginId: string, tool: string): string {
  return `plugin_${pluginId}_${tool}`
}

/** What a contributed tool is called in the action log. */
export function pluginToolId(pluginId: string, tool: string): string {
  return `plugin.${pluginId}.${tool}`
}

/**
 * A schema in the vocabulary the dispatcher enforces, and no larger than a page.
 *
 * Unknown keywords are refused rather than passed through: the schema is
 * advertised to the assistant word for word, and a keyword nothing enforces is
 * a promise to the model that nothing keeps — the failure `schema.ts` was
 * written about.
 */
function schemaAt(where: string, value: unknown, depth: number): Record<string, unknown> {
  if (!isRecord(value)) return fail(`${where} must be an object`)
  if (depth > 6) return fail(`${where} is nested too deeply`)
  onlyKeys(where, value, SCHEMA_KEYS)
  if (value.properties !== undefined) {
    if (!isRecord(value.properties)) return fail(`${where}.properties must be an object`)
    for (const [key, inner] of Object.entries(value.properties)) schemaAt(`${where}.properties.${key}`, inner, depth + 1)
  }
  if (value.items !== undefined) schemaAt(`${where}.items`, value.items, depth + 1)
  return value
}

function toolAt(where: string, raw: unknown): PluginToolManifest {
  if (!isRecord(raw)) return fail(`${where} must be an object`)
  onlyKeys(where, raw, ['name', 'title', 'description', 'tier', 'inputSchema'])
  const name = text(`${where}.name`, raw.name, 16)
  if (!TOOL_NAME.test(name)) return fail(`${where}.name must be lower-case letters, digits and _, starting with a letter`)
  const schema = schemaAt(`${where}.inputSchema`, raw.inputSchema, 0)
  if (schema.type !== 'object') return fail(`${where}.inputSchema must have "type": "object"`)
  if (Buffer.byteLength(JSON.stringify(schema), 'utf8') > MAX_SCHEMA_BYTES) {
    return fail(`${where}.inputSchema must be ${MAX_SCHEMA_BYTES} bytes or fewer`)
  }
  return {
    name,
    title: text(`${where}.title`, raw.title, 60),
    description: text(`${where}.description`, raw.description, 300),
    tier: oneOf(`${where}.tier`, raw.tier, PLUGIN_TOOL_TIERS),
    inputSchema: schema,
  }
}

/**
 * Turn the bytes of a plugin's manifest into a manifest, or say exactly why not.
 *
 * `folder` is the name of the folder it was found in, and a manifest whose id
 * disagrees with it is refused — the same check `parseManifest` makes against
 * the catalogue row, and here it is also what keeps two folders from claiming
 * one id. Never throws.
 */
export function parsePluginManifest(bytes: string, folder: string): PluginManifestParse {
  try {
    if (Buffer.byteLength(bytes, 'utf8') > MAX_MANIFEST_BYTES) {
      return fail(`a manifest must be ${MAX_MANIFEST_BYTES} bytes or fewer`)
    }
    let raw: unknown
    try {
      raw = JSON.parse(bytes)
    } catch {
      return fail('this is not valid JSON')
    }
    if (!isRecord(raw)) return fail('a manifest must be a JSON object')
    onlyKeys('the manifest', raw, ['terminaldeck', 'id', 'name', 'summary', 'version', 'plugin'])
    if (raw.terminaldeck !== MANIFEST_FORMAT) {
      return fail(`this manifest is written for format ${String(raw.terminaldeck)}, and this app reads format ${MANIFEST_FORMAT}`)
    }

    const id = text('id', raw.id, 40)
    if (!SAFE_ID.test(id)) return fail('id must be lower-case letters, digits and hyphens')
    if (id !== folder) return fail(`this manifest calls itself ${id}, and its folder is called ${folder}`)
    const name = text('name', raw.name, 60)
    const summary = text('summary', raw.summary, 120)
    const version = text('version', raw.version, 20)
    if (!VERSION.test(version)) return fail('version must look like 1.2.3')

    if (!isRecord(raw.plugin)) return fail('plugin must be an object')
    const block = raw.plugin
    onlyKeys('plugin', block, ['main', 'runtime', 'capabilities', 'tools'])
    const main = insidePath('plugin.main', block.main, false)
    const lower = main.toLowerCase()
    if (!lower.endsWith('.js') && !lower.endsWith('.mjs') && !lower.endsWith('.cjs')) {
      return fail('plugin.main must be a .js, .mjs or .cjs file')
    }
    const runtime = oneOf('plugin.runtime', block.runtime, ['node'] as const)

    const capabilities: PluginCapability[] = []
    for (const [index, entry] of list('plugin.capabilities', block.capabilities, PLUGIN_CAPABILITIES.length).entries()) {
      const capability = oneOf(`plugin.capabilities[${index}]`, entry, PLUGIN_CAPABILITIES)
      if (!capabilities.includes(capability)) capabilities.push(capability)
    }

    const tools: PluginToolManifest[] = []
    const rawTools = block.tools === undefined ? [] : list('plugin.tools', block.tools, MAX_PLUGIN_TOOLS)
    for (const [index, entry] of rawTools.entries()) {
      const tool = toolAt(`plugin.tools[${index}]`, entry)
      if (tools.some((other) => other.name === tool.name)) return fail(`plugin.tools names ${tool.name} twice`)
      tools.push(tool)
    }
    /*
     * Both directions, because each one alone is a control that does nothing.
     * Tools with no `tools.contribute` would be declared and never offered; the
     * capability with no tools would be a line in the question that grants
     * nothing anybody could use.
     */
    if (tools.length > 0 && !capabilities.includes('tools.contribute')) {
      return fail('plugin.tools are only offered with the tools.contribute capability, which this manifest does not ask for')
    }
    if (tools.length === 0 && capabilities.includes('tools.contribute')) {
      return fail('tools.contribute is asked for, and plugin.tools declares none')
    }

    return {
      ok: true,
      manifest: { terminaldeck: MANIFEST_FORMAT, id, name, summary, version, main, runtime, capabilities, tools },
    }
  } catch (error) {
    return { ok: false, why: isRefusal(error) ? error.message : 'this manifest could not be read' }
  }
}

/** Read a plugin folder's manifest from disk. Never throws. */
export function readPluginManifest(dir: string, folder: string): PluginManifestParse {
  const file = join(dir, STORE_MANIFEST_FILE)
  try {
    // Sized before it is read, so a huge file is refused rather than loaded.
    if (statSync(file).size > MAX_MANIFEST_BYTES) {
      return { ok: false, why: `${STORE_MANIFEST_FILE} must be ${MAX_MANIFEST_BYTES} bytes or fewer` }
    }
    return parsePluginManifest(readFileSync(file, 'utf8'), folder)
  } catch {
    return { ok: false, why: `there is no ${STORE_MANIFEST_FILE} in this folder` }
  }
}
