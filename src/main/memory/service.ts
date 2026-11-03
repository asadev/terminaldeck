import { watch, type FSWatcher } from 'chokidar'
import { lstat, open, readFile, readdir, realpath, stat } from 'node:fs/promises'
import { basename, dirname, isAbsolute, join, posix, relative, sep } from 'node:path'
import type { MemoryNote, MemorySearchHit } from '../../shared/agent-stack'
import { mayCarryFileWrite, parseToolTouches } from '../artifacts'
import { writeFileAtomic } from '../atomic-write'
import { appendCopilotAction, type CopilotPaths } from '../copilot-home'
import { isWithinRoot } from '../fs-tree'
import { isAbortError, streamLines } from '../session-search'
import { listTranscripts, projectPathSpellings, type TranscriptFile } from '../transcript'
import { backlinksOf, buildGraph, LinkResolver, noteLinks, type MemoryGraph } from './links'
import { parseNote } from './note'
import { claudeMemoryPathsFor, discoverSpaces, realDir, type DiscoverInput, type FoundSpace } from './spaces'
import { TextIndex } from './text-index'

/**
 * The agents' memory, read, linked, searchable and correctable — one service
 * behind the Memory page and the two memory tools.
 *
 * ## Built when asked, kept current by events
 *
 * Nothing is read at startup. A space is listed when the page or a tool asks
 * for the spaces, and its notes are read the first time somebody opens that
 * space or searches it. From then on a file watcher on that one folder keeps
 * the notes, the links and the search index current, note by note — no timer
 * re-reads anything. A space nobody has opened costs nothing.
 *
 * ## What a person may change, and the two refusals that keep it safe
 *
 * A note can be corrected in place and moved to the Trash. Both act only on a
 * Markdown file **inside a space this service found**, proven by its real path
 * — a `..`, an absolute path, or a link inside the folder that points out of it
 * is refused before anything is opened. And a save is refused when the file
 * changed after it was read (its time or size moved): an agent writing to its
 * own memory while somebody has the note open must not have that write quietly
 * replaced by a draft composed against the older text. Deleting goes to the
 * Trash through an injected function (Electron's `shell.trashItem` in the app),
 * never `rm`, and the matching line in `MEMORY.md` is removed only when the
 * person asks for that too.
 *
 * Nothing here creates a note. This is the view of an agent's memory and a way
 * to correct it, not a second author of it.
 */

/** Deepest folder level read inside a space. Codex nests one level (`rollout_summaries/`). */
const MAX_DEPTH = 4
/** Most notes read from one space. */
export const MAX_NOTES = 2000
/** How much of one note is read, and the most one may be saved as — the copilot pane's own number. */
export const MAX_NOTE_BYTES = 256 * 1024
/** How long a burst of file events is gathered before the page is told once. */
const CHANGE_DEBOUNCE_MS = 150
/** Conversations read to find who wrote a note, newest first. */
export const MAX_PROVENANCE_CONVERSATIONS = 60
const PROVENANCE_BUDGET_MS = 8_000
const DEADLINE_CHECK_LINES = 512

export interface MemoryDeps {
  /** Where to look: the account stores, Hoot's memory folder and `<userData>`. Asked at every discovery. */
  sources(): DiscoverInput
  /** Move a file to the Trash. `shell.trashItem` in the app. */
  trash(path: string): Promise<void>
  /** Hoot's paths, so an edit or delete of its memory lands in its action log as one from Settings does. */
  hootPaths?(): CopilotPaths | null
  /** A space's notes changed on disk. */
  onChanged?(spaceId: string): void
  /** Watch spaces once read. On in the app. */
  watch?: boolean
}

/** A front matter value shown as a small label beside a note. */
export interface NoteLabel {
  key: 'type' | 'kind' | 'status' | 'source' | 'verified'
  value: string
}

export interface NoteRow extends MemoryNote {
  labels: NoteLabel[]
}

/** What a save is checked against: the file as it was when it was read. */
export interface NoteVersion {
  modifiedAt: number
  bytes: number
}

export interface ResolvedLink {
  target: string
  /** The note it reaches, or null when it reaches nothing. */
  to: string | null
}

export type NoteRead =
  | {
      ok: true
      spaceId: string
      path: string
      text: string
      /** True when the file is larger than {@link MAX_NOTE_BYTES}; such a read cannot be saved back. */
      truncated: boolean
      version: NoteVersion
      note: NoteRow
      /** The flat front matter, as written. */
      front: Record<string, string>
      links: ResolvedLink[]
      backlinks: string[]
      /** True when the space's `MEMORY.md` has a line linking to this note. */
      indexed: boolean
    }
  | { ok: false; error: string }

export type ChangeResult = { ok: true; version: NoteVersion | null; indexLineRemoved: boolean } | { ok: false; error: string }

export interface NoteWrite {
  /** The conversation that wrote it — Claude Code names the transcript after it. */
  conversationId: string
  /** The project folder that conversation ran in, or its stored name. */
  folder: string
  at: number
  tool: string
  action: 'write' | 'edit'
}

export type ProvenanceResult =
  | { ok: true; writes: NoteWrite[]; conversationsRead: number; truncated: boolean }
  | { ok: false; error: string }

/** A refusal with a sentence a person or an agent can act on. */
export class MemoryRefusal extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'MemoryRefusal'
  }
}

interface Entry {
  row: NoteRow
  body: string
  front: Record<string, string>
}

interface SpaceIndex {
  space: FoundSpace
  entries: Map<string, Entry>
  graph: MemoryGraph | null
  watcher: FSWatcher | null
  ready: Promise<void>
}

const LABEL_KEYS: ReadonlyArray<NoteLabel['key']> = ['type', 'kind', 'status', 'source', 'verified']

/** `verified` arrives as a date or as epoch milliseconds; either is shown as a date. */
function labelValue(key: NoteLabel['key'], value: string): string {
  if (key === 'verified' && /^\d{12,}$/.test(value)) {
    return new Date(Number(value)).toISOString().slice(0, 10)
  }
  return value
}

function labelsOf(front: Record<string, string>): NoteLabel[] {
  const labels: NoteLabel[] = []
  for (const key of LABEL_KEYS) {
    const value = front[key]
    if (value !== undefined && value !== '') labels.push({ key, value: labelValue(key, value) })
  }
  return labels
}

function toPosix(path: string): string {
  return sep === '/' ? path : path.split(sep).join('/')
}

function docId(spaceId: string, path: string): string {
  return `${spaceId}\u0000${path}`
}

/** Up to `limit` bytes of a file, and whether there was more. */
async function readHead(path: string, limit: number): Promise<{ text: string; truncated: boolean }> {
  const handle = await open(path, 'r')
  try {
    const buffer = Buffer.alloc(limit + 1)
    const { bytesRead } = await handle.read(buffer, 0, limit + 1, 0)
    const truncated = bytesRead > limit
    return { text: buffer.subarray(0, Math.min(bytesRead, limit)).toString('utf8'), truncated }
  } finally {
    await handle.close()
  }
}

/**
 * The Markdown files in a space, as root-relative POSIX paths.
 *
 * A linked folder inside a space is not followed, and a linked file is kept
 * only when its real path is inside the space — a link out of somebody's memory
 * folder is not part of it.
 */
export async function listNoteFiles(root: string): Promise<string[]> {
  const found: string[] = []
  const walk = async (dir: string, depth: number): Promise<void> => {
    let entries
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (found.length >= MAX_NOTES) return
      if (entry.name.startsWith('.')) continue
      const full = join(dir, entry.name)
      if (entry.isDirectory()) {
        if (depth < MAX_DEPTH) await walk(full, depth + 1)
        continue
      }
      if (!/\.md$/i.test(entry.name)) continue
      if (entry.isSymbolicLink()) {
        try {
          const real = await realpath(full)
          if (!isWithinRoot(root, real) || !(await stat(real)).isFile()) continue
        } catch {
          continue
        }
      } else if (!entry.isFile()) {
        continue
      }
      found.push(toPosix(relative(root, full)))
    }
  }
  await walk(root, 1)
  return found
}

/**
 * A space-relative path to a note, proven to be inside the space, as its real
 * path. Throws {@link MemoryRefusal} with the reason otherwise.
 */
export async function notePath(root: string, path: unknown): Promise<string> {
  if (typeof path !== 'string' || path.trim() === '' || path.includes('\0')) {
    throw new MemoryRefusal('That is not a note in this memory.')
  }
  const written = path.replace(/\\/g, '/')
  if (isAbsolute(path) || written.startsWith('/') || /^[A-Za-z]:/.test(written)) {
    throw new MemoryRefusal('A note is named by its place inside the memory folder, not by a path on the disk.')
  }
  const normal = posix.normalize(written)
  if (normal === '..' || normal.startsWith('../') || normal.split('/').includes('..')) {
    throw new MemoryRefusal('That path leaves the memory folder.')
  }
  if (!/\.md$/i.test(normal)) throw new MemoryRefusal('Only Markdown notes can be opened here.')
  let real: string
  try {
    real = await realpath(join(root, normal))
  } catch {
    throw new MemoryRefusal('That note is no longer there — it may have been deleted while this was open.')
  }
  if (!isWithinRoot(root, real)) throw new MemoryRefusal('That note is a link to a file outside the memory folder.')
  return real
}

export class MemoryService {
  private found: FoundSpace[] | null = null
  private discovering: Promise<FoundSpace[]> | null = null
  private readonly indexes = new Map<string, SpaceIndex>()
  private readonly search = new TextIndex()
  private readonly timers = new Map<string, ReturnType<typeof setTimeout>>()
  private closed = false

  constructor(private readonly deps: MemoryDeps) {}

  /* ---------------------------------------------------------- spaces -- */

  /** Every space, discovered on first ask and again when `refresh` is set. */
  async spaces(refresh = false): Promise<FoundSpace[]> {
    if (!refresh && this.found !== null) return this.found
    if (this.discovering !== null) return this.discovering
    this.discovering = discoverSpaces(this.deps.sources())
      .then((spaces) => {
        this.found = spaces
        // A space that is gone stops being watched; one that is still there keeps its notes.
        for (const [id, index] of this.indexes) {
          const now = spaces.find((space) => space.id === id)
          if (now === undefined) this.drop(id)
          else index.space = now
        }
        return spaces
      })
      .finally(() => {
        this.discovering = null
      })
    return this.discovering
  }

  async space(id: string): Promise<FoundSpace> {
    const found = (await this.spaces()).find((space) => space.id === id)
    if (found === undefined) throw new MemoryRefusal('That memory is not on this machine any more.')
    return found
  }

  /**
   * The Claude memory a session in `cwd` under the store `configDir` reads, or
   * null when that folder has none yet. Asked again after one fresh discovery
   * when the folder is not among the spaces already found, because Claude Code
   * makes the folder the first time it remembers something.
   */
  async claudeSpaceFor(configDir: string, cwd: string): Promise<FoundSpace | null> {
    const roots: string[] = []
    for (const path of claudeMemoryPathsFor(configDir, projectPathSpellings(cwd))) {
      const root = await realDir(path)
      if (root !== null && !roots.includes(root)) roots.push(root)
    }
    if (roots.length === 0) return null
    const match = (spaces: FoundSpace[]): FoundSpace | null =>
      spaces.find((space) => space.kind === 'claude-project' && roots.includes(space.root)) ?? null
    return match(await this.spaces()) ?? match(await this.spaces(true))
  }

  /** The Codex memory under one Codex home, or null. */
  async codexSpaceFor(configDir: string): Promise<FoundSpace | null> {
    const root = await realDir(join(configDir, 'memories'))
    if (root === null) return null
    const match = (spaces: FoundSpace[]): FoundSpace | null =>
      spaces.find((space) => space.kind === 'codex' && space.root === root) ?? null
    return match(await this.spaces()) ?? match(await this.spaces(true))
  }

  /** Every space that serves one project folder: its Claude memory in every store, and its knowledge. */
  async spacesForProject(project: string): Promise<FoundSpace[]> {
    const spellings = new Set(projectPathSpellings(project))
    return (await this.spaces()).filter((space) => {
      if (space.kind === 'knowledge') return space.project !== null && spellings.has(space.project)
      if (space.kind !== 'claude-project') return false
      return space.members.some((member) => member.project !== null && spellings.has(member.project))
    })
  }

  async hootSpace(): Promise<FoundSpace | null> {
    return (await this.spaces()).find((space) => space.kind === 'hoot') ?? null
  }

  /* ----------------------------------------------------------- notes -- */

  /** The notes of one space, newest first. Reads the space the first time. */
  async notes(spaceId: string): Promise<NoteRow[]> {
    const index = await this.indexOf(spaceId)
    return [...index.entries.values()].map((entry) => entry.row).sort((a, b) => b.modifiedAt - a.modifiedAt || a.path.localeCompare(b.path))
  }

  /** Nodes, the links that reached a note, and the ones that reached nothing. */
  async graph(spaceId: string): Promise<MemoryGraph> {
    return this.graphOf(await this.indexOf(spaceId))
  }

  async read(spaceId: string, path: unknown): Promise<NoteRead> {
    try {
      const index = await this.indexOf(spaceId)
      const real = await notePath(index.space.root, path)
      const rel = toPosix(relative(index.space.root, real))
      const info = await stat(real)
      if (!info.isFile()) throw new MemoryRefusal('That is not a note in this memory.')
      const { text, truncated } = await readHead(real, MAX_NOTE_BYTES)
      const entry = this.entryFor(index.space.id, rel, text, info.mtimeMs, info.size)
      index.entries.set(rel, entry)
      this.search.put({ id: docId(index.space.id, rel), title: titleText(entry.row), body: entry.body })
      index.graph = null
      const graph = this.graphOf(index)
      const resolver = new LinkResolver([...index.entries.values()].map((one) => one.row))
      return {
        ok: true,
        spaceId: index.space.id,
        path: rel,
        text,
        truncated,
        version: { modifiedAt: info.mtimeMs, bytes: info.size },
        note: entry.row,
        front: entry.front,
        links: entry.row.links.map((target) => ({ target, to: resolver.resolve(rel, target) })),
        backlinks: backlinksOf(graph, rel),
        indexed: (await this.indexLines(index, rel)).length > 0,
      }
    } catch (error) {
      return { ok: false, error: messageOf(error) }
    }
  }

  /**
   * Search the given spaces, best first. Each is read the first time it is
   * searched; a space not in `spaceIds` is never matched, whatever it holds.
   */
  async searchIn(query: string, spaceIds: readonly string[], limit = 20): Promise<MemorySearchHit[]> {
    const allowed = new Set<string>()
    for (const id of spaceIds) {
      try {
        allowed.add((await this.indexOf(id)).space.id)
      } catch {
        // A space that is gone has nothing to find.
      }
    }
    if (allowed.size === 0) return []
    return this.search
      .search(query, { limit, filter: (id) => allowed.has(id.slice(0, id.indexOf('\u0000'))) })
      .map((hit) => {
        const at = hit.id.indexOf('\u0000')
        const spaceId = hit.id.slice(0, at)
        const path = hit.id.slice(at + 1)
        const row = this.indexes.get(spaceId)?.entries.get(path)?.row
        return { spaceId, path, title: row?.title ?? path, score: hit.score, snippet: hit.snippet }
      })
  }

  /* ---------------------------------------------------------- change -- */

  /** Correct one note in place, if it is still the file that was read. */
  async save(spaceId: string, path: unknown, text: unknown, expected: unknown): Promise<ChangeResult> {
    try {
      const index = await this.indexOf(spaceId)
      if (typeof text !== 'string') throw new MemoryRefusal('Nothing was supplied to save.')
      if (Buffer.byteLength(text, 'utf8') > MAX_NOTE_BYTES) {
        throw new MemoryRefusal(`A note cannot be larger than ${Math.round(MAX_NOTE_BYTES / 1024)} KB.`)
      }
      const real = await notePath(index.space.root, path)
      const info = await stat(real)
      if (!info.isFile()) throw new MemoryRefusal('That is not a note in this memory.')
      const version = asVersion(expected)
      if (version === null || version.modifiedAt !== info.mtimeMs || version.bytes !== info.size) {
        throw new MemoryRefusal('This note changed after you opened it, so nothing was saved. Open it again to see what is there now.')
      }
      writeFileAtomic(real, text)
      const after = await stat(real)
      const rel = toPosix(relative(index.space.root, real))
      this.note(index, rel, text, after.mtimeMs, after.size)
      this.logHoot(index.space, 'memory.edited', `you edited memory/${rel} from the Memory page`)
      return { ok: true, version: { modifiedAt: after.mtimeMs, bytes: after.size }, indexLineRemoved: false }
    } catch (error) {
      return { ok: false, error: messageOf(error) }
    }
  }

  /**
   * Move one note to the Trash and, only when asked, take its line out of the
   * space's `MEMORY.md`.
   */
  async remove(spaceId: string, path: unknown, options: { indexLine?: boolean } = {}): Promise<ChangeResult> {
    try {
      const index = await this.indexOf(spaceId)
      const real = await notePath(index.space.root, path)
      if (!(await lstat(real)).isFile()) throw new MemoryRefusal('That is not a note in this memory.')
      const rel = toPosix(relative(index.space.root, real))
      // Found before the note goes, while its links still resolve to it.
      const lines = options.indexLine === true ? await this.indexLines(index, rel) : []
      await this.deps.trash(real)
      index.entries.delete(rel)
      this.search.remove(docId(index.space.id, rel))
      index.graph = null
      let removed = false
      if (lines.length > 0) removed = await this.dropIndexLines(index, lines)
      this.logHoot(index.space, 'memory.deleted', `you moved memory/${rel} to the Trash from the Memory page`)
      return { ok: true, version: null, indexLineRemoved: removed }
    } catch (error) {
      return { ok: false, error: messageOf(error) }
    }
  }

  /* ------------------------------------------------------ provenance -- */

  /**
   * Which conversations wrote or edited one Claude memory note.
   *
   * Asked for, never run on its own: it reads the `Write` and `Edit` calls in
   * the transcripts of the folders that reach this memory — the owner and every
   * folder linked to it — newest first, at most
   * {@link MAX_PROVENANCE_CONVERSATIONS} of them and for at most eight seconds,
   * with the parser the Artifacts page uses (`parseToolTouches`). A call is
   * matched by the real path of the file it wrote, so a write made through a
   * linked folder or another account's spelling of the store still counts.
   */
  async provenance(spaceId: string, path: unknown, signal?: AbortSignal): Promise<ProvenanceResult> {
    try {
      const space = await this.space(spaceId)
      if (space.kind !== 'claude-project') {
        throw new MemoryRefusal('Only Claude Code memory is written by conversations this app can read back.')
      }
      const real = await notePath(space.root, path)
      const target = basename(real)
      const targetDir = dirname(real)

      const folders = new Map<string, string>()
      for (const projectsDir of space.projectsDirs) {
        for (const member of space.members) {
          const dir = (await realDir(join(projectsDir, member.folder))) ?? join(projectsDir, member.folder)
          if (!folders.has(dir)) folders.set(dir, member.project ?? member.folder)
        }
      }
      const files: Array<TranscriptFile & { folder: string }> = []
      for (const [dir, folder] of folders) {
        for (const file of await listTranscripts(dir)) files.push({ ...file, folder })
      }
      files.sort((a, b) => b.modifiedAt - a.modifiedAt)
      const chosen = files.slice(0, MAX_PROVENANCE_CONVERSATIONS)
      let truncated = files.length > chosen.length

      const deadline = Date.now() + PROVENANCE_BUDGET_MS
      const dirs = new Map<string, string | null>()
      const writes: NoteWrite[] = []
      let read = 0
      for (const file of chosen) {
        if (Date.now() > deadline) {
          truncated = true
          break
        }
        let lines = 0
        for await (const line of streamLines(file.path, signal)) {
          lines += 1
          if (lines % DEADLINE_CHECK_LINES === 0 && Date.now() > deadline) {
            truncated = true
            break
          }
          if (!line.includes(target) || !mayCarryFileWrite(line)) continue
          for (const touch of parseToolTouches(line)) {
            if (basename(touch.path) !== target) continue
            const written = dirname(touch.path)
            if (!dirs.has(written)) dirs.set(written, await realDir(written))
            if (dirs.get(written) !== targetDir) continue
            writes.push({
              conversationId: file.sessionId,
              folder: file.folder,
              at: touch.at > 0 ? touch.at : file.modifiedAt,
              tool: touch.tool,
              action: touch.action,
            })
          }
        }
        read += 1
      }
      writes.sort((a, b) => b.at - a.at)
      return { ok: true, writes: writes.slice(0, 50), conversationsRead: read, truncated }
    } catch (error) {
      if (isAbortError(error)) return { ok: false, error: 'Stopped.' }
      return { ok: false, error: messageOf(error) }
    }
  }

  /* ---------------------------------------------------------- closing -- */

  async close(): Promise<void> {
    this.closed = true
    for (const timer of this.timers.values()) clearTimeout(timer)
    this.timers.clear()
    await Promise.all([...this.indexes.keys()].map((id) => this.drop(id)))
  }

  /* --------------------------------------------------------- internals -- */

  private async indexOf(spaceId: string): Promise<SpaceIndex> {
    const existing = this.indexes.get(spaceId)
    if (existing !== undefined) {
      await existing.ready
      return existing
    }
    const space = await this.space(spaceId)
    const index: SpaceIndex = { space, entries: new Map(), graph: null, watcher: null, ready: Promise.resolve() }
    index.ready = this.build(index)
    this.indexes.set(spaceId, index)
    await index.ready
    return index
  }

  private async build(index: SpaceIndex): Promise<void> {
    for (const rel of await listNoteFiles(index.space.root)) await this.refreshNote(index, rel)
    if (this.deps.watch === true && !this.closed) this.startWatching(index)
  }

  private startWatching(index: SpaceIndex): void {
    const root = index.space.root
    const watcher = watch(root, { ignoreInitial: true, depth: MAX_DEPTH, followSymlinks: false, persistent: true })
    index.watcher = watcher
    const changed = (full: string): void => {
      if (!/\.md$/i.test(full)) return
      const rel = toPosix(relative(root, full))
      if (rel.startsWith('..') || rel.split('/').some((part) => part.startsWith('.'))) return
      void this.refreshNote(index, rel).then(() => this.announce(index.space.id))
    }
    watcher.on('add', changed)
    watcher.on('change', changed)
    watcher.on('unlink', changed)
    watcher.on('error', (error: unknown) => {
      // A memory folder that stopped being watched is a page that stops being
      // live; it must not be silent, and it must not take the app down.
      console.error('[memory] a memory folder could not be watched:', error)
    })
  }

  /** Read one note again, or forget it when it is gone. */
  private async refreshNote(index: SpaceIndex, rel: string): Promise<void> {
    const full = join(index.space.root, rel)
    try {
      const info = await stat(full)
      const real = await realpath(full)
      if (!info.isFile() || !isWithinRoot(index.space.root, real)) throw new Error('not a note')
      const { text } = await readHead(real, MAX_NOTE_BYTES)
      this.note(index, rel, text, info.mtimeMs, info.size)
    } catch {
      index.entries.delete(rel)
      this.search.remove(docId(index.space.id, rel))
      index.graph = null
    }
  }

  private note(index: SpaceIndex, rel: string, text: string, modifiedAt: number, bytes: number): void {
    const entry = this.entryFor(index.space.id, rel, text, modifiedAt, bytes)
    index.entries.set(rel, entry)
    this.search.put({ id: docId(index.space.id, rel), title: titleText(entry.row), body: entry.body })
    index.graph = null
  }

  private entryFor(spaceId: string, rel: string, text: string, modifiedAt: number, bytes: number): Entry {
    const parsed = parseNote(text, rel)
    const front = parsed.data
    return {
      body: parsed.body,
      front,
      row: {
        spaceId,
        path: rel,
        title: parsed.title,
        name: parsed.name,
        description: front.description ?? null,
        type: front.type ?? front.kind ?? null,
        links: noteLinks(parsed.body),
        modifiedAt,
        bytes,
        labels: labelsOf(front),
      },
    }
  }

  private graphOf(index: SpaceIndex): MemoryGraph {
    if (index.graph === null) index.graph = buildGraph([...index.entries.values()].map((entry) => entry.row))
    return index.graph
  }

  /** The 0-based lines of the space's `MEMORY.md` whose links reach `rel`. */
  private async indexLines(index: SpaceIndex, rel: string): Promise<number[]> {
    const indexPath = this.indexNote(index)
    if (indexPath === null || indexPath === rel) return []
    let text: string
    try {
      text = await readFile(await notePath(index.space.root, indexPath), 'utf8')
    } catch {
      return []
    }
    const resolver = new LinkResolver([...index.entries.values()].map((entry) => entry.row))
    const hits: number[] = []
    text.split('\n').forEach((line, at) => {
      if (noteLinks(line).some((target) => resolver.resolve(indexPath, target) === rel)) hits.push(at)
    })
    return hits
  }

  private async dropIndexLines(index: SpaceIndex, lines: readonly number[]): Promise<boolean> {
    const indexPath = this.indexNote(index)
    if (indexPath === null) return false
    const real = await notePath(index.space.root, indexPath)
    const text = await readFile(real, 'utf8')
    const drop = new Set(lines)
    const kept = text.split('\n').filter((_, at) => !drop.has(at))
    const next = kept.join('\n')
    if (next === text) return false
    writeFileAtomic(real, next)
    const info = await stat(real)
    this.note(index, indexPath, next, info.mtimeMs, info.size)
    return true
  }

  /** The space's index note, `MEMORY.md` at its root, whatever its case. */
  private indexNote(index: SpaceIndex): string | null {
    for (const rel of index.entries.keys()) if (rel.toLowerCase() === 'memory.md') return rel
    return null
  }

  private logHoot(space: FoundSpace, action: string, detail: string): void {
    if (space.kind !== 'hoot') return
    const paths = this.deps.hootPaths?.() ?? null
    if (paths !== null) appendCopilotAction(paths, { action, detail })
  }

  private announce(spaceId: string): void {
    if (this.closed || this.deps.onChanged === undefined) return
    const pending = this.timers.get(spaceId)
    if (pending !== undefined) clearTimeout(pending)
    this.timers.set(
      spaceId,
      setTimeout(() => {
        this.timers.delete(spaceId)
        if (!this.closed) this.deps.onChanged?.(spaceId)
      }, CHANGE_DEBOUNCE_MS),
    )
  }

  private async drop(spaceId: string): Promise<void> {
    const index = this.indexes.get(spaceId)
    if (index === undefined) return
    this.indexes.delete(spaceId)
    for (const rel of index.entries.keys()) this.search.remove(docId(spaceId, rel))
    const watcher = index.watcher
    index.watcher = null
    if (watcher !== null) await watcher.close()
  }
}

function titleText(row: NoteRow): string {
  return row.description === null ? row.title : `${row.title} ${row.description}`
}

function asVersion(value: unknown): NoteVersion | null {
  if (typeof value !== 'object' || value === null) return null
  const { modifiedAt, bytes } = value as Record<string, unknown>
  if (typeof modifiedAt !== 'number' || typeof bytes !== 'number') return null
  return { modifiedAt, bytes }
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
