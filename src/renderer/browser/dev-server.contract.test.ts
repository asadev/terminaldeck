import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * `DevServerPanel` renders whatever `dev:server:list` returns, and the two sides
 * of that channel are declared in different files.
 *
 * The same seam as `dev-ports.contract.test.ts` next door, and the same reason
 * for pinning it: main sent `{ port, process, guessed }`, the start page read
 * `{ port, command, likely }`, and *nothing failed* — every row simply rendered
 * as a bare number, which reads as a design choice rather than a bug. A
 * mismatch across an `unknown` bridge is invisible to the type checker.
 *
 * It matters more here than it did there, because more of these fields are
 * conditional. A renderer reading `state` where main writes `status` would draw
 * every project as an unknown status and quietly disappear the whole section —
 * a feature that is simply not on screen, with no error anywhere.
 *
 * Compared as source rather than by importing the type, because the renderer is
 * not allowed to import from `src/main`; `tsconfig.web.json` enforces that and it
 * is the right boundary. Reading the file keeps the check honest without
 * crossing it.
 */

const read = (...parts: string[]): string => readFileSync(join(__dirname, ...parts), 'utf8')

/** Field names declared on an `export interface <name>` block. */
function fieldsOf(source: string, name: string): string[] {
  const block = new RegExp(`export interface ${name} \\{([\\s\\S]*?)\\n\\}`).exec(source)?.[1] ?? ''
  return [...block.matchAll(/^\s{2}(\w+)\??:/gm)].map((match) => match[1]).sort()
}

const EXPECTED = [
  'command',
  'folder',
  'message',
  'note',
  'port',
  'script',
  'sessionId',
  'status',
  'url',
]

describe('the renderer reads the dev-server shape main actually sends', () => {
  const main = read('..', '..', 'main', 'dev-server.ts')
  const mainFields = fieldsOf(main, 'DevServerState')
  const rendererFields = fieldsOf(read('DevServerPanel.tsx'), 'DevServerView')

  it('main declares the fields this test was written against', () => {
    // If this fails, main changed its shape — which is allowed, but the panel,
    // the wire type in `remote/protocol.ts` and the expectation below all have
    // to change with it.
    expect(mainFields).toEqual(EXPECTED)
  })

  it('the renderer declares exactly the same fields', () => {
    expect(rendererFields).toEqual(mainFields)
  })

  it('the wire type carries the same fields as the desktop state', () => {
    // Three clients build against `DevServerReport`, and it is copied field by
    // field out of `DevServerState` in `server.ts`. A field added to one and not
    // the other is a field a phone silently never sees.
    const wire = fieldsOf(read('..', '..', 'main', 'remote', 'protocol.ts'), 'DevServerReport')
    expect(wire).toEqual(mainFields)
  })

  it('the five statuses are the same five on both sides', () => {
    // The renderer refuses to draw a status it does not know, so a status added
    // in main and not here becomes a row that silently disappears.
    const declared = /const DEV_SERVER_STATUSES = \[([^\]]*)\]/.exec(
      read('..', '..', 'main', 'remote', 'protocol.ts'),
    )?.[1]
    const known = /const KNOWN = new Set\(\[([^\]]*)\]\)/.exec(read('DevServerPanel.tsx'))?.[1]
    const names = (source: string | undefined): string[] =>
      [...(source ?? '').matchAll(/'([a-z-]+)'/g)].map((match) => match[1]).sort()
    expect(names(known)).toEqual(names(declared))
    expect(names(declared)).toEqual(['failed', 'idle', 'no-dev-script', 'ready', 'starting'])
  })

  it('the panel renders the fields it declares, rather than ones it invented', () => {
    // The symptom the port-list mismatch produced, pinned so it cannot come back
    // quietly here: the panel must actually read the conditional fields.
    const source = read('DevServerPanel.tsx')
    for (const field of ['command', 'note', 'message', 'port', 'url']) {
      expect(source).toContain(`row.${field}`)
    }
  })
})
