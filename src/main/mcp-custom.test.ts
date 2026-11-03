import { describe, expect, it } from 'vitest'
import {
  customBinaries,
  customBinary,
  customCaveat,
  customId,
  customRow,
  customRows,
  customRuntime,
  customRunsWords,
  isCustomId,
} from './mcp-custom'
import { buildStoreView, type ConfiguredServer, type McpBinaryReport } from './mcp-store'
import { MCP_CATALOGUE } from './mcp-catalogue'

/**
 * The store's custom half: a server somebody typed, as a row.
 *
 * What is being held to account here is the *restraint*. A custom row has no
 * catalogue entry behind it, so almost every field a catalogue row carries has
 * to be empty rather than plausible — and the one thing this app can measure
 * about it, whether the command it starts is on this machine, has to be measured
 * the same way and reported as carefully as it is for the eighteen rows above.
 */

function server(over: Partial<ConfiguredServer> = {}): ConfiguredServer {
  return {
    name: 'mine',
    scope: 'user',
    commandLine: 'npx -y @me/thing',
    transport: 'stdio',
    envKeys: [],
    ...over,
  }
}

const NPX_HERE: McpBinaryReport = { binary: 'npx', found: true, path: '/opt/homebrew/bin/npx' }
const DOCKER_GONE: McpBinaryReport = { binary: 'docker', found: false, path: '' }

describe('which binary a hand-written server needs', () => {
  it('takes the first token through the same tokenizer the add path uses', () => {
    // `npx -y "@scope/thing" "/Users/me/My Folder"` is what people paste out of
    // a README, quotes and all, and a naive split on spaces gets the wrong
    // answer for the argument this app cares about least and the right one for
    // nothing.
    expect(customBinary(server({ commandLine: 'npx -y @me/thing' }))).toBe('npx')
    expect(customBinary(server({ commandLine: "'/Users/me/My Tools/serve' --port 3000" }))).toBe(
      '/Users/me/My Tools/serve',
    )
  })

  it('answers nothing at all for a server that starts nothing on this machine', () => {
    /*
     * An http or sse server is somewhere else. Probing this machine for a binary
     * would be measuring the wrong thing and then reporting it — and the row
     * would say "not found" about a server that works perfectly.
     */
    expect(customBinary(server({ transport: 'http', commandLine: 'https://example.com/mcp' }))).toBe('')
    expect(customBinary(server({ transport: 'sse', commandLine: 'https://example.com/sse' }))).toBe('')
  })

  it('makes no claim about a command it could not read', () => {
    // An unclosed quote is a configuration this app did not write. Answering
    // `''` means no claim; the alternative is a "not found" verdict about a
    // binary whose name was never successfully read.
    expect(customBinary(server({ commandLine: 'npx "unclosed' }))).toBe('')
  })

  it('asks for each binary once, however many servers use it', () => {
    // Six hand-written `npx` servers should cost one `which`, not six.
    const list = customBinaries([
      server({ name: 'a' }),
      server({ name: 'b', commandLine: 'npx -y other' }),
      server({ name: 'c', commandLine: 'docker run thing' }),
      server({ name: 'd', transport: 'http', commandLine: 'https://example.com' }),
    ])
    expect(list).toEqual(['docker', 'npx'])
  })

  it('maps a container command onto the docker runtime, so the Docker filter is right', () => {
    // The only thing that reads `runtime` on a custom row: `mcpNeeds` adds a
    // *Docker* need for it, and a hand-written `docker run …` needs Docker in
    // exactly the way a catalogue row does.
    expect(customRuntime('docker')).toBe('docker')
    expect(customRuntime('/usr/local/bin/podman')).toBe('docker')
    expect(customRuntime('uvx')).toBe('python')
    expect(customRuntime('python3')).toBe('python')
    expect(customRuntime('npx')).toBe('node')
    expect(customRuntime('/Users/me/serve')).toBe('node')
  })
})

describe('what a custom row says about the machine', () => {
  it('names the binary and where it was found', () => {
    expect(customRunsWords(server(), NPX_HERE)).toBe('npx on this machine — /opt/homebrew/bin/npx')
  })

  it('says the runtime is missing without turning the row into a warning', () => {
    const row = customRow(
      server({ commandLine: 'docker run thing' }),
      new Map([['docker', DOCKER_GONE]]),
    )
    /*
     * A catalogue row in this position gets `state: 'unavailable'` and no
     * Install, because installing it would write a line that can never work.
     * This one is the opposite case — the line is **already written** — so it
     * stays installed, keeps its Remove, and says the problem in a sentence.
     */
    expect(row.state).toBe('installed')
    expect(row.runtimeMissing).toBe(true)
    expect(row.blocked).toBe('')
    expect(row.caveat).toContain('docker is not on this machine')
    expect(row.caveat).toContain('nothing was removed')
  })

  it('claims nothing when nothing was looked for', () => {
    // A view built without the probe — an older caller, or a test — must not
    // report a binary missing on the strength of a probe nobody ran.
    const row = customRow(server(), new Map())
    expect(row.runtimeMissing).toBe(false)
    expect(row.caveat).toBe('')
    expect(row.runsWords).toContain('It was not looked for')
  })

  it('does not look for a binary for a server that is somewhere else', () => {
    const row = customRow(
      server({ transport: 'http', commandLine: 'https://example.com/mcp' }),
      new Map([['npx', NPX_HERE]]),
    )
    expect(row.runtimeMissing).toBe(false)
    expect(row.runsWords).toContain('An HTTP server somewhere else')
    expect(customCaveat(undefined)).toBe('')
  })
})

describe('what a custom row refuses to claim', () => {
  it('carries no homepage, package, licence or version', () => {
    /*
     * Inventing any of these would be this app describing a program it has never
     * read. The row draws nothing for an empty one — and rendering the store
     * with a custom row in it is what caught the `<a href="">` those empty
     * fields used to produce, which is a link to the page you are already on.
     */
    const row = customRow(server(), new Map([['npx', NPX_HERE]]))
    expect(row.homepage).toBe('')
    expect(row.registry).toBe('')
    expect(row.licence).toBe('')
    expect(row.version).toBe('')
    expect(row.inputs).toEqual([])
    expect(row.tags).toEqual([])
  })

  it('sits on a shelf the catalogue can never fill', () => {
    expect(customRow(server(), new Map()).category).toBe('your-own')
  })

  it('prices nothing, and borrows nobody else’s mark', () => {
    /*
     * The three fields a row of this store now has to carry, and a custom row is
     * the one row that cannot answer any of them.
     *
     * `cost` is `unknown` rather than `free`, and the difference is the whole
     * point of the field: every other row's price was read off a project's own
     * pricing page on a dated day, and nobody read this one's, because the
     * command may run a package off npm that is free forever or a proxy to a
     * service that bills by the token. `free` here would be this app pricing a
     * program it has never opened — which is exactly the failure the price field
     * was added to prevent.
     *
     * `costNote` is where a catalogue *explains* a price it established, and
     * there is nothing to explain about a measurement nobody took.
     *
     * `logo` is a key into a module whose every picture was fetched once from a
     * named project and recorded with the URL and hash it came from, so there is
     * no key for a program nobody published. `''` is what `StoreLogo` reads as
     * *draw the monogram*: this app's own letter on its own fill, honestly a
     * placeholder. Borrowing some other row's picture would be the store-row
     * version of a button that does nothing.
     */
    const row = customRow(server(), new Map([['npx', NPX_HERE]]))
    expect(row.cost).toBe('unknown')
    expect(row.costNote).toBe('')
    expect(row.logo).toBe('')
  })

  it('says the variables it carries by name and never by value', () => {
    const row = customRow(server({ envKeys: ['API_KEY', 'REGION'] }), new Map())
    expect(row.envKeys).toEqual(['API_KEY', 'REGION'])
    // The whole row, stringified. A value could only be here if something above
    // put one on the wire, and `configuredForStore` sends names.
    expect(JSON.stringify(row)).not.toContain('secret-value')
  })

  it('keeps two servers of one name in two scopes apart', () => {
    // The same name in `user` and in `local` is two servers in two files. One id
    // for both would collapse two rows into one and send an Edit at whichever
    // the map happened to keep.
    expect(customId(server({ scope: 'user' }))).not.toBe(customId(server({ scope: 'local' })))
    expect(isCustomId(customId(server()))).toBe(true)
    expect(isCustomId('filesystem')).toBe(false)
  })
})

describe('which configured servers become rows', () => {
  it('leaves out the ones a catalogue row already is', () => {
    const rows = customRows(
      [server({ name: 'mine' }), server({ name: 'filesystem' })],
      new Set(['user:filesystem']),
      [NPX_HERE],
    )
    expect(rows.map((row) => row.name)).toEqual(['mine'])
  })

  it('keeps a server that merely wears a catalogue name', () => {
    /*
     * This is the pair of rows a person needs. The catalogue's `github` row says
     * *a server called github is already configured and it is not this one*, and
     * this row is that server — with the command it really runs, and a Remove.
     * Claiming it would have hidden somebody's own server behind a name.
     */
    const rows = customRows([server({ name: 'github' })], new Set(), [NPX_HERE])
    expect(rows).toHaveLength(1)
    expect(rows[0]?.custom).toBe(true)
  })
})

describe('the store view, with both halves in it', () => {
  const base = {
    runtimes: [],
    environment: new Set<string>(),
    environmentSource: 'unavailable' as const,
    writer: { found: true, path: '/usr/bin/claude' },
    projectPath: null,
  }

  it('puts a hand-written server in the store it was added from', () => {
    /*
     * The defect this whole module exists for. *Add your own* wrote the server,
     * the list on the other tab showed it, and the store you added it from
     * carried on drawing the catalogue and nothing else — so there was nothing
     * to search, nothing to filter to, no row to read back what you typed, no
     * Edit, and the only Remove was on a different screen.
     */
    const view = buildStoreView({
      ...base,
      configured: [server({ name: 'my-notes', commandLine: 'npx -y @me/notes' })],
      binaries: [NPX_HERE],
    })
    const mine = view.rows.find((row) => row.name === 'my-notes')
    expect(mine?.custom).toBe(true)
    expect(mine?.state).toBe('installed')
    expect(mine?.command).toBe('npx -y @me/notes')
    // And the catalogue is still all there.
    expect(view.rows.filter((row) => !row.custom)).toHaveLength(MCP_CATALOGUE.length)
  })

  it('does not draw a second row for a catalogue server that is installed', () => {
    const entry = MCP_CATALOGUE[0]
    expect(entry).toBeDefined()
    const view = buildStoreView({
      ...base,
      runtimes: [
        { id: entry!.runtime, binary: 'npx', found: true, path: '/usr/bin/npx', needs: 'Node.js.' },
      ],
      configured: [server({ name: entry!.name, commandLine: `npx -y ${entry!.token}` })],
    })
    expect(view.rows.filter((row) => row.name === entry!.name)).toHaveLength(1)
    expect(view.rows.filter((row) => row.custom)).toHaveLength(0)
  })
})
