import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  limitsFromUtilization,
  PROBE_ARGS,
  probeUsage,
  readingsFromUtilization,
  type ProbeAnswer,
} from './usage-probe'
import { isDrawable, usageFreshness, type UsageAccountRef } from './usage-window'
import { identifyLimit } from './plan-limit'

const ACCOUNT: UsageAccountRef = {
  provider: 'claude',
  id: 'work',
  name: 'Work',
  configDir: '/tmp/deck-usage-probe/work',
}

/**
 * The block Claude Code 2.1.234 had actually written into `~/.claude.json` on
 * this machine at 2026-08-18 15:10 local, trimmed to the fields this module
 * reads.
 *
 * Copied rather than composed. Two of its shapes are the ones a hand-written
 * fixture would have got wrong and would then have proved nothing about:
 * `seven_day_sonnet` is *present and null* on a Max account rather than absent,
 * and the model-scoped weekly limit does not appear as a top-level key at all —
 * it is an entry in `limits[]` with the model's name buried under
 * `scope.model.display_name`.
 */
const REAL_UTILIZATION = {
  five_hour: {
    utilization: 0,
    resets_at: '2026-08-18T16:00:00.254050+00:00',
    limit_dollars: null,
    used_dollars: null,
    remaining_dollars: null,
  },
  seven_day: {
    utilization: 34,
    resets_at: '2026-08-23T23:00:00.254085+00:00',
    limit_dollars: null,
    used_dollars: null,
    remaining_dollars: null,
  },
  seven_day_sonnet: null,
  limits: [
    { kind: 'session', group: 'session', percent: 0, resets_at: '2026-08-18T16:00:00.254050+00:00', scope: null },
    { kind: 'weekly_all', group: 'weekly', percent: 34, resets_at: '2026-08-23T23:00:00.254085+00:00', scope: null },
    {
      kind: 'weekly_scoped',
      group: 'weekly',
      percent: 0,
      resets_at: '2026-08-23T23:00:00.254419+00:00',
      scope: { model: { id: null, display_name: 'Fable' }, surface: null },
    },
  ],
}

/** The fetch instant that block carried. Every reading below is stamped with it. */
const FETCHED_AT = 1787051450329

describe('translating the CLI own utilization block', () => {
  it('names the windows the way Claude Code names them', () => {
    /*
     * The labels are not a presentation choice, they are a quotation.
     * `usage-window.ts` requires a reading to carry the source's own words, and
     * these are the exact strings the 2.1.234 binary's own formatter pairs with
     * these keys — which is also what the `/usage` panel draws and therefore what
     * `plan-limit.ts` parses off a screen. That agreement is what lets a reading
     * from either source land on one id instead of doubling the bar.
     */
    const labels = limitsFromUtilization(REAL_UTILIZATION, 'max').map((limit) => limit.label)
    expect(labels).toContain('Current session')
    expect(labels).toContain('Current week (all models)')
    expect(labels).toContain('Current week (Fable)')
  })

  it('lands on the same ids the screen reader would', () => {
    // Not asserted against literals: the point is that the two translations
    // agree, so it is asserted against the function `plan-limit.ts` uses.
    for (const limit of limitsFromUtilization(REAL_UTILIZATION, 'max')) {
      expect(limit.id).toBe(identifyLimit(limit.label).id)
      expect(limit.scope).toBe(identifyLimit(limit.label).scope)
    }
  })

  it('drops a window the account does not have, rather than drawing it at zero', () => {
    /*
     * `seven_day_sonnet: null` is present in the real block and means "this
     * account has no such window" — not "this account has used none of it". The
     * CLI's own formatter skips it for exactly this reason, and the rule in
     * `usage-window.ts` is the same one: unknown is not zero.
     */
    const ids = limitsFromUtilization(REAL_UTILIZATION, 'max').map((limit) => limit.id)
    expect(ids).not.toContain('week:sonnet')

    const withSonnet = { ...REAL_UTILIZATION, seven_day_sonnet: { utilization: 12, resets_at: null } }
    expect(limitsFromUtilization(withSonnet, 'max').map((limit) => limit.id)).toContain('week:sonnet')
    // …and not on a plan the CLI does not title it for.
    expect(limitsFromUtilization(withSonnet, 'pro').map((limit) => limit.id)).not.toContain('week:sonnet')
  })

  it('reads nothing at all out of a shape it does not recognise', () => {
    expect(limitsFromUtilization(null, 'max')).toEqual([])
    expect(limitsFromUtilization('rate limits', 'max')).toEqual([])
    expect(limitsFromUtilization({ five_hour: { utilization: null, resets_at: null } }, 'max')).toEqual([])
    expect(limitsFromUtilization({ limits: [{ kind: 'weekly_scoped', percent: 5, scope: {} }] }, 'max')).toEqual([])
  })
})

describe('a reading is as old as the fetch behind it', () => {
  it('stamps reportedAt with the CLI fetch, not with now', () => {
    /*
     * The single most important line in the module, and the reason reading
     * `.claude.json` is safe at all.
     *
     * `usage-window.ts`'s header names that block as the thing that nearly
     * shipped a wrong bar: it was found 21.3 hours stale, describing a window
     * that had already ended, and would have read as current. It reads as
     * 40 minutes old here, because the fetch instant travels with the numbers.
     */
    const now = FETCHED_AT + 40 * 60_000
    const readings = readingsFromUtilization(REAL_UTILIZATION, 'max', ACCOUNT, FETCHED_AT, now)
    expect(readings.length).toBeGreaterThan(0)
    for (const reading of readings) {
      expect(reading.reportedAt).toBe(FETCHED_AT)
      expect(reading.observedAt).toBe(now)
      expect(usageFreshness(reading, now).ageMs).toBe(40 * 60_000)
    }
  })

  it('lets a five-hour reading go stale and be refused a live bar', () => {
    const fresh = readingsFromUtilization(REAL_UTILIZATION, 'max', ACCOUNT, FETCHED_AT, FETCHED_AT)
    const session = fresh.find((reading) => reading.window === 'five-hour')
    expect(session && isDrawable(session, FETCHED_AT)).toBe(true)

    // Twenty-six minutes: past `STALE_WINDOW_FRACTION` of five hours, which is
    // the whole reason anything ever goes and fetches a new one.
    const later = FETCHED_AT + 26 * 60_000
    const aged = readingsFromUtilization(REAL_UTILIZATION, 'max', ACCOUNT, FETCHED_AT, later)
    const stale = aged.find((reading) => reading.window === 'five-hour')
    expect(stale && isDrawable(stale, later)).toBe(false)
  })

  it('keeps the reset as an instant, which the panel could never give', () => {
    /*
     * The API answers ISO 8601 where the panel prints `Resets 4am (Asia/Dubai)`
     * — words with no date, no year and no DST rule in them. An instant is
     * strictly better: it is what makes `expired` decidable, so a reading that
     * has outlived the window it describes can say so instead of being drawn.
     */
    const readings = readingsFromUtilization(REAL_UTILIZATION, 'max', ACCOUNT, FETCHED_AT)
    const session = readings.find((reading) => reading.window === 'five-hour')
    expect(session?.resets).toEqual({ state: 'at', at: Date.parse('2026-08-18T16:00:00.254050+00:00') })
    expect(usageFreshness(session!, Date.parse('2026-08-18T17:00:00Z')).expired).toBe(true)
  })

  it('says where it came from, in a source id of its own', () => {
    const readings = readingsFromUtilization(REAL_UTILIZATION, 'max', ACCOUNT, FETCHED_AT)
    expect(readings.every((reading) => reading.source === 'claude-usage-api')).toBe(true)
  })
})

describe('the probe itself', () => {
  /** A transport that records what it was asked and answers with a fixture. */
  function transport(answer: ProbeAnswer): {
    ask: NonNullable<Parameters<typeof probeUsage>[1]>['ask']
    seen: {
      command: string
      args: string[]
      cwd: string
      env: NodeJS.ProcessEnv
      shell: boolean
      platform: NodeJS.Platform
    }[]
  } {
    const seen: {
      command: string
      args: string[]
      cwd: string
      env: NodeJS.ProcessEnv
      shell: boolean
      platform: NodeJS.Platform
    }[] = []
    return {
      seen,
      ask: async (command, args, options) => {
        seen.push({
          command,
          args,
          cwd: options.cwd,
          env: options.env,
          // Recorded because the pair decides what happens to the child when
          // the probe is done with it — see the Windows cleanup case below.
          shell: options.shell,
          platform: options.platform,
        })
        return answer
      },
    }
  }

  const OK: ProbeAnswer = {
    usage: {
      session: { total_cost_usd: 0, total_api_duration_ms: 0 },
      subscription_type: 'max',
      rate_limits_available: true,
      rate_limits: REAL_UTILIZATION,
    },
    error: null,
    killed: false,
  }

  it('turns a real answer into readings for the account it was asked about', async () => {
    const { ask, seen } = transport(OK)
    const result = await probeUsage(ACCOUNT, { ask })
    expect(result.outcome).toBe('ok')
    expect(result.readings.map((reading) => reading.window).sort()).toEqual(['five-hour', 'weekly', 'weekly'])
    expect(result.readings.every((reading) => reading.account.configDir === ACCOUNT.configDir)).toBe(true)
    // Run somewhere that is nobody's project. A read of a subscription must not
    // be attributable to a repository the user happens to have open, and some
    // agent CLIs treat the working directory as context.
    expect(seen[0]?.cwd).not.toContain('terminaldeck')
  })

  it('never sends a user message, which is why it costs nothing', () => {
    /*
     * The measured claim this whole design rests on: `total_cost_usd` came back
     * `0` on every run against his own Max login, because no `/v1/messages`
     * request is made — only the control handshake and `get_usage`.
     *
     * Asserted at the argument list, which is the part a future edit could
     * break: `-p` with the two stream-json formats is the mode that answers
     * control requests, and there is no prompt anywhere in it. A positional
     * prompt argument here would start a real turn and spend real tokens.
     */
    expect(PROBE_ARGS).toContain('-p')
    expect(PROBE_ARGS).toContain('stream-json')
    const positional = PROBE_ARGS.filter(
      (arg) => !arg.startsWith('-') && arg !== 'stream-json' && arg !== '',
    )
    expect(positional).toEqual([])
  })

  it('switches every settings file off, so nobody session hooks fire', () => {
    /*
     * Measured, not assumed: a `SessionStart` hook placed in a scratch project
     * fired when the probe ran with `--setting-sources project` and did not fire
     * with this. His machine has `SessionStart`, `SessionEnd` and a dozen more
     * wired to pawl and to Vibeyard, and a bar refreshing itself must not look
     * to all of them like a session starting.
     *
     * The empty string is the whole of it, so the pair is asserted in order —
     * an edit that drops the value leaves `--setting-sources` swallowing the
     * next flag, which is a failure with no symptom at all from inside this app.
     */
    const at = PROBE_ARGS.indexOf('--setting-sources')
    expect(at).toBeGreaterThanOrEqual(0)
    expect(PROBE_ARGS[at + 1]).toBe('')
  })

  it('does not let this app own session identity leak into the child', async () => {
    /*
     * Deck is frequently started from a terminal that is itself inside a Claude
     * Code session, and those export `CLAUDECODE` and a family of
     * `CLAUDE_CODE_*` variables. A child that inherited them would report itself
     * as a continuation of somebody else's session.
     */
    const before = { ...process.env }
    process.env.CLAUDECODE = '1'
    process.env.CLAUDE_CODE_SESSION_ID = 'not-ours'
    try {
      const { ask, seen } = transport(OK)
      await probeUsage(ACCOUNT, { ask })
      expect(seen[0]?.env.CLAUDECODE).toBeUndefined()
      expect(seen[0]?.env.CLAUDE_CODE_SESSION_ID).toBeUndefined()
    } finally {
      process.env = before
    }
  })

  it('tells a signed-out directory from a login with no subscription', async () => {
    /*
     * The CLI sets `rate_limits_available: false` for both, and only
     * `subscription_type` separates them. They need different sentences because
     * only one of them is something a person can do anything about.
     */
    const out = await probeUsage(ACCOUNT, {
      ask: transport({
        usage: { rate_limits_available: false, subscription_type: null },
        error: null,
        killed: false,
      }).ask,
    })
    expect(out.outcome).toBe('signed-out')
    expect(out.detail).toContain('not signed in')

    const metered = await probeUsage(ACCOUNT, {
      ask: transport({
        usage: { rate_limits_available: false, subscription_type: 'max' },
        error: null,
        killed: false,
      }).ask,
    })
    expect(metered.outcome).toBe('no-limits')
  })

  it('reports a kill and a refusal in words, and never throws', async () => {
    const killed = await probeUsage(ACCOUNT, {
      ask: transport({ usage: null, error: null, killed: true }).ask,
      timeoutMs: 4000,
    })
    expect(killed.outcome).toBe('unreadable')
    expect(killed.detail).toContain('4 seconds')

    /*
     * The failure this feature is allowed to have, and the reason it is allowed.
     *
     * `get_usage` is spelled `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET`
     * in the SDK, and this repo has a standing rule about building on
     * undocumented CLI surface. The rule is kept by making the failure
     * harmless: a renamed request comes back as a sentence on the bar, and
     * nothing else in the app changes — no session is typed into, no login is
     * touched, no credential is read.
     */
    const refused = await probeUsage(ACCOUNT, {
      ask: transport({
        usage: null,
        error: 'REPL bridge does not handle control_request subtype: get_usage',
        killed: false,
      }).ask,
    })
    expect(refused.outcome).toBe('unreadable')
    expect(refused.detail).toContain('get_usage')
    expect(refused.readings).toEqual([])
  })

  it('does not spawn at all when there is no runnable claude', async () => {
    const { ask, seen } = transport(OK)
    const result = await probeUsage(ACCOUNT, {
      ask,
      binary: {
        id: 'claude',
        bin: 'claude',
        onPath: '/usr/local/bin/claude',
        runnable: null,
        version: null,
        broken: true,
        said: 'Error: spawn claude ENOENT',
        usedAlternate: false,
        checkedAt: Date.now(),
      },
    })
    expect(result.outcome).toBe('no-binary')
    expect(seen).toHaveLength(0)
  })
})

describe('the child this probe leaves behind, which on Windows is not the one it spawned', () => {
  /**
   * A transport that answers nothing, used only to read what it was handed.
   * The probe's own outcome is irrelevant here; the arguments are the subject.
   */
  function handedTo(platform: NodeJS.Platform): Promise<{
    shell: boolean
    platform: NodeJS.Platform
    command: string
  }> {
    return new Promise((resolve) => {
      void probeUsage(ACCOUNT, {
        platform,
        path: '/usr/bin',
        binary: {
          id: 'claude',
          bin: 'claude',
          onPath: 'C:\\Program Files\\nodejs\\claude.cmd',
          // The bare name, which is what `agent-binaries.ts` deliberately
          // records as `runnable` on Windows — "the resolved path is a `.cmd`
          // shim that CreateProcess will not run".
          runnable: 'claude',
          version: '2.1.234',
          broken: false,
          said: null,
          usedAlternate: false,
          checkedAt: Date.now(),
        },
        ask: async (command, _args, options) => {
          resolve({ shell: options.shell, platform: options.platform, command })
          return { usage: null, error: null, killed: true }
        },
      })
    })
  }

  it('runs through a command processor on Windows and through none on macOS', async () => {
    /*
     * This is the fact the cleanup below depends on, asserted rather than
     * assumed, because it is invisible from this machine.
     *
     * `probeUsage` calls `launchSpec(runnable, null, platform)` with `resolved`
     * hard-coded to null, so on Windows the batch branch is taken
     * unconditionally: every usage reading is `cmd.exe /d /s /c "claude …"`,
     * and the `node …\claude` that answers is a *grandchild*. On macOS there is
     * no shell at all and the child is the CLI itself.
     */
    const windows = await handedTo('win32')
    expect(windows.shell).toBe(true)
    expect(windows.command).toBe('"claude"')

    const mac = await handedTo('darwin')
    expect(mac.shell).toBe(false)
    expect(mac.command).toBe('claude')
  })

  it('tells the transport which platform it is on, so the kill can be the right one', async () => {
    /*
     * The seam that makes the Windows cleanup reachable and testable at all.
     * `askOverStdio` must not read `process.platform` — `platform/host.ts`
     * forbids it, and a probe that did could never be proved from here. So the
     * platform is handed down with the rest of the launch, and if a future edit
     * drops it the cleanup silently becomes the POSIX one on Windows, which is
     * precisely the leak this pins.
     */
    expect((await handedTo('win32')).platform).toBe('win32')
    expect((await handedTo('darwin')).platform).toBe('darwin')
  })

  it('never ends a probe by signalling the process handle it happens to hold', () => {
    /*
     * Asserted over the source, in the style of the check below it, because the
     * failure has no symptom on the machine this is written on.
     *
     * `child.kill()` is right on macOS and wrong on Windows: the handle there
     * is `cmd.exe`, `TerminateProcess` does not descend, and the agent CLI
     * underneath survives every single reading — holding the half gigabyte the
     * function's own comment says the kill exists to avoid. There is no process
     * group on Windows to signal instead, so the only correct call is the tree
     * kill, and this makes reintroducing the naive one a red test rather than a
     * report from a Windows user.
     */
    const source = readFileSync(join(__dirname, 'usage-probe.ts'), 'utf8')
    // Prose is not code. The comment beside the fix quotes the call it replaced
    // — house style here is to keep superseded reasoning rather than delete it
    // — so the check is made against the source with its comments removed,
    // which is also the only thing that could actually spawn anything.
    const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
    expect(code).not.toMatch(/child\.kill\(/)
    expect(code).toContain('killTree(child, {')
    // And the platform must reach it, rather than a default being invented at
    // the call site.
    expect(code).toContain('platform: options.platform')
  })
})

describe('the one thing this module must never do', () => {
  it('writes nothing to any terminal', () => {
    /*
     * Asserted over the source because it is the requirement, in his words:
     * *"find out some other way to keep the bar refresh"*. Typing `/usage` into
     * a session he was working in was the answer for three versions and was the
     * wrong answer three times. The two strings are what that took: a carriage
     * return to submit the command, and an Escape to close the panel afterwards.
     */
    const source = readFileSync(join(__dirname, 'usage-probe.ts'), 'utf8')
    // The command as it would have to be spelled to reach a pty: the slash
    // command plus the carriage return that submits it. The words on their own
    // are all over the prose above, which is the point of writing any of this
    // down.
    expect(source).not.toMatch(new RegExp('/usage' + String.fromCharCode(92) + 'r'))
    // And the Escape that closed the panel afterwards, in both spellings.
    expect(source).not.toContain(String.fromCharCode(27))
    expect(source.includes(String.fromCharCode(92) + 'u001b')).toBe(false)
    // The only thing this module ever writes to a child is JSON on stdin.
    for (const call of source.match(/stdin\.write\([^)]*/g) ?? []) {
      expect(call).toContain('JSON.stringify')
    }
  })
})
