import { describe, expect, it } from 'vitest'
import { resolveOmnibox, type OmniboxResolution } from './omnibox'

function url(input: string): string | null {
  const result = resolveOmnibox(input)
  return result.kind === 'url' ? result.url : null
}

function query(input: string): string | null {
  const result = resolveOmnibox(input)
  return result.kind === 'search' ? result.query : null
}

describe('resolveOmnibox — URLs', () => {
  it('handles the host:port form that new URL() reads as a scheme', () => {
    // `new URL('localhost:3000').protocol` is 'localhost:'. This is the single
    // most likely thing to be typed into this bar.
    expect(url('localhost:3000')).toBe('http://localhost:3000/')
    expect(url('localhost:5173/admin')).toBe('http://localhost:5173/admin')
    expect(url('127.0.0.1:8080')).toBe('http://127.0.0.1:8080/')
    expect(url('[::1]:5173')).toBe('http://[::1]:5173/')
  })

  it('keeps a full URL as given', () => {
    expect(url('https://example.com/x?y=1')).toBe('https://example.com/x?y=1')
    expect(url('  http://localhost:3000  ')).toBe('http://localhost:3000/')
    expect(url('HTTPS://Example.COM')).toBe('https://example.com/')
  })

  it('adds a scheme to a bare host', () => {
    expect(url('example.com')).toBe('http://example.com/')
    expect(url('example.com/a/b?c=1')).toBe('http://example.com/a/b?c=1')
    expect(url('//example.com')).toBe('http://example.com/')
    expect(url('www.example.co.uk')).toBe('http://www.example.co.uk/')
  })

  it('knows the hosts that have no dot', () => {
    expect(url('localhost')).toBe('http://localhost/')
    expect(url('localhost/admin')).toBe('http://localhost/admin')
    expect(url('127.0.0.1')).toBe('http://127.0.0.1/')
  })

  it('takes a dev hostname that is not a real TLD', () => {
    expect(url('terminaldeck.test')).toBe('http://terminaldeck.test/')
    expect(url('printer.local')).toBe('http://printer.local/')
  })

  it('takes a fully-qualified name, trailing dot and all', () => {
    // `example.com.` splits into three labels with an empty one on the end, so
    // the TLD test used to run against '' and send a legal absolute hostname to
    // the search engine — even though LOCAL_HOSTS already listed `localhost.`
    // and the TLD pattern already allowed the dot. Three places, one of which
    // disagreed.
    // The dot survives into the URL, which is right: the root label is part of
    // the name and Chromium keeps it too.
    expect(url('example.com.')).toBe('http://example.com./')
    expect(url('www.example.co.uk.')).toBe('http://www.example.co.uk./')
    expect(url('localhost.')).toBe('http://localhost./')
  })

  it('still refuses an empty label in the middle', () => {
    expect(resolveOmnibox('a..b').kind).toBe('search')
    expect(resolveOmnibox('.example.com').kind).toBe('search')
  })
})

describe('resolveOmnibox — searches', () => {
  it('searches for a single word, which is also a legal hostname', () => {
    // The bug this whole module exists for: `normalizeUrl('cats')` happily
    // returns http://cats/ and the tab spends five seconds failing DNS.
    expect(query('cats')).toBe('cats')
    expect(query('vitest')).toBe('vitest')
  })

  it('searches for anything with a space in it', () => {
    expect(query('how do I center a div')).toBe('how do I center a div')
    expect(query('electron webcontentsview bounds')).toBe('electron webcontentsview bounds')
  })

  it('searches for a number, which a dot does not make into a host', () => {
    expect(query('1.5')).toBe('1.5')
    expect(query('v2.0')).toBe('v2.0')
    expect(query('3.14159')).toBe('3.14159')
  })

  it('searches rather than opening a scheme this panel cannot open', () => {
    expect(query('mailto:asad@example.com')).toBe('mailto:asad@example.com')
    expect(query('javascript:alert(1)')).toBe('javascript:alert(1)')
    expect(query('file:///etc/passwd')).toBe('file:///etc/passwd')
    expect(query('chrome://settings')).toBe('chrome://settings')
  })

  it('percent-encodes the query but shows the user what they typed', () => {
    const result = resolveOmnibox('c++ & rust')
    expect(result.kind).toBe('search')
    if (result.kind !== 'search') return
    expect(result.url).toBe('https://duckduckgo.com/?q=c%2B%2B%20%26%20rust')
    expect(result.display).toBe('c++ & rust')
  })

  it('takes a different search engine', () => {
    const result = resolveOmnibox('terminaldeck', 'https://example.com/find?query=%s')
    expect(result.kind === 'search' && result.url).toBe('https://example.com/find?query=terminaldeck')
  })

  it('appends the query when a template has no placeholder', () => {
    const result = resolveOmnibox('terminaldeck', 'https://example.com/?q=')
    expect(result.kind === 'search' && result.url).toBe('https://example.com/?q=terminaldeck')
  })
})

describe('resolveOmnibox — nothing', () => {
  it('has no opinion about an empty bar', () => {
    const empties: OmniboxResolution['kind'][] = [
      resolveOmnibox('').kind,
      resolveOmnibox('   ').kind,
      resolveOmnibox('\t\n').kind,
    ]
    expect(empties).toEqual(['empty', 'empty', 'empty'])
  })
})
