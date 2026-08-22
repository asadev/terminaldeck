import { describe, expect, it, vi } from 'vitest'
import type { ExtensionManifest } from '../browser-extension-support'
import type { ExtensionResult, InstalledExtension } from '../browser-extensions'
import { extensionTools, listExtensions, noteFor, type ExtensionToolDeps } from './extension-tools'
import { STORE_PLACE } from './store-tools'
import type { ToolContext } from './catalogue'

function installed(id: string, manifest: Partial<ExtensionManifest>): InstalledExtension {
  return {
    entry: {
      id,
      name: id,
      summary: '',
      homepage: 'https://example.com',
      licence: 'MIT',
      version: '1.0',
      category: 'scripting',
      tags: [],
      works: 'works',
      measured: 'Watched working.',
      reach: [],
      source: null,
    },
    dir: `/tmp/${id}`,
    manifest: { manifest_version: 3, name: id, version: '1.0', ...manifest },
    installedAt: 0,
    enabled: true,
  }
}

function depsWith(
  list: InstalledExtension[],
  on: Set<string> = new Set(list.map((one) => one.entry.id)),
  setEnabled: ExtensionToolDeps['setEnabled'] = async () => ({ ok: true, message: 'done' }),
): ExtensionToolDeps {
  return {
    installed: () => list,
    isLoaded: (_profileId, id) => on.has(id),
    currentProfileId: () => 'default',
    profileName: () => 'Default',
    setEnabled,
  }
}

const CONTEXT = {} as ToolContext

describe('the sentence an agent gets about one extension', () => {
  it('warns when its content scripts run on every page', () => {
    /*
     * The reason this tool exists at all. An agent that reads a page without
     * knowing a rewriter is running will report the extension's output as the
     * site's, and be confidently wrong about a colour or a missing element.
     */
    expect(noteFor(installed('a', { host_permissions: ['<all_urls>'] }))).toContain('every page')
  })

  it('names the chrome.* it asks for and this browser has not got', () => {
    expect(noteFor(installed('a', { permissions: ['contextMenus'] }))).toContain('chrome.contextMenus')
  })

  it('names static rulesets, which nothing else would show', () => {
    const note = noteFor(
      installed('a', {
        permissions: ['declarativeNetRequest'],
        declarative_net_request: { rule_resources: [{ id: 'r', enabled: true, path: 'r.json' }] },
      }),
    )
    expect(note).toContain('declarativeNetRequest rulesets')
  })

  it('says nothing about an extension there is nothing to say about', () => {
    // A note on every row would be noise, and noise is how a real warning gets
    // read past.
    expect(noteFor(installed('a', { permissions: ['storage'], host_permissions: ['https://a.com/*'] }))).toBe('')
  })
})

describe('listing', () => {
  it('reports what is running from the live session, not from the disk', () => {
    const list = [installed('a', {}), installed('b', {})]
    const rows = listExtensions(depsWith(list, new Set(['a'])), 'default')
    expect(rows.map((row) => [row.extension, row.on])).toEqual([
      ['a', true],
      ['b', false],
    ])
  })

  it('answers an empty profile with a sentence naming where one is installed', async () => {
    /*
     * `store-tools.ts`: the door *"is not allowed to look open when nothing came
     * through it"*. An empty array with no explanation reads as a failure.
     */
    const [tool] = extensionTools(depsWith([]))
    const output = await tool.run({}, CONTEXT)
    const value = output.value as { extensions: unknown[]; note: string }
    expect(value.extensions).toEqual([])
    // The same words the menu row wears — STORE_PLACE, the one door to the
    // unified store — so the sentence an agent relays matches the screen a
    // person then goes looking at.
    expect(value.note).toContain(STORE_PLACE)
  })
})

describe('the gate', () => {
  it('stays a read when it is only being asked what is there', () => {
    // A listing call must not cost a dialog, or nobody will let an agent check.
    const [tool] = extensionTools(depsWith([]))
    expect(tool.escalate?.({}, CONTEXT)).toBe('read')
  })

  it('rises to alter when something is being switched', () => {
    /*
     * Switching changes every page in the profile for everybody in the window,
     * and it outlives the run because the state is written down. That is not
     * this run's business alone.
     */
    const [tool] = extensionTools(depsWith([]))
    expect(tool.escalate?.({ extension: 'a', on: false }, CONTEXT)).toBe('alter')
  })
})

describe('switching', () => {
  it('refuses without saying which way', async () => {
    const [tool] = extensionTools(depsWith([installed('a', {})]))
    await expect(tool.run({ extension: 'a' }, CONTEXT)).rejects.toThrow('must be true or false')
  })

  it('refuses an extension that is not installed, and names the call that would have worked', async () => {
    const [tool] = extensionTools(depsWith([installed('a', {})]))
    await expect(tool.run({ extension: 'nope', on: true }, CONTEXT)).rejects.toThrow(
      /Call this tool with no extension/,
    )
  })

  it('reports what is actually running afterwards, not what it asked for', async () => {
    /*
     * The failure this guards: the store writes `enabled: true` to disk and the
     * browser then refuses to load it. A tool that answered `on: true` because
     * nothing threw would be reporting its own intention — and the whole point
     * of the tool is to say what is *actually* running.
     */
    const on = new Set<string>()
    const deps = depsWith([installed('a', {})], on, async () => ({ ok: true, message: 'switched on' }))
    const [tool] = extensionTools(deps)
    const output = await tool.run({ extension: 'a', on: true }, CONTEXT)
    expect((output.value as { on: boolean }).on).toBe(false)
    expect(output.summary.on).toBe(false)
  })

  it('turns a refusal from the store into a refusal here', async () => {
    const deps = depsWith([installed('a', {})], new Set(['a']), async () => ({
      ok: false,
      message: 'the browser refused it',
    }))
    const [tool] = extensionTools(deps)
    await expect(tool.run({ extension: 'a', on: true }, CONTEXT)).rejects.toThrow('the browser refused it')
  })

  it('passes the profile through rather than switching whichever is in front', async () => {
    // Switching the wrong profile's extension is the same class of mistake as
    // installing into it, and it is invisible from the answer.
    const setEnabled = vi.fn<ExtensionToolDeps['setEnabled']>(async (): Promise<ExtensionResult> => ({
      ok: true,
      message: 'done',
    }))
    const [tool] = extensionTools(depsWith([installed('a', {})], new Set(['a']), setEnabled))
    await tool.run({ extension: 'a', on: false, profile: 'other-profile' }, CONTEXT)
    expect(setEnabled).toHaveBeenCalledWith('other-profile', 'a', false)
  })
})

describe('what the tool never offers', () => {
  it('has no way to install or remove', () => {
    /*
     * An install downloads and unpacks a program that then runs on every page of
     * a profile. That is a decision for the person whose profile it is, having
     * read what it reaches — and a catalogue an agent can work through is one
     * that can install nine programs while nobody is looking.
     */
    const [tool] = extensionTools(depsWith([]))
    const keys = Object.keys(tool.inputSchema.properties ?? {})
    expect(keys).toEqual(['extension', 'on', 'profile'])
    expect(tool.inputSchema.additionalProperties).toBe(false)
    expect(tool.description.toLowerCase()).toContain('cannot install, remove or drive one')
  })
})

describe('a session asking', () => {
  /*
   * The narrowing that let this tool onto `SESSION_TOOLS` at all. A session
   * resolves everything else — every window, every page — inside its own
   * binding; a list of what is installed in every profile somebody keeps is a
   * list of the separations they went to the trouble of making, and a shell on
   * a server does not need it to read a page.
   */
  const SESSION = { caller: { kind: 'session', sessionId: 's1' } } as unknown as ToolContext

  it('is refused when it names a profile, in words naming the call that works', async () => {
    const [tool] = extensionTools(depsWith([installed('a', {})], new Set(['a'])))
    await expect(tool.run({ profile: 'other-profile' }, SESSION)).rejects.toThrow(
      'Call this tool with no profile',
    )
  })

  it('gets the profile that is switched on when it names none', async () => {
    const [tool] = extensionTools(depsWith([installed('a', {})], new Set(['a'])))
    const out = (await tool.run({}, SESSION)).value as { profile: string; extensions: unknown[] }
    expect(out.profile).toBe('default')
    expect(out.extensions).toHaveLength(1)
  })

  it('still switches one in the profile it is driving', async () => {
    const setEnabled = vi.fn<ExtensionToolDeps['setEnabled']>(async (): Promise<ExtensionResult> => ({
      ok: true,
      message: 'done',
    }))
    const [tool] = extensionTools(depsWith([installed('a', {})], new Set(['a']), setEnabled))
    await tool.run({ extension: 'a', on: false }, SESSION)
    expect(setEnabled).toHaveBeenCalledWith('default', 'a', false)
  })
})
