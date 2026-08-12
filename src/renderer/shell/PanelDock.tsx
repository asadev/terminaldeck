import { Sidebar } from '../components/Sidebar'
import { FileTree } from '../components/FileTree'
import { SearchPanel } from '../components/SearchPanel'
import { GitPanel } from '../components/GitPanel'
import { GitHubPanel } from '../components/GitHubPanel'
import { ReadinessPanel } from '../components/ReadinessPanel'
import { AlertsPanel } from '../components/AlertsPanel'
import { McpInspector } from '../components/McpInspector'
import { HooksPanel } from '../components/HooksPanel'
import { PANELS, type PanelId } from './panels'

interface Props {
  panel: PanelId
  projectPath: string | null
  width: number
  collapsed: boolean
  onToggleCollapsed(): void
  onStartResize(event: React.MouseEvent): void
  onOpenProject(): void
  onNewSession(projectPath: string, resume?: boolean): void
  onOpenFile(path: string): void
}

/** Shown instead of a panel that has nothing to work with yet. */
function NeedsProject({ label }: { label: string }) {
  return (
    <div className="panel-empty">
      <p>{label} needs an open project.</p>
      <p className="panel-empty-hint">Open one with ⌘O.</p>
    </div>
  )
}

/**
 * Renders whichever panel the activity rail has selected.
 *
 * Panels that read from disk are only mounted once a project exists — mounting
 * them against a null path made them render permanent error states, which reads
 * as "this feature is broken" rather than "you have not opened anything yet".
 */
export function PanelDock({
  panel,
  projectPath,
  width,
  collapsed,
  onToggleCollapsed,
  onStartResize,
  onOpenProject,
  onNewSession,
  onOpenFile,
}: Props) {
  const label = PANELS.find((p) => p.id === panel)?.label ?? panel

  if (collapsed) return null

  const body = (() => {
    if (panel === 'projects') {
      return <Sidebar onOpenProject={onOpenProject} onNewSession={onNewSession} />
    }
    switch (panel) {
      case 'hooks':
        return <HooksPanel />
      case 'mcp':
        return <McpInspector projectPath={projectPath} />
      default:
        if (!projectPath) return <NeedsProject label={label} />
        switch (panel) {
          case 'files':
            return <FileTree root={projectPath} onSelect={(entry) => onOpenFile(entry.relPath)} />
          case 'search':
            return <SearchPanel projectPath={projectPath} />
          case 'git':
            return <GitPanel cwd={projectPath} onSelectFile={(file) => onOpenFile(file.path)} />
          case 'github':
            return <GitHubPanel cwd={projectPath} />
          case 'readiness':
            return <ReadinessPanel projectPath={projectPath} />
          case 'alerts':
            return <AlertsPanel projectPath={projectPath} />
          default:
            return null
        }
    }
  })()

  return (
    <>
      <aside className="panel-dock" style={{ width }} aria-label={label}>
        <header className="panel-dock-header">
          <span>{label}</span>
          <button
            type="button"
            className="icon-btn small"
            onClick={onToggleCollapsed}
            title="Collapse panel (⌘B)"
            aria-label="Collapse panel"
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor">
              <path d="M14 6l-6 6 6 6" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </button>
        </header>
        <div className="panel-dock-body">{body}</div>
      </aside>
      <div
        className="dock-resize"
        onMouseDown={onStartResize}
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize panel"
      />
    </>
  )
}
