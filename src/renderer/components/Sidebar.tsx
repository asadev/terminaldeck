import { useStore } from '../state/store'
import { StatusDot } from './StatusDot'

interface Props {
  onOpenProject(): void
  onNewSession(projectPath: string, resume?: boolean): void
}

export function Sidebar({ onOpenProject, onNewSession }: Props) {
  const { projects, sessionsForProject, activeSessionId, setActiveSession, removeProject } =
    useStore()

  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        <span className="sidebar-title">Projects</span>
        <button
          type="button"
          className="icon-btn"
          onClick={onOpenProject}
          title="Open project (⌘O)"
          aria-label="Open project"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor">
            <path d="M12 5v14M5 12h14" strokeWidth="1.8" strokeLinecap="round" />
          </svg>
        </button>
      </div>

      <div className="sidebar-scroll">
        {projects.length === 0 && (
          <p className="sidebar-empty">No projects open yet.</p>
        )}

        {projects.map((project) => {
          const sessions = sessionsForProject(project.path)
          return (
            <section key={project.path} className="project-group">
              <div className="project-row">
                <span className="project-name" title={project.path}>
                  {project.name}
                </span>
                <div className="project-actions">
                  <button
                    type="button"
                    className="icon-btn small"
                    title="Continue last session (⌘⇧T)"
                    aria-label={`Continue the last session in ${project.name}`}
                    onClick={() => onNewSession(project.path, true)}
                  >
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                      <path
                        d="M3 12a9 9 0 1 0 3-6.7M3 4v4h4"
                        strokeWidth="2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                      />
                    </svg>
                  </button>
                  <button
                    type="button"
                    className="icon-btn small"
                    title="New session (⌘T)"
                    aria-label={`New session in ${project.name}`}
                    onClick={() => onNewSession(project.path)}
                  >
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                      <path d="M12 5v14M5 12h14" strokeWidth="2" strokeLinecap="round" />
                    </svg>
                  </button>
                  <button
                    type="button"
                    className="icon-btn small"
                    title="Close project"
                    aria-label={`Close ${project.name}`}
                    onClick={() => removeProject(project.path)}
                  >
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                      <path d="M6 6l12 12M18 6L6 18" strokeWidth="2" strokeLinecap="round" />
                    </svg>
                  </button>
                </div>
              </div>

              <ul className="session-list">
                {sessions.map((s, i) => (
                  <li key={s.id}>
                    <button
                      type="button"
                      className={`session-item${s.id === activeSessionId ? ' active' : ''}`}
                      onClick={() => setActiveSession(s.id)}
                    >
                      <StatusDot status={s.status} />
                      <span className="session-label">Session {i + 1}</span>
                    </button>
                  </li>
                ))}
              </ul>
            </section>
          )
        })}
      </div>
    </aside>
  )
}
