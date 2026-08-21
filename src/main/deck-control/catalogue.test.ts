import { describe, expect, it } from 'vitest'
import {
  advertiseTool,
  buildCatalogue,
  catalogueCost,
  estimateTokens,
  isProtectedSetting,
  MAX_CATALOGUE_TOKENS,
  MAX_CATALOGUE_TOOLS,
  MAX_NOTE_CHARS,
  MAX_SEND_CHARS,
  PROTECTED_SETTING_KEYS,
  PROTECTED_SETTING_PREFIXES,
  sanitizeNote,
  sanitizeSendText,
  type ToolSpec,
} from './catalogue'

/**
 * The table itself, and the two rules that live in it rather than in the
 * dispatcher: what may be typed into a session, and what may never be written
 * to settings.
 *
 * Everything about *when* a tool runs is in `control.test.ts`. This file is
 * about the shapes that would be wrong however carefully they were dispatched.
 */

describe('the catalogue is well formed', () => {
  const tools = buildCatalogue()

  it('covers the surface the design asks for, and nothing it cannot do', () => {
    expect(tools.map((tool) => tool.id).sort()).toEqual([
      'alerts.list',
      'git.diff',
      'git.status',
      'log.note',
      'projects.list',
      'sessions.get',
      'sessions.list',
      'sessions.result',
      'sessions.send',
      'sessions.start',
      'sessions.stop',
      'sessions.transcript',
      'settings.read',
      'settings.write',
    ])
  })

  it('ships no routine tools, because there is no routine engine', () => {
    // House rule three. `COPILOT-DESIGN.md` lists `routines.*` under phase 3;
    // a `routines.create` that wrote a file nothing ever executed would demo
    // perfectly and lie to the user about what their copilot can do.
    expect(tools.some((tool) => tool.id.startsWith('routines.'))).toBe(false)
  })

  it('names every tool in a way the Anthropic API will accept', () => {
    /*
     * This is the assertion that stops a whole class of "works locally, fails
     * in the model" bug. Claude Code presents an MCP tool to the API as
     * `mcp__<server>__<tool>`, and tool names there are `[a-zA-Z0-9_-]{1,128}`.
     * The dotted ids this codebase reads and logs would be rejected — so the
     * wire name replaces the dot, and this pins the mapping rather than
     * trusting it to survive the next tool somebody adds.
     */
    for (const tool of tools) {
      expect(tool.wire).toBe(tool.id.replace(/\./g, '_'))
      expect(tool.wire).toMatch(/^[a-zA-Z0-9_-]{1,64}$/)
      expect(`mcp__deck-control__${tool.wire}`).toMatch(/^[a-zA-Z0-9_-]{1,128}$/)
    }
  })

  it('gives every tool a schema that refuses unknown arguments', () => {
    for (const tool of tools) {
      expect(tool.inputSchema.type).toBe('object')
      // A schema that tolerated extra keys would let a model attach an argument
      // the handler silently ignores and then believe it had an effect.
      expect(tool.inputSchema.additionalProperties).toBe(false)
    }
  })

  it('puts exactly one tool at the alter tier, and it is the settings writer', () => {
    // `sessions.send` and `sessions.stop` are act-tier by declaration and
    // escalate per call; see `control.test.ts`. Anything else arriving at alter
    // by declaration is a change worth noticing in review.
    expect(tools.filter((tool) => tool.tier === 'alter').map((tool) => tool.id)).toEqual([
      'settings.write',
    ])
  })

  it('marks every reading tool read and every writing one not', () => {
    const byId = new Map(tools.map((tool) => [tool.id, tool.tier]))
    expect(byId.get('sessions.list')).toBe('read')
    expect(byId.get('sessions.get')).toBe('read')
    expect(byId.get('sessions.transcript')).toBe('read')
    expect(byId.get('projects.list')).toBe('read')
    expect(byId.get('git.status')).toBe('read')
    // The two fleet capabilities. Both only ever read — `sessions.result`
    // parses transcripts and runs `git status`, and `git.diff` runs `git diff`
    // — so neither may drift up a tier without somebody arguing for it here.
    expect(byId.get('sessions.result')).toBe('read')
    expect(byId.get('git.diff')).toBe('read')
    expect(byId.get('alerts.list')).toBe('read')
    expect(byId.get('settings.read')).toBe('read')
    expect(byId.get('sessions.start')).toBe('act')
    expect(byId.get('sessions.send')).toBe('act')
    expect(byId.get('sessions.stop')).toBe('act')
    // Writing a line in the audit log changes state, so it is not `read`; it
    // is visible and harmless, so it is not `alter`. A confirmation dialog for
    // a log line is exactly the fatigue that turns a real dialog into a reflex.
    expect(byId.get('log.note')).toBe('act')
  })
})

/**
 * The tool that replaced a shell redirect.
 *
 * The action log used to live inside the copilot's own folder — the one
 * directory it may write to — so appending a row, editing one, or deleting the
 * file were all ordinary writes. The file moved to `<userData>/copilot-log/`
 * (`copilot-log-boundary.test.ts` proves the refusal against a real sandbox);
 * this is the door that was left open on purpose, and these are its bounds.
 */
describe('log.note', () => {
  const note = buildCatalogue().find((tool) => tool.id === 'log.note') as ToolSpec

  it('refuses a note too long to be a line in a list', () => {
    // Refused rather than truncated. `scrubArgs` would silently cut it at two
    // thousand characters, and a row that quietly says less than the caller
    // meant is the wrong failure for the one file that exists to be believed.
    expect(() => sanitizeNote('x'.repeat(MAX_NOTE_CHARS + 1))).toThrow(/characters or fewer/)
    expect(sanitizeNote('x'.repeat(MAX_NOTE_CHARS))).toHaveLength(MAX_NOTE_CHARS)
  })

  it('refuses an empty note, including one that is only spaces', () => {
    expect(() => sanitizeNote('')).toThrow(/must not be empty/)
    expect(() => sanitizeNote('   \t ')).toThrow()
  })

  it('refuses a note that could draw extra rows', () => {
    /*
     * `JSON.stringify` escapes a newline, so the file itself cannot be torn.
     * The reason this is refused is what a reader sees: `detail` is rendered as
     * one line in a list, and a note carrying `\n` can paint what looks like a
     * second row — one it could give any wording it liked, including a wording
     * only the app is supposed to produce.
     */
    for (const bad of ['two\nlines', 'tab\there', 'esc[2J', 'null\u0000byte']) {
      expect(() => sanitizeNote(bad), bad).toThrow(/single line of printable text/)
    }
  })

  it('keeps ordinary prose in any language', () => {
    expect(sanitizeNote('Session 4 has been retrying the same migration — told him')).toContain('—')
    expect(sanitizeNote('ملاحظة عن الجلسة')).toBe('ملاحظة عن الجلسة')
  })

  it('puts the note itself in the sentence a person reads', () => {
    // `control.ts` writes `summary` into the row's `detail` for every call at
    // every tier, and `detail` is the field an Activity pane renders. If this
    // stopped quoting the note, the row would record that a note happened
    // without recording the note.
    expect(note.summary({ note: 'the build is green' }, {} as never)).toContain('the build is green')
  })

  it('refuses a bad note before any budget is spent or dialog drawn', () => {
    expect(() => note.precheck?.({ note: 'x'.repeat(MAX_NOTE_CHARS + 1) }, {} as never)).toThrow()
  })
})

describe('what the catalogue costs on every turn', () => {
  const tools = buildCatalogue()

  /**
   * The number this file exists to hold down.
   *
   * Every tool's name, description and schema is in the copilot's context on
   * *every* request — it is a standing charge, paid whether the tool is called
   * or not, on a server that is permanently attached to a permanently-open
   * session. The comparison worth keeping in mind is GitHub's MCP server at
   * roughly 55K tokens for 93 tools.
   */
  it('fits inside its token budget with room to grow', () => {
    const cost = catalogueCost(tools)

    /*
     * Measured, so a failure reads as a number rather than as a boolean. It was
     * 12 tools, 9,034 characters and ~2,582 estimated tokens when this
     * assertion was written; the two fleet capabilities took it to 14 tools and
     * ~3,368; prose edited since has taken it to **14 tools, 13,275 characters,
     * ~3,793 estimated tokens — 47% of the ceiling**, with `sessions.result`
     * the largest single tool.
     *
     * ## This is the built-ins, and the built-ins are no longer the catalogue
     *
     * The instruction that used to be quoted here — *disclose progressively, do
     * not raise the number* — was carried out on 2026-08-21, when four lanes
     * took the **assembled** list to 33 tools and 10,670 tokens. Neither number
     * was raised. Fifteen tools moved behind `tools.describe`, and four of them
     * are in this very list: `sessions.get`, `git.status`, `settings.write` and
     * `log.note` each carry an `index` now and are not advertised.
     *
     * So this figure is no longer what a turn pays. It is the size of one
     * source, held down because a source that doubles is worth a failing test
     * either way. **`catalogue-cost.test.ts` measures the bill** — every source
     * the app assembles, reduced to what is actually advertised — and that is
     * the file to read before adding a tool.
     */
    expect(cost.tools).toBeLessThanOrEqual(MAX_CATALOGUE_TOOLS)
    expect(cost.tokens, `catalogue is ${cost.tokens} estimated tokens over ${cost.tools} tools`).toBeLessThanOrEqual(
      MAX_CATALOGUE_TOKENS,
    )
    expect(cost.overBudget).toBe(false)
  })

  /**
   * The regression this replaced a count-based pin for.
   *
   * A cap on the *number* of tools cannot see a schema that got fat. One tool
   * with a verbose description is the whole budget, and every count assertion
   * in this file would still be green — which is exactly the failure mode
   * `COPILOT-CAPABILITIES.md` item 8 describes.
   */
  it('notices one verbose tool blowing the budget, while the tool count is still legal', () => {
    const verbose: ToolSpec = {
      ...tools[0],
      id: 'sessions.verbose',
      wire: 'sessions_verbose',
      // A description a well-meaning agent could plausibly write: every rule,
      // spelled out. Roughly 30,000 characters.
      description: 'This tool does a thing, and here is every consideration. '.repeat(540),
    }
    const cost = catalogueCost([...tools, verbose])

    expect(cost.tools).toBeLessThanOrEqual(MAX_CATALOGUE_TOOLS) // the old cap: still happy
    expect(cost.tokens).toBeGreaterThan(MAX_CATALOGUE_TOKENS) // the new one: not
    expect(cost.overBudget).toBe(true)
  })

  it('counts tools contributed by other features, not only the built-in ones', () => {
    // `DeckControl` takes `extraTools`, and the routine engine is the obvious
    // first caller. Measuring only `buildCatalogue()` would leave the one growth
    // path nobody is watching outside the budget it is meant to be held to.
    const contributed: ToolSpec[] = Array.from({ length: 4 }, (_unused, index) => ({
      ...tools[0],
      id: `routines.contributed${index}`,
      wire: `routines_contributed${index}`,
    }))
    const cost = catalogueCost([...tools, ...contributed])
    expect(cost.tools).toBe(tools.length + 4)
    expect(cost.tokens).toBeGreaterThan(catalogueCost(tools).tokens)
  })

  it('measures the payload the transport actually sends', () => {
    /*
     * `server.ts` maps its `tools/list` response through `advertiseTool`, so
     * the thing measured and the thing sent are the same object. If somebody
     * inlines that mapping back into the transport, the budget silently starts
     * describing a listing nobody receives.
     */
    const advertised = advertiseTool(tools[0])
    expect(Object.keys(advertised).sort()).toEqual([
      'annotations',
      'description',
      'inputSchema',
      'name',
      'title',
    ])
    expect(catalogueCost(tools).chars).toBe(JSON.stringify({ tools: tools.map(advertiseTool) }).length)
  })

  it('estimates tokens per tool inside the range the field reports for real ones', () => {
    // A sanity check on the estimator rather than on the catalogue: a tool
    // definition is widely reported to cost 100–500 tokens, and every one of
    // these lands in that band. An estimator that put them at 10 or 5,000 would
    // be measuring something other than what it claims to.
    for (const tool of tools) {
      const cost = estimateTokens(JSON.stringify(advertiseTool(tool)))
      expect(cost, `${tool.id} estimated at ${cost} tokens`).toBeGreaterThan(80)
      expect(cost, `${tool.id} estimated at ${cost} tokens`).toBeLessThan(600)
    }
  })

  it('rounds an estimate up, so a budget is never passed by a fraction', () => {
    expect(estimateTokens('')).toBe(0)
    expect(estimateTokens('x')).toBe(1)
    expect(estimateTokens('x'.repeat(7))).toBe(2)
  })
})

describe('what may be typed into a session', () => {
  it('accepts ordinary prose, in any language', () => {
    expect(sanitizeSendText('run the tests please')).toBe('run the tests please')
    expect(sanitizeSendText('テストを実行してください')).toBe('テストを実行してください')
    expect(sanitizeSendText('اجرا کن')).toBe('اجرا کن')
  })

  it('refuses an escape sequence', () => {
    // Without this, "send some text" is "drive the terminal": move the cursor,
    // rewrite the title, open a bracketed paste, query the emulator.
    expect(() => sanitizeSendText('\u001b[2J')).toThrow(/control/i)
    expect(() => sanitizeSendText('ok\u001b]0;pwned\u0007')).toThrow(/control/i)
  })

  it('refuses process control wearing the costume of a message', () => {
    expect(() => sanitizeSendText('\u0003')).toThrow() // Ctrl-C
    expect(() => sanitizeSendText('\u0004')).toThrow() // Ctrl-D
    expect(() => sanitizeSendText('\u001a')).toThrow() // Ctrl-Z
    expect(() => sanitizeSendText('\u007f')).toThrow() // DEL
  })

  it('refuses embedded newlines, so one call cannot become several commands', () => {
    expect(() => sanitizeSendText('ls\nrm -rf /')).toThrow(/submit/i)
    expect(() => sanitizeSendText('ls\rrm -rf /')).toThrow(/submit/i)
    expect(() => sanitizeSendText('a\tb')).toThrow()
  })

  it('refuses C1 controls, which some terminals read as single-byte escapes', () => {
    expect(() => sanitizeSendText('a\u009bm')).toThrow(/control/i)
  })

  it('refuses empty and oversized text', () => {
    expect(() => sanitizeSendText('')).toThrow()
    expect(() => sanitizeSendText('x'.repeat(MAX_SEND_CHARS + 1))).toThrow(/characters or fewer/)
    expect(sanitizeSendText('x'.repeat(MAX_SEND_CHARS))).toHaveLength(MAX_SEND_CHARS)
  })
})

describe('settings the copilot may never write', () => {
  it('closes the namespaces that decide who can reach this machine', () => {
    expect(isProtectedSetting('remote.enabled')).toBe(true)
    // A prefix, not a list of keys: a `remote.*` setting added next month is
    // protected the day it exists rather than the day somebody remembers.
    expect(isProtectedSetting('remote.somethingAddedLater')).toBe(true)
    expect(isProtectedSetting('security.anything')).toBe(true)
    expect(isProtectedSetting('confine.anything')).toBe(true)
  })

  it('closes the copilot’s own configuration against the copilot', () => {
    expect(isProtectedSetting('copilot.enabled')).toBe(true)
    expect(isProtectedSetting('copilot.permissions.alterNeedsConfirmation')).toBe(true)
    expect(isProtectedSetting('deckControl.anything')).toBe(true)
  })

  it('closes the two individual keys that are security decisions in disguise', () => {
    expect(isProtectedSetting('browser.persistSession')).toBe(true)
    expect(isProtectedSetting('advanced.debugMode')).toBe(true)
  })

  it('leaves ordinary preferences alone', () => {
    expect(isProtectedSetting('appearance.theme')).toBe(false)
    expect(isProtectedSetting('notifications.onComplete')).toBe(false)
    expect(isProtectedSetting('general.language')).toBe(false)
  })

  it('does not protect by substring, which would be a lie about the rule', () => {
    // `remote.` is a prefix. A key that merely mentions the word is not covered
    // and the test says so, so nobody later assumes a substring check.
    expect(isProtectedSetting('appearance.remoteLook')).toBe(false)
    expect(PROTECTED_SETTING_PREFIXES.every((prefix) => prefix.endsWith('.'))).toBe(true)
    expect(PROTECTED_SETTING_KEYS.every((key) => key.includes('.'))).toBe(true)
  })
})
