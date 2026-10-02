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
      cost: 'free',
      costNote: '',
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
  it('never takes a path to add an extension from', () => {
    /*
     * Until 0.16.0 this test read "has no way to install or remove", and it
     * pinned a decision that has since been reversed at Asad's word —
     * *"Everything that I can do manually should be able to do through the
     * MCP"*. What survives of it is the rule that made adding your own safe at
     * the panel: an extension added from disk is one a person pointed at in the
     * native chooser, never a path a caller composed. So the schema must have no
     * field a path could travel in, whatever else it grows.
     */
    const [tool] = extensionTools(depsWith([]))
    const keys = Object.keys(tool.inputSchema.properties ?? {})
    expect(keys).toEqual(['action', 'extension', 'name', 'on', 'profile'])
    expect(keys.some((key) => /^(path|folder|file|dir|directory|url|source|origin)$/i.test(key))).toBe(false)
    expect(tool.inputSchema.additionalProperties).toBe(false)
  })

  it('makes every change to what is installed alter, so a person says yes to each', () => {
    const [tool] = extensionTools(depsWith([]))
    for (const action of ['install', 'remove', 'reload', 'rename', 'addfolder', 'addcrx', 'switch']) {
      expect(tool.escalate?.({ action, extension: 'a' }, CONTEXT), action).toBe('alter')
    }
    expect(tool.escalate?.({}, CONTEXT)).toBe('read')
    expect(tool.escalate?.({ action: 'catalogue' }, CONTEXT)).toBe('read')
    expect(tool.escalate?.({ action: 'popup', extension: 'a' }, CONTEXT)).toBe('act')
    // A word nobody wrote down reads as the dangerous one.
    expect(tool.escalate?.({ action: 'uninstall' }, CONTEXT)).toBe('alter')
  })

  it('says plainly that an extension is a program, and that it cannot click inside one', () => {
    const [tool] = extensionTools(depsWith([]))
    expect(tool.description).toContain('is a program that runs on every page')
    expect(tool.description).toContain('Nothing here can click inside an extension')
  })
})

describe('the panel’s other buttons', () => {
  it('installs through the function the panel calls, in the profile named by its name', async () => {
    const install = vi.fn(async (): Promise<ExtensionResult> => ({ ok: true, message: 'Installed.' }))
    const deps: ExtensionToolDeps = {
      ...depsWith([]),
      install,
      profiles: () => [
        { id: 'default', name: 'Default' },
        { id: 'p2', name: 'Work' },
      ],
    }
    const [tool] = extensionTools(deps)
    await tool.run({ action: 'install', extension: 'ublock', profile: 'work' }, CONTEXT)
    expect(install).toHaveBeenCalledWith('p2', 'ublock')
  })

  it('opens the chooser for the person rather than taking a path, and reads a cancel as no change', async () => {
    const addOwn = vi.fn(async (): Promise<ExtensionResult> => ({ ok: true, message: '' }))
    const [tool] = extensionTools({ ...depsWith([]), addOwn })
    const out = (await tool.run({ action: 'addfolder' }, CONTEXT)).value as { added: boolean }
    expect(addOwn).toHaveBeenCalledWith('default', 'folder')
    expect(out.added).toBe(false)
  })

  it('refuses to open a chooser nobody is there to answer', async () => {
    const addOwn = vi.fn(async (): Promise<ExtensionResult> => ({ ok: true, message: 'x' }))
    const [tool] = extensionTools({ ...depsWith([]), addOwn })
    await expect(
      tool.run({ action: 'addcrx' }, { ...CONTEXT, attended: false } as ToolContext),
    ).rejects.toThrow('nobody is there')
    expect(addOwn).not.toHaveBeenCalled()
  })

  it('says a build without the button cannot do it, rather than answering success', async () => {
    const [tool] = extensionTools(depsWith([installed('a', {})]))
    await expect(tool.run({ action: 'remove', extension: 'a' }, CONTEXT)).rejects.toThrow(
      'this build cannot remove an extension',
    )
  })

  it('refuses a remove of something that is not installed, naming the listing call', async () => {
    const remove = vi.fn((): ExtensionResult => ({ ok: true, message: '' }))
    const [tool] = extensionTools({ ...depsWith([]), remove })
    await expect(tool.run({ action: 'remove', extension: 'nope' }, CONTEXT)).rejects.toThrow(
      'Call this tool with no extension',
    )
    expect(remove).not.toHaveBeenCalled()
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

  it('cannot install, remove or add one, and is told who can', async () => {
    const install = vi.fn(async (): Promise<ExtensionResult> => ({ ok: true, message: '' }))
    const addOwn = vi.fn(async (): Promise<ExtensionResult> => ({ ok: true, message: '' }))
    const [tool] = extensionTools({ ...depsWith([installed('a', {})], new Set(['a'])), install, addOwn })
    for (const action of ['install', 'remove', 'addfolder', 'catalogue', 'popup']) {
      await expect(tool.run({ action, extension: 'a' }, SESSION), action).rejects.toThrow(
        'a session can list the extensions and switch one',
      )
    }
    expect(install).not.toHaveBeenCalled()
    expect(addOwn).not.toHaveBeenCalled()
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
