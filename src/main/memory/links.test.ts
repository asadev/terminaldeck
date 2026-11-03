import { describe, expect, it } from 'vitest'
import { backlinksOf, buildGraph, LinkResolver, markdownLinksIn, noteLinks, type LinkableNote } from './links'

function note(path: string, links: string[], name: string | null = null): LinkableNote {
  return { path, name, links }
}

describe('reading links out of a note', () => {
  it('reads both spellings — wiki links and Markdown links to notes beside it', () => {
    const body = [
      'See [[deploy-rules|the rules]] and [[testflight#steps]].',
      '- [Keep the build open](feedback_keep_open.md) — always',
      '- [Site](https://example.com/page.md) is not a note, nor is [top](#heading)',
      '- ![picture](diagram.md) is an image, not a link',
      '- [Spaced](my%20note.md)',
    ].join('\n')
    expect(noteLinks(body)).toEqual(['deploy-rules', 'testflight', 'feedback_keep_open.md', 'my note.md'])
  })

  it('keeps only links that end in .md', () => {
    expect(markdownLinksIn('[a](notes.txt) [b](other.md#x) [c](/abs/path.md)')).toEqual(['other.md'])
  })
})

describe('resolving a link inside one space', () => {
  const notes = [
    note('MEMORY.md', []),
    note('feedback_deploy.md', [], 'deploy-rules'),
    note('sub/testflight.md', []),
    note('sub/Readme.md', []),
    note('Readme.md', []),
  ]
  const resolver = new LinkResolver(notes)

  it('finds a note by its front matter name, case-insensitively', () => {
    expect(resolver.resolve('MEMORY.md', 'Deploy-Rules')).toBe('feedback_deploy.md')
  })

  it('finds a note by its file name, with or without .md', () => {
    expect(resolver.resolve('MEMORY.md', 'testflight')).toBe('sub/testflight.md')
    expect(resolver.resolve('MEMORY.md', 'feedback_deploy.md')).toBe('feedback_deploy.md')
  })

  it('reads a relative Markdown link from the linking note’s own folder', () => {
    expect(resolver.resolve('sub/testflight.md', 'Readme.md')).toBe('sub/Readme.md')
    expect(resolver.resolve('MEMORY.md', 'sub/testflight.md')).toBe('sub/testflight.md')
  })

  it('prefers the note beside the linking one when two share a name', () => {
    expect(resolver.resolve('sub/testflight.md', 'readme')).toBe('sub/Readme.md')
    expect(resolver.resolve('MEMORY.md', 'readme')).toBe('Readme.md')
  })

  it('never leaves the space: a link out of it reaches nothing', () => {
    expect(resolver.resolve('MEMORY.md', '../other-project/memory/MEMORY.md')).toBeNull()
    expect(resolver.resolve('MEMORY.md', 'nowhere')).toBeNull()
  })
})

describe('the graph', () => {
  const notes = [
    note('MEMORY.md', ['a.md', 'b.md', 'gone.md']),
    note('a.md', ['b', 'b.md', 'a', 'missing-name']),
    note('b.md', []),
  ]

  it('draws an edge only for a link that reached a note — once, and never to itself', () => {
    const graph = buildGraph(notes)
    expect(graph.nodes.map((node) => node.path)).toEqual(['MEMORY.md', 'a.md', 'b.md'])
    expect(graph.edges).toEqual([
      { from: 'MEMORY.md', to: 'a.md' },
      { from: 'MEMORY.md', to: 'b.md' },
      { from: 'a.md', to: 'b.md' },
    ])
  })

  it('lists every link that reached nothing, and draws none of them', () => {
    const graph = buildGraph(notes)
    expect(graph.dangling).toEqual([
      { from: 'MEMORY.md', target: 'gone.md' },
      { from: 'a.md', target: 'missing-name' },
    ])
    for (const edge of graph.edges) expect(notes.map((one) => one.path)).toContain(edge.to)
  })

  it('answers backlinks from the edges', () => {
    expect(backlinksOf(buildGraph(notes), 'b.md')).toEqual(['MEMORY.md', 'a.md'])
    expect(backlinksOf(buildGraph(notes), 'MEMORY.md')).toEqual([])
  })
})
