import { useState } from 'react'
import { FileTree, type TreeRootState } from '../components/FileTree'
import { FileViewer } from '../components/FileViewer'
import { ArtifactsPanel } from '../components/ArtifactsPanel'
import { MachinesPanel } from '../machines/MachinesPanel'
import { GitPanel, type GitFileGroup } from '../components/GitPanel'
import { GitHubPanel } from '../components/GitHubPanel'
import { ReadinessPanel } from '../components/ReadinessPanel'
import { McpInspector } from '../components/McpInspector'
import { HooksPanel } from '../components/HooksPanel'
import { PageEmpty } from '../components/PageEmpty'
import { FeatureOffer } from '../features/FeatureOffer'
import { useFeatures } from '../features/FeaturesProvider'
import { Dashboard } from '../dashboard/Dashboard'
import type { WidgetContext } from '../dashboard/widgets'
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
  /**
   * Which part of the view was asked for.
   *
   * A dashboard tile that counts staged files has to be able to land on the
   * staged files, not on Source control in general (rule 1.5). The token is
   * panel-specific and deliberately a plain string: only the panel that
   * receives it knows what its own sections are called, and inventing a union
   * covering all ten would put every panel's internals in this file.
   */
  focus?: string | null
  /*
   * There was a `showInsights` and an `onAlertAction` here, and both left with
   * the Alerts page: *"notifications should be a pop-up just like settings,
   * not a full page."* They are props of `AlertsWindow` now, passed from the
   * same place in `App.tsx` that used to pass them here. Nothing else on any
   * page ever read either of them — they were alerts-only props travelling
   * through a component that renders ten views.
   */
  /** What the dashboard's widgets can reach. Everything on it is a door. */
  dashboard?: Omit<WidgetContext, 'projectPath'>
  /*
   * There was a `copilot` here, and it left with the copilot's page on
   * 2026-08-17 — the same move Alerts made, for a related reason.
   *
   * The copilot is a **window** now, not a view: it always was a real session,
   * and what it lacked was the chrome one gets, so it has a pill in the strip,
   * the window's toolbar, an account chip and the whole control cluster. It is
   * rendered by `App.tsx` beside the other sessions' terminals, which is where
   * a session is rendered. See `copilot/identity.ts` for the argument and
   * `panels.ts` for why the id is gone from `PanelId` rather than merely
   * unrouted.
   */
}

const GIT_GROUPS: readonly GitFileGroup[] = ['conflicted', 'staged', 'unstaged', 'untracked']

function asGitGroup(focus: string | null | undefined): GitFileGroup | undefined {
  return GIT_GROUPS.find((group) => group === focus)
}

/**
 * Shown instead of a view that has nothing to work with yet.
 *
 * Deliberately three things and no more: the view's glyph, one line, one
 * button. It used to print `spec.blurb` in the body as well — the same sentence
 * the toolbar is already showing two centimetres above it — and then offer a
 * ⌘O hint under the button, while the sidebar offered "Open a project" twice
 * more. Four ways to do one thing on one screen, and the subtitle said twice.
 */
function NeedsProject({ panel, onOpenProject }: { panel: PanelId; onOpenProject(): void }) {
  const spec = panelSpec(panel)
  return (
    <PageEmpty
      icon={spec.icon}
      title={`${spec.label} needs an open project`}
      action={{ label: 'Open a project', onClick: onOpenProject, primary: true }}
    />
  )
}

/**
 * What the Files page is showing as a whole — decided from the tree's own
 * condition, so the two halves of the page cannot say different things.
 *
 * The report this answers: the left column read **"Nothing to show."** while
 * the right one headed a `README.md` over a blank body, in the same frame. Both
 * components were telling the truth about themselves. The tree had finished and
 * found nothing; the viewer had been handed a path — held above this page in
 * `App.tsx`, and therefore outliving the project it was chosen in — and was
 * dutifully trying to open it.
 *
 * A page is not the sum of its components' states. When the folder has nothing
 * in it, there is no file in it to be reading either, and the page says one
 * thing.
 */
export type FilesPageState = 'tree-and-viewer' | 'tree-only'

export function filesPageState(tree: TreeRootState): FilesPageState {
  // Loading is deliberately `tree-and-viewer`: the viewer has its own loading
  // state and its own file, and blanking it while the tree re-reads would make
  // a background refresh throw away the file somebody is reading.
  return tree.status === 'empty' || tree.status === 'error' ? 'tree-only' : 'tree-and-viewer'
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
  /*
   * Held here rather than read out of the tree, because the tree owns it and
   * this page only needs to be told. `FileTree` reports a change and nothing
   * else — see its `onRootState`, which is guarded so an unchanged condition
   * never travels and this never loops.
   */
  const [tree, setTree] = useState<TreeRootState>({ status: 'loading' })
  const layout = filesPageState(tree)

  return (
    <div className="files-page" data-layout={layout}>
      <FileTree
        root={root}
        selected={selected}
        className="files-page-tree"
        onRootState={setTree}
        onSelect={(entry) => {
          if (entry.kind === 'file') onSelect(entry.relPath)
        }}
      />
      {layout === 'tree-and-viewer' && (
        <FileViewer root={root} path={selected} className="files-page-viewer" />
      )}
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
export function PanelView({
  panel,
  projectPath,
  onOpenProject,
  openFile,
  onOpenFile,
  focus,
  dashboard,
}: Props) {
  const spec = panelSpec(panel)
  const features = useFeatures()

  const body = (() => {
    /*
     * The view's own feature, missing.
     *
     * This is the place a feature store goes wrong: the row is gone from the
     * sidebar, so the only way to arrive here is to have been here already —
     * the rail remembers the last view across launches, and uninstalling
     * something while looking at it lands you exactly here. A blank page at
     * that moment teaches the reader that the app cannot do the thing. The
     * offer teaches them where it went and gives them it back in one click.
     */
    const owner = features.featureForPanel(panel)
    if (owner && !features.on(owner)) return <FeatureOffer id={owner} icon={spec.icon} />

    switch (panel) {
      case 'hooks':
        return <HooksPanel />
      case 'mcp':
        return <McpInspector projectPath={projectPath} />
      /*
       * Above the project gate, deliberately — like `hooks` and `mcp`.
       *
       * The devices paired with this machine have nothing to do with which
       * folder is open, and a phone is most worth pairing on a fresh install
       * where no project has been opened yet. Gating it behind "open a project
       * first" would hide the feature at exactly the moment somebody wants it.
       */
      case 'remote':
        /*
         * The id is still `remote` and the page is **Machines**, which is the
         * rename described at length in `panels.ts`: the row now leads to two
         * kinds of far-end machine rather than one, and the id is what a saved
         * rail position is keyed on, so only the words changed.
         *
         * `MachinesPanel` is the umbrella. It puts the servers above the
         * devices and renders `RemoteSection` — every capability this case used
         * to render directly — underneath, untouched.
         */
        return <MachinesPanel />
      // There was a `machines` case here, above the project check, and it is
      // gone with the panel: the machines this desktop is paired to are now part
      // of Settings → Remote, beside the phones, because they are the same
      // subject. See `panels.ts`.
      default:
        break
    }
    if (!projectPath) return <NeedsProject panel={panel} onOpenProject={onOpenProject} />
    switch (panel) {
      case 'overview':
        return <Dashboard projectPath={projectPath} context={dashboard} />
      case 'files':
        return <FilesPage root={projectPath} selected={openFile} onSelect={onOpenFile} />
      case 'artifacts':
        // `onOpenFile` is passed, and that is the whole lesson of the page this
        // replaces: Search rendered without its `onOpenHit`, so every row in it
        // highlighted on hover and did nothing on click. A row that looks
        // clickable and is not is the one thing this window is not allowed to
        // have. The panel itself omits the button entirely when the callback is
        // absent, rather than drawing a dead one.
        return <ArtifactsPanel projectPath={projectPath} onOpenFile={onOpenFile} />
      case 'git':
        // A changed file opens on the Files page, which is the page that can
        // actually show it — a row that highlights and does nothing is worse
        // than a row that is not clickable at all.
        return (
          <GitPanel
            cwd={projectPath}
            onSelectFile={(file) => onOpenFile(file.path)}
            focusGroup={asGitGroup(focus)}
          />
        )
      case 'github':
        return <GitHubPanel cwd={projectPath} initialTab={focus === 'issues' ? 'issues' : 'pulls'} />
      case 'readiness':
        return <ReadinessPanel projectPath={projectPath} />
      // There was an `alerts` case here and it is gone with the panel entry, in
      // the same way the `machines` case went above: *"notifications should be
      // a pop-up just like settings, not a full page."* Alerts is `AlertsWindow`
      // now, opened from the bell on the rail's Settings line and from the
      // command palette, and it is not a `PanelId` at all — so this switch
      // cannot be navigated to it. See the note on `PanelId` in `panels.ts`.
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
