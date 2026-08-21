import { describe, expect, it } from 'vitest'
import { advertiseTool, buildCatalogue, type ToolContext, type ToolSpec } from './catalogue'
import {
  advertisedCatalogue,
  describeTool,
  DESCRIBE_ID,
  DESCRIBE_WIRE,
  MAX_DESCRIBE_NAMES,
  visibleTo,
  withDescribe,
} from './describe-tool'
import { SESSION_TOOLS } from './session-tools'
import { Refused } from './surface'

/**
 * Progressive disclosure: the index, the fetch, and the thing it must not leak.
 *
 * The budget half of this feature is measured in `catalogue-cost.test.ts` — that
 * is where the numbers live. This file is about the two properties the saving is
 * worthless without: that a model can still *find* a tool it needs, and that a
 * caller cannot use the meta-tool to learn that a tool it may not call exists.
 */

/** A tool, minimally, so a case can say what it is about in its own arguments. */
function spec(id: string, index?: string): ToolSpec {
  return {
    id,
    wire: id.replace(/\./g, '_'),
    tier: 'read',
    title: id,
    description: `the full description of ${id}, which is long`,
    ...(index === undefined ? {} : { index }),
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    summary: () => id,
    run: async () => ({ value: null, summary: {} }),
  }
}

function ctx(granted?: ReadonlySet<string>): ToolContext {
  return { ...(granted === undefined ? {} : { granted }) } as ToolContext
}

async function describeCall(
  catalogue: readonly ToolSpec[],
  names: unknown,
  granted?: ReadonlySet<string>,
): Promise<{ tools: { name: string }[]; unknown?: string[] }> {
  const tool = describeTool({ catalogue: () => catalogue })
  const out = await tool.run({ tools: names }, ctx(granted))
  return out.value as { tools: { name: string }[]; unknown?: string[] }
}

describe('what the listing advertises', () => {
  const catalogue = withDescribe([spec('a.first'), spec('b.second', 'what b is for'), spec('c.third')])

  it('drops a tool that carries an index and puts its line in the meta-tool instead', () => {
    const listed = advertisedCatalogue(catalogue)

    expect(listed.map((entry) => entry.id)).toEqual(['a.first', 'c.third', DESCRIBE_ID])
    const meta = listed.find((entry) => entry.id === DESCRIBE_ID)
    expect(meta?.description).toContain('b_second — what b is for')
    // The line is the whole of what is paid for it: no schema, no description.
    expect(meta?.description).not.toContain('the full description of b.second')
  })

  it('spends nothing on a meta-tool when nothing is held behind it', () => {
    const nothingHidden = withDescribe([spec('a.first'), spec('c.third')])
    expect(advertisedCatalogue(nothingHidden).map((entry) => entry.id)).toEqual([
      'a.first',
      'c.third',
    ])
  })

  it('never lets the index itself reach the wire as a field', () => {
    /*
     * `index` is a fact about the catalogue, not part of a tool definition. If
     * `advertiseTool` ever started copying it, every disclosed tool would be
     * paying for its line *and* its schema — the opposite of the trade.
     */
    expect(Object.keys(advertiseTool(spec('b.second', 'what b is for')))).not.toContain('index')
  })

  it('advertises a hidden tool in full rather than stranding it out of reach', () => {
    /*
     * A grant that names a disclosed tool and not the meta-tool is a mistake
     * rather than a policy, and the safe direction out of it is the loud one: a
     * tool nobody can find the arguments for is a dead capability, while a
     * listing briefly over budget is a failing test. See `advertisedCatalogue`.
     */
    const noMeta = [spec('a.first'), spec('b.second', 'what b is for')]
    expect(advertisedCatalogue(noMeta).map((entry) => entry.id)).toEqual(['a.first', 'b.second'])
  })
})

describe('what a describe call answers', () => {
  const catalogue = withDescribe([spec('a.first'), spec('b.second', 'what b is for')])

  it('hands back exactly what the listing would have advertised', async () => {
    const answer = await describeCall(catalogue, ['b_second'])

    /*
     * Byte-identical to the definition `tools/list` would have sent. The whole
     * trade this feature makes is that fetching late is the *same* information
     * as sending early; a describe that returned a paraphrase would be a second
     * answer to "what does the model see".
     */
    const hidden = catalogue.find((entry) => entry.id === 'b.second') as ToolSpec
    expect(answer.tools).toEqual([advertiseTool(hidden)])
    expect(answer.unknown).toBeUndefined()
  })

  it('answers by either spelling, because a caller picks one', async () => {
    expect((await describeCall(catalogue, ['b.second'])).tools[0]?.name).toBe('b_second')
    expect((await describeCall(catalogue, ['b_second'])).tools[0]?.name).toBe('b_second')
  })

  it('describes a tool that was advertised in full, rather than pretending it is gone', async () => {
    // Nothing is gained by refusing this and a turn that asks has a reason —
    // a compacted context is the obvious one.
    expect((await describeCall(catalogue, ['a.first'])).tools[0]?.name).toBe('a_first')
  })

  it('takes several names at once and answers each', async () => {
    const answer = await describeCall(catalogue, ['a.first', 'b.second'])
    expect(answer.tools.map((entry) => entry.name)).toEqual(['a_first', 'b_second'])
  })

  it('takes one bare name, because a model sends one as often as an array', async () => {
    expect((await describeCall(catalogue, 'b.second')).tools[0]?.name).toBe('b_second')
  })

  it('refuses an empty ask and an unbounded one', async () => {
    const tool = describeTool({ catalogue: () => catalogue })
    await expect(tool.run({ tools: [] }, ctx())).rejects.toBeInstanceOf(Refused)
    await expect(
      tool.run({ tools: Array.from({ length: MAX_DESCRIBE_NAMES + 1 }, () => 'a.first') }, ctx()),
    ).rejects.toThrow(/at most/)
  })

  it('is a read, and says so where a client can colour it', () => {
    const meta = advertiseTool(describeTool({ catalogue: () => catalogue }))
    expect((meta['annotations'] as { readOnlyHint: boolean }).readOnlyHint).toBe(true)
  })

  it('sees a tool contributed after the catalogue was built', async () => {
    /*
     * `withDescribe` closes the meta-tool over the finished array, which is what
     * lets it answer about `extraTools` — the browser verbs, the asset checks,
     * the server actions. Tonight's whole problem was contributed tools, so a
     * meta-tool that could only see `buildCatalogue()` would have solved
     * nothing.
     */
    const late = withDescribe([...buildCatalogue()])
    expect((await describeCall(late, ['settings_write'])).tools[0]?.name).toBe('settings_write')
  })
})

describe('the thing a positive list exists to stop', () => {
  const catalogue = withDescribe([
    spec('browser.open'),
    spec('assets.ledger', 'the resume ledger'),
    spec('sessions.send'),
    spec('tour.play', 'drive the screen'),
  ])
  const granted: ReadonlySet<string> = new Set([
    'browser.open',
    'browser_open',
    'assets.ledger',
    'assets_ledger',
    DESCRIBE_ID,
    DESCRIBE_WIRE,
  ])

  it('answers about a tool outside the grant exactly as about one that does not exist', async () => {
    /*
     * The wording is `server.ts`'s, for the reason `server.ts` gives: *"the
     * difference between 'no such tool' and 'not for you' is exactly what must
     * not be learnable by trying."* A session that may not drive other sessions
     * must not be able to establish that `sessions.send` is a thing by asking
     * about it.
     */
    const real = await describeCall(catalogue, ['sessions_send'], granted)
    const invented = await describeCall(catalogue, ['sessions_teleport'], granted)

    expect(real.tools).toEqual([])
    expect(real.unknown).toEqual(['no tool called sessions_send'])
    // The two answers are the same answer. Byte for byte, and deliberately.
    expect(JSON.stringify(real)).toBe(
      JSON.stringify(invented).replace('sessions_teleport', 'sessions_send'),
    )
  })

  it('leaks nothing through a mixed ask either', async () => {
    const answer = await describeCall(catalogue, ['assets_ledger', 'tour_play'], granted)
    expect(answer.tools.map((entry) => entry.name)).toEqual(['assets_ledger'])
    expect(answer.unknown).toEqual(['no tool called tour_play'])
  })

  it('shows a caller an index of only its own tools', () => {
    const visible = catalogue.filter((entry) => visibleTo(granted, entry))
    const meta = advertisedCatalogue(visible).find((entry) => entry.id === DESCRIBE_ID)

    expect(meta?.description).toContain('assets_ledger — the resume ledger')
    // `tour.play` is behind the meta-tool for everyone; for this caller it is
    // not behind it, it is absent. An index line naming it would be the same
    // leak as listing it, spelled differently.
    expect(meta?.description).not.toContain('tour_play')
  })

  it('is on the session allow-list, or eight granted tools would be unreachable', () => {
    /*
     * `SESSION_TOOLS` grants a session fourteen tools and eight of them are held
     * behind the meta-tool. Without this entry a session would hold capabilities
     * whose arguments it could never obtain — a dead control, which is the shape
     * of defect this app keeps being about.
     */
    expect(SESSION_TOOLS.has(DESCRIBE_ID)).toBe(true)
    expect(SESSION_TOOLS.has(DESCRIBE_WIRE)).toBe(true)
  })
})

describe('every index line', () => {
  const catalogue = withDescribe([...buildCatalogue()])
  const behind = catalogue.filter((entry) => entry.index !== undefined)

  it('is enough to choose by rather than a restated title', () => {
    /*
     * The failure that makes progressive disclosure cost *more* than it saves:
     * an index a model cannot choose from, so it describes everything. A line
     * has to say what the tool is for, which a title does not.
     */
    expect(behind.length).toBeGreaterThan(0)
    for (const entry of behind) {
      const line = entry.index as string
      expect(line.length, `${entry.id}'s index line is too short to choose by`).toBeGreaterThan(60)
      // Long enough to be useful, short enough that fifteen of them are still a
      // fraction of what fifteen schemas cost.
      expect(line.length, `${entry.id}'s index line is a description, not a line`).toBeLessThan(200)
      expect(line, `${entry.id}'s index line is just its title`).not.toBe(entry.title)
      expect(line.trim(), `${entry.id}'s index line is not a sentence`).toMatch(/\.$/)
    }
  })
})
