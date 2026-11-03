/**
 * Source-text guards on the protocol client that need to read a file off disk.
 *
 * ## Why this lives in `pwa/tests/` and not beside `protocol-client.ts`
 *
 * The co-located `pwa/src/protocol-client.test.ts` is a browser unit test: it is
 * compiled under `pwa/tsconfig.json`, whose `"types": []` is the latch that keeps
 * a Node built-in *nobody planned for* out of this bundle. A test that reads its
 * own source with `node:fs` needs Node's types, so it belongs on the node side of
 * the split — `pwa/tsconfig.node.json` (`"types": ["node"]`, `include:
 * ["tests/**\/*"]`), next to `no-cost.test.ts`, `layout.test.ts` and the other
 * grep-the-source guards that already read this exact file. Keeping the source
 * read here lets the browser unit test stay clean of `node:*` while the guard
 * itself keeps running under vitest unchanged.
 */

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const source = (rel: string): string =>
  readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8')

describe('what the protocol client never asks for', () => {
  it('never asks for a byte stream, which is the half that still holds', () => {
    /*
     * This used to assert that the client could not *read* `net.*`. It can now,
     * and not because anybody taught it to: `decodeServerMessage` delegates to
     * `parseServerFrame`, and that reader gained the byte-stream frames when the
     * desktop learned to reach a port on another machine. One reader, shared on
     * purpose — the alternative is two readers of one wire, which is the drift
     * the shared-parser tests exist to catch.
     *
     * So the claim moves from what it can parse to what it can ask for, which is
     * the part that was ever really true. `net.*` only exists inside a stream
     * begun by a `net.open`, and a browser tab has no socket to serve bytes
     * into. This client sends no such frame, so it is never in that conversation
     * — and being able to read a sentence nobody will say to you costs nothing.
     *
     * Asserted against the source rather than by sending one, because the point
     * is that no code path exists at all, and a runtime test can only show that
     * the path was not taken today.
     */
    const code = source('../src/protocol-client.ts')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/\/\/.*$/gm, '')
    expect(code, 'this client now sends net.open — it has no socket to serve').not.toContain(
      'net.open',
    )
  })
})
