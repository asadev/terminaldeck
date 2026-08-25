import { describe, expect, it, vi } from 'vitest'
import type { Artifact, ArtifactList, ListArtifactsOptions } from '../../artifacts'
import type { ArtifactPreviews, PreviewHandle } from '../../artifact-preview'
import {
  artifactsPanel,
  encodeScope,
  kindOf,
  MAX_ROWS,
  parseScope,
  PREVIEW_ACTION,
  rowIdFor,
  SCAN_ARTIFACTS,
  STOP_ACTION,
  tokenFor,
  type ArtifactsPanelDeps,
} from './artifacts'

/**
 * The Artifacts panel, driven without Electron and without a transcript.
 *
 * The scan is injected, which is the whole point of `deps.list`: what is under
 * test here is the *panel* — the three controls encoded into one scope string,
 * the split that keeps this page from being Files, the cap saying so out loud,
 * and a scan that throws arriving as a sentence rather than as a refusal.
 * Whether `listArtifacts` reads a transcript correctly is settled in
 * `src/main/artifacts.test.ts` against real files, and duplicating it here
 * would be a second, weaker copy of that answer.
 *
 * The clock is pinned so `value` is a fact rather than a race.
 */

const NOW = Date.UTC(2026, 7, 24, 12, 0, 0)
const HOUR = 60 * 60 * 1000

const HERE = '/work/deck'

function artifact(over: Partial<Artifact> & { relPath: string }): Artifact {
  return {
    name: over.relPath.slice(over.relPath.lastIndexOf('/') + 1),
    firstAt: NOW - 3 * HOUR,
    lastAt: NOW - HOUR,
    writes: 1,
    edits: 0,
    lastChars: 120,
    lastTool: 'Write',
    sessionIds: ['session-one'],
    onDisk: { bytes: 400, modifiedAt: NOW - HOUR },
    ...over,
  }
}

function scanned(over: Partial<ArtifactList> = {}): ArtifactList {
  const artifacts = over.artifacts ?? []
  return {
    root: HERE,
    scope: 'all',
    artifacts,
    sessions: [{ sessionId: 'session-one', at: NOW - HOUR, files: artifacts.length }],
    sessionsScanned: 4,
    outsideProject: 0,
    truncated: false,
    cancelled: false,
    tookMs: 12,
    ...over,
  }
}

/** Three files: two written whole, one only edited into. */
const THREE = [
  artifact({ relPath: 'PLAN.md', lastAt: NOW - HOUR }),
  artifact({ relPath: 'src/hero.tsx', lastAt: NOW - 2 * HOUR, sessionIds: ['session-two'] }),
  artifact({
    relPath: 'src/server.ts',
    lastAt: NOW - 3 * HOUR,
    writes: 0,
    edits: 5,
    lastTool: 'Edit',
    sessionIds: ['session-two', 'session-one'],
  }),
]

/**
 * A preview module that binds nothing.
 *
 * The real one opens a socket, and what is under test here is the *panel* —
 * which file a token names, what the notice says, whether the port reaches the
 * rows. `artifact-preview.test.ts` is where a real server is asked real
 * questions over a real port. Two copies of that answer would be one copy and
 * one weaker copy.
 */
function fakePreviews(over: Partial<ArtifactPreviews> = {}) {
  const links: { root: string; token: string; relPath: string }[] = []
  let handle: PreviewHandle | null = null
  const previews: ArtifactPreviews = {
    async serve(root) {
      expect(root).toBe(HERE)
      handle = { port: 41000, secret: 'sEcReT0123456789' }
      return handle
    },
    link(root, token, relPath) {
      links.push({ root, token, relPath })
    },
    current: () => handle,
    stop() {
      handle = null
    },
    stopAll() {
      handle = null
    },
    ...over,
  }
  return { previews, links, held: (): PreviewHandle | null => handle }
}

/**
 * A panel over a fixed answer, and the options the scan was called with.
 *
 * The options are captured rather than asserted inside the stub so a failing
 * expectation names the value it saw.
 */
function panelOver(
  list: ArtifactList | (() => Promise<ArtifactList>),
  extra: Partial<ArtifactsPanelDeps> = {},
) {
  const calls: ListArtifactsOptions[] = []
  const previews = fakePreviews()
  const panel = artifactsPanel({
    list: async (cwd, options) => {
      expect(cwd).toBe(HERE)
      calls.push(options)
      return typeof list === 'function' ? await list() : list
    },
    now: () => NOW,
    previews: previews.previews,
    ...extra,
  })
  return { panel, calls, previews }
}

/** The five fields of a row id, in the grammar the panel's header sets out. */
function readId(id: string | undefined) {
  const parts = (id ?? '').split(' ')
  return {
    token: parts[0],
    kind: parts[1],
    bytes: Number(parts[2]),
    preview: parts[3],
    path: parts.slice(4).join(' '),
  }
}

describe('the scope string', () => {
  it('defaults to what an agent made, read across every session', () => {
    expect(parseScope(undefined)).toEqual({ kind: 'made', breadth: 'all', session: null })
    expect(parseScope('')).toEqual({ kind: 'made', breadth: 'all', session: null })
  })

  it('reads the three controls in any order, first token of a dimension winning', () => {
    expect(parseScope('session:abc changed project')).toEqual({
      kind: 'changed',
      breadth: 'project',
      session: 'abc',
    })
    // The leading token is the one a chip put there, so it must beat the copy
    // of the same dimension that trails behind it.
    expect(parseScope('changed made all').kind).toBe('changed')
  })

  it('ignores a token it does not know rather than refusing the whole scope', () => {
    expect(parseScope('changed sortBy:size')).toEqual({
      kind: 'changed',
      breadth: 'all',
      session: null,
    })
  })

  it('writes the tapped token first, so two live chips stay two ids', () => {
    const state = parseScope('made all')
    // Both of these select the state that is already current; without the
    // leading token they would be the same string, and a client keying its
    // filter row on the id would draw one chip where there are two.
    expect(encodeScope(state, 'made')).toBe('made all session:*')
    expect(encodeScope(state, 'all')).toBe('all made session:*')
    expect(encodeScope(state, 'made')).not.toBe(encodeScope(state, 'all'))
  })
})

describe('reading the panel', () => {
  it('answers with what an agent made here, newest first', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }))
    const answer = await panel.read({ path: HERE })

    expect(answer.path).toBe(HERE)
    expect(answer.rows.map((row) => readId(row.id).token)).toEqual(['PLAN.md', 'src/hero.tsx'])
    expect(answer.rows[0]).toMatchObject({
      title: 'PLAN.md',
      value: '1h ago',
      status: 'made',
    })
    // Below the root the row is the path: five rows reading `index.ts` name
    // nothing, and the row is the only place the phone says which file it is.
    expect(answer.rows[1].title).toBe('src/hero.tsx')
  })

  it('names the session that wrote each file, and says when there were more', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }), {
      sessionNames: async () => new Map([['session-one', 'Rewrite the hero']]),
    })
    const answer = await panel.read({ path: HERE })

    expect(answer.rows[0].detail).toBe('Rewrite the hero')
    // No name for this one, so the short id stands in — never the session's
    // time, which would sit beside the row's own time saying something else.
    expect(answer.rows[1].detail).toBe('session session-')
  })

  it('narrows to what the query names, matching on the whole path', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }))

    expect(
      (await panel.read({ path: HERE, query: 'hero' })).rows.map((row) => readId(row.id).token),
    ).toEqual(['src/hero.tsx'])
    // The desktop matches the relative path, not the filename, so a folder is
    // a legitimate search.
    expect(
      (await panel.read({ path: HERE, query: 'src/' })).rows.map((row) => readId(row.id).token),
    ).toEqual(['src/hero.tsx'])
    expect((await panel.read({ path: HERE, query: 'PLAN' })).rows).toHaveLength(1)
  })

  it('keeps made and changed as two lists, one chip apart', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }))

    const made = await panel.read({ path: HERE, scope: 'made all' })
    expect(made.rows.map((row) => readId(row.id).token)).toEqual(['PLAN.md', 'src/hero.tsx'])

    const changed = await panel.read({ path: HERE, scope: 'changed all' })
    expect(changed.rows.map((row) => readId(row.id).token)).toEqual(['src/server.ts'])
    expect(changed.rows[0].status).toBe('changed')
  })

  it('hands the breadth to the scan rather than filtering afterwards', async () => {
    const { panel, calls } = panelOver(scanned({ artifacts: THREE }))

    await panel.read({ path: HERE })
    await panel.read({ path: HERE, scope: 'project made' })

    // Which transcripts get opened is the scan's decision, and it is the only
    // one of the three controls that cannot be applied to an answer already in
    // hand.
    expect(calls.map((options) => options.scope)).toEqual(['all', 'project'])
    expect(calls[0].maxArtifacts).toBe(SCAN_ARTIFACTS)
  })

  it('narrows to one session without losing the kind that was chosen', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }))

    const one = await panel.read({ path: HERE, scope: 'session:session-two made all' })
    expect(one.rows.map((row) => readId(row.id).token)).toEqual(['src/hero.tsx'])

    const other = await panel.read({ path: HERE, scope: 'session:session-two changed all' })
    expect(other.rows.map((row) => readId(row.id).token)).toEqual(['src/server.ts'])
  })

  it('lets the caller set the scan budget but never the scope', async () => {
    const { panel, calls } = panelOver(scanned({ artifacts: THREE }), {
      scan: { timeBudgetMs: 2_000, scope: 'project' },
    })
    await panel.read({ path: HERE, scope: 'all made' })

    expect(calls[0].timeBudgetMs).toBe(2_000)
    // `scope` is a control on the screen; a host that pinned it would draw a
    // chip that does nothing.
    expect(calls[0].scope).toBe('all')
  })
})

describe('the chips', () => {
  it('lights exactly one chip in each of the three groups', async () => {
    const { panel } = panelOver(
      scanned({
        artifacts: THREE,
        sessions: [
          { sessionId: 'session-one', at: NOW - HOUR, files: 2 },
          { sessionId: 'session-two', at: NOW - 2 * HOUR, files: 2 },
        ],
      }),
    )
    const answer = await panel.read({ path: HERE, scope: 'changed project session:session-two' })
    const scopes = answer.scopes ?? []

    const lit = scopes.filter((scope) => scope.on).map((scope) => scope.label)
    expect(lit).toEqual(['Changed', "This project's sessions", '2h ago · 2 files'])

    // One per dimension, and never a row with nothing lit: a filter row that
    // shows no selection reads as a panel with no filters applied, which would
    // be a lie about every list but the default one.
    expect(lit).toHaveLength(3)
    expect(scopes.every((scope) => scope.id !== '')).toBe(true)
    expect(new Set(scopes.map((scope) => scope.id)).size).toBe(scopes.length)
  })

  it('carries the whole state in every chip, so a tap changes one thing', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }))
    const answer = await panel.read({ path: HERE, scope: 'changed project' })
    const chip = (label: string) => (answer.scopes ?? []).find((scope) => scope.label === label)

    // Tapping Every session must keep Changed, and tapping Made here must keep
    // this project's sessions.
    expect(chip('Every session')?.id).toBe('all changed session:*')
    expect(chip('Made here')?.id).toBe('made project session:*')
  })

  it('offers a session chip only where there is a session to choose between', async () => {
    const one = panelOver(scanned({ artifacts: THREE }))
    const labels = ((await one.panel.read({ path: HERE })).scopes ?? []).map((scope) => scope.label)
    expect(labels).toEqual(['Made here', 'Changed', "This project's sessions", 'Every session'])

    const many = panelOver(
      scanned({
        artifacts: THREE,
        sessions: [
          { sessionId: 'session-one', at: NOW - HOUR, files: 2 },
          { sessionId: 'session-two', at: NOW - 26 * HOUR, files: 1 },
        ],
      }),
      { sessionNames: async () => new Map([['session-one', 'Rewrite the hero']]) },
    )
    const chips = ((await many.panel.read({ path: HERE })).scopes ?? []).map((scope) => scope.label)
    expect(chips).toContain('All sessions')
    expect(chips).toContain('Rewrite the hero · 2 files')
    // No name for the second, so it wears the time the desktop's chip wears.
    expect(chips).toContain('1d ago · 1 file')
  })

  it('keeps the chip for a session the scan no longer lists', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }))
    const answer = await panel.read({ path: HERE, scope: 'session:rolled-past made all' })
    const scopes = answer.scopes ?? []

    // The filter is applied whether or not the session is still in range of the
    // chip row, and a narrowing whose control has vanished is a list a person
    // cannot explain, let alone undo.
    expect(scopes.map((scope) => scope.label)).toContain('session rolled-p')
    expect(scopes.filter((scope) => scope.on).map((scope) => scope.label)).toEqual([
      'Made here',
      'Every session',
      'session rolled-p',
    ])
    expect(scopes.some((scope) => scope.label === 'All sessions')).toBe(true)
    expect(answer.rows).toEqual([])
  })
})

describe('what a row says it is', () => {
  it('carries the kind, the size, the path and no preview, in one id', async () => {
    const { panel } = panelOver(scanned({ artifacts: [artifact({ relPath: 'demo/index.html' })] }))
    const answer = await panel.read({ path: HERE })

    expect(readId(answer.rows[0].id)).toEqual({
      token: 'demo/index.html',
      kind: 'page',
      bytes: 400,
      // Nothing is being served until somebody asks for it. A port in a row
      // nothing is listening on is worse than no port at all.
      preview: '-',
      path: '/work/deck/demo/index.html',
    })
  })

  it('sorts a file into the screen that can show it', () => {
    expect(kindOf(artifact({ relPath: 'demo/index.html' }))).toBe('page')
    expect(kindOf(artifact({ relPath: 'art/logo.PNG' }))).toBe('image')
    expect(kindOf(artifact({ relPath: 'art/logo.svg' }))).toBe('image')
    expect(kindOf(artifact({ relPath: 'notes/walkthrough.mp4' }))).toBe('media')
    expect(kindOf(artifact({ relPath: 'src/hero.tsx' }))).toBe('text')
    expect(kindOf(artifact({ relPath: 'build/app.zip' }))).toBe('other')
    expect(kindOf(artifact({ relPath: 'scratch.txt', onDisk: null }))).toBe('gone')
  })

  it('calls a file with no extension text, because the host corrects that and not the reverse', () => {
    // `files.read` decides binary from the bytes and says so. A wrong `text`
    // guess ends on the host's own answer; a wrong `other` guess ends on a
    // screen refusing to show a Makefile with nobody able to find out why.
    expect(kindOf(artifact({ relPath: 'Makefile' }))).toBe('text')
    expect(kindOf(artifact({ relPath: '.gitignore' }))).toBe('text')
    expect(kindOf(artifact({ relPath: 'scripts/deploy' }))).toBe('text')
  })

  it('offers no action on a row, because the row itself is the control', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }))
    const answer = await panel.read({ path: HERE })

    // `Open in Files` was a button that answered "Opening PLAN.md." and opened
    // nothing. Its absence is the fix, not an omission.
    expect(answer.rows.every((row) => row.actions === undefined)).toBe(true)
  })

  it('names a row a phone can address, whatever the path is', () => {
    expect(tokenFor('PLAN.md')).toBe('PLAN.md')

    // Over `MAX_PANEL_WORD` — 128 bytes — and `panel.act` refuses an id past it
    // by **closing the socket**. This panel sent the raw path from the day it
    // was written.
    const deep = `${'nested/'.repeat(30)}index.ts`
    expect(deep.length).toBeGreaterThan(128)
    const token = tokenFor(deep)
    expect(Buffer.byteLength(token)).toBeLessThanOrEqual(128)
    expect(tokenFor(deep)).toBe(token)

    // A space would make the fifth field of the id ambiguous, and a filename
    // with a space in it is ordinary rather than exotic.
    expect(tokenFor('my notes.md')).not.toContain(' ')
    expect(tokenFor('my notes.md')).not.toBe(tokenFor('my notes.txt'))
  })

  it('keeps the absolute path last, so a name with a space in it survives', () => {
    const id = rowIdFor(artifact({ relPath: 'design notes/read me.md' }), HERE, null)
    expect(readId(id).path).toBe('/work/deck/design notes/read me.md')
    expect(readId(id).kind).toBe('text')
  })
})

describe('running a prototype', () => {
  it('serves the project, registers the redirect and puts the port in every row', async () => {
    const { panel, previews } = panelOver(scanned({ artifacts: THREE }))
    const answer = await panel.act?.({
      path: HERE,
      action: PREVIEW_ACTION,
      id: 'PLAN.md',
      fields: {},
    })

    expect(answer?.notice).toBe('Serving PLAN.md from this machine.')
    expect(previews.links).toEqual([{ root: HERE, token: 'PLAN.md', relPath: 'PLAN.md' }])
    // Every row, not only the one that was asked for: two prototypes in one
    // project are one server, and the second must not be pressed twice.
    expect(answer?.rows.map((row) => readId(row.id).preview)).toEqual([
      '41000.sEcReT0123456789',
      '41000.sEcReT0123456789',
    ])
  })

  it('offers Stop serving only while something is being served', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }))

    const quiet = await panel.read({ path: HERE })
    expect(quiet.actions).toBeUndefined()

    const serving = await panel.act?.({
      path: HERE,
      action: PREVIEW_ACTION,
      id: 'PLAN.md',
      fields: {},
    })
    expect(serving?.actions?.map((action) => action.id)).toEqual([STOP_ACTION])
    expect(serving?.actions?.[0].kind).toBe('destructive')

    const stopped = await panel.act?.({ path: HERE, action: STOP_ACTION, fields: {} })
    expect(stopped?.notice).toBe('Nothing is being served now.')
    expect(stopped?.actions).toBeUndefined()
    // The port has to leave the rows with the server. A row still naming a
    // closed one sends the next tap at a socket nothing is listening on.
    expect(stopped?.rows.every((row) => readId(row.id).preview === '-')).toBe(true)
  })

  it('refuses a file that is not there any more, and says which', async () => {
    const { panel, previews } = panelOver(
      scanned({ artifacts: [artifact({ relPath: 'scratch.txt', onDisk: null, writes: 1 })] }),
    )
    const answer = await panel.act?.({
      path: HERE,
      action: PREVIEW_ACTION,
      id: 'scratch.txt',
      fields: {},
    })

    expect(answer?.notice).toBe('scratch.txt is no longer on disk.')
    expect(previews.held()).toBeNull()
  })

  it('says so when the row a tap named is gone, rather than sending the phone nowhere', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }))

    const missing = await panel.act?.({
      path: HERE,
      action: PREVIEW_ACTION,
      id: 'deleted.md',
      fields: {},
    })
    expect(missing?.notice).toBe('deleted.md is not in this list any more.')

    const unknown = await panel.act?.({ path: HERE, action: 'rename', id: 'PLAN.md', fields: {} })
    expect(unknown?.notice).toBe('This panel has nothing called rename.')
    expect(unknown?.rows).toHaveLength(2)
  })

  it('turns a server that would not bind into a sentence under a list that still works', async () => {
    const { previews } = fakePreviews({
      async serve() {
        throw new Error('listen EADDRINUSE')
      },
    })
    const panel = artifactsPanel({
      list: async () => scanned({ artifacts: THREE }),
      now: () => NOW,
      previews,
    })

    const answer = await panel.act?.({
      path: HERE,
      action: PREVIEW_ACTION,
      id: 'PLAN.md',
      fields: {},
    })
    expect(answer?.notice).toBe('PLAN.md could not be served: listen EADDRINUSE')
    expect(answer?.rows).toHaveLength(2)
  })

  it('draws the list when the preview module cannot even be asked', async () => {
    const { previews } = fakePreviews({
      current() {
        throw new Error('no preview on this host')
      },
    })
    const panel = artifactsPanel({
      list: async () => scanned({ artifacts: THREE }),
      now: () => NOW,
      previews,
    })

    const answer = await panel.read({ path: HERE })
    expect(answer.rows).toHaveLength(2)
    expect(readId(answer.rows[0].id).preview).toBe('-')
  })
})

describe('when there is more than a phone should be sent', () => {
  it('caps the rows, says so in the note and tells the host', async () => {
    const many = Array.from({ length: MAX_ROWS + 31 }, (_, index) =>
      artifact({ relPath: `notes/${index}.md`, lastAt: NOW - index * 1000 }),
    )
    const log = vi.fn()
    const { panel } = panelOver(scanned({ artifacts: many }), { log })
    const answer = await panel.read({ path: HERE })

    expect(answer.rows).toHaveLength(MAX_ROWS)
    // A list that stops at two hundred without a word reads as "that is
    // everything", which is exactly the defect this panel was rewritten for.
    expect(answer.note).toContain('31 older matches not sent to this phone')
    expect(answer.note).toContain(`${MAX_ROWS} of ${many.length} made here`)
    expect(log).toHaveBeenCalledWith(
      `artifacts panel: ${many.length} rows for ${HERE} cut to ${MAX_ROWS}`,
    )
  })

  it('passes on the scanner saying it stopped early', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE, truncated: true }))
    expect((await panel.read({ path: HERE })).note).toContain('older work not read')
  })
})

describe('when there is nothing to show', () => {
  it('says which folder, how much was read, and what went elsewhere', async () => {
    const { panel } = panelOver(
      scanned({ artifacts: [], sessions: [], sessionsScanned: 15, outsideProject: 40 }),
    )
    const answer = await panel.read({ path: HERE, scope: 'project made' })

    // *"No artifacts are still. I don't know. We don't have artifacts maybe."*
    // — a zero has to carry its own evidence or a reader cannot check it.
    expect(answer.note).toContain(HERE)
    expect(answer.note).toContain('15 sessions read')
    expect(answer.note).toContain('40 changes to files outside it')
    expect(answer.note).toContain('Every session')
    expect(answer.rows).toEqual([])
  })

  it('tells a filter that matched nothing apart from a kind that is empty', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }))

    expect((await panel.read({ path: HERE, query: 'nope' })).note).toBe(
      'Nothing matches that filter.',
    )
    const noneMade = panelOver(scanned({ artifacts: [THREE[2]] }))
    expect((await noneMade.panel.read({ path: HERE })).note).toContain(
      'What it edited is under Changed',
    )
  })
})

describe('a host that cannot answer', () => {
  it('turns a scan that throws into a sentence, and keeps the chips', async () => {
    const { panel } = panelOver(async () => {
      throw new Error('EACCES: permission denied, scandir')
    })
    const answer = await panel.read({ path: HERE, scope: 'project changed' })

    // A refusal is what put "This machine could not answer that panel" on a
    // screen whose real answer was a reason, and a person cannot tell that
    // sentence from a broken app.
    expect(answer.note).toBe(
      "This project's history could not be read: EACCES: permission denied, scandir",
    )
    expect(answer.rows).toEqual([])
    expect(answer.path).toBe(HERE)
    // Still drawable, and still holding the state that was asked for — the one
    // control that might fix it is Every session.
    const lit = (answer.scopes ?? []).filter((scope) => scope.on).map((scope) => scope.label)
    expect(lit).toEqual(['Changed', "This project's sessions"])
  })

  it('keeps drawing when the session names cannot be read', async () => {
    const { panel } = panelOver(scanned({ artifacts: THREE }), {
      sessionNames: async () => {
        throw new Error('no window on this host')
      },
    })
    const answer = await panel.read({ path: HERE })

    // A nicety on a page about files. A headless host has no window to ask, and
    // a chip wearing a time is what the desktop shows for a session it did not
    // start either.
    expect(answer.rows).toHaveLength(2)
    expect(answer.rows[0].detail).toBe('session session-')
    expect(answer.note).not.toContain('could not be read')
  })
})
