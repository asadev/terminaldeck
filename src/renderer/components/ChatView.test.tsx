import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  ChatBubble,
  ChatColumn,
  ChatEmpty,
  ChatView,
  dayBreak,
  formatTime,
  markdown,
  mergeMessages,
  renderMarkdown,
  type ChatMessage,
} from './ChatView'
import { runningProvider } from '../shell/agent-presence'
import { CHAT_SESSION_ATTR } from '../driving/where'

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

  it('admits it cannot tell rather than saying the session has been quiet', () => {
    // Two sessions in one folder is not "nothing from this session yet" — that
    // sentence tells somebody staring at a busy terminal that it has said
    // nothing, which is how the wrong conversation got shown in the first place.
    const unsure = renderToStaticMarkup(<ChatEmpty state="ambiguous" />)
    const quiet = renderToStaticMarkup(<ChatEmpty state="no-session-transcript" />)
    expect(unsure).toContain('Cannot tell which conversation')
    expect(unsure).not.toEqual(quiet)
    // And it must point at the view that *is* exact.
    expect(unsure).toContain('terminal')
  })
})

describe('the end of the conversation', () => {
  /**
   * Item 4 of NEXT-UPDATE.md, in his words:
   *
   *   > "there should be only last message whoever has said, no great line
   *   > under there"
   *
   * A sentence explaining the pane used to be rendered after the final bubble,
   * so it followed the newest reply down the screen and was the last thing read
   * every time the agent finished talking.
   */
  it('ends with the last message and nothing else', () => {
    const html = renderToStaticMarkup(
      <ChatColumn
        messages={[
          message({ id: 'a', role: 'you', text: 'Ship it.' }),
          message({ id: 'b', text: 'Shipped.' }),
        ]}
      />,
    )
    expect(html).toContain('Shipped.')
    // Whatever the markup, the column closes immediately after the last bubble.
    expect(html.endsWith('</article></div>')).toBe(true)
  })

  it('says nothing about where the conversation was read from', () => {
    const html = renderToStaticMarkup(<ChatColumn messages={[message({ id: 'a' })]} />)
    expect(html).not.toContain('transcript')
    expect(html).not.toContain('cv-source')
  })
})

describe('what is running in the session, not what was launched into it', () => {
  /**
   * The knock-on from item 1. Run Claude starts an agent inside a session this
   * app spawned as `$SHELL -l`, and `SessionMeta.provider` goes on saying
   * `shell` for the rest of that session's life — correctly, it is a record of
   * the spawn. Everything written *from* it would then be wrong: the pane would
   * tell somebody with a live conversation on screen that a shell has nothing
   * to read, and the control row would withdraw every picker.
   */
  it('stops calling a shell a shell once an agent is running in it', () => {
    expect(runningProvider('shell', true)).toBeUndefined()
  })

  it('says shell again the moment the agent is gone', () => {
    expect(runningProvider('shell', false)).toBe('shell')
    // And while nothing is known — the honest reading of a session nobody has
    // managed to look at yet is the one thing that is on record about it.
    expect(runningProvider('shell', null)).toBe('shell')
  })

  it('does not claim to know which agent somebody typed', () => {
    // `undefined` is "not known", which is true; `'claude'` would be a guess
    // that reads as a fact, and `codex` is one keystroke away.
    expect(runningProvider('shell', true)).not.toBe('claude')
  })

  it('leaves an agent session exactly as it found it', () => {
    expect(runningProvider('claude', true)).toBe('claude')
    expect(runningProvider('claude', false)).toBe('claude')
    expect(runningProvider(undefined, null)).toBeUndefined()
  })
})

describe('the pane says which session it is a view of', () => {
  /**
   * `app.where` answers "what am I looking at" by measuring the DOM — see
   * `driving/where.ts` for why that is the right source rather than a shortcut —
   * and a conversation was the one thing it could see and not name, because this
   * pane's root carried no id. So the tool reported that this app could not say
   * which session was in front of its own window.
   *
   * Asad asked for the capability in one sentence: *"if I ask it where I am right
   * now, it should be able to answer."*
   *
   * These render with no `window`, so the pane falls straight through to its
   * "not wired into this build" state — which is the point: the attribute is on
   * the **root**, so it is there whatever the conversation underneath turns out
   * to be, including before a transcript has been found.
   */
  it('carries the session id when it knows which pty it acts on', () => {
    const html = renderToStaticMarkup(<ChatView cwd="/tmp/x" sessionId="sess-7" />)
    expect(html).toContain(`${CHAT_SESSION_ATTR}="sess-7"`)
  })

  it('leaves the attribute off entirely when it does not', () => {
    /*
     * An absent attribute reads as "not known"; a guessed one reads as a fact.
     * With no id passed in and no live session list to narrow to one, the pane
     * genuinely does not know — and its own composer refuses to attach a file for
     * exactly the same reason.
     */
    const html = renderToStaticMarkup(<ChatView cwd="/tmp/x" />)
    expect(html).not.toContain(CHAT_SESSION_ATTR)
  })
})
