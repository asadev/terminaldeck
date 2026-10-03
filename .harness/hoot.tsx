/**
 * Hoot, looked at: the owl at every size it is drawn, and the surfaces that
 * draw it, in the real components and the real stylesheets.
 *
 * The sizes are the ones the app uses: 15 (tab pill), 17 (sidebar row), 24
 * (tour panel), 28 (window toolbar), 32 (a chat turn), 96 (another machine's
 * empty state) and 200 (Hoot's own welcome page). Nothing here is decorative
 * scaffolding except the captions; each block below is the component the app
 * mounts. `?theme=light` flips the theme; `?still` passes `animated={false}`.
 *
 * The full window (sidebar entry, tab, toolbar, a chat with another machine's
 * Hoot) is the main harness, `index.html`, which mounts the real App.
 */
import './stub'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/shell/shell.css'
import '../src/renderer/copilot/copilot.css'
import { HootMark } from '../src/renderer/copilot/HootMark'
import { CopilotEntry } from '../src/renderer/copilot/CopilotEntry'
import { PageEmpty } from '../src/renderer/components/PageEmpty'
import { BRAND } from '../src/shared/brand'

const params = new URLSearchParams(location.search)
if (params.get('theme') === 'light') document.documentElement.dataset.theme = 'light'
const animated = !params.has('still')

const SIZES = [15, 16, 17, 24, 28, 32, 40, 96, 200]

function Page() {
  return (
    <div style={{ background: 'var(--bg-primary)', color: 'var(--text-primary)', minHeight: '100vh', padding: 24, display: 'grid', gap: 28 }}>
      <section style={{ display: 'flex', alignItems: 'flex-end', gap: 28, flexWrap: 'wrap' }} data-testid="sizes">
        {SIZES.map((size) => (
          <figure key={size} style={{ margin: 0, display: 'grid', justifyItems: 'center', gap: 6, fontSize: 'var(--t-caption)', color: 'var(--text-muted)' }}>
            <HootMark size={size} animated={animated} />
            {size}
          </figure>
        ))}
      </section>

      <section style={{ display: 'flex', gap: 24, alignItems: 'flex-start', flexWrap: 'wrap' }}>
        <div style={{ width: 260, background: 'var(--bg-secondary)', borderRadius: 12, padding: 8 }} data-testid="rail">
          <CopilotEntry stage="ready" active={false} onOpen={() => {}} />
          <CopilotEntry stage="ready" active onOpen={() => {}} />
        </div>

        <div className="cp-remote" style={{ width: 460, background: 'var(--bg-primary)', borderRadius: 12 }} data-testid="chat">
          <div className="cp-remote-log">
            <div className="cp-bubble" data-role="you">Which session needs me?</div>
            <div className="cp-turn">
              <HootMark size={32} className="cp-avatar" animated={animated} />
              <div className="cp-bubble" data-role="agent">
                Two sessions finished. Session 3 is waiting for you: it is asking whether to push.
              </div>
            </div>
          </div>
        </div>
      </section>

      <section style={{ height: 460, display: 'flex', flexDirection: 'column', justifyContent: 'center', background: 'var(--bg-primary)' }} data-testid="empty">
        <PageEmpty
          mark={<HootMark size={200} animated={animated} />}
          title={`${BRAND.assistant} is not running`}
          action={{ label: 'Start it', onClick: () => {}, primary: true }}
        >
          It runs in a folder of its own, with its own memory, as one of your accounts.
        </PageEmpty>
      </section>
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Page />
  </StrictMode>,
)
