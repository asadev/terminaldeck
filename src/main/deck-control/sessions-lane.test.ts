import { describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import { COVERAGE_AREAS } from './actions'
import { UI_COMMANDS, UI_GESTURES } from './actions/ui'
import { browserTools } from './browser-tools'
import { buildCatalogue, catalogueCost, estimateTokens, type ToolSpec } from './catalogue'
import { copilotAdminTools, type CopilotAdminDeps } from './copilot-admin-tools'
import { coverageTool } from './coverage-tool'
import { advertisedCatalogue, describeIndex, withDescribe } from './describe-tool'
import { filesTools, type FilesToolDeps } from './files-tools'
import { projectTools, type ProjectToolDeps } from './project-tools'
import { sessionMoreTools, type SessionMoreDeps } from './session-more-tools'
import { sessionWindowTools } from './session-window-tools'
import { uiTools } from './ui-tools'

/**
 * The lane's tools, held to the catalogue's rules as one set.
 *
 * `sessions-lane.ts` assembles these from the real modules; that file needs an
 * Electron main process to load, so this one builds the same five factories with
 * stand-in deps — nothing here calls a `run`, and a tool's name, tier, index and
 * schema are literals in its factory.
 */

function laneTools(): ToolSpec[] {
  return [
    ...sessionMoreTools({} as SessionMoreDeps),
    ...projectTools({} as ProjectToolDeps),
    ...filesTools({} as FilesToolDeps),
    ...copilotAdminTools({} as CopilotAdminDeps),
    ...uiTools({ evaluate: async () => null }),
    coverageTool(),
  ]
}

/** Every tool a table entry may name: the built-ins, this lane's, and the browser verbs it points at. */
function known(): Set<string> {
  // The session-window tools are `index.ts`'s own (`session-window-tools.ts`),
  // and the sessions table points the `popout:` channels at them.
  const windows = sessionWindowTools({
    view: () => ({ windows: [], displays: [] }),
    open: (sessionId) => ({ ok: false, message: '', sessionId }),
    dock: (sessionId) => ({ ok: false, message: '', sessionId }),
  })
  const all = withDescribe([...buildCatalogue(), ...laneTools(), ...browserTools({} as BrowserDrive), ...windows])
  return new Set(all.map((spec) => spec.id))
}

function named(entry: { tool: string | readonly string[] } | { skip: string } | null): string[] {
  if (entry === null || !('tool' in entry)) return []
  return typeof entry.tool === 'string' ? [entry.tool] : [...entry.tool]
}

describe('the sessions lane', () => {
  it('has decided every channel in its area', () => {
    const undecided = Object.entries(COVERAGE_AREAS.sessions)
      .filter(([, entry]) => entry === null)
      .map(([channel]) => channel)
    expect(undecided).toEqual([])
  })

  it('points every entry at a tool that exists — a table naming a tool nobody built is the lie it replaced', () => {
    const tools = known()
    const tables = [COVERAGE_AREAS.sessions, UI_COMMANDS, UI_GESTURES]
    const missing = tables.flatMap((table) =>
      Object.entries(table).flatMap(([key, entry]) => named(entry).filter((id) => !tools.has(id)).map((id) => `${key} → ${id}`)),
    )
    expect(missing).toEqual([])
  })

  it('adds no tool whose name a built-in already has', () => {
    const builtIn = new Set(buildCatalogue().map((spec) => spec.id))
    const ids = laneTools().map((spec) => spec.id)
    expect(ids.filter((id) => builtIn.has(id))).toEqual([])
    expect(new Set(ids).size).toBe(ids.length)
    for (const spec of laneTools()) expect(spec.wire, spec.id).toBe(spec.id.replace(/\./g, '_'))
  })

  it('holds every one behind tools.describe, so the standing listing does not grow', () => {
    /*
     * The instruction on `MAX_CATALOGUE_TOKENS`: give a new tool an `index` and
     * let it cost one line. None of these is a first reach — each follows a
     * sessions.list, a projects.list or a sessions.send.
     */
    const lane = laneTools()
    expect(lane.filter((spec) => spec.index === undefined).map((spec) => spec.id)).toEqual([])
    const before = catalogueCost(advertisedCatalogue(withDescribe(buildCatalogue())))
    const after = catalogueCost(advertisedCatalogue(withDescribe([...buildCatalogue(), ...lane])))
    expect(after.tools).toBe(before.tools)
  })

  it('costs the index a measured amount, written down so a longer line is visible', () => {
    /*
     * Measured 2026-10-03: 33 tools (with `tools.coverage`), 3,654 characters, ~1,044 estimated tokens of index lines.
     * Every line is a sentence a model chooses by, so the cap is per line as
     * well as in total: a line long enough to be a description belongs in the
     * description.
     */
    const lane = laneTools()
    for (const spec of lane) expect((spec.index ?? '').length, spec.id).toBeLessThanOrEqual(120)
    const tokens = estimateTokens(describeIndex(lane))
    expect(tokens).toBeLessThan(1_200)
  })

  it('declares schemas the dispatcher can hold a caller to', () => {
    for (const spec of laneTools()) {
      const schema = spec.inputSchema as { type?: unknown; additionalProperties?: unknown; properties?: Record<string, unknown>; required?: unknown }
      expect(schema.type, spec.id).toBe('object')
      expect(schema.additionalProperties, spec.id).toBe(false)
      const properties = Object.keys(schema.properties ?? {})
      for (const key of (schema.required as string[] | undefined) ?? []) expect(properties, `${spec.id}.${key}`).toContain(key)
    }
  })
})
