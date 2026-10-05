import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  asChange,
  asHits,
  asNotes,
  asProvenance,
  asRead,
  asSpaces,
  resolveMemoryBridge,
  type NoteReadView,
  type NotesView,
  type SpaceView,
} from './bridge'
import { firstSpace, MemoryGraph, MemoryPage, MemoryPageBody, sharedLine, type MemoryActions, type MemoryPageBodyProps } from './MemoryPage'

/**
 * The page's words and its tolerance of what crosses the bridge, rendered to a
 * string the way the rest of the app's pages are tested.
 */

const noop = (): void => {}
const actions: MemoryActions = {
  selectSpace: noop,
  setMode: noop,
  setQuery: noop,
  setEverywhere: noop,
  openNote: noop,
  closeNote: noop,
  save: noop,
  remove: noop,
  provenance: noop,
  refresh: noop,
}

const alpha: SpaceView = {
  id: 'claude-project:a',
  kind: 'claude-project',
  label: 'alpha',
  root: '/store/projects/-work-alpha/memory',
  project: '/work/alpha',
  sharedWith: ['/work/beta', '/work/gamma'],
  accounts: ['Own'],
}
const hoot: SpaceView = { id: 'hoot:h', kind: 'hoot', label: 'Hoot', root: '/ud/copilot/memory', project: null, sharedWith: [], accounts: [] }
const knowledge: SpaceView = {
  id: 'knowledge:k',
  kind: 'knowledge',
  label: 'alpha',
  root: '/ud/knowledge/k',
  project: '/work/alpha',
  sharedWith: [],
  accounts: [],
}
const unconfirmed: SpaceView = { ...alpha, id: 'claude-project:u', label: '-odd-name', project: null, sharedWith: [] }

const notes: NotesView = {
  notes: [
    { path: 'MEMORY.md', title: 'Memory index', description: null, type: null, labels: [], modifiedAt: 0, links: ['rules.md', 'gone.md'] },
    { path: 'rules.md', title: 'deploy-rules', description: 'Deploy means TestFlight', type: 'feedback', labels: [{ key: 'type', value: 'feedback' }], modifiedAt: 0, links: [] },
    { path: 'loose.md', title: 'loose', description: null, type: null, labels: [], modifiedAt: 0, links: [] },
  ],
  graph: {
    nodes: ['MEMORY.md', 'loose.md', 'rules.md'],
    edges: [{ from: 'MEMORY.md', to: 'rules.md' }],
    dangling: [{ from: 'MEMORY.md', target: 'gone.md' }],
  },
}

function body(extra: Partial<MemoryPageBodyProps> = {}): string {
  return renderToStaticMarkup(
    <MemoryPageBody
      available
      spaces={[hoot, alpha, unconfirmed, knowledge]}
      selected={alpha}
      notes={{ ok: true, value: notes }}
      mode="notes"
      query=""
      everywhere={false}
      hits={null}
      open={null}
      read={undefined}
      provenance={null}
      busy={false}
      message={null}
      actions={actions}
      {...extra}
    />,
  )
}

const opened: NoteReadView = {
  spaceId: alpha.id,
  path: 'rules.md',
  text: '---\nname: deploy-rules\n---\nDeploy means TestFlight. See [[keep]] and [[nowhere]].\n',
  truncated: false,
  version: { modifiedAt: 1, bytes: 10 },
  note: notes.notes[1],
  links: [
    { target: 'keep', to: 'keep.md' },
    { target: 'nowhere', to: null },
  ],
  backlinks: ['MEMORY.md'],
  indexed: true,
}

describe('the list of memories', () => {
  it('groups memories by whose they are, and says plainly which are shared', () => {
    const html = body()
    for (const heading of ['Hoot', 'Claude Code', 'Project knowledge']) expect(html).toContain(`>${heading}</h3>`)
    expect(html).toContain('Shared with 2 folders')
    expect(html).toContain('/work/beta, /work/gamma')
    expect(sharedLine(hoot)).toBeNull()
  })

  it('labels a folder it could not confirm honestly rather than guessing a path', () => {
    expect(body()).toContain('Folder name as Claude Code stores it')
  })

  it('opens on the open project’s own memory, else Hoot’s', () => {
    expect(firstSpace([hoot, alpha, knowledge], '/work/alpha')?.id).toBe(alpha.id)
    expect(firstSpace([hoot, alpha, knowledge], '/work/beta')?.id).toBe(alpha.id)
    expect(firstSpace([hoot, knowledge], '/work/alpha')?.id).toBe(knowledge.id)
    expect(firstSpace([alpha, hoot], null)?.id).toBe(hoot.id)
  })
})

describe('a memory’s notes', () => {
  it('lists each note with its title, description, labels and place', () => {
    const html = body()
    expect(html).toContain('deploy-rules')
    expect(html).toContain('Deploy means TestFlight')
    expect(html).toContain('class="mem-label" data-key="type"')
    expect(html).toContain('rules.md')
    expect(html).toContain('1 link reaches no note.')
  })

  it('shows knowledge records’ kind, status, source and verified date as labels', () => {
    const records: NotesView = {
      notes: [
        {
          path: 'k1.md',
          title: 'storage',
          description: null,
          type: 'decision',
          labels: [
            { key: 'kind', value: 'decision' },
            { key: 'status', value: 'verified' },
            { key: 'source', value: 'review' },
            { key: 'verified', value: '2026-10-04' },
          ],
          modifiedAt: 0,
          links: [],
        },
      ],
      graph: { nodes: ['k1.md'], edges: [], dangling: [] },
    }
    const html = body({ selected: knowledge, notes: { ok: true, value: records } })
    for (const word of ['decision', 'verified', 'review', 'verified 2026-10-04']) expect(html).toContain(word)
  })

  it('shows search results across memories with which memory each came from', () => {
    const html = body({ query: 'deploy', everywhere: true, hits: [{ spaceId: alpha.id, path: 'rules.md', title: 'deploy-rules', snippet: 'Deploy means…' }] })
    expect(html).toContain('Search every memory…')
    expect(html).toContain('Claude Code · alpha')
    expect(html).toContain('Deploy means…')
  })
})

describe('the graph', () => {
  it('draws a dot per note and a line per link that reached one — never a link that reached nothing', () => {
    const html = renderToStaticMarkup(<MemoryGraph notes={notes.notes} graph={notes.graph} onOpen={noop} />)
    expect(html.match(/<line /g)).toHaveLength(1)
    expect(html.match(/class="mem-graph-node"/g)).toHaveLength(3)
    // The dangling target is listed under the graph, not drawn in it.
    expect(html).toContain('Links that reach no note')
    expect(html).toContain('gone.md')
    expect(html).not.toContain('aria-label="Open gone.md"')
  })

  it('opens a note from its dot', () => {
    const html = renderToStaticMarkup(<MemoryGraph notes={notes.notes} graph={notes.graph} current="rules.md" onOpen={noop} />)
    expect(html).toContain('aria-label="Open deploy-rules"')
    expect(html).toContain('data-current="true"')
  })
})

describe('one note', () => {
  it('shows the editor, its links, the links that reach nothing, and what links to it', () => {
    const html = body({ open: { spaceId: alpha.id, path: 'rules.md' }, read: { ok: true, value: opened } })
    expect(html).toContain('<textarea')
    expect(html).toContain('Claude Code reads it at the start of the next conversation')
    expect(html).toContain('keep.md')
    expect(html).toContain('nowhere')
    expect(html).toContain('reaches no note')
    expect(html).toContain('Linked from')
    expect(html).toContain('MEMORY.md')
    expect(html).toContain('Move to Trash')
    expect(html).toContain('Find the conversations that wrote it')
  })

  it('will not save a note it could not show whole', () => {
    const html = body({ open: { spaceId: alpha.id, path: 'rules.md' }, read: { ok: true, value: { ...opened, truncated: true } } })
    expect(html).toContain('saving it here would cut it short')
  })

  it('offers who wrote it only for Claude Code memory', () => {
    const html = body({ selected: hoot, open: { spaceId: hoot.id, path: 'rules.md' }, read: { ok: true, value: opened } })
    expect(html).not.toContain('Find the conversations that wrote it')
  })

  it('lists the conversations that wrote it once asked', () => {
    const html = body({
      open: { spaceId: alpha.id, path: 'rules.md' },
      read: { ok: true, value: opened },
      provenance: {
        ok: true,
        value: { writes: [{ conversationId: 'abcdef123456', folder: '/work/beta', at: 0, tool: 'Edit', action: 'edit' }], conversationsRead: 4, truncated: false },
      },
    })
    expect(html).toContain('Edited in conversation abcdef12')
    expect(html).toContain('/work/beta')
    expect(html).toContain('4 recent conversations read.')
  })
})

describe('when there is nothing, or no bridge', () => {
  it('says the build has no memory page rather than drawing dead controls', () => {
    expect(renderToStaticMarkup(<MemoryPage bridge={{}} />)).toContain('Memory is not available in this build')
  })

  it('says no agent has kept memory yet, with a way to look again', () => {
    const html = body({ spaces: [] })
    expect(html).toContain('No agent has kept memory on this machine yet')
    expect(html).toContain('Look again')
  })
})

describe('reading what crosses the bridge', () => {
  it('fills every missing field rather than failing', () => {
    expect(asSpaces({ spaces: [{ id: 'x' }, {}] })).toEqual([
      { id: 'x', kind: 'claude-project', label: 'x', root: '', project: null, sharedWith: [], accounts: [] },
    ])
    expect(asNotes({ ok: true })).toEqual({ ok: true, value: { notes: [], graph: { nodes: [], edges: [], dangling: [] } } })
    expect(asNotes({ ok: false, error: 'gone' })).toEqual({ ok: false, error: 'gone' })
    expect(asRead({}).ok).toBe(false)
    expect(asHits(null)).toEqual([])
    expect(asChange({ ok: true })).toEqual({ ok: true, value: { version: null, indexLineRemoved: false } })
    expect(asProvenance({ ok: false })).toEqual({ ok: false, error: 'This could not be worked out.' })
  })

  it('calls the preload through its host, and leaves out what it does not have', () => {
    const host = {
      calls: 0,
      memorySpaces(this: { calls: number }) {
        this.calls += 1
        return Promise.resolve({ spaces: [] })
      },
    }
    const bridge = resolveMemoryBridge(host)
    void bridge.memorySpaces?.(false)
    expect(host.calls).toBe(1)
    expect(bridge.memoryNotes).toBeUndefined()
  })
})
