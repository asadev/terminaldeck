import { FileTree } from '../components/FileTree'
import { FileViewer } from '../components/FileViewer'
import { SearchPanel } from '../components/SearchPanel'
import { GitPanel } from '../components/GitPanel'
import { GitHubPanel } from '../components/GitHubPanel'
import { ReadinessPanel } from '../components/ReadinessPanel'
import { AlertsPanel } from '../components/AlertsPanel'
import { McpInspector } from '../components/McpInspector'
import { HooksPanel } from '../components/HooksPanel'
import { PageEmpty } from '../components/PageEmpty'
import { Dashboard } from '../dashboard/Dashboard'
import { Board } from '../board/Board'
import { panelSpec, type PanelId } from './panels'
import { ErrorBoundary } from './ErrorBoundary'

interface Props {
  panel: PanelId
  projectPath: string | null
  onOpenProject(): void
  /** Project-relative path the Files page has open, held above this component
      so Source control can hand a file to it. */
  openFile: string | null
  onOpenFile(relPath: string): void
}

/** Shown instead of a view that has nothing to work with yet. */
function NeedsProject({ panel, onOpenProject }: { panel: PanelId; onOpenProject(): void }) {
  const spec = panelSpec(panel)
  return (
    <PageEmpty
      icon={spec.icon}
      title={`${spec.label} needs an open project`}
      action={{ label: 'Open a project', onClick: onOpenProject, primary: true }}
      hint={
        <>
          Or press <kbd>⌘</kbd> <kbd>O</kbd>.
        </>
      }
    >
      {spec.blurb}
    </PageEmpty>
  )
}

/**
 * Files, as a page rather than a 300px drawer: the tree on the left and the
 * file it selects on the right.
 *
 * `FileViewer` was written, tested and then never rendered — it sat on the
 * unreachable list for exactly as long as the file panel had no room to show
 * anything. A full-width page has the room.
 */
function FilesPage({
  root,
  selected,
  onSelect,
}: {
  root: string
  selected: string | null
  onSelect(relPath: string): void
}) {
  return (
    <div className="files-page">
      <FileTree
        root={root}
        selected={selected}
        className="files-page-tree"
        onSelect={(entry) => {
          if (entry.kind === 'file') onSelect(entry.relPath)
        }}
      />
      <FileViewer root={root} path={selected} className="files-page-viewer" />
    </div>
  )
}

/**
 * One of the sidebar's views, filling the window.
 *
 * Every one of these used to render inside a resizable 300px column with a
 * heading bar of its own — a dashboard, a kanban board and a pull-request list,
 * all in a strip narrower than a phone. They get the window now.
 */
export function PanelView({ panel, projectPath, onOpenProject, openFile, onOpenFile }: Props) {
  const spec = panelSpec(panel)

  const body = (() => {
    switch (panel) {
      case 'hooks':
        return <HooksPanel />
      case 'mcp':
        return <McpInspector projectPath={projectPath} />
      default:
        break
    }
    if (!projectPath) return <NeedsProject panel={panel} onOpenProject={onOpenProject} />
    switch (panel) {
      case 'overview':
        return <Dashboard projectPath={projectPath} />
      case 'board':
        return <Board projectPath={projectPath} />
      case 'files':
        return <FilesPage root={projectPath} selected={openFile} onSelect={onOpenFile} />
      case 'search':
        return <SearchPanel projectPath={projectPath} />
      case 'git':
        // A changed file opens on the Files page, which is the page that can
        // actually show it — a row that highlights and does nothing is worse
        // than a row that is not clickable at all.
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
  })()

  return (
    <div className="panel-page" data-panel={panel} aria-label={spec.label}>
      <ErrorBoundary label={spec.label}>{body}</ErrorBoundary>
    </div>
  )
}
