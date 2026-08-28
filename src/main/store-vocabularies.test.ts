import { describe, expect, it } from 'vitest'
import {
  HOOK_EVENTS,
  MANIFEST_AGENTS,
  MCP_RUNTIMES,
  RUNTIME_COMMAND,
  STORE_CATEGORIES,
} from '../shared/store-manifest'
import { HOOK_PROVIDERS } from './hooks'
import { MCP_CATEGORIES, RUNTIME_BINARY } from './mcp-catalogue'

/**
 * The restated vocabularies, held to the originals they were copied from.
 *
 * `src/shared/store-manifest.ts` writes out three closed lists that already
 * exist in `src/main` — the hook events, the MCP runtimes and their binaries —
 * because `src/shared/**` is compiled into the renderer too and may not import a
 * module that reaches `node:http`. That is the same trade `safeProfileId` in
 * `browser-extensions.ts` makes with `partitionFor`, and it comes with the same
 * obligation: a test that fails when the two drift.
 *
 * This test lives in `src/main/` and not beside the module it checks, because it
 * is the only side of the seam allowed to import both. A copy of this file under
 * `src/shared/` puts `hooks.ts` into the web project's program and produces
 * eleven TS6307 errors about files nobody changed.
 */

describe('the community grammar still agrees with the code that installs things', () => {
  it('names exactly the hook events the hook installer writes, for every agent', () => {
    for (const agent of MANIFEST_AGENTS) {
      expect(HOOK_EVENTS[agent], `${agent} events`).toEqual(HOOK_PROVIDERS[agent].events)
    }
  })

  it('covers every agent the hook installer knows about, so none is silently unpublishable', () => {
    expect([...MANIFEST_AGENTS].sort()).toEqual(Object.keys(HOOK_PROVIDERS).sort())
  })

  it('offers only runtimes the MCP store can probe this machine for', () => {
    for (const runtime of MCP_RUNTIMES) {
      expect(Object.keys(RUNTIME_BINARY), runtime).toContain(runtime)
      expect(RUNTIME_COMMAND[runtime]).toBe(RUNTIME_BINARY[runtime])
    }
  })

  it('leaves docker out, though the built-in catalogue still uses it', () => {
    expect(Object.keys(RUNTIME_BINARY)).toContain('docker')
    expect(MCP_RUNTIMES).not.toContain('docker')
  })

  it('files community rows on the same shelves the MCP store already draws', () => {
    expect([...STORE_CATEGORIES]).toEqual(MCP_CATEGORIES.map((shelf) => shelf.id))
  })
})
