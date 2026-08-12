import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  ChatBubble,
  ChatEmpty,
  ChatView,
  dayBreak,
  formatTime,
  markdown,
  mergeMessages,
  renderMarkdown,
  type ChatMessage,
} from './ChatView'

/**
 * No DOM environment in this project's test setup, so these render to static
 * markup — which is also the environment that makes the security invariant
 * testable: with no `window`, DOMPurify cannot initialise, and the component
 * must fall back to escaped text rather than emitting HTML it never cleaned.
 */

const NOW = Date.parse('2026-08-12T09:00:00.000Z')

function message(overrides: Partial<ChatMessage> & { id: string }): ChatMessage {
  return { role: 'agent', text: 'Hello.', at: NOW, ...overrides }
}

describe('sanitising model output', () => {
  it('refuses to produce HTML when it cannot be sanitised', () => {
    // `dompurify`'s default export outside a browser is an uninitialised factory
    // with no `sanitize`. Reading that as "nothing to clean" would ship raw
    // model output into `dangerouslySetInnerHTML`.
    expect(renderMarkdown('**hi**')).toBeNull()
  })

  it('escapes markup in a reply rather than rendering it', () => {
    const html = renderToStaticMarkup(
      <ChatBubble
        message={message({ id: 'a', text: '<img src=x onerror="alert(1)"> and <script>alert(2)</script>' })}
        heading={null}
      />,
    )
    expect(html).not.toContain('<img')
    expect(html).not.toContain('<script')
    expect(html).toContain('&lt;img')
  })

  it('shows a typed prompt verbatim, never as markup', () => {
    // A person typing `# 1` means "number one", not a heading.
    const html = renderToStaticMarkup(
      <ChatBubble message={message({ id: 'p', role: 'you', text: '# 1 — fix *this*' })} heading={null} />,
    )
    expect(html).toContain('cv-plain')
    expect(html).toContain('# 1 — fix *this*')
    expect(html).not.toContain('<h1')
    expect(html).not.toContain('<em>')
  })
})

describe('what markdown is allowed to become', () => {
  const html = (source: string): string => {
    const out = markdown.parse(source, { async: false })
    return typeof out === 'string' ? out : ''
  }

  it('renders a link label as markup, not as its own source', () => {
    // Caught in the browser harness: the label arrives as a raw token, so
    // `[**mayCarryChat**](url)` put the asterisks on screen. Models write half
    // their links this way.
    const out = html('see [**mayCarryChat**](https://x.example/a) and [`the gate`](https://x.example/b)')
    expect(out).toContain('<strong>mayCarryChat</strong>')
    expect(out).toContain('<code>the gate</code>')
    expect(out).not.toContain('**')
    expect(out).not.toContain('`the gate`')
  })

  it('emits no href, no src and no image, whatever the model wrote', () => {
    const out = html('[go](https://evil.example) ![shot](https://evil.example/x.png) <https://auto.example>')
    expect(out).not.toContain('href')
    expect(out).not.toContain('src')
    expect(out).not.toContain('<img')
    // The destination survives as a tooltip, which is inert.
    expect(out).toContain('title="https://evil.example"')
  })

  it('folds a fenced block into a closed details with its content escaped', () => {
    const out = html('```ts\nconst x = "</code></pre><img src=x onerror=alert(1)>"\n```')
    expect(out).toContain('<details class="cv-code"><summary>ts · 1 line</summary>')
    expect(out).not.toContain('<img')
    expect(out).toContain('&lt;img')
    expect(out).not.toContain('<details open')
  })
})

describe('merging a tail', () => {
  const first = message({ id: 'you:1', role: 'you', text: 'go' })
  const second = message({ id: 'agent:1', text: 'Working.' })

  it('appends messages it has not seen', () => {
    expect(mergeMessages([first], [second]).map((m) => m.id)).toEqual(['you:1', 'agent:1'])
  })

  it('replaces a message that grew, in place', () => {
    // The live turn arrives a block at a time under one id; appending would show
    // the same reply twice, each a prefix of the next.
    const grown = { ...second, text: 'Working.\n\nDone.' }
    const merged = mergeMessages([first, second], [grown])
    expect(merged).toHaveLength(2)
    expect(merged[1].text).toBe('Working.\n\nDone.')
  })

  it('leaves the conversation alone when nothing changed', () => {
    const current = [first, second]
    expect(mergeMessages(current, [])).toBe(current)
  })
})

describe('timestamps', () => {
  it('shows nothing for an undated message rather than 1970', () => {
    expect(formatTime(0)).toBe('')
  })

  it('breaks the day only when the day changes', () => {
    const later = NOW + 60_000
    const tomorrow = NOW + 26 * 60 * 60 * 1000
    expect(dayBreak(NOW, 0)).not.toBeNull()
    expect(dayBreak(later, NOW)).toBeNull()
    expect(dayBreak(tomorrow, NOW)).not.toBeNull()
  })
})

describe('empty states', () => {
  it('tells a missing transcript apart from a silent session', () => {
    const missing = renderToStaticMarkup(<ChatEmpty state="no-transcript" />)
    const silent = renderToStaticMarkup(<ChatEmpty state="silent" />)
    expect(missing).toContain('No transcript for this project yet')
    expect(silent).toContain('Nothing said yet')
    expect(missing).not.toEqual(silent)
  })

  it('says so when the preload has no chat methods, instead of looking empty', () => {
    // Three shipped bugs came from a component silently rendering nothing when
    // the bridge was missing. `window` does not exist here, so this is that path.
    expect(renderToStaticMarkup(<ChatView cwd="/tmp/x" />)).toContain('not wired into this build')
  })
})
