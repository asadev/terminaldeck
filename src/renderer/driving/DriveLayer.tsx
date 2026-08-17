import { useEffect, useState } from 'react'
import { FocusOverlay, type FocusReport } from './FocusOverlay'
import { focusState, subscribeFocus, type FocusState } from './focus-controller'

/**
 * The focus overlay, wired to the store, mounted once for the window.
 *
 * ## Where this goes, and why it is not inside `<App/>`
 *
 * `main.tsx`, as a **sibling of `<App/>` inside `#root`**. Three things follow
 * from that position and all three are the point:
 *
 * 1. **It is not part of the application's layout.** `.app` is a flex row whose
 *    children are the rail and the work; an overlay is neither. Putting it in
 *    that row means every reader of `App.tsx` has to be told it is
 *    `position: fixed` and takes no space.
 * 2. **It is inside the app root, so it is invisible to `overlay-watch.ts`.**
 *    That module treats every child of `<body>` with a box as a floating
 *    surface and parks any browser page underneath it. An overlay portalled
 *    into `<body>` — which is what every other floating surface in this app
 *    does — would blank every web page in the window for as long as a highlight
 *    was up, and would do it hardest at the exact moment the highlight was
 *    pointing *at* the page. `overlayRects` skips the body child that contains
 *    `.app`, which is `#root`, so a sibling of `<App/>` contributes nothing.
 * 3. **`App.tsx` is on the parallel-agent forbidden list** (`CLAUDE.md`), and
 *    `main.tsx` is not. That is a coincidence rather than a reason, but it is a
 *    happy one: the correct home turns out to be the file that was available.
 *
 * ## Why it subscribes rather than taking props
 *
 * Nothing above it knows what a tour is pointing at. See `focus-controller.ts`.
 */
export function DriveLayer({ onReport }: { onReport?: (report: FocusReport) => void }) {
  const [state, setState] = useState<FocusState>(focusState)

  useEffect(() => {
    /*
     * Re-read on subscribe, not only on the next publish.
     *
     * A `setFocus` that lands between this component's first render and its
     * effect would otherwise be lost, and the symptom is a highlight that fails
     * to appear exactly once, at startup, which is the hardest possible time to
     * reproduce.
     */
    setState(focusState())
    return subscribeFocus(setState)
  }, [])

  return <FocusOverlay target={state.target} lit={state.lit} onReport={onReport} />
}
