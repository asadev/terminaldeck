import { posix } from 'node:path'
import { linksIn } from './note'

/**
 * How the notes of one memory space point at each other: which link reaches
 * which note, which notes point back, and which links reach nothing.
 *
 * ## Two spellings of a link, both real
 *
 * `[[name]]` is the one the shared note reader knows, and it is what Claude
 * Code's own memory files use between notes. The other is an ordinary Markdown
 * link to a file beside it — `[Title](feedback_x.md)` — which is how every
 * `MEMORY.md` index on this machine is written. Reading only the first would
 * draw every index as an island with no edges, when the index is the most
 * connected note in the space. So both are read, and nothing else: a link with
 * a scheme (`https:`), an anchor on its own page, or a path that does not end in
 * `.md` is not a link between notes.
 *
 * ## How a target is found
 *
 * Inside its own space only — a link never reaches into another agent's
 * memory, whatever it says. A target with a `/` in it is a path: from the
 * linking note's folder, then from the space root, and nothing else. A bare
 * target is the front matter `name` a note declares, then a file name anywhere
 * in the space, preferring one beside the linking note when two share a name —
 * except a bare `x.md`, which names a file and skips the names. All of it
 * case-insensitive, the way the file systems these folders sit on are by
 * default. A target matching none is **dangling**, and dangling links are
 * listed, never drawn.
 */

export interface LinkableNote {
  /** Path relative to the space root, `/`-separated. */
  path: string
  /** Front matter `name`, or null. */
  name: string | null
  /** Link targets as written. */
  links: readonly string[]
}

export interface GraphEdge {
  from: string
  to: string
}

export interface DanglingLink {
  /** The note the link is in. */
  from: string
  /** The target as written. */
  target: string
}

export interface MemoryGraph {
  nodes: Array<{ path: string }>
  /** Only links that reached a note. Never a self-link, never twice. */
  edges: GraphEdge[]
  dangling: DanglingLink[]
}

const MARKDOWN_LINK = /(?<!!)\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g
const SCHEME = /^[a-z][a-z0-9+.-]*:/i

/** Links to other Markdown files beside this one, as written, without `#heading`. */
export function markdownLinksIn(text: string): string[] {
  const seen = new Set<string>()
  for (const match of text.matchAll(MARKDOWN_LINK)) {
    let href = match[1].split('#')[0].trim()
    if (href === '' || SCHEME.test(href) || href.startsWith('/')) continue
    try {
      href = decodeURIComponent(href)
    } catch {
      // A stray `%` is a literal one; keep the link as it was written.
    }
    if (!/\.md$/i.test(href)) continue
    seen.add(href)
  }
  return [...seen]
}

/** Every link a note body makes, both spellings, de-duplicated, wiki links first. */
export function noteLinks(body: string): string[] {
  return [...new Set([...linksIn(body), ...markdownLinksIn(body)])]
}

function stem(path: string): string {
  return path.replace(/\.md$/i, '').toLowerCase()
}

/** Resolves link targets against the notes of one space. */
export class LinkResolver {
  private readonly paths = new Map<string, string>()
  private readonly names = new Map<string, string>()
  private readonly bare = new Map<string, string[]>()

  constructor(notes: Iterable<LinkableNote>) {
    for (const note of [...notes].sort((a, b) => a.path.localeCompare(b.path))) {
      this.paths.set(stem(note.path), note.path)
      if (note.name !== null && !this.names.has(note.name.toLowerCase())) {
        this.names.set(note.name.toLowerCase(), note.path)
      }
      const base = stem(posix.basename(note.path))
      this.bare.set(base, [...(this.bare.get(base) ?? []), note.path])
    }
  }

  /** The note a link in `from` reaches, or null when it reaches nothing in this space. */
  resolve(from: string, target: string): string | null {
    const written = target.trim().replace(/\\/g, '/')
    if (written === '') return null
    // A path is a path: from the linking note's folder, then from the root, and
    // never by its last segment — a link written to point out of the space
    // reaches nothing rather than a namesake inside it.
    if (written.includes('/')) {
      for (const candidate of [posix.join(posix.dirname(from), written), written]) {
        const normal = posix.normalize(candidate)
        if (normal === '..' || normal.startsWith('../')) continue
        const hit = this.paths.get(stem(normal))
        if (hit !== undefined) return hit
      }
      return null
    }
    // A bare `x.md` names a file; a bare `x` is a name first, then a file.
    if (!/\.md$/i.test(written)) {
      const named = this.names.get(written.toLowerCase())
      if (named !== undefined) return named
    }
    const candidates = this.bare.get(stem(written))
    if (candidates === undefined || candidates.length === 0) return null
    const beside = candidates.find((path) => posix.dirname(path) === posix.dirname(from))
    return beside ?? candidates[0]
  }
}

/** The graph of one space: a node per note, an edge per link that reached one. */
export function buildGraph(unordered: readonly LinkableNote[]): MemoryGraph {
  // By path, so the same notes draw the same graph whichever order they were read in.
  const notes = [...unordered].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))
  const resolver = new LinkResolver(notes)
  const edges: GraphEdge[] = []
  const seen = new Set<string>()
  const dangling: DanglingLink[] = []
  for (const note of notes) {
    for (const target of note.links) {
      const to = resolver.resolve(note.path, target)
      if (to === null) {
        dangling.push({ from: note.path, target })
        continue
      }
      const key = `${note.path}\n${to}`
      if (to === note.path || seen.has(key)) continue
      seen.add(key)
      edges.push({ from: note.path, to })
    }
  }
  return { nodes: notes.map((note) => ({ path: note.path })), edges, dangling }
}

/** Notes whose links reach `path`, sorted. */
export function backlinksOf(graph: MemoryGraph, path: string): string[] {
  return [...new Set(graph.edges.filter((edge) => edge.to === path).map((edge) => edge.from))].sort()
}
