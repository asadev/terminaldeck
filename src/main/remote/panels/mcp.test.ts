import { normalize } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { McpServerConfig } from '../../mcp-client'
import type { Panel, PanelActionRequest, PanelPayload } from './contract'
import { mcpPanel, type McpPanelDeps } from './mcp'

/**
 * The MCP panel, on a phone.
 *
 * Three things are being pinned, and the middle one is why this file is longer
 * than a list of rows would need.
 *
 *  1. **It never throws.** The screen this replaces answered a headless host
 *     with *"This machine could not answer that panel."* Every failure here has
 *     to arrive as a sentence on a drawn screen — an unreadable configuration,
 *     a pool that rejected, an action nobody offered.
 *  2. **A blank environment box keeps the saved value, and a cleared one drops
 *     it.** That promise is about somebody's API key, and the phone is never
 *     sent one, so a wrong merge is a credential silently replaced with an
 *     empty string in a file they cannot see the inside of. Both halves are
 *     exercised through the real `mcp-edit.ts`, with only the spawn stubbed,
 *     because the merge is the thing under test and a stubbed merge tests
 *     nothing.
 *  3. **The edit form and the row agree.** The form is prefilled from the row,
 *     so a disagreement between them is a person saving a command they were
 *     never shown.
 */

/** One configured server, as `loadServers` would hand it over. */
function server(over: Partial<McpServerConfig> = {}): McpServerConfig {
  return {
    id: 'user:mine',
    name: 'mine',
    scope: 'user',
    transport: 'stdio',
    command: 'npx',
    args: ['-y', '@me/thing'],
    env: { API_KEY: 'secret-value' },
    cwd: null,
    url: null,
    source: '/home/me/.claude.json',
    enabled: true,
    disabledReason: null,
    unsupported: null,
    ...over,
  }
}

/**
 * A recorder for the CLI spawn, so what was written can be read back.
 *
 * `path` is stubbed alongside `exec` because the real one probes a login shell,
 * and a unit test that spawns `/bin/sh -lc` to answer a question about a text
 * field is a unit test that fails on a busy machine.
 */
/**
 * The CLI, recorded rather than run — and recorded **as a command line**.
 *
 * `args` alone is not portable and Windows CI proved it: `mcp-add.ts` launches
 * through `cmd.exe /c claude …` on Windows, because `claude` is a `.cmd` shim
 * and `execFile` cannot run one, so the same press arrives here as
 * `['/c', 'claude mcp remove --scope user mine']` instead of
 * `['mcp', 'remove', '--scope', 'user', 'mine']`. Two tests asserted the POSIX
 * shape and failed on a machine where the product was behaving correctly.
 *
 * `line` is what every assertion reads: the whole invocation with the launcher
 * and the program name taken off, so it says what was *asked for* on either
 * platform. `file` and `args` are still recorded, for the one test that is about
 * the launcher itself.
 */
function cli() {
  const calls: { file: string; args: string[]; line: string; cwd: string }[] = []
  return {
    calls,
    writes: {
      path: async () => '/usr/bin',
      exec: async (file: string, args: string[], options: { cwd: string }) => {
        // `cmd /c "claude mcp …"` is one argument carrying the whole line;
        // everywhere else the program is `file` and `args` is already the line.
        const whole = args[0] === '/c' ? (args[1] ?? '') : args.join(' ')
        calls.push({
          file,
          args,
          line: whole.replace(/^claude\s+/, ''),
          cwd: options.cwd,
        })
        return { stdout: '', stderr: '' }
      },
    } satisfies McpPanelDeps['writes'],
  }
}

/**
 * Every action goes through here.
 *
 * `Panel.act` is optional in the contract, because a panel with nothing to do
 * is a legitimate panel — so `panel.act?.(…)` in a test would turn *this* panel
 * losing its verbs into a pass over an undefined view, which is the whole thing
 * these tests exist to catch.
 */
async function act(panel: Panel, request: PanelActionRequest): Promise<PanelPayload> {
  const run = panel.act
  if (run === undefined) throw new Error('the MCP panel must offer actions')
  return run.call(panel, request)
}

const AT = '/work/app'

/* ------------------------------------------------------------- the list -- */

describe('reading the panel', () => {
  it('lists a configured server with what it runs and where it is saved', async () => {
    const panel = mcpPanel({ list: () => [server()] })
    const view = await panel.read({ path: AT })

    expect(view.path).toBe(AT)
    expect(view.rows).toHaveLength(1)
    expect(view.rows[0]).toMatchObject({
      title: 'mine',
      // Quoted by `quoteArgv`, not space-joined: a path with a space in it must
      // read back as the one argument it is in the configuration.
      detail: 'npx -y @me/thing',
      value: 'user · stdio',
      id: 'user:mine',
    })
  })

  it('reads all three scopes, not only the folder in view', async () => {
    // The stand-in this replaces opened three files under the folder, two of
    // which never hold an `mcpServers` key, and missed `~/.claude.json`
    // entirely — so a phone saw nothing while the desktop listed a dozen. The
    // panel asks for a folder and takes back whatever the reader found.
    const seen: (string | null)[] = []
    const panel = mcpPanel({
      list: (projectPath) => {
        seen.push(projectPath)
        return [server(), server({ id: 'project:shared', name: 'shared', scope: 'project' })]
      },
    })
    const view = await panel.read({ path: AT })

    expect(seen).toEqual([AT])
    expect(view.rows.map((row) => row.value)).toEqual(['user · stdio', 'project · stdio'])
  })

  it('shows why a server will not load instead of what it runs', async () => {
    const panel = mcpPanel({
      list: () => [
        server({ scope: 'project', enabled: false, disabledReason: 'Not approved for this project yet.' }),
      ],
    })
    const view = await panel.read({ path: AT })

    expect(view.rows[0].detail).toBe('Not approved for this project yet.')
    expect(view.rows[0].status).toBe('warn')
  })

  it('keeps an HTTP server’s URL on the row rather than a sentence about this app', async () => {
    // Every non-stdio server carries `unsupported` — it says this app's own
    // inspector cannot dial it — and putting that in the detail line would
    // replace the address of every working remote server with a note about us.
    const panel = mcpPanel({
      list: () => [
        server({
          id: 'user:remote',
          name: 'remote',
          transport: 'http',
          command: null,
          args: [],
          url: 'https://example.com/mcp',
          unsupported: 'Claude Code dials HTTP servers itself, so this panel cannot inspect it.',
        }),
      ],
    })
    const view = await panel.read({ path: AT })

    expect(view.rows[0].detail).toBe('https://example.com/mcp')
    expect(view.rows[0].value).toBe('user · http')
  })

  it('filters to one scope and says so when that empties the list', async () => {
    const panel = mcpPanel({ list: () => [server()] })
    const view = await panel.read({ path: AT, scope: 'project' })

    expect(view.rows).toHaveLength(0)
    expect(view.note).toContain('project scope')
    expect(view.scopes?.find((one) => one.id === 'project')?.on).toBe(true)
  })
})

/* ------------------------------------------------------- what is running -- */

describe('what this host is holding', () => {
  const held = (state: string, error: string | null = null): McpPanelDeps['pool'] => ({
    getStatus: () => ({ state, error }),
    connect: async () => ({ state, error }),
    disconnect: async () => null,
  })

  it('draws a connected server green and offers to disconnect it', async () => {
    const panel = mcpPanel({ list: () => [server()], pool: held('ready') })
    const view = await panel.read({ path: AT })

    expect(view.rows[0].status).toBe('ok')
    expect(view.rows[0].actions?.map((one) => one.id)).toEqual(['disconnect', 'edit', 'remove'])
  })

  it('draws a failed server red and puts its error where the command was', async () => {
    const panel = mcpPanel({ list: () => [server()], pool: held('failed', 'spawn npx ENOENT') })
    const view = await panel.read({ path: AT })

    expect(view.rows[0].status).toBe('bad')
    expect(view.rows[0].detail).toBe('spawn npx ENOENT')
  })

  it('claims nothing about connections on a host that holds none', async () => {
    // A headless host with no pool injected still lists, adds, edits and
    // removes. An amber "not connected" light there would report the absence of
    // a feature as a fault.
    const panel = mcpPanel({ list: () => [server()] })
    const view = await panel.read({ path: AT })

    expect(view.rows[0].status).toBeUndefined()
    expect(view.rows[0].actions?.map((one) => one.id)).toEqual(['edit', 'remove'])
  })
})

/* ---------------------------------------------------------------- adding -- */

describe('adding a server', () => {
  it('writes it into the scope the form named, from the folder that addresses it', async () => {
    const spawn = cli()
    const panel = mcpPanel({ list: () => [], writes: spawn.writes })

    const view = await act(panel, {
      path: AT,
      action: 'add',
      fields: { name: 'files', command: 'npx -y @modelcontextprotocol/server-filesystem', scope: 'project', 'env.4': '' },
    })

    expect(spawn.calls).toHaveLength(1)
    expect(spawn.calls[0].line).toContain('--scope project')
    expect(spawn.calls[0].line).toContain('mcp add --scope project files --')
    /*
     * `normalize`, not the literal. `resolveRequest` canonicalises the path for
     * the machine it runs on, and on Windows that rewrites the separators — the
     * assertion that matters is "the CLI ran in the folder we were given", and
     * two of the three scopes are addressed by nothing else.
     */
    expect(spawn.calls[0].cwd).toBe(normalize(AT))
    expect(view.notice).toContain('files')
  })

  it('carries an environment variable through as one -e', async () => {
    const spawn = cli()
    const panel = mcpPanel({ list: () => [], writes: spawn.writes })

    await act(panel, {
      path: AT,
      action: 'add',
      fields: { name: 'files', command: 'npx -y @me/thing', scope: 'user', 'env.4': 'API_KEY=fresh' },
    })

    expect(spawn.calls[0].line).toContain('-e API_KEY=fresh')
  })

  it('asks for a command or a URL rather than naming only the command box', async () => {
    // `resolveRequest` would answer an empty form with "Give the command that
    // starts the server" and say nothing about the URL box beside it, because
    // it is told a transport rather than reading one off the shape.
    const spawn = cli()
    const panel = mcpPanel({ list: () => [], writes: spawn.writes })

    const view = await act(panel, { path: AT, action: 'add', fields: { name: 'files', scope: 'user' } })

    expect(spawn.calls).toHaveLength(0)
    expect(view.notice).toBe('Give the command that starts the server, or its URL.')
  })

  it('offers Add on a folder with nothing configured, with a note rather than an error', async () => {
    const panel = mcpPanel({ list: () => [] })
    const view = await panel.read({ path: '/work/empty' })

    expect(view.rows).toEqual([])
    expect(view.note).toBe('No MCP servers are configured for /work/empty.')
    expect(view.actions?.map((one) => one.id)).toEqual(['add'])
    // Nothing to filter, so no chips.
    expect(view.scopes).toBeUndefined()
  })
})

/* --------------------------------------------------------------- editing -- */

describe('editing a server', () => {
  it('prefills the form from the row it belongs to', async () => {
    const panel = mcpPanel({ list: () => [server()] })
    const view = await panel.read({ path: AT })
    const row = view.rows[0]
    const form = row.actions?.find((one) => one.id === 'edit')?.fields ?? []
    const at = (id: string) => form.find((field) => field.id === id)

    // The form and the row are the same fact twice; a disagreement is somebody
    // saving a command they were never shown.
    expect(at('command')?.value).toBe(row.detail)
    expect(at('name')?.value).toBe('mine')
    expect(at('url')?.value).toBe('')
    expect(at('scope')?.value).toBe('user')

    // One box per saved variable, prefilled with the key and nothing after the
    // `=`. The value is not on this wire in either direction.
    expect(at('env.4')).toMatchObject({ label: 'API_KEY', value: 'API_KEY=' })
    expect(JSON.stringify(form)).not.toContain('secret-value')
    // And one empty box, so a new variable can be added without a second trip.
    expect(at('env.5')).toMatchObject({ label: 'Environment variable' })
    expect(at('env.5')?.value).toBeUndefined()
  })

  it('keeps a saved value the form did not change', async () => {
    const spawn = cli()
    const panel = mcpPanel({ list: () => [server()], writes: spawn.writes })

    await act(panel, {
      path: AT,
      action: 'edit',
      id: 'user:mine',
      fields: {
        name: 'mine',
        command: 'npx -y @me/thing --verbose',
        url: '',
        scope: 'user',
        // Left exactly as it was drawn.
        'env.4': 'API_KEY=',
      },
    })

    // An edit is a remove and then an add, because the CLI that owns the file
    // has no replace. Read off the command line rather than off `args[1]`: on
    // Windows the whole invocation is one argument behind `cmd /c`, so that
    // index is the program's name there and the verb here.
    expect(spawn.calls.map((call) => call.line.split(' ')[1])).toEqual(['remove', 'add'])
    expect(spawn.calls[1].line).toContain('-e API_KEY=secret-value')
    expect(spawn.calls[1].line).toContain('-- npx -y @me/thing --verbose')
  })

  it('drops a variable whose box was cleared', async () => {
    const spawn = cli()
    const panel = mcpPanel({ list: () => [server()], writes: spawn.writes })

    await act(panel, {
      path: AT,
      action: 'edit',
      id: 'user:mine',
      fields: { name: 'mine', command: 'npx -y @me/thing', url: '', scope: 'user', 'env.4': '' },
    })

    expect(spawn.calls[1].line).not.toContain('-e ')
    expect(spawn.calls[1].line).not.toContain('API_KEY')
  })

  it('answers a row that is gone with a sentence rather than a write', async () => {
    const spawn = cli()
    const panel = mcpPanel({ list: () => [], writes: spawn.writes })

    const view = await act(panel, {
      path: AT,
      action: 'edit',
      id: 'user:mine',
      fields: { name: 'mine', command: 'npx', scope: 'user' },
    })

    expect(spawn.calls).toHaveLength(0)
    expect(view.notice).toBe('That server is not in this configuration any more.')
  })
})

/* -------------------------------------------------------------- removing -- */

describe('removing a server', () => {
  it('removes it at its own scope rather than letting the CLI choose', async () => {
    // Without a scope the CLI removes from whichever one the name exists in, so
    // a user-scope and a project-scope server of the same name are one press
    // from the wrong one going. The row knows which it is.
    const spawn = cli()
    const panel = mcpPanel({ list: () => [server()], writes: spawn.writes })

    const view = await act(panel, { path: AT, action: 'remove', id: 'user:mine', fields: {} })

    expect(spawn.calls[0].line).toBe('mcp remove --scope user mine')
    expect(view.notice).toContain('mine')
  })

  it('warns that a shared server goes for everyone', async () => {
    const panel = mcpPanel({ list: () => [server({ id: 'project:shared', name: 'shared', scope: 'project' })] })
    const view = await panel.read({ path: AT })
    const remove = view.rows[0].actions?.find((one) => one.id === 'remove')

    expect(remove?.kind).toBe('destructive')
    expect(remove?.confirm).toContain('.mcp.json')
  })
})

/* ------------------------------------------------------- nothing throws -- */

describe('a dependency that fails', () => {
  it('turns a configuration that cannot be read into a note and still offers Add', async () => {
    const panel = mcpPanel({
      list: () => {
        throw new Error('EACCES: permission denied, open /home/me/.claude.json')
      },
    })

    const view = await panel.read({ path: AT })

    expect(view.rows).toEqual([])
    expect(view.note).toContain('could not be read')
    expect(view.note).toContain('EACCES')
    expect(view.actions?.map((one) => one.id)).toEqual(['add'])
  })

  it('turns a pool that rejects into a line on the redraw', async () => {
    const panel = mcpPanel({
      list: () => [server()],
      pool: {
        getStatus: () => null,
        connect: async () => {
          throw new Error('the transport closed before it spoke')
        },
        disconnect: async () => null,
      },
    })

    const view = await act(panel, { path: AT, action: 'connect', id: 'user:mine', fields: {} })

    expect(view.notice).toBe('the transport closed before it spoke')
    // The point of catching it: there is still a screen underneath.
    expect(view.rows).toHaveLength(1)
  })

  it('answers an action it never offered without pretending it worked', async () => {
    const panel = mcpPanel({ list: () => [server()] })
    const view = await act(panel, { path: AT, action: 'call', id: 'user:mine', fields: {} })

    expect(view.notice).toBe('That is not something this panel offers.')
    expect(view.rows).toHaveLength(1)
  })
})
