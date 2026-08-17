/**
 * No money, anywhere in this client.
 *
 * Cost and price were taken out of every surface of this product. The desktop had
 * a cost column, a spend figure and a per-session dollar amount; all of it is
 * gone, and the instruction for this client was one line: *"No cost or price
 * anywhere."*
 *
 * The browser client never had any — this is not a removal, it is a latch. It is
 * worth having precisely because "we already don't do that" is the state that
 * quietly stops being true: the wire types here are re-exported from the
 * desktop's `protocol.ts`, so the day somebody adds a `costUsd` to a session frame
 * this client would be one `${session.costUsd}` away from putting a dollar sign on
 * a phone.
 *
 * **Tokens and the context window are fine and are deliberately not matched.**
 * They are facts about a conversation rather than a bill, and the desktop still
 * shows both. What is banned is money: a currency symbol, a currency code, or a
 * field named for spending.
 *
 * ## Why this reads the sources as text
 *
 * The same reason `layout.test.ts` reads the stylesheet as text. `main.ts` builds
 * its DOM against a real browser and vitest runs here with no DOM, so the only
 * thing a test can hold this client's *output* to is its input. A grep is a blunt
 * instrument and it is the right one here: the property is "this string never
 * appears", which is exactly what a grep can prove.
 */

import { readdirSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const here = fileURLToPath(new URL('../src/', import.meta.url))

/** Every source file this client is built from, tests included. */
function sources(): Array<{ name: string; text: string }> {
  return readdirSync(here, { withFileTypes: true })
    .filter((entry) => entry.isFile() && /\.(ts|css)$/.test(entry.name))
    .map((entry) => ({ name: entry.name, text: readFileSync(`${here}${entry.name}`, 'utf8') }))
}

/**
 * The text of every string literal in a TypeScript source.
 *
 * Only literals, because that is where a price would have to live to reach a
 * screen — and because a prose comment saying a listener "costs nothing" is a
 * sentence about cheapness, not a feature. Matching those would make this test
 * something people route around by rewording a comment, which is worse than not
 * having it.
 *
 * Template literals are matched whole, including their `${…}` holes, so a
 * `` `$${amount}` `` is caught by the currency rule below.
 */
function literals(text: string): string[] {
  const found: string[] = []
  for (const match of text.matchAll(/'([^'\\\n]|\\.)*'|"([^"\\\n]|\\.)*"|`([^`\\]|\\.)*`/g)) {
    found.push(match[0])
  }
  return found
}

describe('the web client has no cost or price in it', () => {
  it('puts no currency on any string it can draw', () => {
    /*
     * `$` alone is not the test — a template literal is full of them. What is
     * banned is a currency *amount*: a dollar sign against a digit or against an
     * interpolation, and the three other symbols this product would plausibly
     * reach for.
     */
    const money = /(\$\s*[\d.]|\$\s*\$\{|[€£¥]\s*[\d.{])/
    for (const { name, text } of sources()) {
      if (!name.endsWith('.ts')) continue
      for (const literal of literals(text)) {
        expect(money.test(literal), `${name} has a currency amount in ${literal}`).toBe(false)
      }
    }
  })

  it('names no field, function or class after money', () => {
    /*
     * The other half: a screen cannot show a price it has no value for. This
     * matches identifiers rather than prose, so `costs one listener` in a comment
     * is untouched while `costUsd`, `totalCost`, `pricePerToken` and a
     * `.cost-row` class are not.
     */
    const named =
      /\b(cost|price|spend|billing|invoice)(Usd|Cents|PerToken|Total|Row|Cell|Bar|Chip)\b|\b(total|session|daily|monthly)(Cost|Price|Spend)\b|\bcostUsd\b|--cost|\.cost-/i
    for (const { name, text } of sources()) {
      const hit = named.exec(text)
      expect(hit, `${name} names something after money: ${hit?.[0]}`).toBeNull()
    }
  })

  it('reads no money field off anything the desktop sends', () => {
    /*
     * The case this file was actually written for. The wire types here are
     * re-exported from the desktop's `protocol.ts`, so a `costUsd` added over
     * there arrives in this client's type checker as a perfectly good field. The
     * latch that matters is therefore not "we do not have one" but "we never read
     * one", which is a property of *this* code and is checkable.
     *
     * Property reads and bracket reads both, because the second is how somebody
     * gets round the first without meaning to.
     */
    const reads = /[.](cost|price|spend|amount|billing)\b|\[['"](cost|price|spend|billing)/i
    for (const { name, text } of sources()) {
      if (!name.endsWith('.ts')) continue
      const hit = reads.exec(text)
      expect(hit, `${name} reads a money field: ${hit?.[0]}`).toBeNull()
    }
  })

  it('leaves tokens and the context window alone, because those are not a bill', () => {
    /*
     * The other direction, so this file cannot be satisfied by deleting things
     * that were never the problem. A token count and a context window are facts
     * about a conversation, the desktop still shows both, and if a later pass gives
     * this client a usage line it is allowed to — the two rules above are about
     * money and nothing else.
     *
     * There is nothing to assert about them yet: neither crosses this wire, so the
     * browser client shows neither. What this holds is the *reason*, in the one
     * place somebody reading these rules will look.
     */
    const wire = readFileSync(`${here}protocol-client.ts`, 'utf8')
    // A `usage` frame does not exist on this protocol today. When one does, this
    // is the line that should change — deliberately, with a screen behind it.
    expect(wire).not.toMatch(/t: 'usage'/)
  })
})
