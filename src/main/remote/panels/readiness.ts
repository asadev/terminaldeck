/**
 * AI readiness, on a phone, with the buttons attached.
 *
 * ## What this replaces
 *
 * The first phone answer for this panel ran `command -v` over eight hardcoded
 * names — `git`, `node`, `npm`, three agent CLIs, `unshare`, `setpriv` — and
 * called the result readiness. It was honest about being a stand-in and it was
 * also the wrong subject entirely: this app's readiness feature grades **a
 * project**, not a PATH. `readiness.ts` reads the repository for committed
 * secrets, an instructions file, a test command, a lockfile, a reviewable
 * working tree and five more, weights each of them, gates the whole score on
 * the secrets check, and grades the instructions row once per agent. None of
 * that was on the phone, and nothing on the screen could be pressed.
 *
 * > *"these pages are not just to view the information — exactly all actions
 * > that we have in desktop application, they should be inside each option of
 * > them."*
 *
 * So this panel is the desktop's own scanner, mapped into rows, with each
 * check's own fix declared as the action on its row. Nothing here decides what
 * a check means or when it passes; `scanReadiness` and `applyReadinessFix` are
 * imported and called, and the rest of this file is the mapping.
 *
 * ## Which rows carry a button, and which deliberately do not
 *
 * A check offers its fix when the scanner attached one, and offers nothing when
 * it did not. The desktop takes the same position and argues it in
 * `readiness-dismissed.ts`: nobody can write your README for you, and a working
 * tree is dirty because you are working. What the desktop does with those rows
 * is offer to *open the file* and to *put the row away*, and neither crosses to
 * a phone as anything but an inert control:
 *
 *  - **Open it** hands a `file:` URL to the machine's own editor. The machine is
 *    somewhere else — that is the entire premise of this screen — and on a
 *    headless host there is no editor to hand it to. What a person can actually
 *    do from here is read the path, so the path is in the row's detail.
 *  - **Dismiss** is `localStorage` in the desktop window, per machine, and the
 *    file that owns it says so outright: *"'I know, leave me alone' is a fact
 *    about a person, not about a repository."* A second dismissal store on the
 *    host would be a second answer to that question, and the desktop would never
 *    read it.
 *
 * An action that arrives and does nothing is the defect this whole rewrite
 * exists to remove, so neither is declared.
 *
 * ## The fix ids are a total record, and that is not tidiness
 *
 * `PANEL_FIXES` is `Record<ReadinessFixId, true>` rather than a `Set`, so a
 * sixteenth fix id fails to compile here until it is listed. The `Set` spelling
 * is what `readiness.ts` uses for the same job on the IPC channel, and it has
 * already lost two entries: `FIX_IDS` there lists thirteen of the fifteen ids in
 * the union, omitting `create-agents-md` and `create-gemini-md`. `new
 * Set<ReadinessFixId>([…])` type-checks perfectly while missing members, so the
 * desktop's own channel refuses two fixes the desktop's own panel offers — press
 * the Codex or Gemini pill, press the button under the instructions row, and it
 * answers *"That fix is not one this version knows how to apply."* This panel
 * calls `applyReadinessFix` directly rather than through that channel, so it does
 * not inherit the gap, and the record shape is what stops it acquiring its own.
 *
 * ## Headless
 *
 * The scan itself needs no window: every module it reaches — `fs-tree`, `git`,
 * `platform/host`, `providers`, `tool-probe` — imports Electron as a *type* and
 * nothing more, so the ten project checks and every one of their fixes run
 * unchanged on the daemon in `src/headless/`.
 *
 * One row does not. The desktop's readiness page also carries the machine-level
 * finding from `AgentCliUpdate` — an agent CLI too old to sign in, with an
 * Upgrade button — and the module that measures it, `browser-signin.ts`, imports
 * `shell` from `electron` as a value. Importing it on a host with no Electron
 * throws at load, which is exactly the failure this rewrite is answering: the
 * Store panel threw and the phone said *"This machine could not answer that
 * panel."* So it arrives as an injected dependency instead. A caller that has it
 * passes it; a caller that does not gets every project check and a `note` saying
 * which one thing is missing and why. The upgrade *fix* is Electron-free and
 * lives in `readiness.ts`, so it is only the detection that cannot cross.
 *
 * ## Two smaller decisions, said out loud
 *
 * **Scopes re-scan; on the desktop they do not.** The agent pills there swap a
 * row out of a report already in the window — *"pressing a pill re-reads
 * nothing"*. Over the wire a scope is a field on `panel.read`, so each tap is a
 * fresh scan. That is a cost, not a correctness problem: every payload is built
 * from one scan, so the number and the rows in front of a person always agree
 * with each other, which is the property the desktop comment was protecting.
 *
 * **No `query`.** The desktop panel has no search box over these ten rows and
 * neither does this. A filter that hides part of a worklist that already fits on
 * one screen costs more attention than it saves.
 */

import {
  applyReadinessFix,
  listPaths,
  MACHINE_FIX_IDS,
  scanReadiness,
  type ReadinessBand,
  type ReadinessCheck,
  type ReadinessFix,
  type ReadinessFixId,
  type ReadinessFixResult,
  type ReadinessReport,
  type ReadinessStatus,
} from '../../readiness'
import type { PanelAction, PanelRow, PanelScope } from '../protocol'
import type { Panel, PanelActionRequest, PanelPayload, PanelRequest } from './contract'

/**
 * One agent CLI's version, as `staleAgentCli()` reports it.
 *
 * **Declared here rather than imported from `browser-signin.ts`, and the reason
 * is a measurement rather than a preference.** That module imports `shell` from
 * `electron` as a *value*, and `src/headless/seam.test.ts` walks the module
 * graph by **every** `from '…'` clause — `import type` included, because a
 * type-only import is invisible to a regex and the walk is deliberately a regex
 * so that it cannot be fooled by a re-export. So a type-only edge to that file
 * put Electron inside the daemon's closure and broke the seam, which is the one
 * hard constraint on this half of the tree.
 *
 * Structurally identical to `AgentCliReport` on purpose: this is the shape of a
 * **dependency**, which the caller satisfies with the real function on a desktop
 * and does not satisfy at all on a server. `readiness.test.ts` pins the fields
 * against the real interface so the two cannot drift silently.
 */
export interface AgentCliReport {
  /** The command asked, so a person can run the same thing themselves. */
  command: string
  /** What it answered, or null when it is not installed or would not say. */
  version: string | null
  /** True only when a version was read *and* it is below the floor. */
  stale: boolean
  /** What to do about it. Empty when there is nothing to do. */
  advice: string
}

/** What the panel needs from the machine it is answering for. */
export interface ReadinessPanelDeps {
  /** The desktop's scanner. Injected so a test can drive rows it built itself. */
  scan?: (projectPath: string) => Promise<ReadinessReport>
  /** The desktop's fix runner — the function behind `readiness:fix`. */
  fix?: (projectPath: string, fixId: ReadinessFixId) => Promise<ReadinessFixResult>
  /**
   * Agent CLIs on this machine too old to sign in, from `staleAgentCli()`.
   *
   * Optional because the module that answers it cannot be loaded without
   * Electron. Absent means the row is absent and the `note` says so — never a
   * thrown panel, and never a silent omission.
   */
  staleAgents?: () => Promise<AgentCliReport[]>
}

/** Re-read the panel. The only action that is about the panel rather than a row. */
const SCAN_ACTION = 'scan'

/** The neutral view — the project's own answer, graded for no named agent. */
const PROJECT_SCOPE = 'project'

/** The summary row's id. Outside `ReadinessCheckId`, so it collides with none. */
const SCORE_ROW = 'score'

/**
 * Every fix id this panel will dispatch.
 *
 * Total by type, for the reason the header gives: the `Set` spelling of this
 * same list in `readiness.ts` is missing two of its members and nothing caught
 * it. A new id added to `ReadinessFixId` breaks this object until it is listed.
 */
const PANEL_FIXES: Record<ReadinessFixId, true> = {
  'create-claude-md': true,
  'create-agents-md': true,
  'create-gemini-md': true,
  'create-readme': true,
  'create-gitignore': true,
  'patch-gitignore': true,
  'git-init': true,
  'ignore-secrets': true,
  'untrack-secrets': true,
  'add-test-script': true,
  'replace-test-script': true,
  'add-typecheck-script': true,
  'add-lint-script': true,
  'create-lockfile': true,
  'upgrade-agent-cli': true,
}

function isFixId(value: string): value is ReadinessFixId {
  return Object.hasOwn(PANEL_FIXES, value)
}

/**
 * The status tint, and the one status that has none.
 *
 * `skip` is absent rather than mapped to a colour: a check that does not apply
 * is not a warning, and tinting it as one is how *"1 of 5 checks passing"* came
 * to sit above twelve rows. What says it was skipped is the word in `value`.
 */
const TINT: Record<ReadinessStatus, string | null> = {
  pass: 'ok',
  warn: 'warn',
  fail: 'bad',
  skip: null,
}

/** The right-hand word on a row. Mirrors `STATUS_LABEL` in `ReadinessPanel.tsx`. */
const STATUS_LABEL: Record<ReadinessStatus, string> = {
  pass: 'Passing',
  warn: 'Warning',
  fail: 'Failing',
  skip: 'Not applicable',
}

/** Mirrors `BAND_COPY` in `ReadinessPanel.tsx`, which is where the words were chosen. */
const BAND_COPY: Record<ReadinessBand, string> = {
  strong: 'Ready',
  fair: 'Workable',
  weak: 'Rough',
  'at-risk': 'At risk',
}

/**
 * A band as a tint, over three values rather than four.
 *
 * `fair` and `weak` both land on `warn` because the tint answers *is this a
 * problem*, which has three answers, while the band answers *how ready is this*,
 * which has four. The fourth distinction is not lost — the band's own word leads
 * the summary row's detail.
 */
const BAND_TINT: Record<ReadinessBand, string> = {
  strong: 'ok',
  fair: 'warn',
  weak: 'warn',
  'at-risk': 'bad',
}

/**
 * Failures first, gate above everything.
 *
 * A copy of `sortChecks` in `ReadinessPanel.tsx`, and a copy on purpose: that
 * file is React and this one runs in the main process and in a daemon with no
 * DOM, so neither can import the other. The renderer already mirrors this
 * module's types for the mirror-image reason, stated in its own header. What
 * both spellings encode is that this list is a worklist and not a report card,
 * and that nothing else on it matters while credentials are exposed.
 */
const STATUS_ORDER: Record<ReadinessStatus, number> = { fail: 0, warn: 1, pass: 2, skip: 3 }

function sortChecks(checks: readonly ReadinessCheck[]): ReadinessCheck[] {
  const rank = (check: ReadinessCheck): number =>
    check.gate && (check.status === 'fail' || check.status === 'warn') ? -1 : STATUS_ORDER[check.status]
  return [...checks].sort((a, b) => rank(a) - rank(b) || b.weight - a.weight)
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * The count under the score, and why it names two numbers.
 *
 * The same arithmetic `headlineFor` prints on the desktop, minus the score
 * itself, which is the row's `value` here rather than a clause in its sentence.
 * Reading *"5 of 9 applicable checks passing"* over ten rows is only coherent
 * with the last clause attached: the tenth is skipped, the scan decided that,
 * and the weighting honours it by leaving it out of the denominator.
 */
export function countLine(passing: number, applicable: number, skipped: number): string {
  const counted = `${passing} of ${applicable} applicable check${applicable === 1 ? '' : 's'} passing, weighted`
  return skipped === 0 ? `${counted}.` : `${counted} · ${skipped} not applicable here.`
}

/**
 * One check's fix as a button.
 *
 * `confirm` carries the fix's full description and is set only on a destructive
 * one, because that is the only kind the phone asks twice about — a `confirm`
 * beside `kind: 'default'` would be a paragraph nothing renders. What every
 * other fix discloses instead is `touches`, which moves into the row's detail:
 * the desktop had that list in a `title` tooltip until 2026-08-18 and moved it
 * onto the row on the argument that *"a hover is not a thing that happens on a
 * touch screen"*. This is the touch screen that argument was about.
 */
function buttonFor(fix: ReadinessFix): PanelAction {
  return {
    id: fix.id,
    label: fix.label,
    ...(fix.destructive ? { kind: 'destructive' as const, confirm: fix.description } : {}),
  }
}

function rowFor(check: ReadinessCheck): PanelRow {
  const tint = TINT[check.status]
  const unrepairable = check.fix === null && check.status !== 'pass' && check.opens !== null
  const detail = [
    check.detail,
    check.gate && check.status !== 'pass'
      ? 'Nothing else on this list counts for much while this is open — it caps the score.'
      : '',
    check.fix ? `Changes ${listPaths(check.fix.touches)}.` : '',
    // The path, for the row the desktop offers an Open button on. No machine
    // repairs this one and this phone cannot open a file on a computer that may
    // be in another country, so what it can give is the name of the file.
    unrepairable ? `This one is ${check.opens} — it needs a person, not a button.` : '',
  ]
    .filter((piece) => piece !== '')
    .join(' ')

  return {
    title: check.title,
    detail,
    value: STATUS_LABEL[check.status],
    ...(tint === null ? {} : { status: tint }),
    id: check.id,
    ...(check.fix === null ? {} : { actions: [buttonFor(check.fix)] }),
  }
}

/**
 * The machine-level row, and the sentence that stands in for it when it cannot
 * be measured.
 *
 * Warned rather than failed, deliberately. A stale CLI does break sign-in, but
 * it is not a finding about the project this panel was opened on and it takes no
 * part in the score — painting the loudest colour on the one row that is not
 * what the page is for would push the project's own failures down the screen.
 */
async function machineRows(
  deps: ReadinessPanelDeps,
  notes: string[],
): Promise<PanelRow[]> {
  if (!deps.staleAgents) {
    notes.push(
      'Agent CLI versions are not read on this host: the module that measures them is part of the desktop app and needs its runtime to load. Everything above is this project, and it was scanned in full.',
    )
    return []
  }
  try {
    const stale = await deps.staleAgents()
    return stale.map((row) => ({
      title: `${row.command} is too old to sign in`,
      detail: row.advice,
      value: row.version ?? 'unknown',
      status: 'warn',
      id: `agent-cli:${row.command}`,
      actions: [{ id: 'upgrade-agent-cli', label: 'Upgrade it' }],
    }))
  } catch (error) {
    notes.push(`Agent CLI versions could not be read: ${messageOf(error)}`)
    return []
  }
}

/**
 * The readiness panel for one host.
 *
 * `scan` and `fix` default to the desktop's own functions, so the caller in
 * `server.ts` constructs this with nothing at all on a headless host and with
 * `staleAgents` on a desktop one.
 */
export function readinessPanel(deps: ReadinessPanelDeps = {}): Panel {
  const scan = deps.scan ?? scanReadiness
  const fix = deps.fix ?? applyReadinessFix

  async function read(request: PanelRequest): Promise<PanelPayload> {
    const notes: string[] = []
    const scanAgain: PanelAction[] = [{ id: SCAN_ACTION, label: 'Scan again' }]

    let report: ReadinessReport | null = null
    try {
      report = await scan(request.path)
    } catch (error) {
      // Every individual check inside `scanReadiness` is already guarded and
      // degrades to a row; reaching here means the read of the folder itself
      // failed. A note says which folder and why, and Scan again stays — it is
      // the one control that helps when the answer is "try that again".
      notes.push(`This folder could not be scanned: ${messageOf(error)}`)
    }

    const machine = await machineRows(deps, notes)

    if (report === null) {
      return {
        path: request.path,
        note: notes.join(' '),
        actions: scanAgain,
        rows: machine,
      }
    }

    /*
     * Picking an agent selects a variant the scan already computed — its check,
     * its score, its band and its cap all came out of the same `scoreChecks`
     * the neutral answer went through. Nothing is recalculated here, which is
     * what keeps the number and the rows telling one story; the desktop makes
     * the same substitution in `reportFor` and for the same reason.
     */
    const agents = report.agents ?? []
    const picked = request.scope === undefined || request.scope === PROJECT_SCOPE
      ? null
      : (agents.find((entry) => entry.agent === request.scope) ?? null)
    const checks = picked === null
      ? report.checks
      : report.checks.map((check) => (check.id === picked.check.id ? picked.check : check))
    const score = picked?.score ?? report.score
    const band = picked?.band ?? report.band
    const cappedBy = picked?.cappedBy ?? report.cappedBy

    const counted = checks.filter((check) => check.status !== 'skip')
    const summary = [
      `${BAND_COPY[band]} — ${countLine(counted.filter((check) => check.status === 'pass').length, counted.length, checks.length - counted.length)}`,
      cappedBy === null ? '' : `Score held at ${score} by ${cappedBy} — fix that first.`,
      picked === null ? '' : `Graded for ${picked.label}, which reads ${picked.file}.`,
    ]
      .filter((piece) => piece !== '')
      .join(' ')

    const scopes: PanelScope[] = agents.length === 0
      ? []
      : [
          { id: PROJECT_SCOPE, label: 'Project', on: picked === null },
          ...agents.map((entry) => ({
            id: entry.agent,
            label: entry.label,
            on: picked?.agent === entry.agent,
          })),
        ]

    return {
      path: request.path,
      ...(notes.length === 0 ? {} : { note: notes.join(' ') }),
      ...(scopes.length === 0 ? {} : { scopes }),
      actions: scanAgain,
      rows: [
        {
          title: 'AI readiness',
          detail: summary,
          value: `${score} out of 100`,
          status: BAND_TINT[band],
          id: SCORE_ROW,
        },
        ...machine,
        ...sortChecks(checks).map(rowFor),
      ],
    }
  }

  /**
   * Do one thing, then answer with the panel as it is *afterwards*.
   *
   * The re-read is not a courtesy — it is the contract, and here it is also the
   * only correct answer: a fix that untracks a secret changes what the secrets
   * check finds, and a fix that writes a lockfile changes the score. Replying
   * with the payload the button was drawn from would show somebody the problem
   * they just repaired.
   *
   * The whole request is passed back into `read`, so the scope survives: a fix
   * applied while looking at one agent's grading redraws that agent's grading.
   *
   * `notice` is the fix's own message, verbatim. There is no success flag on the
   * frame and none is needed — `readiness.ts` builds these sentences through
   * `ok()` and `refuse()`, and a refusal says *"nothing was changed"* in words.
   */
  async function act(request: PanelActionRequest): Promise<PanelPayload> {
    if (request.action === SCAN_ACTION) {
      return { ...(await read(request)), notice: 'Scanned again.' }
    }

    if (!isFixId(request.action)) {
      return { ...(await read(request)), notice: 'That is not an action this panel offers.' }
    }

    // A machine fix is about this computer and not about a folder, so it is sent
    // the empty path the desktop sends it. See `MACHINE_FIX_IDS`, which states
    // that as a contract rather than an accident.
    const root = MACHINE_FIX_IDS.has(request.action) ? '' : request.path

    let result: ReadinessFixResult
    try {
      result = await fix(root, request.action)
    } catch (error) {
      // The same wording the `readiness:fix` channel uses for a throw, because a
      // person reading it on a phone and on the desktop is reading about the
      // same event.
      result = { ok: false, message: `The fix could not be applied: ${messageOf(error)}`, changed: [] }
    }

    return { ...(await read(request)), notice: result.message }
  }

  return { read, act }
}
