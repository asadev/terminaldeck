import { tokenizeCommand, type McpAddTransport } from './mcp-add'
import type { ConfiguredServer, McpBinaryReport, McpStoreRow } from './mcp-store'
import type { McpRuntime } from './mcp-catalogue'

/**
 * The servers somebody added themselves, as rows of the same store.
 *
 * ## Why this exists
 *
 *   > *"should allow custom tools and store"*
 *
 * The MCP store had an **Add your own** button, and pressing it worked — and
 * then the thing you added was not in the store. It went into the configuration,
 * the list on the MCP page showed it, and the store you added it from carried on
 * displaying the catalogue's rows, none of which was yours. So *your own* was an
 * escape hatch out of the store rather than a part of it: nothing to search,
 * nothing to filter to, no row to read back what you had typed, no Edit, and the
 * only Remove was on a different screen.
 *
 * A row here fixes that with the one thing that makes a store a store: your
 * server is a row, on the same shelf model, under the same search box, with the
 * same controls. `Added by you` is a value of the *source* filter next to
 * *Official reference* and *Community*, which is where a person looks for it.
 *
 * ## What a custom row is allowed to claim, which is very little
 *
 * The catalogue rows carry a homepage, a registry entry, a licence, a version, a
 * declared list of inputs, a price, a mark, and a runtime out of a fixed set of
 * three. A server somebody typed has **none** of that, and inventing any of it
 * would be this app describing a program it has never read. So those fields are
 * empty and the row draws nothing for them.
 *
 * The two things this app can honestly say are said:
 *
 *  - **What is actually configured** — the command, quoted so it reads back as
 *    what is in the file, and the *names* of the environment variables it
 *    carries. Never their values: `configuredForStore` never puts one on the
 *    wire, and this module is downstream of that.
 *  - **Whether the thing that starts it is on this machine.** That is the same
 *    `which` every other claim in this store is made with, applied to whatever
 *    binary the command actually names — `docker`, `uvx`, `bun`, or an absolute
 *    path to something in somebody's home directory. It is the one measurement
 *    that is as available for a hand-written server as for a catalogue one, and
 *    a store that measured it for forty rows and shrugged at the forty-first
 *    would be worse where it matters most.
 *
 * ## Why a missing runtime does not make the row buttonless
 *
 * A catalogue row whose runtime is missing gets `state: 'unavailable'` and no
 * Install, because installing it would write a line that could never work. A
 * *custom* row in the same position is the opposite case: the line is **already
 * written**, and this is exactly the moment somebody wants the Remove. So it
 * stays `installed`, keeps every control, and the missing binary is a sentence
 * on the row rather than the absence of one.
 */

/* ------------------------------------------------------------- the binary -- */

/**
 * Which binary starts this server, or `''` when nothing local does.
 *
 * The first token of the command line, taken through the same tokenizer the add
 * path uses — so `npx -y "@scope/thing"` and `'/Users/me/My Tools/serve'` are
 * both read the way the CLI will read them, quotes and all. An `http` or `sse`
 * server has no local binary at all and answers `''`, because probing the
 * machine for one would be measuring the wrong thing and then reporting it.
 */
export function customBinary(server: ConfiguredServer): string {
  if ((server.transport ?? 'stdio') !== 'stdio') return ''
  let argv: string[]
  try {
    argv = tokenizeCommand(server.commandLine)
  } catch {
    // An unclosed quote is a configuration this app did not write and cannot
    // parse. Answering `''` means the row makes no claim about the machine,
    // which is the honest outcome — the alternative is a "not found" verdict
    // about a binary whose name was never successfully read.
    return ''
  }
  return argv[0] ?? ''
}

/**
 * Every binary the custom half of a configuration needs looked up, deduplicated.
 *
 * Exported so the probe happens **once** for the whole page rather than per row.
 * Somebody with six hand-written `npx` servers should cost one `which`, not six.
 */
export function customBinaries(servers: readonly ConfiguredServer[]): string[] {
  const wanted = new Set<string>()
  for (const server of servers) {
    const binary = customBinary(server)
    if (binary !== '') wanted.add(binary)
  }
  return [...wanted].sort()
}

/**
 * The closest of the catalogue's three runtimes, for the one thing that reads it.
 *
 * `mcpNeeds` in the renderer's bridge adds a *Docker* need when a row's runtime
 * is `docker`, and a hand-written `docker run …` server needs Docker in exactly
 * the same way a catalogue one does — so that filter has to be right for it.
 *
 * Nothing else reads this field on a custom row: `runsWords` is what the row
 * prints, precisely because "npx — fetched from npm the first time it runs" is
 * true of most catalogue rows and a straight lie under `/usr/local/bin/serve`.
 * `node` is the fallback rather than a fourth value for the same reason the
 * category was widened and the origin was not — see `McpStoreRow.custom`.
 */
export function customRuntime(binary: string): McpRuntime {
  const name = binary.replace(/\\/g, '/').split('/').pop() ?? binary
  const bare = name.replace(/\.(exe|cmd|bat)$/i, '').toLowerCase()
  if (bare === 'docker' || bare === 'podman' || bare === 'nerdctl') return 'docker'
  if (/^(uvx?|python3?|pipx|pixi|poetry|conda)$/.test(bare)) return 'python'
  return 'node'
}

/* -------------------------------------------------------------- the words -- */

/**
 * How this one runs, in a sentence, with the measurement in it.
 *
 * Written here rather than in the row's JSX because it is three different true
 * sentences and which one is true is decided by a probe. A component picking
 * between them is a component nothing can test without a machine.
 */
export function customRunsWords(
  server: ConfiguredServer,
  report: McpBinaryReport | undefined,
): string {
  const transport = server.transport ?? 'stdio'
  if (transport !== 'stdio') {
    return transport === 'http'
      ? 'An HTTP server somewhere else. Nothing starts on this machine, so there is nothing here to look for.'
      : 'An SSE server somewhere else. Nothing starts on this machine, so there is nothing here to look for.'
  }
  const binary = customBinary(server)
  if (binary === '') return 'A command on this machine. This app could not read which binary it starts.'
  if (report === undefined) return `${binary} on this machine. It was not looked for.`
  return report.found
    ? `${binary} on this machine — ${report.path}`
    : `${binary} on this machine, and it is not there.`
}

/** The sentence a row prints when the thing that starts it is missing, or `''`. */
export function customCaveat(report: McpBinaryReport | undefined): string {
  if (report === undefined || report.found) return ''
  return (
    `${report.binary} is not on this machine, so this server cannot start here. It is still in ` +
    'your configuration — nothing was removed — and whatever runs it will fail until that binary ' +
    'is installed or the command is changed.'
  )
}

/* --------------------------------------------------------------- the rows -- */

/**
 * The id a custom row wears.
 *
 * Scope and name together, because those two are what addresses a server: the
 * same name can legitimately exist in `user` and in `local`, they are different
 * servers in different files, and one id for both would collapse two rows into
 * one and send an Edit at whichever the map happened to keep.
 *
 * The `own:` prefix keeps it out of the catalogue's id space for good. Nothing
 * in `MCP_CATALOGUE` contains a colon, and `resolveInstall` answers *this build
 * has no such server* for an id it does not know — so a custom id that somehow
 * reached the install channel is refused rather than matched.
 */
export function customId(server: ConfiguredServer): string {
  return `own:${server.scope}:${server.name}`
}

/** Is this an id this module minted? Used to route Edit and Remove. */
export function isCustomId(id: string): boolean {
  return id.startsWith('own:')
}

/**
 * One configured-but-uncatalogued server, as a store row.
 *
 * `state` is always `installed` — that is what being in the configuration means
 * — and `blocked` is always `''`, because `blocked` is *why this row has no
 * Install* and this row is not offering one. The runtime problem, when there is
 * one, goes in `caveat`, which the row prints whatever its state.
 */
export function customRow(
  server: ConfiguredServer,
  binaries: ReadonlyMap<string, McpBinaryReport>,
): McpStoreRow {
  const transport: McpAddTransport = server.transport ?? 'stdio'
  const binary = customBinary(server)
  const report = binary === '' ? undefined : binaries.get(binary)
  const envKeys = [...(server.envKeys ?? [])]
  return {
    id: customId(server),
    name: server.name,
    summary:
      'You added this one. It is not in this app’s catalogue, nothing here was measured about ' +
      'what it does, and no fingerprint was checked against it — it is configured because you ' +
      'said so.',
    category: 'your-own',
    /*
     * Its own name and the shelf's name are the only things anybody could search
     * for. Inventing tags — reading the package name out of the command and
     * calling them keywords — would make this app describe a program it has
     * never read, which is the whole thing a custom row is not allowed to do.
     */
    tags: [],
    homepage: '',
    registry: '',
    licence: '',
    version: '',
    runtime: customRuntime(binary),
    runtimeBinary: binary,
    /*
     * `third-party` is the nearest true value of a union that is about what a
     * *catalogue* established, and nothing reads it on this row: `custom` is
     * what the source filter and the chip go by. See `McpStoreRow.custom`.
     */
    origin: 'third-party',
    /*
     * The one price this app is entitled to report about somebody else's server,
     * which is that it has not measured one.
     *
     * Every other row's `cost` was read off a project's own pricing page on a
     * dated day. Nobody read this one's, because nobody knows what it is: the
     * command may run a package off npm that is free forever, or a proxy to a
     * service that bills by the token. `free` would be this app pricing a
     * program it has never opened, and it would be the exact failure the price
     * field was added to prevent — see `store/storefront.ts`, which argues the
     * same five values for both stores and already carries `unknown` on the
     * browser half for exactly this row.
     */
    cost: 'unknown',
    /*
     * And no sentence under it. `costNote` is where a catalogue explains a price
     * it established — *"free to 1,000 searches a month, then billed"* — and
     * there is nothing to explain about a measurement that was not taken. The
     * chip reading *Not known* is the whole of what is known.
     */
    costNote: '',
    /*
     * No mark. `logo` is a key into `renderer/store/logo-data.ts`, whose pictures
     * were each fetched once from a named project and recorded with the URL and
     * the hash they came from — so there is no key for a program nobody
     * published. `''` is what `StoreLogo` reads as *draw the monogram*: this
     * app's own first letter on one of its own fills, which is honestly a
     * placeholder and reads as one. Borrowing some other row's picture for a
     * command somebody typed would be the store-row version of a button that
     * does nothing.
     */
    logo: '',
    command: server.commandLine,
    inputs: [],
    state: 'installed',
    scope: server.scope,
    custom: true,
    transport,
    envKeys,
    runsWords: customRunsWords(server, report),
    runtimeMissing: report !== undefined && !report.found,
    taken: '',
    blocked: '',
    caveat: customCaveat(report),
  }
}

/**
 * Every configured server that no catalogue row claims, as rows.
 *
 * `claimed` is the set of names `buildStoreView` matched to a catalogue entry —
 * matched, meaning the configured command actually contains that entry's package
 * token. A server merely *wearing* a catalogue name without being it is *not*
 * claimed and does appear here, which is right and is the pair of rows a person
 * needs: the catalogue row says "a server called github is configured and it is
 * not this one", and this row is that server, with the command it really runs
 * and a Remove.
 */
export function customRows(
  configured: readonly ConfiguredServer[],
  claimed: ReadonlySet<string>,
  binaries: readonly McpBinaryReport[],
): McpStoreRow[] {
  const byBinary = new Map(binaries.map((report) => [report.binary, report]))
  return configured
    .filter((server) => !claimed.has(`${server.scope}:${server.name}`))
    .map((server) => customRow(server, byBinary))
}
