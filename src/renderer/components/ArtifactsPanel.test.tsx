import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  ArtifactRow,
  ArtifactsPanel,
  ChangeBody,
  changeSummary,
  diffLines,
  directoryOf,
  MAX_DIFF_LINES,
  SCAN_FRESH_MS,
  scanOutcome,
  splitLines,
  summarize,
  type Artifact,
  type ArtifactChange,
  type ArtifactList,
  type ArtifactsBridge,
} from './ArtifactsPanel'

/**
 * There is no DOM environment in this project's test setup, so these render to
 * static markup. That covers the diff alignment, the honesty of the summary
 * line and the accessible structure — the parts most likely to rot. The async
 * load is state, and is exercised through `src/main/artifacts.test.ts` against
 * real transcript fixtures.
 */

const NOW = Date.parse('2026-08-16T12:00:00.000Z')

function artifact(overrides: Partial<Artifact> & { relPath: string }): Artifact {
  const relPath = overrides.relPath
  return {
    name: relPath.slice(relPath.lastIndexOf('/') + 1),
    firstAt: NOW - 3600_000,
    lastAt: NOW - 600_000,
    writes: 1,
    edits: 0,
    lastChars: 40,
    lastTool: 'Write',
    sessionIds: ['sess-1'],
    onDisk: { bytes: 1024, modifiedAt: NOW - 600_000 },
    ...overrides,
  }
}

function list(overrides: Partial<ArtifactList> = {}): ArtifactList {
  return {
    root: '/p',
    scope: 'project',
    artifacts: [],
    sessions: [],
    sessionsScanned: 3,
    outsideProject: 0,
    truncated: false,
    cancelled: false,
    tookMs: 12,
    ...overrides,
  }
}

/* ------------------------------------------------------------------- diff -- */

describe('splitLines', () => {
  it('lets a trailing newline terminate the last line', () => {
    expect(splitLines('a\nb\n')).toEqual(['a', 'b'])
    expect(splitLines('a\nb')).toEqual(['a', 'b'])
    expect(splitLines('')).toEqual([])
  })
})

describe('diffLines', () => {
  it('keeps every line of both sides, in order', () => {
    // The safety property. A diff that silently drops a line is worse than no
    // diff at all, because it looks like the agent never wrote it.
    const before = 'one\ntwo\nthree\n'
    const after = 'one\nTWO\nthree\nfour\n'
    const { lines } = diffLines(before, after)

    expect(lines.filter((line) => line.kind !== 'add').map((line) => line.text)).toEqual([
      'one',
      'two',
      'three',
    ])
    expect(lines.filter((line) => line.kind !== 'del').map((line) => line.text)).toEqual([
      'one',
      'TWO',
      'three',
      'four',
    ])
  })

  it('marks only what changed', () => {
    const { lines } = diffLines('a\nb\nc\n', 'a\nB\nc\n')
    expect(lines).toEqual([
      { kind: 'same', text: 'a' },
      { kind: 'del', text: 'b' },
      { kind: 'add', text: 'B' },
      { kind: 'same', text: 'c' },
    ])
  })

  it('handles a pure insertion without rewriting its neighbours', () => {
    const { lines } = diffLines('a\nc\n', 'a\nb\nc\n')
    expect(lines).toEqual([
      { kind: 'same', text: 'a' },
      { kind: 'add', text: 'b' },
      { kind: 'same', text: 'c' },
    ])
  })

  it('handles a one-line edit, which is what most Edits are', () => {
    const { lines } = diffLines('const a = 0', 'const a = 1')
    expect(lines).toEqual([
      { kind: 'del', text: 'const a = 0' },
      { kind: 'add', text: 'const a = 1' },
    ])
  })

  it('falls back to a block replacement rather than a quadratic stall', () => {
    // O(n×m) on two 10,000-line sides is 100 million cells in the render path.
    const huge = Array.from({ length: MAX_DIFF_LINES + 10 }, (_, i) => `line ${i}`).join('\n')
    const { lines, truncated } = diffLines(huge, huge.replace('line 0', 'line zero'))
    expect(truncated).toBe(true)
    expect(lines.some((line) => line.kind === 'same')).toBe(false)
  })
})

/* ---------------------------------------------------------------- summary -- */

describe('summarize', () => {
  it('says nothing was produced rather than showing an empty list', () => {
    expect(summarize(list(), 0)).toBe('Nothing written or edited in 3 sessions.')
  })

  it('distinguishes "no sessions" from "sessions that produced nothing"', () => {
    expect(summarize(list({ sessionsScanned: 0 }), 0)).toBe(
      'No sessions recorded for this project yet.',
    )
  })

  it('counts what is shown against what was found', () => {
    const found = list({
      artifacts: [artifact({ relPath: 'a.ts' }), artifact({ relPath: 'b.ts' })],
      sessions: [{ sessionId: 's', at: NOW, files: 2 }],
    })
    expect(summarize(found, 2)).toBe('2 files · 1 session')
    expect(summarize(found, 1)).toBe('1 of 2 files · 1 session')
  })

  it('admits when a cap stopped the scan', () => {
    const found = list({
      artifacts: [artifact({ relPath: 'a.ts' })],
      sessions: [{ sessionId: 's', at: NOW, files: 1 }],
      truncated: true,
    })
    expect(summarize(found, 1)).toContain('older work not read')
  })
})

describe('changeSummary', () => {
  it('leaves out the half that is zero', () => {
    expect(changeSummary(artifact({ relPath: 'a.ts', writes: 1, edits: 0 }))).toBe('1 write')
    expect(changeSummary(artifact({ relPath: 'a.ts', writes: 0, edits: 3 }))).toBe('3 edits')
    expect(changeSummary(artifact({ relPath: 'a.ts', writes: 2, edits: 1 }))).toBe(
      '2 writes · 1 edit',
    )
  })
})

describe('directoryOf', () => {
  it('is empty at the project root', () => {
    expect(directoryOf('README.md')).toBe('')
    expect(directoryOf('src/main/index.ts')).toBe('src/main')
  })
})

/* ----------------------------------------------------------------- render -- */

describe('ArtifactRow', () => {
  it('shows the name, the directory and what happened to it', () => {
    const html = renderToStaticMarkup(
      <ArtifactRow
        artifact={artifact({ relPath: 'src/main/index.ts', writes: 1, edits: 4 })}
        now={NOW}
        selected={false}
        onSelect={() => undefined}
      />,
    )
    expect(html).toContain('index.ts')
    expect(html).toContain('src/main')
    expect(html).toContain('1 write · 4 edits')
    expect(html).toContain('10m ago')
  })

  it('says when a file the agent made is no longer there', () => {
    const html = renderToStaticMarkup(
      <ArtifactRow
        artifact={artifact({ relPath: 'scratch.tmp', onDisk: null })}
        now={NOW}
        selected={false}
        onSelect={() => undefined}
      />,
    )
    expect(html).toContain('not on disk')
  })
})

describe('ChangeBody', () => {
  function change(overrides: Partial<ArtifactChange> = {}): ArtifactChange {
    return {
      at: NOW - 60_000,
      sessionId: 'sess-1',
      action: 'edit',
      tool: 'Edit',
      before: 'const a = 0',
      after: 'const a = 1',
      replaceAll: false,
      clipped: false,
      ...overrides,
    }
  }

  it('renders an edit as a diff with both halves', () => {
    const html = renderToStaticMarkup(<ChangeBody change={change()} />)
    expect(html).toContain('data-kind="del"')
    expect(html).toContain('data-kind="add"')
    expect(html).toContain('const a = 0')
    expect(html).toContain('const a = 1')
  })

  it('renders a write as the text it put in, not as a wall of green', () => {
    const html = renderToStaticMarkup(
      <ChangeBody change={change({ action: 'write', before: '', after: 'hello\nworld\n' })} />,
    )
    expect(html).toContain('data-write="true"')
    expect(html).not.toContain('data-kind="add"')
    expect(html).toContain('hello')
  })
})

describe('ArtifactsPanel', () => {
  const bridge: ArtifactsBridge = {
    listArtifacts: async () => ({ ok: true, ...list() }),
    artifactChanges: async () => ({
      ok: true,
      root: '/p',
      relPath: 'a.ts',
      changes: [],
      totalChanges: 0,
      truncated: false,
      cancelled: false,
      tookMs: 1,
    }),
  }

  it('opens on a reading state rather than on an instruction', () => {
    // The defect this page and the Files page were both reported for: a whole
    // pane spent telling you to click something.
    const html = renderToStaticMarkup(
      <ArtifactsPanel projectPath="/p" bridge={bridge} now={NOW} />,
    )
    expect(html).toContain('Reading this project’s history…')
    expect(html).not.toMatch(/pick something/i)
  })

  it('names itself for a screen reader', () => {
    const html = renderToStaticMarkup(
      <ArtifactsPanel projectPath="/p" bridge={bridge} now={NOW} />,
    )
    expect(html).toContain('aria-label="Artifacts"')
  })

  it('offers both scopes, with this project’s own sessions first', () => {
    const html = renderToStaticMarkup(
      <ArtifactsPanel projectPath="/p" bridge={bridge} now={NOW} />,
    )
    expect(html).toContain('This project’s sessions')
    expect(html).toContain('Every session')
    expect(html.indexOf('This project’s sessions')).toBeLessThan(html.indexOf('Every session'))
  })
})

/* ------------------------------------------------- every reply is an answer -- */

/**
 * The page that never resolved.
 *
 * Two of the four stuck sentences in the recording — "Reading this project’s
 * history…" and "Reading the changes…" — came from one omission here:
 *
 *     if (response.ok) setList(ready)
 *     else if (response.error !== 'cancelled') setList(error)
 *
 * A `cancelled` reply set nothing at all, so the page kept the sentence it had
 * and kept it for good. The main process produces that reply whenever a scan is
 * superseded, and — until the fix in `artifacts.ts` — a *changes* request
 * superseded the *list* request beside it on every scope toggle.
 *
 * The generation guard in the component already drops replies the page has
 * moved on from, so anything reaching this function is a reply the page is
 * still waiting on. Every one of them has to end the wait.
 */
describe('scanOutcome', () => {
  it('hands a successful scan straight through', () => {
    const ok = { ok: true as const, artifacts: [] }
    expect(scanOutcome(ok)).toEqual({ done: ok })
  })

  it('turns a cancelled scan into something the page can act on', () => {
    const outcome = scanOutcome({ ok: false, error: 'cancelled', message: 'Scan cancelled.' })
    expect(outcome).not.toEqual({ done: expect.anything() })
    expect('failed' in outcome && outcome.failed.length > 0).toBe(true)
  })

  it('quotes the main process’s own reason for anything else', () => {
    expect(scanOutcome({ ok: false, error: 'failed', message: 'Could not read it.' })).toEqual({
      failed: 'Could not read it.',
    })
  })

  it('never answers with nothing, whatever the error is called', () => {
    // The shape of the original bug: an error name nobody thought of falling
    // through every arm and leaving the spinner where it was.
    for (const error of ['cancelled', 'failed', 'invalid-project', 'something-new']) {
      const outcome = scanOutcome({ ok: false, error, message: 'why' })
      expect('failed' in outcome).toBe(true)
    }
  })
})

describe('SCAN_FRESH_MS', () => {
  it('is long enough that a trip to a terminal does not re-walk every transcript', () => {
    // Asad watched this page re-scan from scratch each time he came back to it.
    // The scan is the most expensive read in the app; the window has to cover a
    // working session of flipping between the page and a session.
    expect(SCAN_FRESH_MS).toBeGreaterThanOrEqual(60_000)
  })
})
