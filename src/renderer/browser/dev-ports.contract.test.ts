import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The browser start page renders whatever `dev:ports` returns, and the two
 * sides of that channel are declared in different files.
 *
 * They disagreed on first write: main sent `{ port, process, guessed }`, the
 * start page read `{ port, command, likely }`. Nothing failed — every row
 * rendered as a bare port number with no process name beside it, which reads as
 * a design choice rather than a bug. That is the problem with a seam crossed by
 * `unknown`: the type checker cannot see across it, so the mismatch is
 * invisible until someone looks at the screen.
 *
 * Compared as source rather than by importing the type, because the renderer is
 * not allowed to import from `src/main` — `tsconfig.web.json` enforces that,
 * and it is the right boundary. Reading the file keeps the check honest without
 * crossing it.
 */

const read = (...parts: string[]): string => readFileSync(join(__dirname, ...parts), 'utf8')

/** Field names declared on an `export interface DevPort` block. */
function fieldsOf(source: string): string[] {
  const block = /export interface DevPort \{([\s\S]*?)\n\}/.exec(source)?.[1] ?? ''
  return [...block.matchAll(/^\s{2}(\w+)\??:/gm)].map((m) => m[1]).sort()
}

describe('the renderer reads the shape main actually sends', () => {
  const mainFields = fieldsOf(read('..', '..', 'main', 'dev-ports.ts'))
  const rendererFields = fieldsOf(read('StartPage.tsx'))

  it('main declares the fields this test was written against', () => {
    // If this fails, main changed its shape — which is allowed, but the start
    // page and the expectation below have to change with it.
    expect(mainFields).toEqual(['guessed', 'port', 'process'])
  })

  it('the renderer declares exactly the same fields', () => {
    expect(rendererFields).toEqual(mainFields)
  })

  it('the start page renders the process name, not just the port', () => {
    // The symptom the mismatch produced, pinned so it cannot come back quietly.
    const src = read('StartPage.tsx')
    expect(src).toContain('p.process')
    expect(src).toContain('p.guessed')
    expect(src).not.toMatch(/p\.(command|likely)\b/)
  })
})
