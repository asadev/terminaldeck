import { describe, expect, it } from 'vitest'
import {
  SETUP_AGENTS,
  ServerSetups,
  agentOn,
  agentSetup,
  authPortOf,
  installCommand,
  installConsequence,
  whyNotInstall,
  type SetupDeps,
  type SetupRunResult,
  type SetupShell,
  type SetupState,
} from './setup'
import { factCannot, factYes, type AgentFact, type Fact } from './facts'

/**
 * The setup flow, exercised where it is most likely to be quietly wrong.
 *
 * Two properties are worth a test each and the rest is arithmetic:
 *
 *  1. **Nothing is ever left behind on somebody else's machine.** Every way out
 *     of a sign-in — refused, abandoned, the terminal closing — has to stop the
 *     login it started and remove the scratch folder it made. The one that is
 *     easy to get wrong is the by-hand fallback, where the folder must go and
 *     the login must *stay*, because the person has just been asked to finish
 *     at the prompt that login is sitting on.
 *  2. **Nothing is offered on a guess.** A server with no downloader, or not
 *     enough memory, is told so before a button rather than sixty seconds into
 *     a download.
 *
 * Everything here runs against a plain object. There is no `ssh2` within reach,
 * which is the whole reason the flow takes its transport as a dependency.
 */

/** What stopping the login looks like on the wire. Named, so the assertion reads. */
const CTRL_C = '\u0003'

const ROOM = { downloader: 'curl', npm: '/usr/bin/npm', memoryAvailableKb: 4_000_000, homeFreeKb: 4_000_000 }

interface Recorded {
  scripts: string[]
  typed: string[]
  states: SetupState[]
  shell: SetupShell
  deps: SetupDeps
}

/**
 * A server that answers, with the two scripted replies the flow depends on.
 *
 * `mktemp` and the bounded wait are the only two round trips whose *content*
 * matters to the flow, so they are answered by shape rather than by call order —
 * a test that counted calls would break the moment a step was added and would
 * say nothing about what broke.
 */
function box(over: { url?: string; connects?: boolean } = {}): Recorded {
  const scripts: string[] = []
  const typed: string[] = []
  const states: SetupState[] = []
  const listeners: Array<(chunk: string) => void> = []

  const shell: SetupShell = {
    onData: (listener) => {
      listeners.push(listener)
      return () => {
        const at = listeners.indexOf(listener)
        if (at >= 0) listeners.splice(at, 1)
      }
    },
    write: (data) => {
      typed.push(data)
    },
  }

  const deps: SetupDeps = {
    runScript: async (_serverId, script): Promise<SetupRunResult> => {
      scripts.push(script)
      if (script.includes('mktemp -d')) {
        return { code: 0, stdout: '/tmp/td-signin-abc123', stderr: '' }
      }
      if (script.includes('open.url')) {
        const url = over.url ?? 'https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A39695%2Fcallback&state=x'
        return { code: url === '' ? 1 : 0, stdout: url, stderr: '' }
      }
      return { code: 0, stdout: '', stderr: '' }
    },
    withConnection: async () => {
      // A server that will not carry a socket is the ordinary case this has to
      // survive, not an edge one: `AllowTcpForwarding no` is a real setting on
      // real machines and the flow's answer to it is the by-hand path.
      if (over.connects !== true) throw new Error('this server will not carry it')
      return undefined as never
    },
    openInBrowser: async () => undefined,
    broadcast: (next) => states.push(next),
  }

  return { scripts, typed, states, shell, deps }
}

describe('the pane offers every agent, not the one this app is built by', () => {
  /*
   * Part 3 of the naming rule, and the only place it *can* be checked — see the
   * header of `neutral-naming.test.ts`, which explains why a string scan cannot.
   * The failure this catches is the **absence** of two rows rather than the
   * presence of a bad word, and it is the exact shape of what shipped on
   * 2026-08-19 and was overruled the same night:
   *
   *   > *"where we can have an option between Claude, Codex, Gemini, in those
   *   > places don't name only Claude. Give all the options."*
   */
  it('knows three agents, and can install and sign in to each of them', () => {
    expect([...SETUP_AGENTS]).toEqual(['claude', 'codex', 'gemini'])
    for (const id of SETUP_AGENTS) {
      // A row that could not be installed on a healthy server would be a name on
      // a screen with nothing behind it, which is worse than not listing it.
      expect(installCommand(id, ROOM), `${id} has no install command`).not.toBeNull()
      expect(whyNotInstall(id, ROOM), `${id} is refused on a healthy server`).toBeNull()
      expect(installConsequence(id, 'imza-vps')).toContain('imza-vps')
    }
  })

  it('names each agent on its own row and nowhere else', () => {
    // Part 1: the row *is* the agent, so it says so. What must not happen is one
    // agent's name turning up in another's sentence, which is how a screen ends
    // up reading as "install Claude Code, and also there are others".
    const labels = SETUP_AGENTS.map((id) => agentSetup(id).label)
    expect(labels).toEqual(['Claude Code', 'Codex CLI', 'Gemini CLI'])
    for (const id of SETUP_AGENTS) {
      const sentence = installConsequence(id, 'x')
      const mine = agentSetup(id).label
      for (const other of labels) {
        if (other !== mine) expect(sentence, `${id} names ${other}`).not.toContain(other)
      }
    }
  })

  it('says how each one signs in, and all three answers were measured', () => {
    /*
     * The three shapes are not preferences, they are what each CLI does on a
     * headless machine — measured on the real box on 2026-08-20. A row whose
     * `verified` note was empty would be a claim nobody had checked, which is
     * exactly the wizard that strands somebody halfway.
     */
    expect(agentSetup('claude').signIn).toBe('browser-shim-tunnel')
    expect(agentSetup('codex').signIn).toBe('device-code')
    expect(agentSetup('gemini').signIn).toBe('in-terminal')
    for (const id of SETUP_AGENTS) {
      expect(agentSetup(id).verified.split(/\s+/).length).toBeGreaterThan(20)
    }
    // A device-code flow with no address to open is a dead end, and the other
    // two must not carry one — they would open a page nobody asked for.
    expect(agentSetup('codex').deviceUrl).not.toBeNull()
    expect(agentSetup('claude').deviceUrl).toBeNull()
    expect(agentSetup('gemini').deviceUrl).toBeNull()
  })

  it('never offers to remove the folder that holds somebody’s own logins', () => {
    // `~/.claude`, `~/.codex` and `~/.gemini` are the person's transcripts,
    // settings and sign-ins, and may predate this app entirely. The way back
    // undoes what this app did, and nothing else.
    for (const id of SETUP_AGENTS) {
      for (const leaf of agentSetup(id).leaves) {
        expect(leaf.startsWith('.local/'), `${id} would remove ~/${leaf}`).toBe(true)
      }
    }
  })
})

describe('what a person is told before a button exists', () => {
  it('names the server in the sentence, so it is about their machine', () => {
    expect(installConsequence('claude', 'imza-vps')).toContain('imza-vps')
    // The three claims that were measured rather than guessed.
    expect(installConsequence('claude', 'x')).toMatch(/320 MB/)
    expect(installConsequence('claude', 'x')).toMatch(/administrator access/)
    expect(installConsequence('claude', 'x')).toMatch(/remove it again/)
  })

  it('refuses a server with no way to download, rather than installing one for it', () => {
    // Installing a downloader in order to install an assistant is the general
    // provisioning this feature deliberately is not.
    expect(whyNotInstall('claude', { ...ROOM, downloader: '' })).toMatch(/no way to download/i)
  })

  it('refuses the npm rows on a server with no npm, and says which part is missing', () => {
    /*
     * Measured: both of these ship as npm packages and neither has a standalone
     * installer, so a server with no Node cannot take them however much room it
     * has. The row stays on screen with this sentence and no button — "this
     * server has no npm" is something somebody can act on, and a row that
     * vanished would look like an app that only knows one agent.
     */
    const none = { ...ROOM, npm: '' }
    expect(whyNotInstall('codex', none)).toMatch(/no npm/i)
    expect(whyNotInstall('gemini', none)).toMatch(/no npm/i)
    expect(installCommand('codex', none)).toBeNull()
    // And it does not take the third one down with it: that one is a single
    // native download and needs no Node at all, which was measured.
    expect(whyNotInstall('claude', none)).toBeNull()
  })

  it('says the memory figure before the download rather than after the kernel stops it', () => {
    const why = whyNotInstall('claude', { ...ROOM, memoryAvailableKb: 300 * 1024 })
    expect(why).toMatch(/300 MB/)
    expect(why).toMatch(/512 MB/)
  })

  it('says the space figure the same way, with each agent’s own figure', () => {
    expect(whyNotInstall('claude', { ...ROOM, homeFreeKb: 100 * 1024 })).toMatch(/100 MB/)
    // The smallest of the three fits where the largest does not, which is the
    // whole reason the figure is per-row rather than one number for all three.
    expect(whyNotInstall('codex', { ...ROOM, homeFreeKb: 200 * 1024 })).toMatch(/200 MB/)
    expect(whyNotInstall('gemini', { ...ROOM, homeFreeKb: 200 * 1024 })).toBeNull()
  })

  it('gets out of the way when there is nothing in the way', () => {
    expect(whyNotInstall('claude', ROOM)).toBeNull()
  })

  it('takes wget as well, because plenty of images ship exactly one of the two', () => {
    expect(installCommand('claude', { ...ROOM, downloader: 'curl' })).toContain('curl')
    expect(installCommand('claude', { ...ROOM, downloader: 'wget' })).toContain('wget')
    expect(installCommand('claude', { ...ROOM, downloader: '' })).toBeNull()
  })

  it('installs the npm rows into the account’s own home, never as root', () => {
    // Measured: `npm prefix -g` on the real box is `/usr`, and both `/usr/bin`
    // and `/usr/lib/node_modules` are root-owned — so a bare `npm install -g`
    // would need administrator access, which §7 does not allow this to ask for.
    for (const id of ['codex', 'gemini'] as const) {
      const command = installCommand(id, ROOM) ?? ''
      expect(command).toContain('--prefix "$HOME/.local"')
      expect(command).not.toContain('sudo')
    }
  })
})

describe('reading the address the sign-in will come back to', () => {
  it('finds the number that is baked into it', () => {
    expect(
      authPortOf(
        'https://claude.ai/oauth/authorize?code_challenge=x&redirect_uri=http%3A%2F%2Flocalhost%3A36437%2Fcallback&state=y',
      ),
    ).toBe(36437)
  })

  it('refuses the other address claude prints, which goes somewhere else entirely', () => {
    // Measured: `claude` produces two addresses at once. This is the one printed
    // on the terminal, and it redirects to Anthropic rather than to a listener
    // on the server — carrying it would reach nothing.
    expect(
      authPortOf(
        'https://claude.ai/oauth/authorize?redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=y',
      ),
    ).toBeNull()
  })

  it('refuses anything that is not this machine', () => {
    expect(authPortOf('https://x/?redirect_uri=http%3A%2F%2Fevil.example%3A80%2Fcallback')).toBeNull()
    expect(authPortOf('https://x/?nothing=here')).toBeNull()
  })
})

describe('which agent a row is about', () => {
  const agents = (value: AgentFact[]): { agents: Fact<AgentFact[]> } => ({
    agents: factYes(value, 1, 'looked'),
  })

  it('picks out whichever row is being asked about', () => {
    const found = agents([
      { id: 'gemini', path: '/g', version: '1', signedIn: 'unknown', account: null },
      { id: 'claude', path: '/c', version: '2', signedIn: 'yes', account: 'a@b' },
    ])
    expect(agentOn(found, 'claude')?.path).toBe('/c')
    expect(agentOn(found, 'gemini')?.path).toBe('/g')
    // Absent is a real answer and a different one from "could not look": this
    // draws a Set it up button, and the one below draws nothing.
    expect(agentOn(found, 'codex')).toBeNull()
  })

  it('answers nothing when the check itself could not run', () => {
    // Not "none installed". The difference decides whether a button is drawn,
    // and drawing one here would offer to install over a working install.
    for (const id of SETUP_AGENTS) {
      expect(agentOn({ agents: factCannot(1, 'could not look') }, id)).toBeNull()
    }
  })
})

describe('a sign-in never leaves anything behind', () => {
  it('removes the scratch folder and leaves the login alone on the by-hand path', async () => {
    const { deps, shell, scripts, typed } = box({ connects: false })
    const setups = new ServerSetups(deps)
    const state = await setups.signIn('s1', 'claude', shell, '/home/asad/.local/bin/claude')

    expect(state.byHand).toBe(true)
    // Gone: the folder it made on their machine.
    expect(scripts.some((script) => script.startsWith('rm -rf "/tmp/td-signin-'))).toBe(true)
    // Still there: the login, sitting at the prompt the person was just told to
    // use. Stopping it here would take that prompt away from them.
    expect(typed.some((line) => line.includes(CTRL_C))).toBe(false)
    expect(typed.some((line) => line.includes('auth login --claudeai'))).toBe(true)
  })

  it('stops the login and removes the folder when it is cancelled part-way', async () => {
    /*
     * Cancelled while the sign-in is genuinely in flight — waiting for the
     * address to appear — which is what the terminal being closed, or the page
     * being left, actually looks like. This is the path that would otherwise
     * leave a login running and a listener open on somebody else's machine with
     * nothing left on this side that knows about either.
     */
    const scripts: string[] = []
    const typed: string[] = []
    const shell: SetupShell = { onData: () => () => {}, write: (data) => void typed.push(data) }
    const deps: SetupDeps = {
      runScript: async (_serverId, script): Promise<SetupRunResult> => {
        scripts.push(script)
        if (script.includes('mktemp -d')) return { code: 0, stdout: '/tmp/td-signin-abc123', stderr: '' }
        // The bounded wait, held open for the length of this test.
        if (script.includes('open.url')) return new Promise<SetupRunResult>(() => {})
        return { code: 0, stdout: '', stderr: '' }
      },
      withConnection: async () => undefined as never,
      broadcast: () => {},
    }
    const setups = new ServerSetups(deps)
    const running = setups.signIn('s1', 'claude', shell, '/c')
    // Let it get as far as the wait, which is where a real cancel arrives.
    await new Promise((resolve) => setTimeout(resolve, 0))
    await setups.cancel('s1')
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(scripts.some((script) => script.startsWith('rm -rf "/tmp/td-signin-'))).toBe(true)
    expect(typed.some((line) => line.includes(CTRL_C))).toBe(true)
    void running
  })

  it('carries the absolute path rather than trusting the name to be findable', async () => {
    // The whole reason the probe widens its search: the installer puts this in
    // a folder a non-interactive sign-in cannot see, and prints advice about it
    // rather than fixing it.
    const { deps, shell, typed } = box({ connects: false })
    await new ServerSetups(deps).signIn('s1', 'claude', shell, '/home/asad/.local/bin/claude')
    expect(typed.some((line) => line.includes('/home/asad/.local/bin/claude auth login'))).toBe(true)
  })

  it('makes the scratch folder unreadable by the other accounts on the machine', async () => {
    // Measured: the test box has three home folders on it. The address a sign-in
    // is in the middle of is not for the other two.
    const { deps, shell, scripts } = box({ connects: false })
    await new ServerSetups(deps).signIn('s1', 'claude', shell, '/c')
    const made = scripts.find((script) => script.includes('mktemp -d')) ?? ''
    expect(made).toContain('chmod 700 "$d"')
    expect(made).toContain('umask 077')
  })
})

describe('an install that cannot happen', () => {
  it('says so and never types anything into the terminal', async () => {
    const { deps, shell, typed } = box()
    const setups = new ServerSetups(deps)
    const state = await setups.install(
      's1',
      'claude',
      shell,
      { ...ROOM, downloader: '' },
      'imza-vps',
    )
    expect(state.step).toBe('failed')
    expect(typed).toEqual([])
  })
})
