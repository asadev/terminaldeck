/**
 * What the Memory page reads from the main process, and the shapes it reads.
 *
 * The shapes mirror `src/main/memory/service.ts` and `spaces.ts` field for
 * field. They are written again here rather than imported, by the house rule
 * that a feature's types cross the bridge as `unknown` and each side keeps its
 * own — and every answer goes through a reader below that fills a missing field
 * with its empty value, so a main process older or newer than the page cannot
 * blank it.
 */

/* ----------------------------------------------------------------- shapes -- */

export type SpaceKind = 'claude-project' | 'codex' | 'hoot' | 'knowledge'

export interface SpaceView {
  id: string
  kind: SpaceKind
  label: string
  root: string
  /** The project folder, when it was confirmed. */
  project: string | null
  /** Other folders whose memory is this same folder, through a link that exists on disk. */
  sharedWith: string[]
  accounts: string[]
}

export interface NoteLabelView {
  key: string
  value: string
}

export interface NoteRowView {
  path: string
  title: string
  description: string | null
  type: string | null
  labels: NoteLabelView[]
  modifiedAt: number
  links: string[]
}

export interface GraphView {
  nodes: string[]
  edges: Array<{ from: string; to: string }>
  dangling: Array<{ from: string; target: string }>
}

export interface NotesView {
  notes: NoteRowView[]
  graph: GraphView
}

export interface NoteVersionView {
  modifiedAt: number
  bytes: number
}

export interface NoteReadView {
  spaceId: string
  path: string
  text: string
  truncated: boolean
  version: NoteVersionView
  note: NoteRowView
  links: Array<{ target: string; to: string | null }>
  backlinks: string[]
  indexed: boolean
}

export interface HitView {
  spaceId: string
  path: string
  title: string
  snippet: string
}

export interface WriteView {
  conversationId: string
  folder: string
  at: number
  tool: string
  action: 'write' | 'edit'
}

export interface ProvenanceView {
  writes: WriteView[]
  conversationsRead: number
  truncated: boolean
}

export type Answer<T> = { ok: true; value: T } | { ok: false; error: string }

/* ----------------------------------------------------------------- bridge -- */

/**
 * What this page needs from `window.deck`. The names are the preload's: the
 * contract test matches every `*Bridge` interface against what it exposes.
 */
export interface MemoryBridge {
  memorySpaces(refresh: boolean): Promise<unknown>
  memoryNotes(spaceId: string): Promise<unknown>
  memoryRead(spaceId: string, path: string): Promise<unknown>
  memorySearch(query: string, spaceIds: string[]): Promise<unknown>
  memorySave(spaceId: string, path: string, text: string, version: unknown): Promise<unknown>
  memoryDelete(spaceId: string, path: string, indexLine: boolean): Promise<unknown>
  memoryProvenance(spaceId: string, path: string): Promise<unknown>
  onMemoryChanged(callback: (spaceId: string) => void): () => void
}

const BRIDGE_METHODS: ReadonlyArray<keyof MemoryBridge> = [
  'memorySpaces',
  'memoryNotes',
  'memoryRead',
  'memorySearch',
  'memorySave',
  'memoryDelete',
  'memoryProvenance',
  'onMemoryChanged',
]

/**
 * The bridge as it exists, each method called through its host — a preload
 * whose functions sit on a prototype throws on `this` otherwise. `globalThis`
 * so the page renders to a string in tests.
 */
export function resolveMemoryBridge(host?: unknown): Partial<MemoryBridge> {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return {}
  const all = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof all[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown => (all[name] as (...a: unknown[]) => unknown).apply(all, args)
  }
  return bridge as Partial<MemoryBridge>
}

/* ------------------------------------------------------------- readers -- */

type Raw = Record<string, unknown>

function obj(value: unknown): Raw {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Raw) : {}
}
function arr(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}
function str(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}
function strOrNull(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}
function num(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}
function strings(value: unknown): string[] {
  return arr(value).filter((one): one is string => typeof one === 'string' && one !== '')
}

const KINDS: readonly SpaceKind[] = ['claude-project', 'codex', 'hoot', 'knowledge']

function failed(value: unknown, fallback: string): { ok: false; error: string } {
  return { ok: false, error: str(obj(value).error, fallback) }
}

export function asSpaces(value: unknown): SpaceView[] {
  return arr(obj(value).spaces)
    .map(obj)
    .map((space) => ({
      id: str(space.id),
      kind: KINDS.find((kind) => kind === space.kind) ?? 'claude-project',
      label: str(space.label, str(space.id)),
      root: str(space.root),
      project: strOrNull(space.project),
      sharedWith: strings(space.sharedWith),
      accounts: strings(space.accounts),
    }))
    .filter((space) => space.id !== '')
}

export function asNoteRow(value: unknown): NoteRowView {
  const note = obj(value)
  return {
    path: str(note.path),
    title: str(note.title, str(note.path)),
    description: strOrNull(note.description),
    type: strOrNull(note.type),
    labels: arr(note.labels)
      .map(obj)
      .map((label) => ({ key: str(label.key), value: str(label.value) }))
      .filter((label) => label.key !== '' && label.value !== ''),
    modifiedAt: num(note.modifiedAt),
    links: strings(note.links),
  }
}

export function asNotes(value: unknown): Answer<NotesView> {
  const v = obj(value)
  if (v.ok !== true) return failed(value, 'This memory could not be read.')
  const graph = obj(v.graph)
  return {
    ok: true,
    value: {
      notes: arr(v.notes).map(asNoteRow).filter((note) => note.path !== ''),
      graph: {
        nodes: arr(graph.nodes)
          .map((node) => str(obj(node).path))
          .filter((path) => path !== ''),
        edges: arr(graph.edges)
          .map(obj)
          .map((edge) => ({ from: str(edge.from), to: str(edge.to) }))
          .filter((edge) => edge.from !== '' && edge.to !== ''),
        dangling: arr(graph.dangling)
          .map(obj)
          .map((link) => ({ from: str(link.from), target: str(link.target) }))
          .filter((link) => link.from !== '' && link.target !== ''),
      },
    },
  }
}

export function asRead(value: unknown): Answer<NoteReadView> {
  const v = obj(value)
  if (v.ok !== true) return failed(value, 'This note could not be read.')
  const version = obj(v.version)
  return {
    ok: true,
    value: {
      spaceId: str(v.spaceId),
      path: str(v.path),
      text: str(v.text),
      truncated: v.truncated === true,
      version: { modifiedAt: num(version.modifiedAt), bytes: num(version.bytes) },
      note: asNoteRow(v.note),
      links: arr(v.links)
        .map(obj)
        .map((link) => ({ target: str(link.target), to: strOrNull(link.to) }))
        .filter((link) => link.target !== ''),
      backlinks: strings(v.backlinks),
      indexed: v.indexed === true,
    },
  }
}

export function asHits(value: unknown): HitView[] {
  return arr(obj(value).hits)
    .map(obj)
    .map((hit) => ({ spaceId: str(hit.spaceId), path: str(hit.path), title: str(hit.title, str(hit.path)), snippet: str(hit.snippet) }))
    .filter((hit) => hit.spaceId !== '' && hit.path !== '')
}

export function asChange(value: unknown): Answer<{ version: NoteVersionView | null; indexLineRemoved: boolean }> {
  const v = obj(value)
  if (v.ok !== true) return failed(value, 'Nothing was changed.')
  const version = obj(v.version)
  return {
    ok: true,
    value: {
      version: Object.keys(version).length === 0 ? null : { modifiedAt: num(version.modifiedAt), bytes: num(version.bytes) },
      indexLineRemoved: v.indexLineRemoved === true,
    },
  }
}

export function asProvenance(value: unknown): Answer<ProvenanceView> {
  const v = obj(value)
  if (v.ok !== true) return failed(value, 'This could not be worked out.')
  return {
    ok: true,
    value: {
      writes: arr(v.writes)
        .map(obj)
        .map((write) => ({
          conversationId: str(write.conversationId),
          folder: str(write.folder),
          at: num(write.at),
          tool: str(write.tool),
          action: write.action === 'edit' ? ('edit' as const) : ('write' as const),
        }))
        .filter((write) => write.conversationId !== ''),
      conversationsRead: num(v.conversationsRead),
      truncated: v.truncated === true,
    },
  }
}
