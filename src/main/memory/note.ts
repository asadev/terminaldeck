import { basename } from 'node:path'
import { parseFrontMatter } from '../copilot-inspect'

/**
 * One markdown memory note, read: its flat front matter, its body, the
 * `[[links]]` it makes, and the name a link to it would use.
 *
 * The front matter reader is the copilot's own (`parseFrontMatter`) — flat
 * `key: value` lines, never a YAML parser — so every part of the app reads a
 * memory file the same way.
 */
export interface ParsedNote {
  data: Record<string, string>
  body: string
  /** Front matter `name`, else null. */
  name: string | null
  /** `name`, else the first `# heading`, else the file name. */
  title: string
  /** Link targets in order, without `|alias` or `#heading`, de-duplicated. */
  links: string[]
}

const LINK = /\[\[([^\]\n]+?)\]\]/g

export function linksIn(text: string): string[] {
  const seen = new Set<string>()
  for (const match of text.matchAll(LINK)) {
    const target = match[1].split('|')[0].split('#')[0].trim()
    if (target !== '') seen.add(target)
  }
  return [...seen]
}

/** The body after a front matter block, or the whole text when it has none. */
export function bodyOf(text: string): string {
  if (!text.startsWith('---')) return text
  const end = text.indexOf('\n---', 3)
  if (end < 0) return text
  const after = text.indexOf('\n', end + 4)
  return after < 0 ? '' : text.slice(after + 1)
}

export function parseNote(text: string, file: string): ParsedNote {
  const data = parseFrontMatter(text)
  const body = bodyOf(text)
  const name = data.name?.trim() ? data.name.trim() : null
  const heading = /^#\s+(.+)$/m.exec(body)?.[1]?.trim()
  return {
    data,
    body,
    name,
    title: name ?? heading ?? basename(file).replace(/\.md$/i, ''),
    links: linksIn(body),
  }
}
