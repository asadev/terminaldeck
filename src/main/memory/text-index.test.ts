import { describe, expect, it } from 'vitest'
import { TextIndex, snippetOf, tokens } from './text-index'
import { bodyOf, linksIn, parseNote } from './note'

describe('the full-text index', () => {
  const index = new TextIndex()
  index.put({ id: 'keychain', title: 'Keychain access', body: 'The vault keeps logins encrypted with safeStorage.' })
  index.put({ id: 'relay', title: 'Relay server', body: 'The relay is the network; never Tailscale.' })
  index.put({ id: 'vault', title: 'Account vault', body: 'One vault per machine. The vault file is account-vault.bin.' })

  it('ranks a document whose title holds the word above one that only mentions it', () => {
    const hits = index.search('vault')
    expect(hits.map((hit) => hit.id)).toEqual(['vault', 'keychain'])
    expect(hits[0].score).toBeGreaterThan(hits[1].score)
  })

  it('matches the last word as a prefix, so a half-typed search answers', () => {
    expect(index.search('tailsc').map((hit) => hit.id)).toEqual(['relay'])
  })

  it('holds a search to a scope', () => {
    expect(index.search('vault', { filter: (id) => id !== 'vault' }).map((hit) => hit.id)).toEqual(['keychain'])
  })

  it('forgets a replaced or removed document', () => {
    const local = new TextIndex()
    local.put({ id: 'a', title: 'one', body: 'alpha' })
    local.put({ id: 'a', title: 'one', body: 'beta' })
    expect(local.search('alpha')).toEqual([])
    expect(local.search('beta').map((hit) => hit.id)).toEqual(['a'])
    local.remove('a')
    expect(local.size).toBe(0)
    expect(local.search('beta')).toEqual([])
  })

  it('answers nothing for an empty query or index', () => {
    expect(index.search('   ')).toEqual([])
    expect(new TextIndex().search('vault')).toEqual([])
  })

  it('reads words in any script', () => {
    expect(tokens('Grüße, 東京 2026!')).toEqual(['grüße', '東京', '2026'])
  })

  it('cuts a snippet around the first match', () => {
    const body = `${'x '.repeat(80)}the needle is here ${'y '.repeat(80)}`
    const snippet = snippetOf(body, ['needle'])
    expect(snippet).toContain('needle')
    expect(snippet.startsWith('…')).toBe(true)
  })
})

describe('reading a memory note', () => {
  const text = [
    '---',
    'name: relay-is-the-network',
    'description: never Tailscale',
    'metadata:',
    '  type: feedback',
    '---',
    '',
    'See [[servers]] and [[vault|the vault]] and [[servers#ports]] again.',
  ].join('\n')

  it('takes its name, body and links, without aliases or headings, once each', () => {
    const note = parseNote(text, '/m/feedback_relay.md')
    expect(note.name).toBe('relay-is-the-network')
    expect(note.title).toBe('relay-is-the-network')
    expect(note.links).toEqual(['servers', 'vault'])
    expect(note.body.startsWith('\nSee')).toBe(true)
  })

  it('falls back to the first heading, then the file name', () => {
    expect(parseNote('# Heading here\ntext', '/m/a.md').title).toBe('Heading here')
    expect(parseNote('just text', '/m/plain-note.md').title).toBe('plain-note')
  })

  it('treats an unterminated front matter block as body', () => {
    expect(bodyOf('---\nname: x\nno end')).toBe('---\nname: x\nno end')
    expect(linksIn('[[ ]] [[a]]')).toEqual(['a'])
  })
})
