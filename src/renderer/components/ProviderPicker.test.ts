import { describe, expect, it } from 'vitest'
import {
  accountProviderIds,
  buildAccountProviderRows,
  buildProviderRows,
  chosenAccountProvider,
  firstAccountProvider,
  firstAvailable,
  parseAccountProviders,
  PROVIDER_OPTIONS,
  providerOption,
  resumeAvailability,
} from './ProviderPicker'

/**
 * Pure logic only. There is no DOM in this project's test setup and the picker
 * renders through `Modal`, which portals into `document.body` — so the parts
 * worth holding to a contract are extracted and exercised directly.
 */

const detected = {
  claude: true,
  codex: false,
  gemini: false,
  shell: true,
}

describe('PROVIDER_OPTIONS', () => {
  it('covers every provider the app can spawn', () => {
    expect(PROVIDER_OPTIONS.map((p) => p.id)).toEqual(['claude', 'codex', 'gemini', 'shell'])
  })

  it('mirrors which providers have a resume command in the main process', () => {
    // `claude --continue` and `codex resume --last` exist; the Gemini CLI has
    // no equivalent, and a shell has no session to resume.
    const resumable = PROVIDER_OPTIONS.filter((p) => p.canResume).map((p) => p.id)
    expect(resumable).toEqual(['claude', 'codex'])
  })

  it('offers an install command for every agent that can be missing', () => {
    for (const option of PROVIDER_OPTIONS) {
      if (option.id === 'shell') expect(option.install).toBeNull()
      else expect(option.install).toBeTruthy()
    }
  })
})

describe('buildProviderRows', () => {
  it('marks installed providers available', () => {
    const rows = buildProviderRows(detected)
    expect(rows.find((r) => r.id === 'claude')?.available).toBe(true)
    expect(rows.find((r) => r.id === 'claude')?.reason).toBeNull()
  })

  it('explains why a missing provider cannot be picked', () => {
    const rows = buildProviderRows(detected)
    const codex = rows.find((r) => r.id === 'codex')
    expect(codex?.available).toBe(false)
    /*
     * "Could not start", not "not on your PATH".
     *
     * `detectProviders` runs each agent once now instead of only looking it up,
     * because a `codex` that resolves on PATH and then dies with a spawn error
     * is the case that put a Node stack trace in front of the user. The old
     * sentence was wrong about exactly that case — the binary *was* on his PATH
     * — so the row no longer claims to know which of the two happened, and the
     * install line below it is the fix for both.
     */
    expect(codex?.reason).toContain('could not start')
    expect(codex?.reason).not.toContain('PATH')
  })

  it('lists every provider even when most are missing', () => {
    // A missing agent is information the user needs, not something to hide —
    // the install command is right there in the row.
    expect(buildProviderRows(detected)).toHaveLength(PROVIDER_OPTIONS.length)
  })

  it('always keeps the shell available', () => {
    const rows = buildProviderRows({ claude: false, codex: false, gemini: false, shell: false })
    expect(rows.find((r) => r.id === 'shell')?.available).toBe(true)
  })

  it('fails open when detection produced nothing usable', () => {
    // Locking every agent out on a failed `which` would make the app useless
    // in exactly the case it is least able to diagnose.
    for (const broken of [null, undefined, {}, 'nope', 42]) {
      const rows = buildProviderRows(broken)
      expect(rows.every((r) => r.available)).toBe(true)
    }
  })

  it('treats an all-false result as a real answer, not a broken detector', () => {
    const rows = buildProviderRows({ claude: false, codex: false, gemini: false, shell: false })
    expect(rows.filter((r) => r.available).map((r) => r.id)).toEqual(['shell'])
  })
})

describe('resumeAvailability', () => {
  const rows = buildProviderRows(detected)
  const row = (id: string) => rows.find((r) => r.id === id)

  it('is offered for an installed provider that supports it', () => {
    expect(resumeAvailability(row('claude'))).toEqual({ enabled: true, reason: null })
  })

  it('explains itself for an installed provider with no resume command', () => {
    const installed = buildProviderRows({ claude: true, codex: true, gemini: true, shell: true })
    const result = resumeAvailability(installed.find((r) => r.id === 'gemini'))
    expect(result.enabled).toBe(false)
    expect(result.reason).toContain('no resume command')
  })

  it('says nothing extra for a provider that is not installed', () => {
    // The row itself already says why it cannot be used; repeating it under
    // the checkbox would be noise.
    expect(resumeAvailability(row('codex'))).toEqual({ enabled: false, reason: null })
  })

  it('is off when nothing is selected', () => {
    expect(resumeAvailability(undefined)).toEqual({ enabled: false, reason: null })
  })
})

describe('firstAvailable', () => {
  it('picks the first provider that can actually be used', () => {
    const rows = buildProviderRows({ claude: false, codex: true, gemini: false, shell: true })
    expect(firstAvailable(rows)).toBe('codex')
  })

  it('falls back to the shell when no agent is installed', () => {
    expect(firstAvailable(buildProviderRows({ claude: false, codex: false, gemini: false }))).toBe(
      'shell',
    )
  })

  it('returns null for an empty list', () => {
    expect(firstAvailable([])).toBeNull()
  })
})

/* ------------------------------------------------- adding an account -- */

/**
 * The Add-account list, which is where Asad's request lands:
 *
 *   > "If I add any new account it just redirects me to claude only … I should
 *   > be able to choose which LLM I want to connect."
 *
 * The important assertions here are the *refusals*. Offering an agent whose
 * login this app cannot actually keep separate is worse than not offering it —
 * the user would believe they had switched account and they would not have —
 * and for Gemini it is worse still, because its two "accounts" would address
 * one keychain entry and the second sign-in would overwrite the first.
 */

describe('which agents the Add-account dialog offers', () => {
  const installed = { claude: true, codex: true, gemini: true, shell: true }

  it('offers exactly the agents whose login this app can keep separate', () => {
    /*
     * The renderer keeps its own copy of this so the dialog can draw before any
     * IPC answers — a list whose rows flip from selectable to disabled a beat
     * after it opens is a list somebody clicks the wrong row in.
     *
     * The copy is held to the main process's answer by
     * `provider-accounts.test.ts`, which reads this file's source and compares
     * the literals. It has to be done from that side: `tsconfig.web.json` does
     * not include `src/main`, so a renderer test cannot import the table, and
     * `src/preload/contract.test.ts` already established reading sources as the
     * way this codebase guards a seam a compiler cannot see.
     */
    expect(accountProviderIds()).toEqual(['claude', 'codex'])
  })

  it('offers Claude and Codex when both are installed', () => {
    const rows = buildAccountProviderRows(installed)
    expect(rows.filter((row) => row.canAdd).map((row) => row.id)).toEqual(['claude', 'codex'])
    expect(firstAccountProvider(rows)).toBe('claude')
  })

  it('lists Gemini, disabled, with the reason on the row', () => {
    // Listed rather than omitted: a missing row is indistinguishable from a
    // bug, and Gemini is the row that most needs explaining — it *has* a
    // config-directory variable, so its absence would look like an oversight.
    const gemini = buildAccountProviderRows(installed).find((row) => row.id === 'gemini')
    expect(gemini?.canAdd).toBe(false)
    expect(gemini?.note).toMatch(/one login per machine/)
  })

  it('leaves the shell out entirely', () => {
    // Unlike Gemini there is nothing to explain, so a row would carry one
    // sentence saying "this is not an agent".
    expect(buildAccountProviderRows(installed).some((row) => row.id === 'shell')).toBe(false)
  })

  it('refuses an agent that is not installed, keeping its install line', () => {
    const rows = buildAccountProviderRows({ claude: false, codex: true, gemini: true, shell: true })
    const claude = rows.find((row) => row.id === 'claude')
    expect(claude?.canAdd).toBe(false)
    expect(claude?.reason).toMatch(/could not start/)
    expect(claude?.install).toBe('npm install -g @anthropic-ai/claude-code')
    // The first *usable* agent is preselected, not the first listed one.
    expect(firstAccountProvider(rows)).toBe('codex')
  })

  it('has nothing to preselect when nothing can take an account', () => {
    const rows = buildAccountProviderRows({ claude: false, codex: false, gemini: true, shell: true })
    expect(firstAccountProvider(rows)).toBeNull()
  })
})

describe('which agent a new account actually gets', () => {
  /**
   * The selection is computed from the rows rather than stored beside them, and
   * these are the three cases that decides.
   */
  const installed = { claude: true, codex: true, gemini: true, shell: true }

  it('is an addable agent before anything has been clicked', () => {
    // The first paint. Nothing has been chosen and the form still has to say
    // which agent Add would use — a state a `useEffect` cannot reach in time.
    expect(chosenAccountProvider(buildAccountProviderRows(installed), null)?.id).toBe('claude')
  })

  it('is what was clicked, once something has been', () => {
    expect(chosenAccountProvider(buildAccountProviderRows(installed), 'codex')?.id).toBe('codex')
  })

  it('moves off an agent that has just stopped being addable', () => {
    /*
     * Detection and the main process both answer *after* the list is drawn, and
     * either can withdraw a row. Held in state, the selection would stay on the
     * withdrawn one and Add would stay lit over a radio that refuses.
     */
    const rows = buildAccountProviderRows({ claude: true, codex: false, gemini: true, shell: true })
    expect(chosenAccountProvider(rows, 'codex')?.id).toBe('claude')
  })

  it('never resolves to an agent that cannot hold a second login', () => {
    // Gemini is selectable by no route at all — not by clicking, and not by
    // being the only row left.
    const rows = buildAccountProviderRows({ claude: false, codex: false, gemini: true, shell: true })
    expect(chosenAccountProvider(rows, 'gemini')).toBeNull()
    expect(chosenAccountProvider(rows, null)).toBeNull()
  })
})

describe('the main process’s answer, once it arrives', () => {
  const installed = { claude: true, codex: true, gemini: true, shell: true }

  it('replaces the catalogue’s short sentence with the measured one', () => {
    const rows = buildAccountProviderRows(
      installed,
      parseAccountProviders({
        providers: [
          { id: 'gemini', label: 'Gemini CLI', supported: false, reason: 'Measured: keychain.' },
        ],
      }),
    )
    expect(rows.find((row) => row.id === 'gemini')?.note).toBe('Measured: keychain.')
  })

  it('lets the main process withdraw an agent the catalogue offers', () => {
    /*
     * The direction that matters. If a future build of an agent stops honouring
     * its config variable, the main process is where that is discovered, and a
     * renderer that ignored the answer would keep offering a switcher that
     * silently shares one login.
     */
    const rows = buildAccountProviderRows(
      installed,
      parseAccountProviders({
        providers: [{ id: 'codex', label: 'Codex CLI', supported: false, reason: 'Not any more.' }],
      }),
    )
    expect(rows.find((row) => row.id === 'codex')?.canAdd).toBe(false)
    expect(rows.find((row) => row.id === 'codex')?.note).toBe('Not any more.')
  })

  it('treats anything but an explicit yes as no', () => {
    // An answer this build cannot read must not become an offer to isolate a
    // login it cannot isolate.
    const parsed = parseAccountProviders({
      providers: [
        { id: 'claude', supported: 'yes' },
        { id: 'codex', supported: true },
        'nonsense',
        { label: 'no id' },
      ],
    })
    expect(parsed.map((entry) => [entry.id, entry.supported])).toEqual([
      ['claude', false],
      ['codex', true],
    ])
    // A label is never invented — it falls back to the id rather than to a
    // blank row.
    expect(parsed[0].label).toBe('claude')
  })

  it('falls back to the catalogue when the answer is unusable', () => {
    for (const answer of [null, undefined, 'nope', {}, { providers: 'no' }]) {
      expect(parseAccountProviders(answer)).toEqual([])
    }
    const rows = buildAccountProviderRows(installed, parseAccountProviders(null))
    expect(rows.filter((row) => row.canAdd).map((row) => row.id)).toEqual(['claude', 'codex'])
  })
})

describe('the catalogue’s account facts', () => {
  it('gives a reason for every agent it refuses, and none for the rest', () => {
    for (const option of PROVIDER_OPTIONS) {
      if (option.canHaveAccounts) expect(option.accountsNote).toBeNull()
      else expect(option.accountsNote).toBeTruthy()
    }
  })

  it('looks up by id and answers nothing for an unknown one', () => {
    expect(providerOption('codex')?.label).toBe('Codex CLI')
  })
})
