import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { IdentityChanged, ServerHealth, ServerPage } from './ServerPage'
import type { Fact, Server, ServerCard, ServerState, ServerView } from './types'

/**
 * One server's page: three zones, in one order, and the order is the design.
 *
 * The tests worth having here are about **what the page refuses to do**. It
 * refuses to summarise a fact it could not read as good news; it refuses to show
 * a host machine's numbers on a container's page; it refuses to offer a way past
 * an identity that changed. Each of those is a thing that would look fine on
 * screen and be wrong on somebody else's machine.
 */

const NOW = 1_700_000_000_000

function plain(html: string): string {
  return html.replace(/&#x27;/g, "'").replace(/&quot;/g, '"').replace(/&amp;/g, '&')
}

function yes<T>(value: T): Fact<T> {
  return { known: 'yes', value, measuredAt: NOW, how: 'asked' }
}

function card(over: Partial<ServerCard> = {}): ServerCard {
  return { id: 'c1', kind: 'app', name: 'Thing', detail: '', running: true, url: null, ...over }
}

function view(over: Partial<ServerView> = {}): ServerView {
  return {
    cards: [],
    facts: {},
    offered: {},
    absent: {},
    how: [],
    cannot: [],
    measuredAt: NOW,
    ...over,
  }
}

const SERVER: Server = { id: 's1', name: 'Shop', address: 'example.com', username: 'admin' }

function page(state: ServerState | undefined): string {
  return plain(
    renderToStaticMarkup(
      <ServerPage
        server={SERVER}
        state={state}
        bridge={null}
        now={NOW}
        onState={() => {}}
        onBack={() => {}}
        onForget={() => {}}
        onRename={() => {}}
      />,
    ),
  )
}

function health(state: ServerState | undefined): string {
  return plain(renderToStaticMarkup(<ServerHealth state={state} now={NOW} onRefresh={() => {}} />))
}

describe('the calm zone', () => {
  it('is one sentence, some numbers, and one thing to press', () => {
    const html = health({
      id: 's1',
      link: 'ready',
      view: view({
        cards: [card({ kind: 'site', name: 'Shop' })],
        facts: { disk: yes({ usedKb: 34, totalKb: 100 }) },
        measuredAt: NOW - 20 * 60_000,
      }),
    })
    expect(html).toContain("Everything's running.")
    expect(html).toContain('34% full')
    expect(html).toContain('as of 20 minutes ago')
    /*
     * Exactly one button in this zone. The moment it has more it is a control
     * surface and has to be read carefully; it is the one part of the page that
     * is allowed to be glanced at. The refresh earns its place because a person
     * who wants to know *now* has to be able to ask — and asking on a press is
     * what makes "nothing asks on a timer" honest rather than merely cheap.
     */
    expect(html.match(/<button/g)).toHaveLength(1)
    expect(html).toContain('Check now')
  })

  it('refuses to say everything is running over a card it could not read', () => {
    const html = health({
      id: 's1',
      link: 'ready',
      view: view({ cards: [card(), card({ id: 'c2', running: null })] }),
    })
    /*
     * The claim is bounded rather than absent. `words.ts` explains why the
     * sentence changed shape: on a real machine with eleven healthy containers
     * and one unreadable website, leading with the failure described a healthy
     * box as a broken one. What must never happen is the unqualified promise —
     * so that is what is asserted against, and the exact-match check is what
     * stops "Everything we can check is running" being read as containing it.
     */
    expect(html).toContain('Everything we can check is running.')
    expect(html).not.toContain("Everything's running")
  })

  /*
   * Measured, not imagined: a container reports the numbers of the machine it is
   * running on. One reported 39 GB of disk and a 64-hour uptime, and both
   * belonged to the rented box rather than to the container.
   */
  it('shows no numbers at all for something inside a container', () => {
    const html = health({
      id: 's1',
      link: 'ready',
      view: view({
        facts: {
          init: yes('container-none'),
          disk: yes({ usedKb: 39, totalKb: 100 }),
          uptimeSeconds: yes(232_603),
        },
      }),
    })
    expect(html).not.toContain('39%')
    expect(html).not.toContain('servers-reading')
  })

  it('says it is connecting rather than summarising a server it has not reached', () => {
    const html = health({ id: 's1', link: 'connecting' })
    expect(html).toContain('Connecting…')
    expect(html).not.toContain("Everything's running")
  })
})

describe('the middle zone', () => {
  it('runs sites, then apps, then databases, then the rest', () => {
    const html = page({
      id: 's1',
      link: 'ready',
      view: view({
        cards: [
          card({ id: 'c4', kind: 'other', name: 'Something' }),
          card({ id: 'c3', kind: 'database', name: 'Records' }),
          card({ id: 'c2', kind: 'app', name: 'Worker' }),
          card({ id: 'c1', kind: 'site', name: 'Shop' }),
        ],
      }),
    })
    const order = ['Websites', 'Apps', 'Databases', 'Other things running'].map((heading) =>
      html.indexOf(heading),
    )
    expect(order.every((at) => at > -1)).toBe(true)
    expect([...order].sort((a, b) => a - b)).toEqual(order)
  })

  it('starts the remainder shut, says how many, and leaves the three real groups open', () => {
    /*
     * Fifty-nine cards under that heading on a real server, against three the
     * person owns. Open, the zone that answers "is my website all right" cannot
     * be read in one screen.
     */
    const html = page({
      id: 's1',
      link: 'ready',
      view: view({
        cards: [
          card({ id: 'c1', kind: 'app', name: 'Worker' }),
          card({ id: 'c2', kind: 'other', name: 'systemd-udevd' }),
          card({ id: 'c3', kind: 'other', name: 'apparmor' }),
        ],
      }),
    })
    // The number is on the closed door, because it is the whole reason to open it.
    expect(html).toContain('Other things running (2)')
    // Shut means not rendered, not merely not visible.
    expect(html).not.toContain('systemd-udevd')
    expect(html).not.toContain('apparmor')
    // And the group above it is untouched.
    expect(html).toContain('Worker')
  })

  it('says a reason every card in a group gives once, not once per card', () => {
    /*
     * Counted on a real page: the same sentence fifty-nine times. It stops
     * being an explanation around the third repetition and becomes texture,
     * which is the state in which nobody reads the one that is different.
     */
    const because = "We can't tell how this was set up, so we don't know how to put it back."
    const html = page({
      id: 's1',
      link: 'ready',
      view: view({
        cards: [card({ id: 'c1', kind: 'app', name: 'One' }), card({ id: 'c2', kind: 'app', name: 'Two' })],
        absent: {
          c1: [{ actionId: 'update', because }],
          c2: [{ actionId: 'update', because }],
        },
      }),
    })
    expect(html.split(because).length - 1).toBe(1)
  })

  it('treats a server that keeps nothing as an answer, not a failure', () => {
    const html = page({ id: 's1', link: 'ready', view: view() })
    expect(html).toContain("couldn't find anything this server is set up to keep running")
    // And it points at the thing that makes the empty page honest rather than a
    // dead end: there is still a terminal, one door further in.
    expect(html).toContain('Advanced')
  })

  it('draws no button for an action the facts did not support', () => {
    // `offered` is empty for this card, so there is nothing to draw. A button
    // that cannot act is absent rather than greyed hopefully.
    const html = page({
      id: 's1',
      link: 'ready',
      view: view({ cards: [card({ kind: 'site', name: 'Shop' })] }),
      previews: {},
    })
    expect(html).toContain('Shop')
    expect(html).not.toContain('Restart')
  })

  it('writes the reason an action a person would look for is not there', () => {
    /*
     * A database we could not recognise has no Backup button, and nobody could
     * work that out from an absent button — while dumping it with the wrong tool
     * produces a file that looks like a backup and is not one.
     */
    const html = page({
      id: 's1',
      link: 'ready',
      view: view({
        cards: [card({ kind: 'database', name: 'Records' })],
        absent: { c1: [{ actionId: 'backup', because: "We can't tell what kind of database this is." }] },
      }),
    })
    expect(html).toContain("We can't tell what kind of database this is.")
  })
})

describe('the door', () => {
  it('is one labelled click, and nothing behind it is on the page until it is opened', () => {
    const html = page({ id: 's1', link: 'ready', view: view() })
    expect(html).toContain('Advanced')
    expect(html).not.toContain('Open a terminal')
    expect(html).not.toContain('Forget this server')
  })
})

describe('when the identity changed', () => {
  it('offers the two fingerprints and no way past them', () => {
    /*
     * The whole value of this check is that it cannot be clicked through. A
     * warning with a "connect anyway" beside it is a warning that will be
     * dismissed, and this is the one moment on the whole screen where continuing
     * could hand a password to somebody who is not who they say they are.
     */
    const html = plain(
      renderToStaticMarkup(
        <IdentityChanged
          state={{
            id: 's1',
            link: 'failed',
            identityChanged: true,
            problem: 'This server answered with a different identity.',
            identity: { expected: 'SHA256:aaa', offered: 'SHA256:bbb' },
          }}
          onBack={() => {}}
        />,
      ),
    )
    expect(html).toContain('SHA256:aaa')
    expect(html).toContain('SHA256:bbb')
    expect(html).not.toMatch(/anyway|continue|proceed|ignore|trust it/i)
    expect(html.match(/<button/g)).toHaveLength(1)
  })

  it('replaces the whole page rather than sitting above it as a banner', () => {
    const html = page({
      id: 's1',
      link: 'failed',
      identityChanged: true,
      problem: 'It answered as somebody else.',
      view: view({ cards: [card({ kind: 'site', name: 'Shop' })] }),
    })
    expect(html).toContain('different identity')
    // No cards, no numbers, no Advanced door, and above all no Try again:
    // nothing on this page is worth reading while we do not know what answered.
    expect(html).not.toContain('Websites')
    expect(html).not.toContain('Advanced')
    expect(html).not.toContain('Try again')
  })
})

describe('when it could not connect at all', () => {
  it('shows the sentence the main process wrote, and something to press', () => {
    const html = page({ id: 's1', link: 'failed', problem: 'That address did not answer.' })
    expect(html).toContain('That address did not answer.')
    expect(html).toContain('Try again')
  })
})
