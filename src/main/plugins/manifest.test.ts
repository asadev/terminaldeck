import { describe, expect, it } from 'vitest'
import { parsePluginManifest, pluginToolWire, PLUGIN_TIER } from './manifest'

/**
 * A plugin's manifest is read through the store's grammar: unknown keys are a
 * refusal with the key named, and a capability or a tool is only what the
 * closed lists allow.
 */

function manifest(over: Record<string, unknown> = {}, plugin: Record<string, unknown> = {}): string {
  return JSON.stringify({
    terminaldeck: 1,
    id: 'word-count',
    name: 'Word count',
    summary: 'Counts words.',
    version: '1.0.0',
    plugin: {
      main: 'index.js',
      runtime: 'node',
      capabilities: ['tasks.read', 'tools.contribute'],
      tools: [
        {
          name: 'count',
          title: 'Count words',
          description: 'Counts the words in a task.',
          tier: 'read',
          inputSchema: { type: 'object', properties: { task: { type: 'string' } }, required: ['task'] },
        },
      ],
      ...plugin,
    },
    ...over,
  })
}

function why(bytes: string, folder = 'word-count'): string {
  const parsed = parsePluginManifest(bytes, folder)
  if (parsed.ok) throw new Error('expected a refusal')
  return parsed.why
}

describe('a plugin manifest', () => {
  it('reads a good one', () => {
    const parsed = parsePluginManifest(manifest(), 'word-count')
    expect(parsed.ok).toBe(true)
    if (!parsed.ok) return
    expect(parsed.manifest.capabilities).toEqual(['tasks.read', 'tools.contribute'])
    expect(parsed.manifest.tools.map((tool) => tool.name)).toEqual(['count'])
    expect(pluginToolWire('word-count', 'count')).toBe('plugin_word-count_count')
  })

  it('wears the tier of a program this app starts', () => {
    expect(PLUGIN_TIER).toBe(3)
  })

  it('refuses a key it does not know, by name', () => {
    expect(why(manifest({ command: 'curl x | sh' }))).toContain('command')
    expect(why(manifest({}, { shell: true }))).toContain('shell')
  })

  it('refuses a capability that is not on the list', () => {
    expect(why(manifest({}, { capabilities: ['tasks.read', 'network'] }))).toContain('plugin.capabilities[1]')
  })

  it('refuses a main file outside its own folder, and anything but node', () => {
    expect(why(manifest({}, { main: '../escape.js' }))).toContain('..')
    expect(why(manifest({}, { main: '/usr/bin/env.js' }))).toContain('cannot start with /')
    expect(why(manifest({}, { runtime: 'python' }))).toContain('plugin.runtime')
  })

  it('refuses tools without tools.contribute, and tools.contribute without tools', () => {
    expect(why(manifest({}, { capabilities: ['tasks.read'] }))).toContain('tools.contribute')
    expect(why(manifest({}, { tools: [] }))).toContain('declares none')
  })

  it('refuses an id that is not its folder, so two folders cannot claim one id', () => {
    expect(why(manifest(), 'other')).toContain('its folder is called other')
  })

  it('cannot make a wire name too long for the model’s API, even at both limits', () => {
    const id = 'a'.repeat(40)
    const bytes = manifest({ id }, { tools: [{ name: 'abcdefghijklmnop', title: 't', description: 'd', tier: 'read', inputSchema: { type: 'object' } }] })
    expect(parsePluginManifest(bytes, id).ok).toBe(true)
    expect(pluginToolWire(id, 'abcdefghijklmnop')).toMatch(/^[a-zA-Z0-9_-]{1,64}$/)
    expect(why(manifest({}, { tools: [{ name: 'abcdefghijklmnopq', title: 't', description: 'd', tier: 'read', inputSchema: { type: 'object' } }] }))).toContain('16 characters')
  })

  it('refuses schema words nothing enforces', () => {
    const bytes = manifest({}, { tools: [{ name: 'count', title: 't', description: 'd', tier: 'read', inputSchema: { type: 'object', pattern: '.*' } }] })
    expect(why(bytes)).toContain('pattern')
  })
})
