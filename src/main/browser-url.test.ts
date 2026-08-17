import { describe, expect, it } from 'vitest'
import {
  NEW_TAB_LABEL,
  isNavigationAllowed,
  normalizeUrl,
  pageTitle,
  shortLabel,
} from './browser-url'

function url(input: string): string | null {
  const result = normalizeUrl(input)
  return result.ok ? result.url : null
}

describe('normalizeUrl', () => {
  it('handles the host:port form that new URL() reads as a scheme', () => {
    // `new URL('localhost:3000').protocol` is 'localhost:' — checked against
    // node, not assumed. This is the default thing typed into this URL bar.
    expect(url('localhost:3000')).toBe('http://localhost:3000/')
    expect(url('localhost:3000/dashboard')).toBe('http://localhost:3000/dashboard')
    expect(url('127.0.0.1:8080')).toBe('http://127.0.0.1:8080/')
    expect(url('[::1]:5173')).toBe('http://[::1]:5173/')
  })

  it('adds a scheme to a bare host', () => {
    expect(url('example.com')).toBe('http://example.com/')
    expect(url('example.com/a/b?c=1')).toBe('http://example.com/a/b?c=1')
    expect(url('//example.com')).toBe('http://example.com/')
  })

  it('keeps http and https as given', () => {
    expect(url('https://example.com/x')).toBe('https://example.com/x')
    expect(url('  http://localhost:5173  ')).toBe('http://localhost:5173/')
    expect(url('HTTPS://Example.COM')).toBe('https://example.com/')
  })

  it('refuses file:, which is the whole point of the allow-list', () => {
    const result = normalizeUrl('file:///Users/apple/.ssh/id_rsa')
    expect(result.ok).toBe(false)
    expect(result.ok === false && result.reason).toMatch(/http/)
  })

  it('refuses the other schemes that execute or exfiltrate', () => {
    expect(url('javascript:alert(1)')).toBeNull()
    expect(url('data:text/html,<script>fetch("//x")</script>')).toBeNull()
    expect(url('blob:http://x/1')).toBeNull()
    expect(url('chrome://settings')).toBeNull()
    expect(url('devtools://devtools/bundled/inspector.html')).toBeNull()
    expect(url('ws://localhost:3000')).toBeNull()
    expect(url('about:blank')).toBeNull()
  })

  it('refuses a Windows path, which parses as the scheme "c:"', () => {
    expect(url('C:\\Users\\apple\\secrets.txt')).toBeNull()
  })

  it('refuses embedded whitespace and control characters', () => {
    expect(url('http://good.example\nhttp://evil.example')).toBeNull()
    expect(url('http://good.example evil.example')).toBeNull()
  })

  it('refuses empty and non-string input', () => {
    expect(normalizeUrl('').ok).toBe(false)
    expect(normalizeUrl('   ').ok).toBe(false)
    expect(normalizeUrl(undefined).ok).toBe(false)
    expect(normalizeUrl(42).ok).toBe(false)
  })

  it('refuses a URL with no host', () => {
    expect(url('http://')).toBeNull()
  })
})

describe('isNavigationAllowed', () => {
  it('allows http and https', () => {
    expect(isNavigationAllowed('http://localhost:3000/x')).toBe(true)
    expect(isNavigationAllowed('https://example.com')).toBe(true)
  })

  it('allows about:blank, which an empty view holds', () => {
    expect(isNavigationAllowed('about:blank')).toBe(true)
  })

  it('blocks the schemes a hostile page would reach for', () => {
    expect(isNavigationAllowed('file:///etc/passwd')).toBe(false)
    expect(isNavigationAllowed('file://localhost/etc/passwd')).toBe(false)
    expect(isNavigationAllowed('javascript:fetch("//x")')).toBe(false)
    expect(isNavigationAllowed('data:text/html,x')).toBe(false)
    expect(isNavigationAllowed('about:srcdoc')).toBe(false)
    expect(isNavigationAllowed('')).toBe(false)
    expect(isNavigationAllowed(null)).toBe(false)
    expect(isNavigationAllowed('not a url')).toBe(false)
  })
})

describe('shortLabel', () => {
  it('drops the scheme and a bare root path', () => {
    expect(shortLabel('http://localhost:3000/')).toBe('localhost:3000')
    expect(shortLabel('http://localhost:3000/pricing')).toBe('localhost:3000/pricing')
  })

  it('names an empty view', () => {
    expect(shortLabel('about:blank')).toBe('New tab')
    expect(shortLabel('')).toBe('New tab')
    expect(shortLabel(undefined)).toBe('New tab')
  })

  it('clamps a path the page made enormous', () => {
    // This lands in the tab strip and in refusal messages. A URL path has no
    // length limit, and the page chooses it.
    const label = shortLabel(`http://evil.example/${'a'.repeat(500_000)}`)
    expect(label.length).toBeLessThanOrEqual(121)
    expect(label.startsWith('evil.example/aaa')).toBe(true)
    expect(label.endsWith('…')).toBe(true)
  })

  it('strips control characters from a string it could not parse', () => {
    // The parsed branch gets percent-encoding for free; the fallback does not.
    expect(shortLabel('not a url\u001b[2K\nsecond line')).toBe('not a url [2K second line')
  })
})

/**
 * The app's own start page used to introduce itself as `about:blank`.
 *
 * `webContents.getTitle()` never comes back empty: with no `<title>` in the
 * document Chromium hands back the address, and a tab that has not been
 * anywhere has the address `about:blank`. `stateOf` passed that through as the
 * page's title and four surfaces printed it — the sidebar row, the tab strip,
 * the pane bar, and the tooltip each of those carries. Seen on screen rather
 * than inferred: a fresh browser tab in a dev build, sidebar row and strip tab
 * both reading `about:blank` over a page headed "Open a page".
 */
describe('pageTitle', () => {
  it('refuses the address Chromium substitutes for a missing <title>', () => {
    expect(pageTitle('about:blank', 'about:blank')).toBe('')
    // Also when the state has already blanked the URL out from under it.
    expect(pageTitle('about:blank', '')).toBe('')
  })

  it('leaves a page that actually named itself alone', () => {
    expect(pageTitle('Dashboard', 'http://localhost:3000/')).toBe('Dashboard')
    expect(pageTitle('  Dashboard  ', 'http://localhost:3000/')).toBe('Dashboard')
  })

  it('drops a title that is only the address again', () => {
    // shortLabel already renders the same address better, so falling back to it
    // is an improvement rather than a loss.
    expect(pageTitle('http://localhost:3000/pricing', 'http://localhost:3000/pricing')).toBe('')
    expect(shortLabel('http://localhost:3000/pricing')).toBe('localhost:3000/pricing')
  })

  it('treats anything that is not a string as no title', () => {
    expect(pageTitle(undefined, 'http://localhost:3000/')).toBe('')
    expect(pageTitle(null, 'http://localhost:3000/')).toBe('')
    expect(pageTitle('   ', 'http://localhost:3000/')).toBe('')
  })

  it('returns emptiness rather than a placeholder of its own', () => {
    // Two functions both inventing a name is how a pane bar and a sidebar row
    // end up calling the same page two different things. Naming stays with
    // shortLabel, which had a name for this case all along.
    expect(pageTitle('about:blank', 'about:blank')).toBe('')
    expect(shortLabel('about:blank')).toBe(NEW_TAB_LABEL)
  })
})
