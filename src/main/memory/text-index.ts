/**
 * A small full-text index: words in, ranked documents out.
 *
 * In memory and in TypeScript on purpose. The memory this serves is a few
 * hundred notes and a couple of megabytes; ranking all of it is a millisecond,
 * it runs the same in the window, the headless host and a test, and it adds no
 * native module. The `better-sqlite3` this app ships is built for Electron and
 * does not load under a plain Node test runner, so an index on it could only be
 * tested by mocking the thing being tested. BM25 is the standard lexical
 * ranking; nothing here guesses at meaning, and nothing leaves the machine.
 */

export interface IndexedDoc {
  id: string
  /** Weighted above the body. */
  title: string
  body: string
}

export interface TextHit {
  id: string
  score: number
  snippet: string
}

const K1 = 1.2
const B = 0.75
const TITLE_WEIGHT = 3
const SNIPPET_CHARS = 160

/** Lower-case words of letters and digits, in any script. */
export function tokens(text: string): string[] {
  return text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []
}

interface Entry {
  doc: IndexedDoc
  /** Term → weighted frequency in this document. */
  freq: Map<string, number>
  length: number
}

export class TextIndex {
  private readonly docs = new Map<string, Entry>()
  /** Term → ids of documents containing it. */
  private readonly postings = new Map<string, Set<string>>()
  private totalLength = 0

  get size(): number {
    return this.docs.size
  }

  has(id: string): boolean {
    return this.docs.has(id)
  }

  /** Add or replace a document. */
  put(doc: IndexedDoc): void {
    this.remove(doc.id)
    const freq = new Map<string, number>()
    for (const term of tokens(doc.title)) freq.set(term, (freq.get(term) ?? 0) + TITLE_WEIGHT)
    for (const term of tokens(doc.body)) freq.set(term, (freq.get(term) ?? 0) + 1)
    let length = 0
    for (const [term, count] of freq) {
      length += count
      let ids = this.postings.get(term)
      if (!ids) this.postings.set(term, (ids = new Set()))
      ids.add(doc.id)
    }
    this.docs.set(doc.id, { doc, freq, length })
    this.totalLength += length
  }

  remove(id: string): void {
    const entry = this.docs.get(id)
    if (!entry) return
    for (const term of entry.freq.keys()) {
      const ids = this.postings.get(term)
      ids?.delete(id)
      if (ids && ids.size === 0) this.postings.delete(term)
    }
    this.totalLength -= entry.length
    this.docs.delete(id)
  }

  /**
   * Rank documents by BM25 over the query's words. The last word also matches
   * as a prefix, so a search box answers while the word is half typed.
   * `filter` keeps only ids it accepts — how a caller holds a search to a scope.
   */
  search(query: string, options: { limit?: number; filter?: (id: string) => boolean } = {}): TextHit[] {
    const words = tokens(query)
    if (words.length === 0 || this.docs.size === 0) return []
    const limit = options.limit ?? 20
    const avg = this.totalLength / this.docs.size
    const scores = new Map<string, number>()
    words.forEach((word, i) => {
      const terms = i === words.length - 1 ? this.expand(word) : this.postings.has(word) ? [word] : []
      for (const term of terms) {
        const ids = this.postings.get(term)
        if (!ids) continue
        const idf = Math.log(1 + (this.docs.size - ids.size + 0.5) / (ids.size + 0.5))
        for (const id of ids) {
          if (options.filter && !options.filter(id)) continue
          const entry = this.docs.get(id) as Entry
          const f = entry.freq.get(term) ?? 0
          const score = (idf * f * (K1 + 1)) / (f + K1 * (1 - B + (B * entry.length) / avg))
          scores.set(id, (scores.get(id) ?? 0) + score)
        }
      }
    })
    return [...scores.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, limit)
      .map(([id, score]) => ({ id, score, snippet: snippetOf((this.docs.get(id) as Entry).doc.body, words) }))
  }

  private expand(word: string): string[] {
    if (this.postings.has(word) && word.length < 3) return [word]
    const out: string[] = []
    for (const term of this.postings.keys()) if (term.startsWith(word)) out.push(term)
    return out
  }
}

/** A line of the body around the first query word, on one line. */
export function snippetOf(body: string, words: readonly string[]): string {
  const flat = body.replace(/\s+/g, ' ').trim()
  const lower = flat.toLowerCase()
  let at = -1
  for (const word of words) {
    at = lower.indexOf(word)
    if (at >= 0) break
  }
  if (at < 0) return flat.slice(0, SNIPPET_CHARS)
  const start = Math.max(0, at - 40)
  const text = flat.slice(start, start + SNIPPET_CHARS)
  return `${start > 0 ? '…' : ''}${text}${start + SNIPPET_CHARS < flat.length ? '…' : ''}`
}
