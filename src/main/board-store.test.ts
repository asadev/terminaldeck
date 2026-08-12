import { readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it, vi } from 'vitest'
import { boardFileName, boardFilePath, loadBoard, saveBoard } from './board-store'

/**
 * The store's whole job is to be boring and durable, so these tests are about
 * the failure modes rather than the happy path: identifying a project the same
 * way every time, and refusing anything that would put the app's memory or the
 * previous board at risk.
 *
 * Deliberately no import of the renderer's board model — the store treats a
 * board as opaque JSON, and `tsconfig.node` cannot see `src/renderer` anyway.
 */

const USER_DATA = join(tmpdir(), `terminaldeck-board-store-test-${process.pid}`)

vi.mock('electron', async () => {
  const { tmpdir: tmp } = await import('node:os')
  const { join: j } = await import('node:path')
  return { app: { getPath: () => j(tmp(), `terminaldeck-board-store-test-${process.pid}`) } }
})

afterAll(() => rmSync(USER_DATA, { recursive: true, force: true }))

const PROJECT = '/Users/asad/Projects/terminaldeck'

function board(cardTitle = 'A'): Record<string, unknown> {
  return {
    version: 1,
    projectPath: PROJECT,
    columns: [
      { id: 'todo', title: 'Todo', cardIds: ['a'] },
      { id: 'doing', title: 'Doing', cardIds: [] },
      { id: 'done', title: 'Done', cardIds: [] },
    ],
    cards: { a: { id: 'a', title: cardTitle, notes: '', tags: [], createdAt: 1, sessionId: null } },
  }
}

describe('boardFileName', () => {
  /**
   * Regression: the name used to be hashed from the raw string, so opening the
   * same folder with a trailing slash produced a second, empty board and made
   * it look like every card had been deleted.
   */
  it('gives a project one file however its path is spelled', () => {
    const canonical = boardFileName(PROJECT)
    expect(boardFileName(`${PROJECT}/`)).toBe(canonical)
    expect(boardFileName(`${PROJECT}/.`)).toBe(canonical)
    expect(boardFileName('/Users/asad/Projects/../Projects/terminaldeck')).toBe(canonical)
    expect(boardFileName('/Users/asad//Projects//terminaldeck')).toBe(canonical)
  })

  it('still separates same-named folders in different trees', () => {
    expect(boardFileName('/one/web')).not.toBe(boardFileName('/two/web'))
  })

  it('never lets a project name escape the boards directory', () => {
    for (const path of ['/Users/asad/..', '/a/b/../..', '/', '/tmp/..%2F..%2Fetc']) {
      const name = boardFileName(path)
      expect(name).not.toContain('/')
      expect(name).toMatch(/^[a-zA-Z0-9._-]+-[0-9a-f]{10}\.json$/)
      expect(boardFilePath(path)).toBe(join(USER_DATA, 'boards', name))
    }
  })

  it('keeps a readable prefix for a normal project', () => {
    expect(boardFileName(PROJECT).startsWith('terminaldeck-')).toBe(true)
  })
})

describe('saveBoard', () => {
  it('round-trips a board unchanged', () => {
    saveBoard(PROJECT, board())
    expect(loadBoard(PROJECT)).toEqual(board())
  })

  it('stamps the caller path over one carried in the payload', () => {
    saveBoard(PROJECT, { ...board(), projectPath: '/somewhere/else' })
    expect((loadBoard(PROJECT) as { projectPath: string }).projectPath).toBe(PROJECT)
  })

  /**
   * Regression: the cap was `json.length`, which counts UTF-16 units. Three
   * byte characters are one unit each, so a board in Chinese or Arabic could
   * be three times over a cap that exists to bound what gets read back.
   */
  it('measures the size cap in bytes, not UTF-16 units', () => {
    const huge = { ...board(), cards: { a: { title: '中'.repeat(1_500_000) } } }
    const json = JSON.stringify(huge)
    expect(json.length).toBeLessThan(4 * 1024 * 1024)
    expect(Buffer.byteLength(json, 'utf8')).toBeGreaterThan(4 * 1024 * 1024)
    expect(() => saveBoard(PROJECT, huge)).toThrow(/too large/)
  })

  it('leaves the previous board intact when it rejects a payload', () => {
    saveBoard(PROJECT, board('keep me'))
    expect(() => saveBoard(PROJECT, { columns: [], cards: { a: { t: '中'.repeat(2_000_000) } } }))
      .toThrow(/too large/)
    expect((loadBoard(PROJECT) as { cards: { a: { title: string } } }).cards.a.title).toBe('keep me')
  })

  it('refuses a payload that is not board-shaped', () => {
    expect(() => saveBoard(PROJECT, null)).toThrow(/not a board/)
    expect(() => saveBoard(PROJECT, 'a board, honest')).toThrow(/not a board/)
    expect(() => saveBoard(PROJECT, { columns: {}, cards: {} })).toThrow(/not a board/)
    expect(() => saveBoard(PROJECT, { columns: [], cards: [] })).toThrow(/not a board/)
  })

  it('demands an absolute project path', () => {
    expect(() => saveBoard('relative/path', board())).toThrow(/absolute/)
    expect(() => loadBoard('relative/path')).toThrow(/absolute/)
  })

  it('leaves no temp file behind', () => {
    const project = '/Users/asad/Projects/tidy'
    saveBoard(project, board())
    expect(readdirSync(join(USER_DATA, 'boards')).filter((f) => f.endsWith('.tmp'))).toEqual([])
  })
})

describe('loadBoard', () => {
  it('returns null for a board that was never saved', () => {
    expect(loadBoard('/Users/asad/Projects/never-opened')).toBeNull()
  })

  it('returns null for a truncated file rather than throwing', () => {
    const project = '/Users/asad/Projects/truncated'
    saveBoard(project, board())
    writeFileSync(boardFilePath(project), '{"columns":[],"car', 'utf8')
    expect(loadBoard(project)).toBeNull()
  })

  /**
   * Regression: only the write path was capped, so any file that arrived by
   * another route — hand-edited, restored from a backup, written by an older
   * build — was read into memory whole and then parsed into something several
   * times larger again.
   */
  it('ignores an oversized file instead of reading it into memory', () => {
    const project = '/Users/asad/Projects/oversized'
    saveBoard(project, board())
    // Valid JSON on purpose: only the size check can be what rejects this.
    writeFileSync(
      boardFilePath(project),
      `{"columns":[],"cards":{},"pad":"${'x'.repeat(5 * 1024 * 1024)}"}`,
      'utf8',
    )
    expect(loadBoard(project)).toBeNull()
  })

  it('accepts a large file that is still under the cap', () => {
    const project = '/Users/asad/Projects/big-but-fine'
    const big = { ...board(), pad: 'x'.repeat(1024 * 1024) }
    saveBoard(project, big)
    expect((loadBoard(project) as { pad: string }).pad.length).toBe(1024 * 1024)
  })
})
