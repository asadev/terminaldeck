import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ServerLogins, serverAgentRuns } from './ServerAccounts'
import type { AgentOnServer, ServerView } from '../../machines/servers/types'

/**
 * Settings → Coding AI → Servers, which used to be one hardcoded line.
 *
 *   > *"But right now, if you can see, I have a server account connected, but
 *   > coding AI things pages, I don't have any kind of control of server. So
 *   > make sure we have that."*
 *
 * `renderToStaticMarkup` runs no effects, so the list read and the SSH round
 * trip never happen here — which is why what one server answered is a prop and
 * the rule that sorts it is a pure function. Both are the halves worth pinning:
 * the states that matter are answers from a machine nobody has in front of them.
 */

function agent(over: Partial<AgentOnServer> & { id: string }): AgentOnServer {
  return { path: '/usr/bin/x', version: '1.0.0', signedIn: 'unknown', account: null, ...over }
}

function view(agents: AgentOnServer[] | 'cannot'): ServerView {
  return {
    cards: [],
    facts: {
      agents:
        agents === 'cannot'
          ? { known: 'cannot', measuredAt: 1, why: 'That sign-in may not read other home folders.' }
          : { known: 'yes', value: agents, measuredAt: 1, how: 'looked in the usual places' },
    },
    offered: {},
    absent: {},
    how: [],
    cannot: [],
    measuredAt: 1,
  }
}

describe('one server’s agents', () => {
  /**
   * The same separation the local list makes, in the same words.
   *
   *   > *"And server side also the same thing should be there."*
   */
  it('splits them into signed in, not signed in, and not answered', () => {
    const runs = serverAgentRuns([
      agent({ id: 'claude', signedIn: 'yes', account: 'asad@example.com' }),
      agent({ id: 'codex' }),
    ])
    expect(runs.map((run) => run.id)).toEqual(['signed-in', 'not-signed-in', 'not-answered'])
    expect(runs[0].agents.map((row) => row.id)).toEqual(['claude'])
    expect(runs[0].agents[0].line).toBe('Signed in as asad@example.com')
    // Gemini was not on the server at all, so it is the "not installed" half of
    // *"whatever is not install or login should be separate"*.
    expect(runs[1].agents.map((row) => row.id)).toEqual(['gemini'])
    expect(runs[1].agents[0].line).toBe('Not installed')
    // Codex is there and cannot be asked — `probe.sh` has a status command for
    // one agent out of three — so it is not filed as signed out.
    expect(runs[2].agents.map((row) => row.id)).toEqual(['codex'])
  })

  it('never calls an agent it could not ask about signed out', () => {
    const runs = serverAgentRuns([agent({ id: 'gemini' })])
    const gemini = runs.flatMap((run) => run.agents).find((row) => row.id === 'gemini')
    expect(gemini?.state).toBe('unknown')
    expect(gemini?.line).toContain('no way to be asked')
  })

  it('separates a broken install from an absent one', () => {
    // An empty version is not missing data: the binary is there and would not
    // answer, which is a different thing to be told than "not installed".
    const runs = serverAgentRuns([agent({ id: 'claude', version: '', signedIn: 'no' })])
    const claude = runs.flatMap((run) => run.agents).find((row) => row.id === 'claude')
    expect(claude?.line).toBe('Installed, and would not start')
  })

  it('says a signed-in agent is signed in even when it named nobody', () => {
    const runs = serverAgentRuns([agent({ id: 'claude', signedIn: 'yes' })])
    expect(runs[0].agents[0].line).toBe('Signed in')
  })
})

describe('what one server’s panel draws', () => {
  it('draws nothing at all until the row is opened', () => {
    // Opening a row is what buys the SSH round trip. A closed row makes no claim
    // about that machine, which is the honest state — see `useServers`.
    expect(renderToStaticMarkup(<ServerLogins name="Office PC" look={undefined} />)).toBe('')
  })

  it('says which server it is waiting on', () => {
    const html = renderToStaticMarkup(<ServerLogins name="Office PC" look={{ state: 'looking' }} />)
    expect(html).toContain('Asking Office PC…')
  })

  it('shows the server’s own reason rather than a shrug', () => {
    const html = renderToStaticMarkup(
      <ServerLogins name="Office PC" look={{ state: 'failed', problem: 'Office PC did not answer.' }} />,
    )
    expect(html).toContain('Office PC did not answer.')
  })

  it('passes on the measured reason a question could not be asked', () => {
    const html = renderToStaticMarkup(
      <ServerLogins name="Office PC" look={{ state: 'ready', view: view('cannot') }} />,
    )
    expect(html).toContain('That sign-in may not read other home folders.')
    expect(html).not.toContain('Not installed')
  })

  it('names the login on a signed-in row', () => {
    const html = renderToStaticMarkup(
      <ServerLogins
        name="Office PC"
        look={{
          state: 'ready',
          view: view([agent({ id: 'claude', signedIn: 'yes', account: 'asad@example.com' })]),
        }}
      />,
    )
    expect(html).toContain('asad@example.com')
    expect(html).toContain('Signed in')
    expect(html).toContain('Not signed in or not installed')
  })
})
