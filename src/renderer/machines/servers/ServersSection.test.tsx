import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ServersSection } from './ServersSection'
import type { Server, ServerState } from './types'

/**
 * The servers list — the first thing somebody sees inside Machines.
 *
 * What is worth pinning here is not the layout but the **claims**: a list that
 * says something about a machine it has never connected to is a status page
 * that lies, and this list is drawn with nothing connected at all.
 */

const NOW = 1_700_000_000_000

function server(over: Partial<Server> = {}): Server {
  return {
    id: 's1',
    name: 'Shop',
    address: 'example.com',
    username: 'admin',
    ...over,
  }
}

/**
 * The markup with its entities turned back into the characters a person sees.
 *
 * `renderToStaticMarkup` escapes an apostrophe to `&#x27;`, so every assertion
 * about copy written the way English is written would otherwise have to be
 * spelled in HTML — which reads as a test about the renderer rather than about
 * the sentence.
 */
function plain(html: string): string {
  return html
    .replace(/&#x27;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
}

function render(over: Partial<Parameters<typeof ServersSection>[0]> = {}): string {
  return plain(renderToStaticMarkup(
    <ServersSection
      wired
      missing={[]}
      reading={false}
      problem={null}
      servers={[]}
      states={new Map()}
      now={NOW}
      onOpen={() => {}}
      onAdd={() => {}}
      onRetry={() => {}}
      {...over}
    />,
  ))
}

describe('what a row claims', () => {
  it('says nothing at all about a server nobody has opened', () => {
    /*
     * There is no third state here on purpose. A grey "unknown" chip and a
     * hopeful green dot are both claims about a machine this app has not spoken
     * to during this launch, and drawing one is how a list becomes a thing
     * people trust without reading.
     */
    const html = render({ servers: [server()] })
    expect(html).toContain('Shop')
    expect(html).toContain('admin at example.com')
    expect(html).not.toContain('servers-row-state')
  })

  it('shows the last thing a server said, and how old that is', () => {
    const state: ServerState = {
      id: 's1',
      link: 'ready',
      view: { cards: [], facts: {}, offered: {}, absent: {}, how: [], cannot: [], measuredAt: NOW - 20 * 60_000 },
    }
    const html = render({ servers: [server()], states: new Map([['s1', state]]) })
    expect(html).toContain("There's nothing here we can check on.")
    expect(html).toContain('20 minutes ago')
  })

  it('calls a server by its address when it has no name of its own', () => {
    const html = render({ servers: [server({ name: '', username: '' })] })
    // `asServersView` fills the name from the address, so this checks the row
    // renders whatever it is given rather than an empty span.
    expect(html).toContain('example.com')
  })
})

describe('a build that cannot do this says so', () => {
  it('does not draw an empty list when the channels are simply absent', () => {
    /*
     * An area that renders "you have no servers" when the part of the app that
     * connects is missing teaches somebody that the product cannot do the thing,
     * and they never look again. The two sentences send a person to two
     * completely different places.
     */
    const html = render({ wired: false })
    expect(html).toContain('cannot reach servers yet')
    expect(html).not.toContain('You have not added a server yet')
  })

  it('names the missing channels when only some of them are there, because half-wired looks like working', () => {
    const html = render({ missing: ['openServer', 'runServerAction'] })
    expect(html).toContain('openServer')
    expect(html).toContain('runServerAction')
  })

  it('gives a failed read something to press', () => {
    const html = render({ problem: 'That did not come back.' })
    expect(html).toContain('That did not come back.')
    expect(html).toContain('Try again')
  })
})

describe('adding one', () => {
  it('offers it as the primary thing to do, and greys it when the build cannot', () => {
    expect(render()).toContain('Add a server')
    expect(render({ wired: false })).toContain('disabled')
  })

  it('says what will be needed before anybody presses it', () => {
    // Three things, named on the list screen, so nobody opens the form to find
    // out they have to go and ask somebody for something.
    expect(render()).toContain('either a password or a key')
  })
})
