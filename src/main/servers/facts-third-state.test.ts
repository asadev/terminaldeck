import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { parseProbe } from './probe.sh'
import type { Fact, ServerFacts } from './facts'

/**
 * Nothing this app did not measure is ever reported as measured.
 *
 * This is the guard on the rule the whole feature is arranged around, in his
 * words: *"make sure we don't design it as per our design, it's gonna be used
 * for all so they might have different settings, we need something common."*
 *
 * The failure it exists to prevent is not a crash. It is a page that quietly
 * asserts something true of the machine this was written on and false of
 * somebody else's — "no containers" on a box full of them, "0 listening" on a
 * box where nothing counted, "16% disk used" about a completely different
 * computer. Every one of those type-checks perfectly and every one is a lie on
 * a stranger's server.
 *
 * So the rule, stated as a test rather than as a comment: **an answer we do not
 * have is `cannot`.** `no` is reserved for the two questions where absence is
 * itself an answer about the server — is a container runtime installed, is a web
 * server installed — and for the two lists that follow directly from them. The
 * test below pins that membership exactly, so that a field added later cannot
 * join the group by accident.
 */

const fixture = (name: string): string =>
  readFileSync(resolve(__dirname, 'probe-fixtures', `${name}.txt`), 'utf8')

/**
 * Every field of the record that is a fact, found from a real parse rather than
 * from a list somebody has to remember to update.
 *
 * That matters more than it looks: a hand-written list is how the eleventh
 * fact, added in six months, escapes this test entirely.
 */
function factsOf(record: ServerFacts): [string, Fact<unknown>][] {
  return Object.entries(record).filter(
    (entry): entry is [string, Fact<unknown>] =>
      typeof entry[1] === 'object' &&
      entry[1] !== null &&
      'known' in (entry[1] as Record<string, unknown>),
  )
}

describe('a question with no answer', () => {
  it('is cannot on every single field, when the server said nothing at all', () => {
    // The extreme case, and the one that would be silently wrong: a server that
    // answers the connection and then produces nothing. Every fact must be the
    // third state — not a default, not a zero, not an empty list.
    const facts = parseProbe('', 'server-1', 1_000)
    const wrong = factsOf(facts)
      .filter(([, fact]) => fact.known !== 'cannot')
      .map(([name, fact]) => `${name} is ${fact.known}`)
    expect(wrong).toEqual([])
  })

  it('carries a sentence with every cannot, because a blank is what starts a lie', () => {
    const facts = parseProbe('', 'server-1', 1_000)
    for (const [name, fact] of factsOf(facts)) {
      if (fact.known !== 'cannot') continue
      expect(fact.why, `${name} has no reason`).toBeTruthy()
      expect(fact.why.length, `${name}'s reason is not a sentence`).toBeGreaterThan(10)
    }
  })

  it('stamps when it was measured on all three states alike', () => {
    // The age is what this feature shows instead of polling for a fresh number,
    // so a fact with no timestamp is a fact that cannot be displayed honestly.
    for (const raw of ['', fixture('ubuntu-administrator'), fixture('container-nothing-installed')]) {
      for (const [name, fact] of factsOf(parseProbe(raw, 'server-1', 1_234))) {
        expect(fact.measuredAt, `${name} has no time`).toBe(1_234)
      }
    }
  })
})

describe('the few questions where absence is itself an answer', () => {
  it('is the container runtime and the web server, and what follows from them', () => {
    // `no` is a claim: *we asked, and there is none*. It is correct for these
    // two because the probe checks for the programs directly and their absence
    // from a machine is a fact about that machine. Everywhere else, the honest
    // word is `cannot`, and this pins which is which so that a future field
    // does not quietly join the wrong group.
    const facts = parseProbe(fixture('container-nothing-installed'), 'server-1', 1_000)
    const negatives = factsOf(facts)
      .filter(([, fact]) => fact.known === 'no')
      .map(([name]) => name)
      .sort()
    expect(negatives).toEqual(['containerRuntime', 'containers', 'siteNames', 'webServer'].sort())
  })

  it('never says no about containers when it was only refused permission', () => {
    const facts = parseProbe(fixture('ubuntu-ordinary-account'), 'server-1', 1_000)
    expect(facts.containerRuntime.known).not.toBe('no')
    expect(facts.containerRuntime.known).toBe('cannot')
  })
})

describe('every fact says how it was found', () => {
  it('names the check in words, on everything it measured', () => {
    // Shown behind the detail on a card rather than hidden. Two audiences: a
    // person who wonders why the app thinks something, and whoever has to
    // debug a wrong card on a stranger's server with nothing else to go on.
    for (const [name, fact] of factsOf(parseProbe(fixture('ubuntu-administrator'), 's', 1))) {
      if (fact.known === 'cannot') continue
      expect(fact.how, `${name} does not say how it was found`).toBeTruthy()
      expect(fact.how, `${name}'s how is not readable`).toMatch(/ /)
    }
  })
})
