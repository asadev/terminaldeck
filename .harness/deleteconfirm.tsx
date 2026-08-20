/**
 * The delete confirmation, on its own, in a real browser.
 *
 * It is the one dialog in this app whose *colours* were specified out loud —
 * *"when I hover on the delete it will have the white text and red color… and
 * when it's not hover, it will have red text only"* — and colour cannot be seen
 * in a static render. Nor can the ⓘ the body moved behind this round: a
 * `HoverNote` draws nothing until a pointer is on it, so the only proof that the
 * paragraph is still reachable is a pointer on it.
 *
 * One theme per load — `?theme=light` — rather than both side by side, because
 * `Modal` portals into `document.body` and a theme set on a wrapper inside the
 * page would not reach it. The appearance has to be on the root element, which
 * is exactly how the app itself sets it.
 */
import './stub'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { CloseSessionConfirm } from '../src/renderer/components/CloseSessionConfirm'
import { setBindings } from '../src/renderer/browser/binding-view'

const theme = new URLSearchParams(location.search).get('theme') === 'light' ? 'light' : 'dark'
document.documentElement.dataset.theme = theme

setBindings({
  sessions: [
    {
      sessionId: 's1',
      machineId: '',
      colour: 0,
      ended: false,
      windows: [
        { n: 1, browserTabId: 'b:1', url: 'https://stripe.com', title: 'Stripe' },
        { n: 2, browserTabId: 'b:2', url: 'https://docs.dev', title: 'Docs' },
      ],
    },
  ],
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <CloseSessionConfirm
      open
      title="Session 1"
      status="waiting"
      provider="claude"
      sessionId="s1"
      onCancel={() => undefined}
      onConfirm={() => undefined}
    />
  </StrictMode>,
)
