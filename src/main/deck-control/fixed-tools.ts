/**
 * Stays Fixed, as tools: the project page's buttons for Hoot and for AI apps
 * outside this one.
 *
 * ## What each one is, and why its tier
 *
 *  - `fixed.status` — **read**. Is this project set up, its guards, the build
 *    marked as good, how the last check went, whether one is running; and, when
 *    asked, what this machine can and cannot check here.
 *  - `fixed.check` — **act**. Runs the check and answers with *only* the
 *    differences nobody asked for; everything unchanged is one line with a
 *    count. It runs the person's product in scratch copies, which is the
 *    routine thing a person does with the page's Run check button, so it is
 *    `act` and not `alter`: nothing it does persists except the engine's own
 *    record of the run.
 *  - `fixed.results` — **read**. The last check anybody ran here — the page, an
 *    agent over Stays Fixed's own MCP server, a terminal — the same way.
 *  - `fixed.stop` — **act**. The page's Stop.
 *  - `fixed.setup` — **alter**. Writes a settings file into the project and
 *    three lines into its `.gitignore`. A change to somebody's repository is a
 *    configuration change, and the dialog names the folder.
 *  - `fixed.agents` — **alter**. Gives, or stops giving, every agent session
 *    started in the project a tool server. That is a grant.
 *  - `fixed.mark_good` — **alter, and always put to the owner**
 *    (`ownerMustAnswer`), even for an access key whose owner turned "ask me
 *    before big changes" off. Marking a build as good decides what "working"
 *    means for every check after it. Stays Fixed's whole design rests on that
 *    being a person's act and never an agent's — its own MCP server has no tool
 *    that can do it — so this door is a question to the owner, every time.
 *
 * Every one of them goes through `staysfixed/service.ts`, the object the page
 * uses, so a check Hoot starts is the check the page shows a spinner for, and a
 * second `fixed.check` while one runs joins it rather than starting another.
 *
 * ## Waiting
 *
 * A check of a command-line tool takes seconds; a website, with the old build
 * booted live to prove a difference, takes minutes. Most AI apps give a tool
 * call about a minute, and the relay gives a call from the internet two and a
 * half (`MCP_RELAY_WAIT_MS`). So `fixed.check` waits up to `wait` seconds —
 * 45 by default, at most 120, the same bounds `notifications.wait` settled on —
 * and, if the check is still going, answers with what it is doing and says to
 * call `fixed.results` with a `wait` to collect the answer. The check carries
 * on either way.
 *
 * ## What never comes back
 *
 * Pictures. The page shows a before and an after beside a difference; a model
 * is told how many were kept and gets none of the bytes — a full-page PNG as
 * base64 is a hundred thousand tokens of nothing a model can read.
 */

import { BRAND } from '../../shared/brand'
import { STAYS_FIXED } from '../../shared/stays-fixed'
import type { FixedMarkOutcome, FixedReadiness, FixedSetupOutcome } from '../staysfixed/read'
import type { FixedProgress, FixedShownResults, StaysFixedStatus } from '../staysfixed/service'
import { BadArgument, optBool, optInt, requireKnownFolder, str, type ToolContext, type ToolSpec } from './catalogue'
import { remoteDevice, requireDeviceFolder, requireKeyFolder } from './remote-start'

/* -------------------------------------------------------------- the deps -- */

/** The service's methods, as closures — `staysfixed/service.ts` is the one implementation. */
export interface FixedToolDeps {
  status(projectPath: string): Promise<StaysFixedStatus>
  readiness(projectPath: string, refresh: boolean): Promise<FixedReadiness>
  setup(projectPath: string): Promise<FixedSetupOutcome>
  check(projectPath: string, by: string): Promise<FixedShownResults>
  progress(projectPath: string): FixedProgress | null
  stop(projectPath: string): boolean
  waitFor(projectPath: string, ms: number): Promise<FixedShownResults | null>
  results(projectPath: string, full: boolean): FixedShownResults | null
  markGood(projectPath: string, anyway: boolean): Promise<FixedMarkOutcome>
  setAgents(projectPath: string, on: boolean): Promise<StaysFixedStatus>
}

export const DEFAULT_CHECK_WAIT_SECONDS = 45
export const MAX_CHECK_WAIT_SECONDS = 120

const PROJECT_ARG = {
  type: 'string',
  description: 'The project folder, absolute, as projects.list names it.',
} as const

/* --------------------------------------------------------------- helpers -- */

/**
 * The folder, if this caller may run things in it.
 *
 * A check starts the person's product, so the rule is the one for starting a
 * session (`requireStartableFolder` in `catalogue.ts`, which is private there):
 * the app must have the folder open, a paired device must have been granted
 * it, and an access key limited to some folders must name it.
 */
function projectFor(args: Record<string, unknown>, context: ToolContext): string {
  const known = requireKnownFolder(context.surface, str(args, 'project'))
  const device = remoteDevice(context.caller)
  if (device === null) return requireKeyFolder(context.caller, known)
  return requireDeviceFolder(context.surface, device, known)
}

/** Who asked, as the page says it while the check runs. */
export function askedBy(context: ToolContext): string {
  const caller = context.caller
  if (caller.kind === 'key') return caller.keyName ?? 'an AI app'
  if (caller.kind === 'remote') return 'a paired device'
  if (caller.kind === 'session') return 'an agent session'
  return BRAND.assistant
}

/** Results, as a model reads them: everything the page shows except the pictures. */
export function resultsForModel(results: FixedShownResults | null, full = false): Record<string, unknown> {
  if (results === null) {
    return { ran: false, note: `No check has run in this project yet. Call fixed.check.` }
  }
  return {
    ran: true,
    verdict: results.verdict,
    headline: results.headline,
    at: results.at,
    durationMs: results.durationMs,
    comparedAgainst: results.against,
    checked: results.checked,
    differences: results.differences.map((d) => ({
      id: d.id,
      title: d.title,
      needsPerson: d.needsPerson,
      ...(d.needsPerson ? { needsPersonWhy: d.needsPersonWhy } : {}),
      places: d.count,
      changes: d.changes,
      ...(d.more > 0 ? { moreChanges: d.more } : {}),
      picturesKept: results.pictures[d.id]?.length ?? 0,
    })),
    unchanged: results.unchanged,
    notChecked: results.notChecked,
    newlyUnsteady: results.unsteady,
    ...(full ? { engineSummary: results.detail, notLookedAt: results.gaps } : {}),
  }
}

function waitArg(args: Record<string, unknown>, fallback: number): number {
  return optInt(args, 'wait', fallback, 0, MAX_CHECK_WAIT_SECONDS)
}

/* ----------------------------------------------------------------- tools -- */

export function fixedTools(deps: FixedToolDeps): ToolSpec[] {
  return [
    {
      id: 'fixed.status',
      wire: 'fixed_status',
      tier: 'read',
      title: `${STAYS_FIXED}: where a project stands`,
      index: `${STAYS_FIXED} in one project: set up or not, its guards, the build marked good, the last check, and what this machine can check.`,
      description:
        `${STAYS_FIXED} is a regression safety net built into this app: it runs a project's product twice, compares it with ` +
        'the build last marked as good, and reports only differences nobody asked for. This answers where one project stands: ' +
        'whether it is set up (if not, fixed.setup), its guards (one plain-English rule per bug already fixed once), which build ' +
        'is marked as good, how the last check went and when, whether a check is running now, and whether agent sessions here ' +
        'get the Stays Fixed tools. Pass machine: true to also hear what this computer can and cannot check here and the exact ' +
        'fix for each gap — that part takes up to half a minute.',
      inputSchema: {
        type: 'object',
        properties: {
          project: PROJECT_ARG,
          machine: { type: 'boolean', description: 'Also say what this machine can check here. Slower.' },
        },
        required: ['project'],
        additionalProperties: false,
      },
      summary: (args) => `Look at ${STAYS_FIXED} in ${String(args.project ?? 'a project')}`,
      run: async (args, context) => {
        const project = projectFor(args, context)
        const status = await deps.status(project)
        const machine = optBool(args, 'machine', false)
        let readiness: FixedReadiness | { error: string } | null = null
        if (machine && status.available) {
          readiness = await deps.readiness(project, false).catch((error: unknown) => ({
            error: error instanceof Error ? error.message : String(error),
          }))
        }
        return {
          value: {
            project: status.projectPath,
            available: status.available,
            ...(status.unavailable ? { unavailable: status.unavailable } : {}),
            setUp: status.setUp,
            settingsFile: status.configFile,
            gitRepository: status.git,
            agentsGetIt: status.agents,
            guards: status.guards.map((g) => ({ name: g.name, because: g.because })),
            ...(status.guardProblem ? { guardProblem: status.guardProblem } : {}),
            markedGood: status.reference
              ? { build: status.reference.name, at: status.reference.setAt, forced: status.reference.forced }
              : null,
            lastCheck: status.last
              ? { verdict: status.last.verdict, headline: status.last.headline, at: status.last.at, differences: status.last.differences.length }
              : null,
            running: status.running,
            ...(readiness === null ? {} : { machine: readiness }),
            next: !status.setUp
              ? 'fixed.setup'
              : status.reference === null
                ? 'fixed.check, then ask the owner to mark the build as good (fixed.mark_good)'
                : 'fixed.check',
          },
          summary: { setUp: status.setUp, guards: status.guards.length, running: status.running !== null },
        }
      },
    },
    {
      id: 'fixed.setup',
      wire: 'fixed_setup',
      tier: 'alter',
      title: `Set up ${STAYS_FIXED} in a project`,
      index: `Set ${STAYS_FIXED} up in a project: it reads the repository and writes a settings file. Needs a git repository.`,
      description:
        `Set ${STAYS_FIXED} up in a project — the page's Set up button. It reads the repository (package.json, the framework, ` +
        'routes, commands, built apps) and writes `staysfixed.config.js` with an explanation beside every option, plus three ' +
        'lines in .gitignore. It never overwrites a settings file that is already there. The project must be a git repository. ' +
        'Answers with what it wrote and anything only a person can do (a licence, a device, a password), each with its fix.',
      inputSchema: {
        type: 'object',
        properties: { project: PROJECT_ARG },
        required: ['project'],
        additionalProperties: false,
      },
      summary: (args) => `Set up ${STAYS_FIXED} in ${String(args.project ?? 'a project')} (writes a settings file there)`,
      run: async (args, context) => {
        const project = projectFor(args, context)
        const outcome = await deps.setup(project)
        return { value: outcome, summary: { ok: outcome.ok, wrote: outcome.wrote.length } }
      },
    },
    {
      id: 'fixed.check',
      wire: 'fixed_check',
      tier: 'act',
      title: `Run a ${STAYS_FIXED} check`,
      index: `Check that nothing that already worked in a project has changed; answers with only the differences nobody asked for.`,
      description:
        `Run ${STAYS_FIXED} on a project: it runs the product the way the settings say, compares it with the build marked as ` +
        'good, subtracts what the product disagrees with itself about, and answers with ONLY the differences nobody asked for — ' +
        'each with a plain title, the before and after values, and needsPerson when it touches money, signing in, lost data, a ' +
        'crash or a bug already fixed once (a person must look at those). Everything unchanged is one line with a count. If a ' +
        'check is already running here this joins it. Waits up to `wait` seconds (default 45, max 120); if it is still running ' +
        'then, it says what it is doing and you call fixed.results with a wait to collect the answer. verdict not-compared means ' +
        'nothing is marked as good yet — that is not a pass.',
      inputSchema: {
        type: 'object',
        properties: {
          project: PROJECT_ARG,
          wait: { type: 'integer', description: `Seconds to wait for the answer, 0–${MAX_CHECK_WAIT_SECONDS}. Default ${DEFAULT_CHECK_WAIT_SECONDS}.` },
        },
        required: ['project'],
        additionalProperties: false,
      },
      summary: (args) => `Run a ${STAYS_FIXED} check in ${String(args.project ?? 'a project')}`,
      run: async (args, context) => {
        const project = projectFor(args, context)
        const wait = waitArg(args, DEFAULT_CHECK_WAIT_SECONDS)
        const running = deps.check(project, askedBy(context))
        // The check carries on whatever happens to this call; a rejection is
        // answered here when it lands in time, and on the page when it does not.
        running.catch(() => undefined)
        let timer: ReturnType<typeof setTimeout> | null = null
        const done = await Promise.race([
          running.then((results) => ({ results })),
          new Promise<null>((resolve) => {
            timer = setTimeout(() => resolve(null), wait * 1000)
          }),
        ])
        if (timer) clearTimeout(timer)
        if (done === null) {
          return {
            value: {
              running: true,
              progress: deps.progress(project),
              next: `Still running. Call fixed.results with project and wait (up to ${MAX_CHECK_WAIT_SECONDS}) to get the answer when it finishes.`,
            },
            summary: { running: true },
          }
        }
        return {
          value: resultsForModel(done.results),
          summary: { verdict: done.results.verdict, differences: done.results.differences.length },
        }
      },
    },
    {
      id: 'fixed.results',
      wire: 'fixed_results',
      tier: 'read',
      title: `The last ${STAYS_FIXED} check`,
      index: `The last ${STAYS_FIXED} check in a project — anybody's — with only its unintended differences; can wait for a running one.`,
      description:
        `The last ${STAYS_FIXED} check in a project, whoever ran it — the page, an agent through Stays Fixed's own tools, a ` +
        'terminal — as only the differences nobody asked for, each with before and after, plus one line for everything ' +
        'unchanged and one for what was not looked at. Pass wait (seconds, max 120) to wait for a check that is running. Pass ' +
        'full: true for the full report: every change of every difference, the engine\'s own summary and every thing it did not ' +
        'look at with why.',
      inputSchema: {
        type: 'object',
        properties: {
          project: PROJECT_ARG,
          wait: { type: 'integer', description: `Seconds to wait for a running check, 0–${MAX_CHECK_WAIT_SECONDS}. Default 0.` },
          full: { type: 'boolean', description: 'The full report rather than the summary.' },
        },
        required: ['project'],
        additionalProperties: false,
      },
      summary: (args) => `Read the last ${STAYS_FIXED} check in ${String(args.project ?? 'a project')}`,
      run: async (args, context) => {
        const project = projectFor(args, context)
        const wait = waitArg(args, 0)
        const full = optBool(args, 'full', false)
        if (wait > 0) await deps.waitFor(project, wait * 1000)
        const progress = deps.progress(project)
        const results = deps.results(project, full)
        return {
          value: { ...resultsForModel(results, full), ...(progress ? { runningNow: progress } : {}) },
          summary: { verdict: results?.verdict ?? null, running: progress !== null },
        }
      },
    },
    {
      id: 'fixed.stop',
      wire: 'fixed_stop',
      tier: 'act',
      title: `Stop a ${STAYS_FIXED} check`,
      index: `Stop the ${STAYS_FIXED} check running in a project.`,
      description: `Stop the ${STAYS_FIXED} check running in a project. Stays Fixed puts away what it started first. Answers whether one was running.`,
      inputSchema: {
        type: 'object',
        properties: { project: PROJECT_ARG },
        required: ['project'],
        additionalProperties: false,
      },
      summary: (args) => `Stop the ${STAYS_FIXED} check in ${String(args.project ?? 'a project')}`,
      run: async (args, context) => {
        const project = projectFor(args, context)
        const stopped = deps.stop(project)
        return { value: { stopped, ...(stopped ? {} : { note: 'No check was running there.' }) }, summary: { stopped } }
      },
    },
    {
      id: 'fixed.mark_good',
      wire: 'fixed_mark_good',
      tier: 'alter',
      title: 'Mark this build as good',
      index: `Ask the owner to mark the last-checked build as good, so every later ${STAYS_FIXED} check compares against it.`,
      description:
        'Ask the owner to mark the build that was last checked as good — what every later check compares against. The owner is ' +
        'always asked, whatever this app\'s settings say about asking: deciding what "working" means is a person\'s call. It is ' +
        'refused for a build that was never checked, or whose check could not run — call fixed.check first. When the last check ' +
        'found differences it is refused too, unless anyway: true, which asks the owner to accept those differences as the new ' +
        'normal; say which differences in your message to them.',
      inputSchema: {
        type: 'object',
        properties: {
          project: PROJECT_ARG,
          anyway: { type: 'boolean', description: 'Accept the differences the last check found as the new normal.' },
        },
        required: ['project'],
        additionalProperties: false,
      },
      ownerMustAnswer: () => true,
      summary: (args) =>
        optBool(args, 'anyway', false)
          ? `Mark the last-checked build in ${String(args.project ?? 'a project')} as good, accepting the differences its check found`
          : `Mark the last-checked build in ${String(args.project ?? 'a project')} as good`,
      run: async (args, context) => {
        const project = projectFor(args, context)
        const outcome = await deps.markGood(project, optBool(args, 'anyway', false))
        return { value: outcome, summary: { marked: outcome.marked, refusedFor: outcome.refusedFor } }
      },
    },
    {
      id: 'fixed.agents',
      wire: 'fixed_agents',
      tier: 'alter',
      title: `Give agents ${STAYS_FIXED}`,
      index: `Turn on or off whether agent sessions started in a project get the ${STAYS_FIXED} tools.`,
      description:
        `Whether every agent session started in a project from now on — Claude Code, Codex and Gemini — gets ${STAYS_FIXED}'s ` +
        'own tools (check its own work, explain a finding, prove a cause). On by default once a project is set up. Sessions ' +
        'already running keep what they started with. Nothing in the agents\' own settings files is changed.',
      inputSchema: {
        type: 'object',
        properties: {
          project: PROJECT_ARG,
          on: { type: 'boolean', description: 'true to give it, false to stop giving it.' },
        },
        required: ['project', 'on'],
        additionalProperties: false,
      },
      precheck: (args) => {
        if (typeof args.on !== 'boolean') throw new BadArgument('on is required and must be true or false')
      },
      summary: (args) =>
        `${args.on === true ? 'Give' : 'Stop giving'} agent sessions in ${String(args.project ?? 'a project')} the ${STAYS_FIXED} tools`,
      run: async (args, context) => {
        const project = projectFor(args, context)
        const status = await deps.setAgents(project, args.on === true)
        return { value: { agentsGetIt: status.agents, setUp: status.setUp }, summary: { on: status.agents } }
      },
    },
  ]
}
