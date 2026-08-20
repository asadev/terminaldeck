/**
 * The **whole app**, with a session on another machine open in the window.
 *
 *     npx vite --config .harness/vite.config.ts --port 5199
 *     open http://localhost:5199/remoteapp.html
 *
 * `remoteline.html` draws the two chips on their own, which is the right page
 * for measuring them. This one exists for the question that page cannot answer:
 * whether `App.tsx` actually mounts them. Both of the things the 2026-08-20
 * review asked for here were reported fixed twice and found missing twice, each
 * time by somebody reading the source instead of opening the bar — so the
 * assertion that counts is a screenshot of the real title line, built by the
 * real component, over the real remote pane.
 *
 * Everything is `stub.ts`'s except the far machine's answers, which are added
 * here: that fixture's paired machine advertises `create`, `localhost`, `web`,
 * `close` and `send`, so with it alone this window is talking to a build that
 * predates every chip on this bar.
 */
import './stub'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { App } from '../src/renderer/App'

const query = new URLSearchParams(location.search)
/** The other machine worth reproducing: a build with none of this on it. */
const old = query.has('old')

const deck = (globalThis as unknown as { deck: Record<string, unknown> }).deck

/*
 * The far machine's capabilities, with the three this bar reads off them.
 *
 * Added to the *stub's own* view rather than a new one, so the rail, the strip
 * and the pane are all still talking about the same machine and the same
 * sessions. Without `controls` the cluster draws its "that machine needs
 * updating" reading; without `account` the chip is absent, which is `?old`.
 */
const listMachines = deck.listMachines as () => Promise<{
  links: Array<{ capabilities: string[] }>
}>
deck.listMachines = async () => {
  const view = await listMachines()
  if (!old) {
    for (const link of view.links) {
      for (const name of ['controls', 'usage', 'account']) {
        if (!link.capabilities.includes(name)) link.capabilities.push(name)
      }
    }
  }
  return view
}

const CONNECTORS = [
  { id: 'user:github', name: 'github', scope: 'user', transport: 'stdio', enabled: true, disabledReason: null },
  { id: 'project:playwright', name: 'playwright', scope: 'project', transport: 'stdio', enabled: true, disabledReason: null },
  {
    id: 'user:figma',
    name: 'figma',
    scope: 'user',
    transport: 'http',
    enabled: false,
    disabledReason: 'Not approved for this project',
  },
]

const ACCOUNTS = [
  { id: 'system', name: 'Default', provider: 'claude', color: '--acct-1', system: true },
  { id: 'app-imatch-ae', name: 'app.imatch.ae@gmail.com', provider: 'claude', color: '--acct-3', system: false },
  { id: 'school-asadiqbal', name: 'school.asadiqbal@gmail.com', provider: 'claude', color: '--acct-5', system: false },
]

/** What that machine's `controls.read` answers, connectors and all. */
deck.readMachineControls = async () =>
  old
    ? null
    : {
        model: { value: 'opus-5', label: 'Opus 5', source: 'screen' },
        effort: { value: 'xhigh', label: 'Extra high', source: 'screen' },
        fast: { value: 'off', label: 'Off', source: 'screen' },
        permission: { value: null, label: null, source: null },
        live: true,
        agent: { running: true, saw: 'Claude Code' },
        gate: { canType: true, reason: null },
        connectors: CONNECTORS,
      }
deck.applyMachineControl = async () => ({
  ok: true,
  message: 'Model is now Sonnet 5.',
  reading: { value: 'sonnet-5', label: 'Sonnet 5', source: 'screen' },
})
deck.readMachineAccount = async () => (old ? null : { current: ACCOUNTS[1], accounts: ACCOUNTS })
/*
 * A refusal, because that is the only path that puts a sentence on this bar and
 * the one worth being able to look at. The far machine's own words; the id it
 * answers with is the one the session still has, because a switch that did not
 * happen left it running.
 */
deck.switchMachineAccount = async (_id: string, sessionId: string) => ({
  ok: false,
  message: 'That account has never signed in on this computer.',
  session: sessionId,
})

createRoot(document.getElementById('root') as HTMLElement).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
