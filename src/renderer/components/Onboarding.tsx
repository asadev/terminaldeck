import { useEffect, useState } from 'react'
import './Onboarding.css'
import { BRAND } from '@shared/brand'

interface ToolStatus {
  id: string
  label: string
  state: 'ready' | 'installed-not-authed' | 'missing' | 'unknown'
  version?: string
  purpose: string
  remedy?: string
  url?: string
}

interface Prerequisites {
  tools: ToolStatus[]
  canRunSessions: boolean
  needsLogin: boolean
}

interface Props {
  onContinue(): void
  onOpenProject(): void
}

const STATE_LABEL: Record<ToolStatus['state'], string> = {
  ready: 'Ready',
  'installed-not-authed': 'Sign in needed',
  missing: 'Not installed',
  unknown: 'Unknown',
}

/**
 * First-run screen.
 *
 * Deck runs the agent CLIs as real subprocesses — it never handles anyone's
 * credentials. That is good for security but means a new user with nothing
 * installed would otherwise open the app, press ⌘T, and watch a shell appear
 * with no explanation. This screen is the explanation.
 */
export function Onboarding({ onContinue, onOpenProject }: Props) {
  const [prereq, setPrereq] = useState<Prerequisites | null>(null)
  const [checking, setChecking] = useState(true)

  const check = async () => {
    setChecking(true)
    try {
      const result = (await window.deck.checkPrerequisites()) as Prerequisites
      setPrereq(result)
    } finally {
      setChecking(false)
    }
  }

  useEffect(() => {
    void check()
  }, [])

  const agents = prereq?.tools.filter((t) => ['claude', 'codex', 'gemini'].includes(t.id)) ?? []
  const extras = prereq?.tools.filter((t) => !['claude', 'codex', 'gemini'].includes(t.id)) ?? []

  return (
    <div className="onboarding">
      <div className="onboarding-inner">
        <h1>Welcome to {BRAND.name}</h1>
        <p className="onboarding-lede">
          {BRAND.name} runs coding agents in real terminals. It never sees your logins — each agent signs
          you in itself, inside the session.
        </p>

        <section>
          <h2>Coding agents</h2>
          <p className="onboarding-note">You need at least one.</p>
          {checking && <p className="onboarding-note">Checking what you have…</p>}
          <ul className="onboarding-list">
            {agents.map((tool) => (
              <li key={tool.id} className={`onboarding-row state-${tool.state}`}>
                <span className="onboarding-dot" aria-hidden="true" />
                <div className="onboarding-row-main">
                  <span className="onboarding-name">
                    {tool.label}
                    {tool.version && <span className="onboarding-version">{tool.version}</span>}
                  </span>
                  <span className="onboarding-purpose">{tool.remedy ?? tool.purpose}</span>
                </div>
                <span className="onboarding-state">{STATE_LABEL[tool.state]}</span>
                {tool.state === 'missing' && tool.url && (
                  <a className="onboarding-link" href={tool.url} target="_blank" rel="noreferrer">
                    Get it
                  </a>
                )}
              </li>
            ))}
          </ul>
        </section>

        <section>
          <h2>Optional</h2>
          <p className="onboarding-note">Missing these only disables the matching view.</p>
          <ul className="onboarding-list">
            {extras.map((tool) => (
              <li key={tool.id} className={`onboarding-row state-${tool.state}`}>
                <span className="onboarding-dot" aria-hidden="true" />
                <div className="onboarding-row-main">
                  <span className="onboarding-name">{tool.label}</span>
                  <span className="onboarding-purpose">{tool.purpose}</span>
                </div>
                <span className="onboarding-state">{STATE_LABEL[tool.state]}</span>
              </li>
            ))}
          </ul>
        </section>

        {prereq?.needsLogin && (
          <p className="onboarding-callout">
            An agent is installed but not signed in. Open a project and start a session — the agent
            will walk you through signing in, right there in the terminal.
          </p>
        )}

        <div className="onboarding-actions">
          <button type="button" className="btn-primary" onClick={onOpenProject}>
            Open a project
          </button>
          <button type="button" className="btn-ghost" onClick={() => void check()}>
            Re-check
          </button>
          <button type="button" className="btn-ghost" onClick={onContinue}>
            Skip for now
          </button>
        </div>
      </div>
    </div>
  )
}
