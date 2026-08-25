import { describe, expect, it } from 'vitest'
import type {
  ReadinessCheck,
  ReadinessCheckId,
  ReadinessFix,
  ReadinessFixId,
  ReadinessFixResult,
  ReadinessForAgent,
  ReadinessReport,
} from '../../readiness'
import { CHECK_WEIGHTS } from '../../readiness'
import type { AgentCliVersion } from '../../browser-signin'
import type { PanelRow } from '../protocol'
import type { Panel, PanelActionRequest, PanelPayload } from './contract'
import { countLine, readinessPanel, type AgentCliReport } from './readiness'

/**
 * Everything here drives the panel through injected `scan` and `fix`, and never
 * through the real ones.
 *
 * Not only for speed. `applyReadinessFix` writes into a repository and one of
 * its ids runs the machine's package manager — `readiness.test.ts` records the
 * run where a first draft of it upgraded the agent CLI on the machine the suite
 * was running on, from 0.32.1 to 0.46.0, while asserting that a channel
 * dispatched. What this file is checking is the mapping between a report and a
 * panel, which is a pure question, so it is asked purely.
 */

const FOLDER = '/work/project'

function check(over: Partial<ReadinessCheck> & Pick<ReadinessCheck, 'id'>): ReadinessCheck {
  return {
    id: over.id,
    title: over.title ?? over.id,
    status: over.status ?? 'pass',
    weight: over.weight ?? CHECK_WEIGHTS[over.id],
    detail: over.detail ?? 'What the scan found here.',
    fix: over.fix ?? null,
    gate: over.gate ?? false,
    opens: over.opens ?? null,
  }
}

function report(over: Partial<ReadinessReport> = {}): ReadinessReport {
  return {
    projectPath: FOLDER,
    score: 70,
    band: 'fair',
    checks: [check({ id: 'secrets', title: 'No secrets committed', gate: true })],
    cappedBy: null,
    agents: [],
    scannedAt: '2026-08-24T09:00:00.000Z',
    ...over,
  }
}

/** A fix that writes one file and can be undone by deleting it. */
const CREATE_README: ReadinessFix = {
  id: 'create-readme',
  label: 'Create the README',
  description: 'Writes a short README at the project root, with placeholders to fill in.',
  touches: ['README.md'],
  destructive: false,
}

/** The one shape of fix that reaches into git's index. */
const UNTRACK_SECRETS: ReadinessFix = {
  id: 'untrack-secrets',
  label: 'Untrack and ignore',
  description:
    'Adds the secret patterns, then stops git following those files. They stay on your disk, and they remain in every past commit.',
  touches: ['.gitignore', 'git index'],
  destructive: true,
}

function applied(message: string): ReadinessFixResult {
  return { ok: true, message, changed: [] }
}

function agentEntry(over: Partial<ReadinessForAgent> = {}): ReadinessForAgent {
  return {
    agent: 'codex',
    label: 'Codex CLI',
    file: 'AGENTS.md',
    check: check({ id: 'claude-md', title: 'Agent instructions present and useful', status: 'fail' }),
    score: 20,
    band: 'at-risk',
    cappedBy: null,
    ...over,
  }
}

/** `act` is optional on the interface, and this panel is one of the ones that has it. */
async function act(panel: Panel, request: PanelActionRequest): Promise<PanelPayload> {
  if (!panel.act) throw new Error('the readiness panel is expected to act')
  return panel.act(request)
}

function rowNamed(payload: PanelPayload, id: string): PanelRow {
  const found = payload.rows.find((row) => row.id === id)
  if (!found) throw new Error(`no row with id ${id} in ${payload.rows.map((row) => row.id).join(', ')}`)
  return found
}

/* ------------------------------------------------------------------ read -- */

describe('reading the panel', () => {
  it('leads with the score, the band and the count the weighting actually produced', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () =>
        report({
          score: 68,
          band: 'fair',
          checks: [
            check({ id: 'secrets', status: 'pass', gate: true }),
            check({ id: 'readme', status: 'pass' }),
            check({ id: 'git-repo', status: 'pass' }),
            check({ id: 'lockfile', status: 'fail' }),
            check({ id: 'lint-script', status: 'skip' }),
          ],
        }),
    })

    const payload = await panel.read({ path: FOLDER })
    const summary = payload.rows[0]

    expect(summary.title).toBe('AI readiness')
    expect(summary.value).toBe('68 out of 100')
    expect(summary.status).toBe('warn')
    expect(summary.detail).toContain('Workable')
    expect(summary.detail).toContain('3 of 4 applicable checks passing, weighted')
    expect(summary.detail).toContain('1 not applicable here')
    expect(payload.path).toBe(FOLDER)
  })

  it('says why a capped score is not the number the weights alone give', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () =>
        report({ score: 39, band: 'at-risk', cappedBy: 'No secrets committed' }),
    })

    const payload = await panel.read({ path: FOLDER })
    expect(payload.rows[0].detail).toContain('Score held at 39 by No secrets committed')
    expect(payload.rows[0].status).toBe('bad')
  })

  it('tints each status the way the phone reads it, and leaves a skipped check untinted', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () =>
        report({
          checks: [
            check({ id: 'secrets', status: 'pass', gate: true }),
            check({ id: 'readme', status: 'warn' }),
            check({ id: 'lockfile', status: 'fail' }),
            check({ id: 'lint-script', status: 'skip' }),
          ],
        }),
    })

    const payload = await panel.read({ path: FOLDER })

    expect(rowNamed(payload, 'secrets').status).toBe('ok')
    expect(rowNamed(payload, 'readme').status).toBe('warn')
    expect(rowNamed(payload, 'lockfile').status).toBe('bad')

    // No tint at all, and the word carries what the colour cannot.
    expect(rowNamed(payload, 'lint-script').status).toBeUndefined()
    expect(rowNamed(payload, 'lint-script').value).toBe('Not applicable')
    expect(rowNamed(payload, 'secrets').value).toBe('Passing')
  })

  it('puts the gate above every other failure, then failures before warnings', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () =>
        report({
          checks: [
            check({ id: 'lint-script', status: 'skip' }),
            check({ id: 'claude-md', status: 'pass' }),
            check({ id: 'readme', status: 'warn' }),
            check({ id: 'lockfile', status: 'fail' }),
            check({ id: 'secrets', status: 'warn', gate: true }),
          ],
        }),
    })

    const payload = await panel.read({ path: FOLDER })
    // The summary leads; the checks follow it in worklist order.
    expect(payload.rows.slice(1).map((row) => row.id)).toEqual([
      'secrets',
      'lockfile',
      'readme',
      'claude-md',
      'lint-script',
    ])
    expect(rowNamed(payload, 'secrets').detail).toContain('it caps the score')
  })

  it('offers the agents the scan graded as scopes, and none when it graded none', async () => {
    const graded = readinessPanel({
      staleAgents: async () => [],
      scan: async () => report({ agents: [agentEntry()] }),
    })
    const bare = readinessPanel({ staleAgents: async () => [], scan: async () => report() })

    expect(await graded.read({ path: FOLDER }).then((payload) => payload.scopes)).toEqual([
      { id: 'project', label: 'Project', on: true },
      { id: 'codex', label: 'Codex CLI', on: false },
    ])
    expect((await bare.read({ path: FOLDER })).scopes).toBeUndefined()
  })

  it('swaps the instructions check and the score when a scope names an agent', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () =>
        report({
          score: 70,
          band: 'fair',
          checks: [
            check({ id: 'secrets', status: 'pass', gate: true }),
            check({ id: 'claude-md', status: 'pass' }),
          ],
          agents: [agentEntry()],
        }),
    })

    const neutral = await panel.read({ path: FOLDER })
    expect(neutral.rows[0].value).toBe('70 out of 100')
    expect(rowNamed(neutral, 'claude-md').value).toBe('Passing')

    const forAgent = await panel.read({ path: FOLDER, scope: 'codex' })
    expect(forAgent.rows[0].value).toBe('20 out of 100')
    expect(forAgent.rows[0].detail).toContain('Graded for Codex CLI')
    expect(rowNamed(forAgent, 'claude-md').value).toBe('Failing')
    expect(forAgent.scopes?.find((scope) => scope.id === 'codex')?.on).toBe(true)
  })

  it('falls back to the project view for a scope this report has no entry for', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () => report({ score: 70, agents: [agentEntry()] }),
    })

    const payload = await panel.read({ path: FOLDER, scope: 'an-agent-that-left-the-catalogue' })
    expect(payload.rows[0].value).toBe('70 out of 100')
    expect(payload.rows[0].detail).not.toContain('Graded for')
  })
})

/* --------------------------------------------------------------- buttons -- */

describe('what a row offers', () => {
  it('carries a fixable check’s own fix, and gives an unfixable one nothing to press', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () =>
        report({
          checks: [
            check({ id: 'readme', status: 'fail', fix: CREATE_README }),
            // The shape the desktop argues about at length: a true finding no
            // machine can repair.
            check({ id: 'git-clean', status: 'warn', fix: null, opens: null }),
          ],
        }),
    })

    const payload = await panel.read({ path: FOLDER })
    expect(rowNamed(payload, 'readme').actions).toEqual([
      { id: 'create-readme', label: 'Create the README' },
    ])
    expect(rowNamed(payload, 'git-clean').actions).toBeUndefined()
  })

  it('marks a destructive fix destructive and hands over its full description to confirm', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () =>
        report({
          checks: [check({ id: 'secrets', status: 'fail', gate: true, fix: UNTRACK_SECRETS })],
        }),
    })

    const payload = await panel.read({ path: FOLDER })
    expect(rowNamed(payload, 'secrets').actions).toEqual([
      {
        id: 'untrack-secrets',
        label: 'Untrack and ignore',
        kind: 'destructive',
        confirm: UNTRACK_SECRETS.description,
      },
    ])
  })

  it('puts what a fix touches on the row itself, where a hover cannot reach', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () =>
        report({
          checks: [check({ id: 'secrets', status: 'fail', gate: true, fix: UNTRACK_SECRETS })],
        }),
    })

    const payload = await panel.read({ path: FOLDER })
    expect(rowNamed(payload, 'secrets').detail).toContain('Changes .gitignore, git index.')
  })

  it('names the file behind a finding no button can repair', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () =>
        report({
          checks: [check({ id: 'readme', status: 'warn', fix: null, opens: 'README.md' })],
        }),
    })

    const payload = await panel.read({ path: FOLDER })
    expect(rowNamed(payload, 'readme').detail).toContain('README.md')
    expect(rowNamed(payload, 'readme').actions).toBeUndefined()
  })

  it('offers Scan again on the panel itself, whatever the rows say', async () => {
    const panel = readinessPanel({ staleAgents: async () => [], scan: async () => report() })
    expect((await panel.read({ path: FOLDER })).actions).toEqual([
      { id: 'scan', label: 'Scan again' },
    ])
  })
})

/* ---------------------------------------------------------------- acting -- */

describe('acting on the panel', () => {
  it('runs the fix, then answers with the panel as it is afterwards', async () => {
    let repaired = false
    const asked: Array<[string, ReadinessFixId]> = []
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () =>
        report({
          score: repaired ? 78 : 55,
          checks: [
            check({
              id: 'readme',
              status: repaired ? 'pass' : 'fail',
              fix: repaired ? null : CREATE_README,
            }),
          ],
        }),
      fix: async (path, id) => {
        asked.push([path, id])
        repaired = true
        return applied('Wrote the README. Fill in the placeholders.')
      },
    })

    const payload = await act(panel, { path: FOLDER, action: 'create-readme', fields: {} })

    expect(asked).toEqual([[FOLDER, 'create-readme']])
    expect(payload.notice).toBe('Wrote the README. Fill in the placeholders.')
    // The re-scan, not the report the button was drawn from.
    expect(payload.rows[0].value).toBe('78 out of 100')
    expect(rowNamed(payload, 'readme').value).toBe('Passing')
    expect(rowNamed(payload, 'readme').actions).toBeUndefined()
  })

  it('keeps the chosen agent scope across a fix', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () => report({ agents: [agentEntry()] }),
      fix: async () => applied('Done.'),
    })

    const payload = await act(panel, {
      path: FOLDER,
      scope: 'codex',
      action: 'create-agents-md',
      fields: {},
    })
    expect(payload.rows[0].value).toBe('20 out of 100')
    expect(payload.scopes?.find((scope) => scope.id === 'codex')?.on).toBe(true)
  })

  it('dispatches the two instructions fixes the desktop’s own channel refuses', async () => {
    const asked: ReadinessFixId[] = []
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () => report(),
      fix: async (_path, id) => {
        asked.push(id)
        return applied('Written.')
      },
    })

    for (const id of ['create-agents-md', 'create-gemini-md'] as const) {
      const payload = await act(panel, { path: FOLDER, action: id, fields: {} })
      expect(payload.notice).toBe('Written.')
    }
    expect(asked).toEqual(['create-agents-md', 'create-gemini-md'])
  })

  it('sends a machine fix the empty path, and a project fix the folder', async () => {
    const asked: Array<[string, ReadinessFixId]> = []
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () => report(),
      fix: async (path, id) => {
        asked.push([path, id])
        return applied('Upgraded.')
      },
    })

    await act(panel, { path: FOLDER, action: 'upgrade-agent-cli', fields: {} })
    await act(panel, { path: FOLDER, action: 'create-readme', fields: {} })

    expect(asked).toEqual([
      ['', 'upgrade-agent-cli'],
      [FOLDER, 'create-readme'],
    ])
  })

  it('answers Scan again with a fresh panel and a notice, running no fix', async () => {
    let scans = 0
    let fixes = 0
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () => {
        scans += 1
        return report()
      },
      fix: async () => {
        fixes += 1
        return applied('never')
      },
    })

    const payload = await act(panel, { path: FOLDER, action: 'scan', fields: {} })
    expect(payload.notice).toBe('Scanned again.')
    expect(scans).toBe(1)
    expect(fixes).toBe(0)
  })

  it('refuses an action it never offered, redraws, and runs nothing', async () => {
    let fixes = 0
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () => report(),
      fix: async () => {
        fixes += 1
        return applied('never')
      },
    })

    const payload = await act(panel, { path: FOLDER, action: 'rm -rf', fields: {} })
    expect(payload.notice).toBe('That is not an action this panel offers.')
    expect(payload.rows.length).toBeGreaterThan(0)
    expect(fixes).toBe(0)
  })

  it('turns a throwing fix into a notice rather than a thrown panel', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () => report(),
      fix: async () => {
        throw new Error('EACCES on .gitignore')
      },
    })

    const payload = await act(panel, { path: FOLDER, action: 'ignore-secrets', fields: {} })
    expect(payload.notice).toBe('The fix could not be applied: EACCES on .gitignore')
    expect(payload.rows.length).toBeGreaterThan(0)
  })
})

/* ------------------------------------------------------------- degrading -- */

describe('degrading rather than throwing', () => {
  it('catches a scanner that throws into a note, and still offers Scan again', async () => {
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () => {
        throw new Error('ENOENT: no such folder')
      },
    })

    const payload = await panel.read({ path: FOLDER })
    expect(payload.note).toContain('This folder could not be scanned: ENOENT: no such folder')
    expect(payload.rows).toEqual([])
    expect(payload.actions).toEqual([{ id: 'scan', label: 'Scan again' }])
  })

  it('explains the one row a host with no window cannot answer, and keeps every other', async () => {
    // No `staleAgents`: the module that measures them imports Electron as a
    // value, so a headless host cannot load it at all.
    const panel = readinessPanel({
      scan: async () =>
        report({ checks: [check({ id: 'secrets', status: 'pass', gate: true })] }),
    })

    const payload = await panel.read({ path: FOLDER })
    expect(payload.note).toContain('Agent CLI versions are not read on this host')
    // The project's own checks are all there — the degrade costs one row, not
    // the panel, which is the failure this rewrite exists to remove.
    expect(rowNamed(payload, 'secrets').value).toBe('Passing')
    expect(payload.rows.some((row) => row.id?.startsWith('agent-cli'))).toBe(false)
  })

  it('reports a stale agent CLI with an upgrade button when the host can measure one', async () => {
    const panel = readinessPanel({
      scan: async () => report(),
      staleAgents: async () => [
        {
          command: 'some-agent',
          version: '0.32.1',
          stale: true,
          advice: 'Upgrade it: `brew upgrade some-agent`.',
        },
      ],
    })

    const payload = await panel.read({ path: FOLDER })
    const row = rowNamed(payload, 'agent-cli:some-agent')
    expect(row.title).toBe('some-agent is too old to sign in')
    expect(row.value).toBe('0.32.1')
    expect(row.status).toBe('warn')
    expect(row.actions).toEqual([{ id: 'upgrade-agent-cli', label: 'Upgrade it' }])
    expect(payload.note).toBeUndefined()
  })

  it('keeps a failing agent CLI probe out of the rows and in the note', async () => {
    const panel = readinessPanel({
      scan: async () => report(),
      staleAgents: async () => {
        throw new Error('the login shell would not answer')
      },
    })

    const payload = await panel.read({ path: FOLDER })
    expect(payload.note).toContain('Agent CLI versions could not be read: the login shell would not answer')
    expect(payload.rows.some((row) => row.id?.startsWith('agent-cli'))).toBe(false)
  })
})

/* ------------------------------------------------------------ the count -- */

describe('countLine', () => {
  it('drops the trailing clause when nothing was skipped', () => {
    expect(countLine(9, 10, 0)).toBe('9 of 10 applicable checks passing, weighted.')
  })

  it('names how many rows the count is not counting', () => {
    expect(countLine(3, 4, 6)).toBe(
      '3 of 4 applicable checks passing, weighted · 6 not applicable here.',
    )
  })

  it('reads as one check when only one applies', () => {
    expect(countLine(1, 1, 9)).toContain('1 of 1 applicable check passing')
  })
})

/* ------------------------------------------------------------ the shape -- */

describe('the shape the contract asks for', () => {
  it('names a row by the check id an action would name', async () => {
    const ids: ReadinessCheckId[] = ['secrets', 'readme', 'lockfile']
    const panel = readinessPanel({
      staleAgents: async () => [],
      scan: async () => report({ checks: ids.map((id) => check({ id })) }),
    })

    const payload = await panel.read({ path: FOLDER })
    for (const id of ids) expect(rowNamed(payload, id).id).toBe(id)
  })
})

/**
 * The one thing a type-only import used to guarantee, asserted instead.
 *
 * `AgentCliReport` is declared in `readiness.ts` rather than imported from
 * `browser-signin.ts`, because `src/headless/seam.test.ts` walks the module
 * graph by **every** `from '…'` clause — `import type` included, since a regex
 * cannot tell one from the other and the walk is a regex on purpose so a
 * re-export cannot fool it. A type-only edge to that file therefore put
 * `electron` inside the daemon's closure and broke the seam, which is the one
 * hard constraint on this half of the tree.
 *
 * What that import *did* buy was a compile error the day `AgentCliVersion` grew
 * a field. This buys it back: the assignment below only typechecks while the two
 * shapes agree, and it is a compile-time check written as a test so that it has
 * somewhere to live.
 */
describe('the shape the desktop actually answers with', () => {
  it('still matches the one this panel asks for', () => {
    const fromTheDesktop: AgentCliVersion = {
      command: 'claude --version',
      version: '1.0.60',
      stale: true,
      advice: 'Update the Claude CLI to sign in from here.',
    }
    const asThisPanelWantsIt: AgentCliReport = fromTheDesktop
    // And back, so a field added on *either* side is a failure rather than a
    // silently widened structural match.
    const andBack: AgentCliVersion = asThisPanelWantsIt
    expect(andBack).toEqual(fromTheDesktop)
  })
})
