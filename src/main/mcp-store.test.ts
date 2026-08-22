import { describe, expect, it, vi } from 'vitest'
import type { McpCatalogue, McpCatalogueEntry } from './mcp-catalogue'
import {
  buildInstall,
  buildStoreView,
  installFromCatalogue,
  readEnvironmentNames,
  resolveInstall,
  type ConfiguredServer,
  type McpRuntimeReport,
  type McpStoreDeps,
} from './mcp-store'

/**
 * The store's engine.
 *
 * Everything here is the part that decides what a person is shown and what gets
 * written into another application's configuration, so every test is about one
 * of two failure shapes: a row that says something untrue about this machine,
 * or a write that happens when it should not have.
 */

/* ---------------------------------------------------------------- fixture -- */

const NEEDS_NOTHING: McpCatalogueEntry = {
  id: 'plain',
  name: 'plain',
  summary: 'Does a thing.',
  homepage: 'https://example.com/plain',
  licence: 'MIT',
  version: '1.0.0',
  registry: 'https://www.npmjs.com/package/plain',
  runtime: 'node',
  command: 'npx -y plain-server',
  token: 'plain-server',
  inputs: [],
  origin: 'third-party',
  caveat: null,
}

const NEEDS_A_PATH: McpCatalogueEntry = {
  ...NEEDS_NOTHING,
  id: 'rooted',
  name: 'rooted',
  command: 'npx -y rooted-server ${ROOT}',
  token: 'rooted-server',
  inputs: [
    { key: 'ROOT', label: 'Directory', hint: 'Absolute.', kind: 'path', into: 'arg', required: true },
  ],
}

const NEEDS_A_TOKEN: McpCatalogueEntry = {
  ...NEEDS_NOTHING,
  id: 'guarded',
  name: 'guarded',
  command: 'npx -y guarded-server',
  token: 'guarded-server',
  inputs: [
    { key: 'API_TOKEN', label: 'API token', hint: 'From them.', kind: 'secret', into: 'env', required: true },
  ],
}

const NEEDS_DOCKER: McpCatalogueEntry = {
  ...NEEDS_NOTHING,
  id: 'boxed',
  name: 'boxed',
  runtime: 'docker',
  command: 'docker run -i --rm boxed/server',
  token: 'boxed/server',
}

const CATALOGUE: McpCatalogue = [NEEDS_NOTHING, NEEDS_A_PATH, NEEDS_A_TOKEN, NEEDS_DOCKER]

const NODE_OK: McpRuntimeReport = {
  id: 'node',
  binary: 'npx',
  found: true,
  path: '/usr/bin/npx',
  needs: 'Node.js',
}
const DOCKER_MISSING: McpRuntimeReport = {
  id: 'docker',
  binary: 'docker',
  found: false,
  path: '',
  needs: 'Docker',
}

function view(over: Partial<Parameters<typeof buildStoreView>[0]> = {}) {
  return buildStoreView({
    catalogue: CATALOGUE,
    configured: [],
    runtimes: [NODE_OK, DOCKER_MISSING],
    environment: new Set<string>(),
    environmentSource: 'login-shell',
    writer: { found: true, path: '/usr/local/bin/claude' },
    projectPath: null,
    ...over,
  })
}

function row(id: string, over: Partial<Parameters<typeof buildStoreView>[0]> = {}) {
  const found = view(over).rows.find((entry) => entry.id === id)
  if (!found) throw new Error(`no row ${id}`)
  return found
}

/* ------------------------------------------------------------------ view -- */

describe('buildStoreView', () => {
  it('offers a row whose runtime is here', () => {
    expect(row('plain').state).toBe('available')
    expect(row('plain').blocked).toBe('')
  })

  it('refuses a row whose runtime is not, and says which binary was looked for', () => {
    /*
     * The honest-capability requirement, and the thing that separates this store
     * from a list of links: `docker` was actually looked for on this machine.
     * A row that installed anyway would write a command that cannot start, and
     * the failure would surface much later as "MCP is broken".
     */
    const boxed = row('boxed')
    expect(boxed.state).toBe('unavailable')
    expect(boxed.blocked).toContain('docker is not on this machine')
    expect(boxed.blocked).toContain('Docker')
  })

  it('knows its own row in the configuration by token, not by name alone', () => {
    const configured: ConfiguredServer[] = [
      { name: 'plain', scope: 'user', commandLine: 'npx -y plain-server' },
    ]
    expect(row('plain', { configured }).state).toBe('installed')
    expect(row('plain', { configured }).scope).toBe('user')
  })

  it('shows an installed row what is actually configured, not the template', () => {
    /*
     * Caught by rendering the page and looking at it: the installed row printed
     * its `${ROOT}` placeholder next to a Remove button, so the one question
     * that row exists to answer — which directory did I point it at — had no
     * answer on screen.
     */
    const configured: ConfiguredServer[] = [
      { name: 'rooted', scope: 'user', commandLine: 'npx -y rooted-server /Users/me/code' },
    ]
    expect(row('rooted', { configured }).command).toBe('npx -y rooted-server /Users/me/code')
    // And a row that is not installed still shows the template, placeholder and
    // all, because that is what pressing Install would write.
    expect(row('rooted').command).toContain('${ROOT}')
  })

  it('will not touch a server that merely shares a name', () => {
    /*
     * Somebody's own `plain` server, added by hand, pointing somewhere else.
     * Treating it as installed would put a Remove on it that deletes a line this
     * store never wrote; treating it as available would offer an Install the CLI
     * refuses as a duplicate. Neither, and the row says which.
     */
    const configured: ConfiguredServer[] = [
      { name: 'plain', scope: 'local', commandLine: 'node /home/me/my-own-server.js' },
    ]
    const taken = row('plain', { configured })
    expect(taken.state).toBe('taken')
    expect(taken.taken).toBe('node /home/me/my-own-server.js')
    expect(taken.blocked).toContain('already configured and it is not this one')
  })

  it('blocks every row when the tool that writes the configuration is missing', () => {
    // Not `unavailable`: the machine can run these servers perfectly well, it is
    // *writing* that is impossible. Different problem, different sentence.
    const noWriter = view({ writer: { found: false, path: '' } })
    const plain = noWriter.rows.find((entry) => entry.id === 'plain')
    expect(plain?.state).toBe('available')
    expect(plain?.blocked).toContain('command line tool')
  })

  it('marks an environment input as inheritable only when it was actually found', () => {
    expect(row('guarded').inputs[0].inEnvironment).toBe(false)
    const seen = row('guarded', { environment: new Set(['API_TOKEN']) })
    expect(seen.inputs[0].inEnvironment).toBe(true)
  })

  it('never offers to inherit an argument', () => {
    // A command line argument cannot come from the environment. An offer to
    // leave it blank would be a control that does nothing.
    const rooted = row('rooted', { environment: new Set(['ROOT']) })
    expect(rooted.inputs[0].inEnvironment).toBe(false)
  })
})

/* --------------------------------------------------------------- install -- */

describe('buildInstall', () => {
  it('substitutes an argument and quotes it', () => {
    const built = buildInstall(NEEDS_A_PATH, { ROOT: '/Users/me/My Folder' }, new Set())
    expect(built.command).toBe('npx -y rooted-server "/Users/me/My Folder"')
    expect(built.extras).toEqual([])
  })

  it('refuses rather than leaving a placeholder in the command', () => {
    /*
     * The failure this function exists for. An unsubstituted `${ROOT}` produces
     * a server rooted at a literal dollar-brace: it starts, it answers, and it
     * reads nothing — a working-looking failure, which is the worst kind.
     */
    expect(() => buildInstall(NEEDS_A_PATH, {}, new Set())).toThrow(/needs directory/i)
    expect(() => buildInstall(NEEDS_A_PATH, { ROOT: '  ' }, new Set())).toThrow(/needs directory/i)
  })

  it('refuses a value that would split in the wrong place', () => {
    // Nothing here goes through a shell — the tokens go straight into
    // `execFile`'s argv — so this is not an injection guard. It is a tokenizer
    // that would break the argument in two.
    expect(() => buildInstall(NEEDS_A_PATH, { ROOT: '/a/"b' }, new Set())).toThrow(/double quote/i)
  })

  it('writes a typed secret as an environment pair', () => {
    const built = buildInstall(NEEDS_A_TOKEN, { API_TOKEN: 'sk-live-1' }, new Set())
    expect(built.extras).toEqual(['API_TOKEN=sk-live-1'])
    expect(built.inherited).toEqual([])
  })

  it('leaves a secret to the shell when the shell already has it', () => {
    /*
     * The whole point of measuring the login environment. Nothing is written
     * down, so there is no second copy of the token in a config file — and the
     * row is only ever offered this when the name was actually found, never
     * blind.
     */
    const built = buildInstall(NEEDS_A_TOKEN, {}, new Set(['API_TOKEN']))
    expect(built.extras).toEqual([])
    expect(built.inherited).toEqual(['API_TOKEN'])
  })

  it('prefers what was typed over what the shell has', () => {
    const built = buildInstall(NEEDS_A_TOKEN, { API_TOKEN: 'typed' }, new Set(['API_TOKEN']))
    expect(built.extras).toEqual(['API_TOKEN=typed'])
    expect(built.inherited).toEqual([])
  })

  it('refuses a required secret that is neither typed nor in the shell', () => {
    expect(() => buildInstall(NEEDS_A_TOKEN, {}, new Set())).toThrow(/needs api token/i)
  })

  it('refuses a pasted value with a line break in it', () => {
    // A newline would end the `KEY=value` entry and begin something else in the
    // extras list. A token never has one; a paste that does is a paste that
    // went wrong.
    expect(() => buildInstall(NEEDS_A_TOKEN, { API_TOKEN: 'a\nb' }, new Set())).toThrow(/line break/i)
  })
})

describe('resolveInstall', () => {
  it('takes only strings, and trims them', () => {
    const request = resolveInstall({ id: 'plain', scope: 'user', values: { A: ' x ', B: 7 } })
    expect(request.values).toEqual({ A: 'x' })
  })

  it('falls back to user scope rather than guessing', () => {
    expect(resolveInstall({ id: 'plain', scope: 'nonsense' }).scope).toBe('user')
  })

  it('refuses nothing at all', () => {
    expect(() => resolveInstall(null)).toThrow(/nothing to install/i)
    expect(() => resolveInstall({})).toThrow(/nothing to install/i)
  })
})

/* ----------------------------------------------------------- the writing -- */

/** A deps set whose probes answer whatever is asked, without touching a machine. */
function deps(over: { found?: string[]; env?: string[]; add?: McpStoreDeps['add'] } = {}): McpStoreDeps {
  const found = new Set(over.found ?? ['npx', 'docker', 'claude'])
  return {
    platform: 'darwin',
    path: async () => '/usr/bin',
    add: over.add ?? (async () => ({ ok: true, message: 'Added.' })),
    exec: async (file, args) => {
      if (file === 'which') return { stdout: found.has(args[0]) ? `/usr/bin/${args[0]}\n` : '', stderr: '' }
      // The login shell, printing names.
      return { stdout: (over.env ?? []).join('\n'), stderr: '' }
    },
  }
}

describe('installFromCatalogue', () => {
  it('writes the whole server through the add path', async () => {
    const add = vi.fn(async () => ({ ok: true, message: 'Added.' }))
    const result = await installFromCatalogue(
      { id: 'filesystem', scope: 'user', values: { ROOT: '/Users/me/code' } },
      [],
      deps({ add }),
    )
    expect(result.ok).toBe(true)
    expect(add).toHaveBeenCalledWith({
      name: 'filesystem',
      scope: 'user',
      transport: 'stdio',
      command: 'npx -y @modelcontextprotocol/server-filesystem "/Users/me/code"',
      url: '',
      extras: [],
      projectPath: null,
    })
  })

  it('re-probes the runtime rather than trusting the view', async () => {
    /*
     * The view the renderer is looking at may be minutes old and Docker may have
     * been quit in between. A store that installs a row it has already drawn as
     * unavailable is the dead control with an extra step.
     */
    const add = vi.fn(async () => ({ ok: true, message: 'Added.' }))
    const result = await installFromCatalogue(
      { id: 'github', scope: 'user', values: { GITHUB_PERSONAL_ACCESS_TOKEN: 'ghp_x' } },
      [],
      deps({ found: ['npx', 'claude'], add }),
    )
    expect(result.ok).toBe(false)
    expect(result.message).toContain('docker is not on this machine')
    expect(add).not.toHaveBeenCalled()
  })

  it('refuses to overwrite a server that already owns the name', async () => {
    const add = vi.fn(async () => ({ ok: true, message: 'Added.' }))
    const result = await installFromCatalogue({ id: 'memory', scope: 'user', values: {} }, [
      { name: 'memory', scope: 'user', commandLine: 'node /home/me/memory.js' },
    ], deps({ add }))
    expect(result.ok).toBe(false)
    expect(result.message).toContain('Nothing was changed.')
    expect(add).not.toHaveBeenCalled()
  })

  it('says where a typed secret went, in the message', async () => {
    // *"a row that cannot work without one says so BEFORE install"* is the other
    // half; this is the half after. A person who has just typed a token into a
    // box is entitled to be told, in the same breath, that it is now in a file.
    const result = await installFromCatalogue(
      { id: 'tavily', scope: 'user', values: { TAVILY_API_KEY: 'tvly-1' } },
      [],
      deps(),
    )
    expect(result.ok).toBe(true)
    expect(result.message).toContain('TAVILY_API_KEY was written into your user configuration in plain text')
  })

  it('says when nothing was written down, because the shell already had it', async () => {
    const add = vi.fn(async () => ({ ok: true, message: 'Added.' }))
    const result = await installFromCatalogue({ id: 'tavily', scope: 'user', values: {} }, [], deps({
      env: ['PATH', 'TAVILY_API_KEY'],
      add,
    }))
    expect(result.ok).toBe(true)
    expect(result.message).toContain('left to your login shell')
    expect(add).toHaveBeenCalledWith(expect.objectContaining({ extras: [] }))
  })

  it('refuses a required secret before it writes anything', async () => {
    const add = vi.fn(async () => ({ ok: true, message: 'Added.' }))
    const result = await installFromCatalogue({ id: 'tavily', scope: 'user', values: {} }, [], deps({ add }))
    expect(result.ok).toBe(false)
    expect(result.message).toMatch(/needs api key/i)
    expect(add).not.toHaveBeenCalled()
  })

  it('never throws for an ordinary refusal', async () => {
    // A store whose failure mode is an unhandled rejection is the silent-drop
    // bug this codebase keeps having to fix elsewhere.
    await expect(installFromCatalogue({ id: 'not-a-row' }, [], deps())).resolves.toEqual({
      ok: false,
      message: 'This build has no such server.',
    })
  })
})

describe('readEnvironmentNames', () => {
  it('reads this process’s own environment on Windows', async () => {
    const answer = await readEnvironmentNames(
      ['A', 'B'],
      'win32',
      { A: 'set', B: '' } as NodeJS.ProcessEnv,
      deps(),
    )
    expect([...answer.names]).toEqual(['A'])
    expect(answer.source).toBe('process')
  })

  it('claims nothing when the shell could not be asked', async () => {
    /*
     * A failed probe is not evidence of absence. Reporting "not set" from one
     * would push somebody into pasting a token they did not need to — which is
     * the opposite of what this whole path is for.
     */
    const answer = await readEnvironmentNames(['A'], 'darwin', {} as NodeJS.ProcessEnv, {
      platform: 'darwin',
      path: async () => '/usr/bin',
      exec: async () => {
        throw new Error('no shell')
      },
    })
    expect(answer.names.size).toBe(0)
    expect(answer.source).toBe('unavailable')
  })

  it('keeps only the names it was asked about', async () => {
    const answer = await readEnvironmentNames(['WANTED'], 'darwin', {} as NodeJS.ProcessEnv, {
      platform: 'darwin',
      path: async () => '/usr/bin',
      exec: async () => ({ stdout: 'HOME\nWANTED\nSECRET_OF_THEIRS\n', stderr: '' }),
    })
    expect([...answer.names]).toEqual(['WANTED'])
  })
})
