/**
 * `tools.coverage` — "can you do the thing I do by hand?", answered from the
 * table that proves it.
 *
 * ## Why the table is a tool
 *
 * `actions/` lists every action a person can take in this app — every channel
 * the window sends the main process, every command and gesture that only moves
 * the window — and says for each one which tool does the same thing, or, in one
 * sentence, why no tool may. `actions.test.ts` and `actions/ui.test.ts` keep it
 * against the source, so it is never a list somebody forgot to update.
 *
 * Until now the only reader of that table was a test. But the question it
 * answers is exactly the one an AI in another application has about this one,
 * and has no way to settle: it can see the tool names, and it cannot see the
 * *gaps*. Told "export my saved passwords", a model with no tool for it will
 * look for one, call the nearest thing, or invent a workaround; told "there is
 * deliberately no tool, because it would hand a secret back in the clear", it
 * says that to the person and stops. The skip sentences were written for a
 * reviewer and they are the right sentence for the model too — which is why the
 * table now ships, rather than being a test fixture that happens to be true.
 *
 * Read-only, and it reaches nothing: the answer is the table itself, the same
 * object the tests check. A tool it names may still be one this caller cannot
 * see; the answer says so, and `tools.describe` is where that is decided.
 */

import { COVERAGE_AREAS, type Coverage, type CoverageMap } from './actions'
import { UI_COMMANDS, UI_GESTURES } from './actions/ui'
import { optBool, optStr, type ToolSpec } from './catalogue'

/** Every table, by the area name a caller passes. The window's two count as one. */
const TABLES: Readonly<Record<string, CoverageMap>> = Object.freeze({
  ...COVERAGE_AREAS,
  window: Object.freeze({ ...UI_COMMANDS, ...UI_GESTURES }),
})

export const COVERAGE_AREA_NAMES: readonly string[] = Object.keys(TABLES)

/** Rows one answer carries. The whole table is a few hundred rows; a model wants the few that match. */
export const MAX_COVERAGE_ROWS = 60

export interface CoverageRow {
  area: string
  action: string
  tools?: string[]
  skip?: string
}

function rowOf(area: string, action: string, entry: Coverage): CoverageRow {
  if (entry === null) return { area, action, skip: 'Not decided yet.' }
  if ('skip' in entry) return { area, action, skip: entry.skip }
  return { area, action, tools: typeof entry.tool === 'string' ? [entry.tool] : [...entry.tool] }
}

/** Every row, from every table, in a stable order. */
export function coverageRows(): CoverageRow[] {
  return Object.entries(TABLES).flatMap(([area, table]) =>
    Object.entries(table).map(([action, entry]) => rowOf(area, action, entry)),
  )
}

/**
 * The rows a query names: every word of it somewhere in the action, a tool id
 * or the reason. Words rather than a phrase, because the action names are the
 * app's own (`session:held-retry`, "drop a file on a session") and a model asks
 * in its own ("retry a session that failed").
 */
export function matchingRows(rows: readonly CoverageRow[], query: string): CoverageRow[] {
  const words = query.toLowerCase().split(/[\s:._-]+/u).filter((word) => word.length > 1)
  if (words.length === 0) return [...rows]
  return rows.filter((row) => {
    const text = `${row.action} ${(row.tools ?? []).join(' ')} ${row.skip ?? ''}`.toLowerCase()
    return words.every((word) => text.includes(word))
  })
}

export function coverageTool(): ToolSpec {
  return {
    id: 'tools.coverage',
    wire: 'tools_coverage',
    tier: 'read',
    title: 'Can a tool do what a person does here?',
    index: 'Whether a tool can do something a person does in this app — and if not, the reason. Ask before working around.',
    description:
      'This app’s own table of every action a person can take in it — every button, menu, command and gesture — ' +
      'and for each, the tool that does the same thing, or one sentence on why there deliberately is no tool ' +
      '(it would hand back a password, answer its own confirmation, and so on). Pass `query` in plain words ' +
      '("rename a session", "saved passwords") to find the rows; `area` narrows to sessions, machines, agents, ' +
      'browser or window. With nothing, it answers the counts. When a row says there is no tool, tell the person ' +
      'that and why, rather than looking for another way to do it. A tool it names may still be one you cannot ' +
      'see; tools.describe says.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Plain words for the action, e.g. "switch account".' },
        area: { type: 'string', enum: [...COVERAGE_AREA_NAMES] },
        skippedOnly: { type: 'boolean', description: 'Only the actions with no tool, and why.' },
      },
      additionalProperties: false,
    },
    summary: (args) => {
      const query = optStr(args, 'query')
      return query === null ? 'Read what the tools cover' : `Look up whether a tool can “${query}”`
    },
    run: async (args) => {
      const area = optStr(args, 'area')
      const query = optStr(args, 'query')
      const skippedOnly = optBool(args, 'skippedOnly', false)
      const all = coverageRows()
      const counts = Object.fromEntries(
        Object.keys(TABLES).map((name) => {
          const rows = all.filter((row) => row.area === name)
          return [name, { actions: rows.length, withTool: rows.filter((row) => row.tools !== undefined).length }]
        }),
      )
      const scoped = all.filter((row) => (area === null || row.area === area) && (!skippedOnly || row.skip !== undefined))
      if (query === null && !skippedOnly && area === null) {
        return {
          value: {
            counts,
            note: 'Pass `query` to look an action up, or `skippedOnly: true` for every action with no tool and why.',
          },
          summary: { rows: 0 },
        }
      }
      const found = query === null ? scoped : matchingRows(scoped, query)
      const rows = found.slice(0, MAX_COVERAGE_ROWS)
      return {
        value: {
          counts,
          rows,
          matched: found.length,
          ...(found.length > rows.length ? { note: 'More rows matched; narrow the query or the area.' } : {}),
          ...(found.length === 0 && query !== null
            ? { note: 'Nothing in the table matches those words. Try fewer, or the name of the screen it is on.' }
            : {}),
        },
        summary: { rows: rows.length, matched: found.length },
      }
    },
  }
}
