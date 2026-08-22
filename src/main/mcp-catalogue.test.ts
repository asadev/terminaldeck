import { describe, expect, it } from 'vitest'
import {
  catalogueEntry,
  environmentKeys,
  MCP_CATALOGUE,
  MCP_CATEGORIES,
  requiredRuntimes,
  RUNTIME_BINARY,
  RUNTIME_NEEDS,
} from './mcp-catalogue'

/**
 * The catalogue's shape, held to what its own header promises.
 *
 * None of this checks that a server *works* — nothing in this repository can,
 * because the artifact is fetched from a registry at spawn time and run by the
 * agent rather than by this app, and `mcp-catalogue.ts` says so outright. What
 * these check is the class of mistake that is invisible on the page and fatal at
 * install time: a token that does not identify its own row, a placeholder
 * nothing fills, a field nothing places.
 *
 * Every one of them has a failure it was written for.
 */

const PLACEHOLDER = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g

describe('the MCP catalogue', () => {
  it('has a unique id and a unique server name for every row', () => {
    // The name is the key in another application's config file. Two rows with
    // one name is two rows racing to own it, and the loser silently reads as
    // "installed" forever because the other one is wearing its name.
    expect(new Set(MCP_CATALOGUE.map((entry) => entry.id)).size).toBe(MCP_CATALOGUE.length)
    expect(new Set(MCP_CATALOGUE.map((entry) => entry.name)).size).toBe(MCP_CATALOGUE.length)
  })

  it('names every row with something the CLI will accept as a positional', () => {
    // `mcp-add.ts` refuses a name that could be read as a flag by the CLI's own
    // parser. A catalogue row that cannot be added is a button that always
    // fails, so the same rule is enforced here rather than discovered there.
    for (const entry of MCP_CATALOGUE) {
      expect(entry.name, entry.id).toMatch(/^[A-Za-z0-9][A-Za-z0-9._-]*$/)
    }
  })

  it('gives every row a token that actually appears in its own command', () => {
    /*
     * This is the one that catches a typo nothing else would.
     *
     * The token is how a row knows it is installed. A token with a character
     * wrong matches no configured server, so the row reports itself available
     * forever — Install writes a duplicate name, the CLI refuses it, and the
     * store looks broken while the configuration is perfectly fine.
     */
    for (const entry of MCP_CATALOGUE) {
      expect(entry.command, entry.id).toContain(entry.token)
    }
  })

  it('gives every row a token no other row would match', () => {
    // `tavily-mcp` and `firecrawl-mcp` are one careless shortening apart. If one
    // row's token appears in another's command, the two rows report each other
    // installed.
    for (const entry of MCP_CATALOGUE) {
      for (const other of MCP_CATALOGUE) {
        if (other.id === entry.id) continue
        expect(other.command, `${entry.id} token in ${other.id}`).not.toContain(entry.token)
      }
    }
  })

  it('fills every placeholder from an input, and places every arg input', () => {
    /*
     * Both directions, because they fail differently.
     *
     * A placeholder with no input is a `${ROOT}` that survives into the config
     * file — a filesystem server rooted at a literal dollar-brace, which starts,
     * answers, and reads nothing. `buildInstall` throws on that, so the symptom
     * would be an Install that always refuses.
     *
     * An `arg` input with no placeholder is a field somebody fills in and which
     * then goes nowhere at all — the same silent drop, from the other end.
     */
    for (const entry of MCP_CATALOGUE) {
      const placeholders = [...entry.command.matchAll(PLACEHOLDER)].map((match) => match[1])
      const argKeys = entry.inputs.filter((input) => input.into === 'arg').map((input) => input.key)
      expect([...placeholders].sort(), entry.id).toEqual([...argKeys].sort())
    }
  })

  it('names every environment input with a shell identifier', () => {
    // It reaches a command line as `KEY=value`. Anything else is not a variable
    // and the CLI would take it as a malformed pair.
    for (const entry of MCP_CATALOGUE) {
      for (const input of entry.inputs) {
        if (input.into !== 'env') continue
        expect(input.key, `${entry.id}.${input.key}`).toMatch(/^[A-Za-z_][A-Za-z0-9_]*$/)
      }
    }
  })

  it('gives every row a source and a package address that can be opened', () => {
    // Both are rendered as links. *"most probably most of the open sourced one"*
    // is a claim a person is entitled to check, and a row whose Source is a
    // sentence rather than an address cannot be checked.
    for (const entry of MCP_CATALOGUE) {
      expect(entry.homepage, entry.id).toMatch(/^https:\/\//)
      expect(entry.registry, entry.id).toMatch(/^https:\/\//)
      expect(entry.licence.trim(), entry.id).not.toBe('')
      expect(entry.summary.trim(), entry.id).not.toBe('')
      expect(entry.version.trim(), entry.id).not.toBe('')
    }
  })

  it('has a runtime word and an install sentence for every runtime it uses', () => {
    for (const runtime of requiredRuntimes()) {
      expect(RUNTIME_BINARY[runtime]).toBeTruthy()
      expect(RUNTIME_NEEDS[runtime]).toBeTruthy()
    }
  })

  it('sits on exactly one shelf, and one the store draws', () => {
    /*
     * One, never three. `browser-extension-catalogue.ts` gives the reason and it
     * holds here: *"a row that appeared under three headings would make a
     * catalogue of twenty-four look like a catalogue of forty, and a store
     * overstating its own size is the first thing that makes the rest of it
     * unbelievable."*
     */
    const known = new Set(MCP_CATEGORIES.map((category) => category.id))
    for (const entry of MCP_CATALOGUE) {
      expect(known.has(entry.category), `${entry.name} is in ${entry.category}`).toBe(true)
    }
  })

  it('leaves no shelf empty, so every heading the store can draw has something under it', () => {
    // A heading with nothing under it is the section-shaped version of a chip
    // that filters to nothing. Every one of the nine is used.
    const used = new Set(MCP_CATALOGUE.map((entry) => entry.category))
    for (const category of MCP_CATEGORIES) {
      expect(used.has(category.id), `nothing is in ${category.id}`).toBe(true)
    }
  })

  it('carries tags, in the words somebody would actually type', () => {
    for (const entry of MCP_CATALOGUE) {
      expect(entry.tags.length, `${entry.name} has no tags`).toBeGreaterThan(2)
      for (const tag of entry.tags) {
        expect(tag, `${entry.name}: ${tag}`).toBe(tag.toLowerCase())
        expect(tag.trim(), `${entry.name}: ${tag}`).toBe(tag)
      }
      expect(new Set(entry.tags).size, `${entry.name} repeats a tag`).toBe(entry.tags.length)
    }
  })

  it('answers the searches people arrive with rather than the names it happens to use', () => {
    /*
     * A server is written into the configuration under a short name, because
     * that name is typed — so the names are `postgres`, `fetch`, `git`. None of
     * those is what somebody looking for one types, and the summaries do not
     * rescue it: `brave-search`'s says "Web and local search through the Brave
     * Search API", so *web search* finds it, and `postgres`'s says nothing about
     * *sql* at all.
     */
    const finds = (word: string): string[] =>
      MCP_CATALOGUE.filter((entry) =>
        [entry.name, entry.summary, ...entry.tags].join(' ').toLowerCase().includes(word),
      ).map((entry) => entry.id)

    expect(finds('sql')).toEqual(expect.arrayContaining(['postgres', 'sqlite']))
    expect(finds('screenshot')).toEqual(expect.arrayContaining(['playwright', 'puppeteer']))
    expect(finds('documentation')).toContain('context7')
    expect(finds('folder')).toContain('filesystem')
    expect(finds('pull requests')).toContain('github')
  })

  it('says what an archived row is, on the row', () => {
    /*
     * The store keeps rows nobody is maintaining, for the same reason the
     * browser store keeps uBlock Origin's old refusal on screen: *"it is not in
     * the list"* and *"nobody is fixing it"* are different answers, and the
     * second is the useful one. What is not allowed is keeping it and staying
     * quiet, so an archived row without a caveat fails here.
     */
    for (const entry of MCP_CATALOGUE) {
      if (entry.origin !== 'reference-archived') continue
      expect(entry.caveat, entry.id).toBeTruthy()
      expect(entry.caveat ?? '', entry.id).toContain('archived')
    }
  })

  it('offers both halves of what was asked for', () => {
    // *"most probably most of the open sourced one"* — the reference servers and
    // the ones everybody actually pastes out of a README. A catalogue that
    // drifted to one or the other is a catalogue that answers half the ask.
    const origins = new Set(MCP_CATALOGUE.map((entry) => entry.origin))
    expect(origins.has('reference')).toBe(true)
    expect(origins.has('third-party')).toBe(true)
    // And more than one way of being run, because the honest capability check
    // has nothing to say on a machine where every row needs the same binary.
    expect(requiredRuntimes().length).toBeGreaterThan(1)
  })

  it('collects only environment keys, never argument placeholders', () => {
    // The set that gets intersected with the login shell. An `arg` key in here
    // would produce a "already in your shell" offer on a field that would ignore
    // it — a control that does nothing, which is the one thing this store may
    // not have.
    const keys = new Set(environmentKeys())
    for (const entry of MCP_CATALOGUE) {
      for (const input of entry.inputs) {
        if (input.into === 'arg') expect(keys.has(input.key), input.key).toBe(false)
        else expect(keys.has(input.key), input.key).toBe(true)
      }
    }
  })

  it('finds a row by id and refuses anything that is not one', () => {
    expect(catalogueEntry('filesystem')?.name).toBe('filesystem')
    expect(catalogueEntry('not-a-row')).toBeNull()
    expect(catalogueEntry(null)).toBeNull()
    expect(catalogueEntry(7)).toBeNull()
  })
})
