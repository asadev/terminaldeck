/**
 * Is this computer ready to run agents, and is this folder ready for one?
 *
 * The Setup pane and the project Readiness view, as tools:
 *
 *  - `setup.status` — which agent CLIs and tools are installed, signed in and
 *    current (`setup:status`, which already folds in `prereq:check`).
 *  - `readiness.scan` — a folder's score: instructions file, git, a test
 *    script, secrets kept out of the repository, and the fix for each gap.
 *  - `readiness.fix` — apply one of those fixes.
 *
 * ## A fix is applied only when the scan is offering it
 *
 * `readiness.ts` is built on one rule: *"a fix is a description of an action,
 * not the action itself… nothing happens until the user asks for it by id,
 * after showing the user its description."* The window keeps that by drawing
 * the description next to the button. A model has no button, so the tool keeps
 * it the other way round — it scans the folder first and applies a fix only if
 * that scan, now, offers it, and returns the description it applied. A fix id
 * guessed from a name, or remembered from a scan of a different folder, is
 * refused rather than run against a repository it was never offered for.
 *
 * Every fix writes into the person's project (or, for the one machine fix,
 * upgrades an agent CLI), so `readiness.fix` is `alter`.
 */

import { requireKnownFolder, type ToolSpec } from './catalogue'
import { optStr, str } from './agents-area-args'
import { Refused } from './surface'

/** The parts of a `ReadinessReport` this file reads. The rest is passed through. */
export interface ReadinessReportLike {
  checks: Array<{ id: string; fix: { id: string; label: string; description: string; touches: string[]; destructive: boolean } | null }>
}

export interface SetupToolDeps {
  /** `readSetup` — agent CLIs, prerequisites, the copilot. */
  setup(): Promise<unknown>
  /** `scanReadiness`. */
  scan(projectPath: string): Promise<ReadinessReportLike>
  /** `applyReadinessFix`. */
  fix(projectPath: string, fixId: string): Promise<{ ok: boolean; message: string; changed: string[] }>
  /** `FIX_IDS` — the fixes the channel accepts by id. */
  fixIds: ReadonlySet<string>
}

export function setupTools(deps: SetupToolDeps): ToolSpec[] {
  return [
    {
      id: 'setup.status',
      wire: 'setup_status',
      tier: 'read',
      title: 'Check this computer’s setup',
      description:
        'Whether this computer can run agent sessions: each agent CLI (installed, which version, signed in, ' +
        'out of date), the tools they need, and whether at least one agent is ready. When nothing works, this ' +
        'says what is missing and how to install it. Takes a few seconds — it runs each CLI.',
      index: 'Check which agent CLIs and tools are installed and signed in on this computer.',
      inputSchema: { type: 'object', properties: {}, additionalProperties: false },
      summary: () => 'Check this computer’s setup',
      run: async () => ({ value: await deps.setup(), summary: {} }),
    },

    {
      id: 'readiness.scan',
      wire: 'readiness_scan',
      tier: 'read',
      title: 'Score a folder’s readiness for agents',
      description:
        'Score an open folder 0–100 on how ready it is for a coding agent — an instructions file, a README, ' +
        'git, ignore rules, a test and typecheck script, a lockfile, secrets kept out of the repository — with ' +
        'what was found for each, and the fix on offer for each gap (what it does and which files it touches). ' +
        'Graded per agent too. Read-only.',
      index: 'Score how ready an open folder is for coding agents, with a fix for each gap.',
      inputSchema: {
        type: 'object',
        properties: { projectPath: { type: 'string', description: 'An open folder. See projects.list.' } },
        required: ['projectPath'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'projectPath'))
      },
      summary: (args) => `Score the readiness of ${optStr(args, 'projectPath') ?? '?'}`,
      run: async (args, context) => {
        const path = requireKnownFolder(context.surface, str(args, 'projectPath'))
        const report = await deps.scan(path)
        return { value: report, summary: { projectPath: path, checks: report.checks.length } }
      },
    },

    {
      id: 'readiness.fix',
      wire: 'readiness_fix',
      tier: 'alter',
      title: 'Apply a readiness fix',
      description:
        'Apply one fix readiness.scan offers for an open folder — create an instructions file or a .gitignore, ' +
        'add a test script, stop tracking a committed secret, upgrade an agent CLI. Only a fix the folder’s scan ' +
        'is offering right now can be applied. It writes into the project, so the person confirms it; the ' +
        'result lists the files that changed.',
      index: 'Apply one of the fixes readiness.scan offers for a folder.',
      inputSchema: {
        type: 'object',
        properties: {
          projectPath: { type: 'string' },
          fixId: { type: 'string', description: 'The fix id from readiness.scan.' },
        },
        required: ['projectPath', 'fixId'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'projectPath'))
        const fixId = str(args, 'fixId')
        if (!deps.fixIds.has(fixId)) {
          throw new Refused('not-permitted', `${fixId} is not a fix this version can apply by id.`)
        }
      },
      summary: (args) => `Apply the readiness fix ${optStr(args, 'fixId') ?? '?'} to ${optStr(args, 'projectPath') ?? '?'}`,
      run: async (args, context) => {
        const path = requireKnownFolder(context.surface, str(args, 'projectPath'))
        const fixId = str(args, 'fixId')
        if (!deps.fixIds.has(fixId)) {
          throw new Refused('not-permitted', `${fixId} is not a fix this version can apply by id.`)
        }
        const report = await deps.scan(path)
        const offered = report.checks.map((check) => check.fix).find((fix) => fix !== null && fix.id === fixId)
        if (!offered) {
          throw new Refused(
            'not-permitted',
            `the scan of ${path} is not offering ${fixId} right now — that gap may already be closed. ` +
              'Run readiness.scan to see the fixes on offer.',
          )
        }
        const result = await deps.fix(path, fixId)
        if (!result.ok) throw new Refused('not-permitted', result.message)
        return {
          value: { ...result, applied: offered },
          summary: { projectPath: path, fixId, changed: result.changed.length },
        }
      },
    },
  ]
}
