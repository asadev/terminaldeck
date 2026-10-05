/**
 * Memory: what the agents on this machine actually remember, as notes you can
 * read, follow, search, correct and throw away.
 *
 * ## What is on it
 *
 * Every memory this app can find (`src/main/memory/spaces.ts`): Claude Code's
 * per-project memory in each account store, Codex's memories, Hoot's own, and
 * each project's knowledge records. One is open at a time, as a list of its
 * notes or as a graph of how they link. A note opens to its text in the same
 * editor Settings uses for Hoot's memory, with what it links to, what links to
 * it, and the links in it that reach nothing — and, for Claude Code's memory,
 * which conversations wrote it, worked out only when asked.
 *
 * ## Saying what is shared
 *
 * Some project folders already read the same memory through a link somebody
 * made on disk. The page says so on that memory — *shared with N folders*, and
 * which — rather than listing the same notes twice under two names. It never
 * makes or removes such a link.
 *
 * ## The graph draws only what is real
 *
 * A dot is a note and a line is a link that reached one. A link that reaches
 * nothing has no second end, so it is listed under the graph, never drawn — a
 * line to an invented dot would be a note that does not exist.
 */

import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement } from 'react'
import { BRAND } from '../../shared/brand'
import { PageEmpty } from '../components/PageEmpty'
import { Pill, PillRow } from '../components/Pill'
import { Button } from '../settings/controls'
import { FileEditor } from '../settings/sections/CopilotEditor'
import '../settings/sections/CopilotSection.css'
import {
  asChange,
  asHits,
  asNotes,
  asProvenance,
  asRead,
  asSpaces,
  resolveMemoryBridge,
  type Answer,
  type GraphView,
  type HitView,
  type MemoryBridge,
  type NoteReadView,
  type NoteRowView,
  type NotesView,
  type ProvenanceView,
  type SpaceKind,
  type SpaceView,
} from './bridge'
import { layoutGraph } from './graph-layout'
import './MemoryPage.css'

/** The sidebar row's icon too: three notes and the links between them. */
export const MEMORY_ICON =
  'M9.1 7.6l5.8.6M8.2 9.1l2 5.8M15.8 10.1l-3.6 5M7 9.4a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4zM17 10.4a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4zM11 19.4a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4z'

export type MemoryMode = 'notes' | 'graph'

const SEARCH_DELAY_MS = 200

const KIND_ORDER: readonly SpaceKind[] = ['hoot', 'claude-project', 'codex', 'knowledge']

export const KIND_TITLE: Readonly<Record<SpaceKind, string>> = {
  hoot: BRAND.assistant,
  'claude-project': 'Claude Code',
  codex: 'Codex',
  knowledge: 'Project knowledge',
}

/** When a save takes effect, said under the editor. */
const SAVE_EFFECT: Readonly<Record<SpaceKind, string>> = {
  hoot: `Saves the note on disk. ${BRAND.assistant} reads it the next time it starts.`,
  'claude-project': 'Saves the note on disk. Claude Code reads it at the start of the next conversation in this folder.',
  codex: 'Saves the note on disk. Codex reads it at the start of its next conversation.',
  knowledge: 'Saves the record on disk. It is used in the next brief or plan for this project.',
}

/* ------------------------------------------------------------------ words -- */

export function sharedLine(space: SpaceView): string | null {
  const count = space.sharedWith.length
  if (count === 0) return null
  return `Shared with ${count} folder${count === 1 ? '' : 's'}`
}

function where(space: SpaceView): string | null {
  if (space.kind === 'claude-project') return space.project ?? 'Folder name as Claude Code stores it'
  if (space.kind === 'knowledge') return space.project
  if (space.kind === 'codex' && space.accounts.length > 0) return space.accounts.join(', ')
  return null
}

function dateOf(ms: number): string {
  if (ms <= 0) return ''
  return new Date(ms).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })
}

/** The space to open first: the open project's own memory, else Hoot's, else the first. */
export function firstSpace(spaces: readonly SpaceView[], projectPath: string | null): SpaceView | null {
  if (projectPath !== null) {
    const own =
      spaces.find((space) => space.kind === 'claude-project' && space.project === projectPath) ??
      spaces.find((space) => space.kind === 'claude-project' && space.sharedWith.includes(projectPath)) ??
      spaces.find((space) => space.kind === 'knowledge' && space.project === projectPath)
    if (own !== undefined) return own
  }
  return spaces.find((space) => space.kind === 'hoot') ?? spaces[0] ?? null
}

/* ------------------------------------------------------------- the page -- */

export interface MemoryActions {
  selectSpace(id: string): void
  setMode(mode: MemoryMode): void
  setQuery(query: string): void
  setEverywhere(everywhere: boolean): void
  openNote(spaceId: string, path: string): void
  closeNote(): void
  save(text: string): void
  remove(indexLine: boolean): void
  provenance(): void
  refresh(): void
}

export interface MemoryPageBodyProps {
  available: boolean
  /** Undefined while the first read is out; null when it failed. */
  spaces: SpaceView[] | null | undefined
  selected: SpaceView | null
  notes: Answer<NotesView> | undefined
  mode: MemoryMode
  query: string
  everywhere: boolean
  hits: HitView[] | null
  open: { spaceId: string; path: string } | null
  read: Answer<NoteReadView> | undefined
  provenance: Answer<ProvenanceView> | 'reading' | null
  busy: boolean
  message: { text: string; ok: boolean } | null
  actions: MemoryActions
}

export function MemoryPage({
  bridge: given,
  projectPath = null,
}: {
  bridge?: Partial<MemoryBridge>
  projectPath?: string | null
}): ReactElement {
  const bridge = useMemo(() => given ?? resolveMemoryBridge(), [given])
  const [spaces, setSpaces] = useState<SpaceView[] | null | undefined>(undefined)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [notes, setNotes] = useState<Answer<NotesView> | undefined>(undefined)
  const [mode, setMode] = useState<MemoryMode>('notes')
  const [query, setQuery] = useState('')
  const [everywhere, setEverywhere] = useState(false)
  const [hits, setHits] = useState<HitView[] | null>(null)
  const [open, setOpen] = useState<{ spaceId: string; path: string } | null>(null)
  const [read, setRead] = useState<Answer<NoteReadView> | undefined>(undefined)
  const [provenance, setProvenance] = useState<Answer<ProvenanceView> | 'reading' | null>(null)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<{ text: string; ok: boolean } | null>(null)
  const [changes, setChanges] = useState(0)
  const projectRef = useRef(projectPath)

  const loadSpaces = useCallback(
    async (refresh: boolean) => {
      if (bridge.memorySpaces === undefined) return
      try {
        const found = asSpaces(await bridge.memorySpaces(refresh))
        setSpaces(found)
        setSelectedId((current) =>
          current !== null && found.some((space) => space.id === current) ? current : (firstSpace(found, projectRef.current)?.id ?? null),
        )
      } catch {
        setSpaces(null)
      }
    },
    [bridge],
  )

  useEffect(() => {
    void loadSpaces(false)
  }, [loadSpaces])

  // A space's notes, again whenever the folder changes on disk.
  useEffect(() => {
    if (selectedId === null || bridge.memoryNotes === undefined) return
    let live = true
    bridge
      .memoryNotes(selectedId)
      .then((value) => live && setNotes(asNotes(value)))
      .catch((error: unknown) => live && setNotes({ ok: false, error: String(error) }))
    return () => {
      live = false
    }
  }, [bridge, selectedId, changes])

  useEffect(
    () =>
      bridge.onMemoryChanged?.((spaceId) => {
        if (spaceId === selectedId) setChanges((n) => n + 1)
      }),
    [bridge, selectedId],
  )

  // Search, a moment after the typing stops.
  useEffect(() => {
    const words = query.trim()
    if (words === '' || bridge.memorySearch === undefined) {
      setHits(null)
      return
    }
    const ids = everywhere ? (spaces ?? []).map((space) => space.id) : selectedId === null ? [] : [selectedId]
    let live = true
    const timer = setTimeout(() => {
      bridge
        .memorySearch?.(words, ids)
        .then((value) => live && setHits(asHits(value)))
        .catch(() => live && setHits([]))
    }, SEARCH_DELAY_MS)
    return () => {
      live = false
      clearTimeout(timer)
    }
  }, [bridge, query, everywhere, spaces, selectedId, changes])

  const readNote = useCallback(
    async (spaceId: string, path: string) => {
      if (bridge.memoryRead === undefined) return
      try {
        setRead(asRead(await bridge.memoryRead(spaceId, path)))
      } catch (error) {
        setRead({ ok: false, error: String(error) })
      }
    },
    [bridge],
  )

  const actions: MemoryActions = {
    selectSpace: (id) => {
      setSelectedId(id)
      setNotes(undefined)
      setOpen(null)
      setRead(undefined)
      setMessage(null)
    },
    setMode: (next) => {
      setMode(next)
      if (next === 'graph') setOpen(null)
    },
    setQuery,
    setEverywhere,
    openNote: (spaceId, path) => {
      if (spaceId !== selectedId) {
        setSelectedId(spaceId)
        setNotes(undefined)
      }
      setMode('notes')
      setOpen({ spaceId, path })
      setRead(undefined)
      setProvenance(null)
      setMessage(null)
      void readNote(spaceId, path)
    },
    closeNote: () => {
      setOpen(null)
      setRead(undefined)
      setProvenance(null)
      setMessage(null)
    },
    save: (text) => {
      if (open === null || read === undefined || !read.ok || bridge.memorySave === undefined) return
      setBusy(true)
      bridge
        .memorySave(open.spaceId, open.path, text, read.value.version)
        .then(async (value) => {
          const answer = asChange(value)
          setMessage(answer.ok ? { text: 'Saved.', ok: true } : { text: answer.error, ok: false })
          if (answer.ok) await readNote(open.spaceId, open.path)
        })
        .catch((error: unknown) => setMessage({ text: String(error), ok: false }))
        .finally(() => setBusy(false))
    },
    remove: (indexLine) => {
      if (open === null || bridge.memoryDelete === undefined) return
      setBusy(true)
      bridge
        .memoryDelete(open.spaceId, open.path, indexLine)
        .then((value) => {
          const answer = asChange(value)
          if (!answer.ok) {
            setMessage({ text: answer.error, ok: false })
            return
          }
          setOpen(null)
          setRead(undefined)
          setMessage({
            text: answer.value.indexLineRemoved ? 'Moved to the Trash, and its line taken out of MEMORY.md.' : 'Moved to the Trash.',
            ok: true,
          })
          setChanges((n) => n + 1)
        })
        .catch((error: unknown) => setMessage({ text: String(error), ok: false }))
        .finally(() => setBusy(false))
    },
    provenance: () => {
      if (open === null || bridge.memoryProvenance === undefined) return
      setProvenance('reading')
      bridge
        .memoryProvenance(open.spaceId, open.path)
        .then((value) => setProvenance(asProvenance(value)))
        .catch((error: unknown) => setProvenance({ ok: false, error: String(error) }))
    },
    refresh: () => {
      void loadSpaces(true)
      setChanges((n) => n + 1)
    },
  }

  return (
    <MemoryPageBody
      available={bridge.memorySpaces !== undefined}
      spaces={spaces}
      selected={spaces?.find((space) => space.id === selectedId) ?? null}
      notes={notes}
      mode={mode}
      query={query}
      everywhere={everywhere}
      hits={hits}
      open={open}
      read={read}
      provenance={provenance}
      busy={busy}
      message={message}
      actions={actions}
    />
  )
}

export function MemoryPageBody(props: MemoryPageBodyProps): ReactElement {
  const { available, spaces, selected, mode, query, everywhere, actions } = props
  if (!available) return <PageEmpty icon={MEMORY_ICON} title="Memory is not available in this build" />
  if (spaces === undefined) return <div className="mem mem-loading" aria-busy="true" />
  if (spaces === null) {
    return (
      <PageEmpty icon={MEMORY_ICON} title="Memory could not be read">
        Terminal Deck did not answer. Reopen this page in a moment.
      </PageEmpty>
    )
  }
  if (spaces.length === 0) {
    return (
      <PageEmpty icon={MEMORY_ICON} title="No agent has kept memory on this machine yet" action={{ label: 'Look again', onClick: actions.refresh }}>
        Notes appear here once Claude Code, Codex or {BRAND.assistant} remembers something.
      </PageEmpty>
    )
  }

  return (
    <div className="mem">
      <SpaceList spaces={spaces} selected={selected} onSelect={actions.selectSpace} onRefresh={actions.refresh} />
      <section className="mem-main" aria-label={selected?.label ?? 'Memory'}>
        <div className="mem-tools">
          <input
            className="mem-search"
            type="search"
            value={query}
            placeholder={everywhere ? 'Search every memory…' : 'Search this memory…'}
            aria-label="Search memory"
            spellCheck={false}
            autoComplete="off"
            onChange={(event) => actions.setQuery(event.target.value)}
          />
          <PillRow label="Where to search">
            <Pill on={!everywhere} onClick={() => actions.setEverywhere(false)}>
              This memory
            </Pill>
            <Pill on={everywhere} onClick={() => actions.setEverywhere(true)}>
              Every memory
            </Pill>
          </PillRow>
          <PillRow label="Show">
            <Pill on={mode === 'notes'} onClick={() => actions.setMode('notes')}>
              Notes
            </Pill>
            <Pill on={mode === 'graph'} onClick={() => actions.setMode('graph')}>
              Graph
            </Pill>
          </PillRow>
        </div>
        <MainPane {...props} />
      </section>
    </div>
  )
}

function MainPane(props: MemoryPageBodyProps): ReactElement {
  const { selected, notes, mode, query, hits, open, read, spaces, actions, message } = props
  if (query.trim() !== '' && open === null) {
    return <SearchResults hits={hits} spaces={spaces ?? []} onOpen={actions.openNote} />
  }
  if (selected === null) return <p className="mem-quiet">Choose a memory on the left.</p>
  if (open !== null) {
    // Keyed by the note, so a half-finished delete question does not follow a link to the next one.
    return <NoteView key={`${open.spaceId}/${open.path}`} {...props} space={selected} read={read} />
  }
  return (
    <>
      <SpaceHead space={selected} />
      {message !== null && (
        <p className="mem-message" data-ok={message.ok ? 'true' : 'false'} role="status">
          {message.text}
        </p>
      )}
      {notes === undefined ? (
        <p className="mem-quiet">Reading…</p>
      ) : !notes.ok ? (
        <p className="mem-problem">{notes.error}</p>
      ) : mode === 'graph' ? (
        <MemoryGraph
          notes={notes.value.notes}
          graph={notes.value.graph}
          onOpen={(path) => actions.openNote(selected.id, path)}
        />
      ) : (
        <NoteList notes={notes.value.notes} dangling={notes.value.graph.dangling.length} onOpen={(path) => actions.openNote(selected.id, path)} onGraph={() => actions.setMode('graph')} />
      )}
    </>
  )
}

/* ---------------------------------------------------------------- spaces -- */

function SpaceList({
  spaces,
  selected,
  onSelect,
  onRefresh,
}: {
  spaces: SpaceView[]
  selected: SpaceView | null
  onSelect(id: string): void
  onRefresh(): void
}): ReactElement {
  return (
    <nav className="mem-spaces" aria-label="Memories">
      {KIND_ORDER.map((kind) => {
        const ofKind = spaces.filter((space) => space.kind === kind)
        if (ofKind.length === 0) return null
        return (
          <div key={kind} className="mem-group">
            <h3 className="mem-group-title">{KIND_TITLE[kind]}</h3>
            <ul className="mem-list">
              {ofKind.map((space) => {
                const shared = sharedLine(space)
                const place = where(space)
                return (
                  <li key={space.id} className="mem-row" data-selected={space.id === selected?.id ? 'true' : undefined}>
                    <button
                      type="button"
                      className="mem-row-button"
                      aria-current={space.id === selected?.id ? 'true' : undefined}
                      title={space.root}
                      onClick={() => onSelect(space.id)}
                    >
                      <span className="mem-row-name">{space.label}</span>
                      {place !== null && (
                        // The inner run is load-bearing: see `.mem-row-meta-text`.
                        <span className="mem-row-meta">
                          <span className="mem-row-meta-text">{place}</span>
                        </span>
                      )}
                      {shared !== null && (
                        <span className="mem-row-shared" title={space.sharedWith.join('\n')}>
                          {shared}
                        </span>
                      )}
                    </button>
                  </li>
                )
              })}
            </ul>
          </div>
        )
      })}
      <div className="mem-spaces-foot">
        <Button onClick={onRefresh} title="Find memory folders made since this page opened">
          Look again
        </Button>
      </div>
    </nav>
  )
}

function SpaceHead({ space }: { space: SpaceView }): ReactElement {
  const shared = sharedLine(space)
  return (
    <header className="mem-head">
      <h2 className="mem-title">{space.label}</h2>
      <p className="mem-path">{space.root}</p>
      {shared !== null && (
        <p className="mem-shared">
          {shared}, through a link that is already on disk: {space.sharedWith.join(', ')}. Notes written from any of them land here.
        </p>
      )}
      {space.accounts.length > 1 && <p className="mem-quiet">Read by the accounts {space.accounts.join(', ')}.</p>}
    </header>
  )
}

/* ----------------------------------------------------------------- notes -- */

function Labels({ note }: { note: NoteRowView }): ReactElement | null {
  const labels = note.labels.length > 0 ? note.labels : note.type !== null ? [{ key: 'type', value: note.type }] : []
  if (labels.length === 0) return null
  return (
    <span className="mem-labels">
      {labels.map((label) => (
        <span key={label.key} className="mem-label" data-key={label.key} title={label.key}>
          {label.key === 'verified' ? `verified ${label.value}` : label.value}
        </span>
      ))}
    </span>
  )
}

function NoteList({
  notes,
  dangling,
  onOpen,
  onGraph,
}: {
  notes: NoteRowView[]
  dangling: number
  onOpen(path: string): void
  onGraph(): void
}): ReactElement {
  if (notes.length === 0) return <p className="mem-quiet">No notes in this memory.</p>
  return (
    <>
      <ul className="mem-notes">
        {notes.map((note) => (
          <li key={note.path} className="mem-note">
            <button type="button" className="mem-note-button" onClick={() => onOpen(note.path)}>
              <span className="mem-note-head">
                <span className="mem-note-title">{note.title}</span>
                <Labels note={note} />
                <span className="mem-note-when">{dateOf(note.modifiedAt)}</span>
              </span>
              {note.description !== null && <span className="mem-note-description">{note.description}</span>}
              <span className="mem-note-path">{note.path}</span>
            </button>
          </li>
        ))}
      </ul>
      {dangling > 0 && (
        <p className="mem-quiet">
          {dangling} link{dangling === 1 ? '' : 's'} reach{dangling === 1 ? 'es' : ''} no note.{' '}
          <button type="button" className="mem-link" onClick={onGraph}>
            See which
          </button>
        </p>
      )}
    </>
  )
}

function SearchResults({
  hits,
  spaces,
  onOpen,
}: {
  hits: HitView[] | null
  spaces: SpaceView[]
  onOpen(spaceId: string, path: string): void
}): ReactElement {
  if (hits === null) return <p className="mem-quiet">Searching…</p>
  if (hits.length === 0) return <p className="mem-quiet">Nothing matches.</p>
  const labels = new Map(spaces.map((space) => [space.id, `${KIND_TITLE[space.kind]} · ${space.label}`]))
  return (
    <ul className="mem-notes" aria-label="Search results">
      {hits.map((hit) => (
        <li key={`${hit.spaceId}/${hit.path}`} className="mem-note">
          <button type="button" className="mem-note-button" onClick={() => onOpen(hit.spaceId, hit.path)}>
            <span className="mem-note-head">
              <span className="mem-note-title">{hit.title}</span>
              <span className="mem-note-when">{labels.get(hit.spaceId) ?? ''}</span>
            </span>
            <span className="mem-note-description">{hit.snippet}</span>
            <span className="mem-note-path">{hit.path}</span>
          </button>
        </li>
      ))}
    </ul>
  )
}

/* ------------------------------------------------------------------ note -- */

function NoteView({
  space,
  read,
  provenance,
  busy,
  message,
  actions,
}: MemoryPageBodyProps & { space: SpaceView }): ReactElement {
  const [confirming, setConfirming] = useState(false)
  const [indexLine, setIndexLine] = useState(false)
  const back = (
    <div className="mem-back">
      <Button onClick={actions.closeNote}>All notes</Button>
    </div>
  )
  if (read === undefined) {
    return (
      <>
        {back}
        <p className="mem-quiet">Reading…</p>
      </>
    )
  }
  if (!read.ok) {
    return (
      <>
        {back}
        <p className="mem-problem">{read.error}</p>
      </>
    )
  }
  const note = read.value
  const linked = note.links.filter((link) => link.to !== null)
  const nowhere = note.links.filter((link) => link.to === null)

  return (
    <article className="mem-open" aria-label={note.note.title}>
      {back}
      <header className="mem-head">
        <h2 className="mem-title">{note.note.title}</h2>
        <p className="mem-path">
          {space.label} · {note.path}
        </p>
        <Labels note={note.note} />
        {note.note.description !== null && <p className="mem-description">{note.note.description}</p>}
      </header>

      <FileEditor
        label={note.note.title}
        text={note.text}
        problem={null}
        effect={SAVE_EFFECT[space.kind]}
        saveBecause={note.truncated ? 'This note is larger than the page can show, so saving it here would cut it short.' : null}
        saving={busy}
        note={message}
        onSave={actions.save}
      >
        {!confirming && (
          <Button tone="danger" disabled={busy} onClick={() => setConfirming(true)}>
            Move to Trash
          </Button>
        )}
      </FileEditor>

      {confirming && (
        <div className="mem-confirm" role="group" aria-label="Move this note to the Trash">
          <p className="mem-confirm-text">Move “{note.note.title}” to the Trash? You can put it back from the Trash.</p>
          {note.indexed && (
            <label className="mem-check">
              <input type="checkbox" checked={indexLine} onChange={(event) => setIndexLine(event.target.checked)} />
              Also take its line out of MEMORY.md
            </label>
          )}
          <div className="settings-actions">
            <Button tone="danger" disabled={busy} onClick={() => actions.remove(note.indexed && indexLine)}>
              Move to Trash
            </Button>
            <Button disabled={busy} onClick={() => setConfirming(false)}>
              Keep it
            </Button>
          </div>
        </div>
      )}

      <section className="mem-section" aria-label="Links">
        <h3 className="mem-section-title">Links</h3>
        {linked.length === 0 && nowhere.length === 0 ? (
          <p className="mem-quiet">This note links to no other note.</p>
        ) : (
          <ul className="mem-links">
            {linked.map((link) => (
              <li key={link.target}>
                <button type="button" className="mem-link" onClick={() => actions.openNote(space.id, link.to as string)}>
                  {link.to}
                </button>
              </li>
            ))}
            {nowhere.map((link) => (
              <li key={link.target} className="mem-dangling">
                {link.target} <span className="mem-quiet-inline">— reaches no note</span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="mem-section" aria-label="Linked from">
        <h3 className="mem-section-title">Linked from</h3>
        {note.backlinks.length === 0 ? (
          <p className="mem-quiet">No note links here.</p>
        ) : (
          <ul className="mem-links">
            {note.backlinks.map((path) => (
              <li key={path}>
                <button type="button" className="mem-link" onClick={() => actions.openNote(space.id, path)}>
                  {path}
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>

      {space.kind === 'claude-project' && <Provenance provenance={provenance} onAsk={actions.provenance} />}
    </article>
  )
}

function Provenance({
  provenance,
  onAsk,
}: {
  provenance: Answer<ProvenanceView> | 'reading' | null
  onAsk(): void
}): ReactElement {
  return (
    <section className="mem-section" aria-label="Written by">
      <h3 className="mem-section-title">Written by</h3>
      {provenance === null ? (
        <div className="settings-actions">
          <Button onClick={onAsk} title="Reads this folder’s recent conversations for the calls that wrote this note">
            Find the conversations that wrote it
          </Button>
        </div>
      ) : provenance === 'reading' ? (
        <p className="mem-quiet">Reading this folder’s conversations…</p>
      ) : !provenance.ok ? (
        <p className="mem-problem">{provenance.error}</p>
      ) : (
        <>
          {provenance.value.writes.length === 0 ? (
            <p className="mem-quiet">None of the conversations read wrote this note.</p>
          ) : (
            <ul className="mem-writes">
              {provenance.value.writes.map((write) => (
                <li key={`${write.conversationId}-${write.at}-${write.tool}`} className="mem-write">
                  <span className="mem-write-when">{dateOf(write.at)}</span>
                  <span className="mem-write-what">
                    {write.action === 'edit' ? 'Edited' : 'Written'} in conversation {write.conversationId.slice(0, 8)}
                  </span>
                  <span className="mem-write-where">{write.folder}</span>
                </li>
              ))}
            </ul>
          )}
          <p className="mem-quiet">
            {provenance.value.conversationsRead} recent conversation{provenance.value.conversationsRead === 1 ? '' : 's'} read
            {provenance.value.truncated ? '; older ones were not.' : '.'}
          </p>
        </>
      )}
    </section>
  )
}

/* ----------------------------------------------------------------- graph -- */

const GRAPH_WIDTH = 800
const GRAPH_HEIGHT = 480
/** Above this many notes, names are on hover only — a page of overlapping words reads as nothing. */
const LABEL_LIMIT = 40

export function MemoryGraph({
  notes,
  graph,
  current = null,
  onOpen,
}: {
  notes: NoteRowView[]
  graph: GraphView
  current?: string | null
  onOpen(path: string): void
}): ReactElement {
  const positions = useMemo(
    () => layoutGraph(graph.nodes, graph.edges, { width: GRAPH_WIDTH, height: GRAPH_HEIGHT, margin: 32 }),
    [graph],
  )
  const titles = new Map(notes.map((note) => [note.path, note.title]))
  const degree = new Map<string, number>()
  for (const edge of graph.edges) {
    degree.set(edge.from, (degree.get(edge.from) ?? 0) + 1)
    degree.set(edge.to, (degree.get(edge.to) ?? 0) + 1)
  }
  const labelled = graph.nodes.length <= LABEL_LIMIT

  return (
    <div className="mem-graph-wrap">
      {graph.nodes.length === 0 ? (
        <p className="mem-quiet">No notes to draw.</p>
      ) : (
        <svg className="mem-graph" viewBox={`0 0 ${GRAPH_WIDTH} ${GRAPH_HEIGHT}`} role="group" aria-label="How the notes link">
          <g className="mem-graph-edges">
            {graph.edges.map((edge) => {
              const a = positions.get(edge.from)
              const b = positions.get(edge.to)
              if (a === undefined || b === undefined) return null
              return <line key={`${edge.from}\n${edge.to}`} x1={a.x} y1={a.y} x2={b.x} y2={b.y} />
            })}
          </g>
          {graph.nodes.map((path) => {
            const at = positions.get(path)
            if (at === undefined) return null
            const title = titles.get(path) ?? path
            const radius = 4 + Math.min(6, Math.sqrt(degree.get(path) ?? 0) * 1.6)
            return (
              <g
                key={path}
                className="mem-graph-node"
                data-current={path === current ? 'true' : undefined}
                transform={`translate(${at.x.toFixed(1)} ${at.y.toFixed(1)})`}
                role="button"
                tabIndex={0}
                aria-label={`Open ${title}`}
                onClick={() => onOpen(path)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter' || event.key === ' ') {
                    event.preventDefault()
                    onOpen(path)
                  }
                }}
              >
                <title>{title}</title>
                <circle r={radius} />
                {labelled && (
                  // A dot in the right half is labelled on its left, so the label stays in the frame.
                  <text x={at.x > GRAPH_WIDTH / 2 ? -(radius + 4) : radius + 4} y={4} textAnchor={at.x > GRAPH_WIDTH / 2 ? 'end' : 'start'}>
                    {title}
                  </text>
                )}
              </g>
            )
          })}
        </svg>
      )}
      <section className="mem-section" aria-label="Links that reach no note">
        <h3 className="mem-section-title">Links that reach no note</h3>
        {graph.dangling.length === 0 ? (
          <p className="mem-quiet">Every link reaches a note.</p>
        ) : (
          <ul className="mem-links">
            {graph.dangling.map((link) => (
              <li key={`${link.from}\n${link.target}`} className="mem-dangling">
                <button type="button" className="mem-link" onClick={() => onOpen(link.from)}>
                  {titles.get(link.from) ?? link.from}
                </button>{' '}
                <span className="mem-quiet-inline">links to</span> {link.target}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  )
}
