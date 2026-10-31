import { useEffect, useState } from 'react'
import './Onboarding.css'
import { BRAND } from '@shared/brand'
import { NO_VERSION, NO_VERSION_HINT, toolVersionLabel as versionLabel } from '../settings/setup-status'

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
        {/* The second half stays. "It never sees your logins" is the security
            claim this whole screen exists to make good on, and it is the one
            sentence a first-run screen is entitled to spend. What went was the
            explanation of *how* — the agent signing you in inside the session
            is something the reader will watch happen in a minute anyway. */}
        <p className="onboarding-lede">
          {BRAND.name} runs coding agents in real terminals, and never sees your logins.
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
                    {versionLabel(tool) && (
                      <span
                        className="onboarding-version"
                        data-none={versionLabel(tool) === NO_VERSION || undefined}
                        title={versionLabel(tool) === NO_VERSION ? NO_VERSION_HINT : undefined}
                      >
                        {versionLabel(tool)}
                      </span>
                    )}
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
            An agent is installed but not signed in. Start a session and it will ask.
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
