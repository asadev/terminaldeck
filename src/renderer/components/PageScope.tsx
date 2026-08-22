import { thisMachine } from '../platform'

/**
 * What this page is reporting on: the folder, and the machine it is on.
 *
 * ## The report
 *
 * Asad, walking the Project and Integrations pages on 2026-08-21 and finding
 * every one of them empty:
 *
 *   > *"Maybe I'm not the actual one or something. I don't know."*
 *
 * Two readings, and the frames support both. Either *"I am not in the actual
 * project"* — the pages drew a bare title ("Artifacts", "AI readiness", "MCP
 * servers") with no folder anywhere on them, while the folder in play was an
 * empty `~/Templates` — or *"these are not mine"*, the two sessions on screen
 * running under two different logins on two different computers. Both resolve
 * the same way: a page that reports on something has to say what.
 *
 * It is the same argument the MCP page had already made for itself — *"On MCP
 * servers did nothing"*, when what it was doing was reading a different folder
 * from the one in the rail — and the same one Source control makes by putting
 * its branch on the page. This is that line, once, for every view, so that six
 * pages cannot end up with six different ideas of where their subject lives.
 *
 * ## Why it is drawn here and not in the toolbar
 *
 * The toolbar's `meta` slot already carries a folder and an account for a
 * *session*, and the natural-looking move is to feed it a folder for a page
 * too. It is the wrong slot: that composition draws an account chip beside the
 * folder, and which login the window last used is not a fact about the
 * Artifacts page. A page states its own subject, on the page, above its own
 * content.
 *
 * ## What "machine" means here, and why it is a word rather than a hostname
 *
 * Every folder a Project page can be opened on is a folder on this computer —
 * `projectPath` comes from this machine's own file dialog — so the honest
 * second half is *this Mac* / *this PC*, which `platform.ts` already spells for
 * the rest of the app. A hostname would need a channel that does not exist, and
 * inventing one to print a name nobody asked for is the sort of nearly-true
 * chrome this round exists to remove.
 *
 * A page that genuinely reports on *another* machine passes its name in — the
 * MCP servers page does, when a paired machine's connectors are what is on
 * screen — and then the line names that machine instead.
 */

interface Props {
  /**
   * The folder this page read, or null when the page is not about a folder at
   * all — Integrations pages with no project open.
   */
  path: string | null
  /**
   * The machine the subject lives on. Defaults to this one, spelled the way the
   * rest of the app spells it.
   */
  machine?: string
  /**
   * One more fact worth a word, when a page has one: the scope a list came from,
   * the session a reading was resolved through. Kept to the same quiet line so a
   * page does not grow a second header underneath this one.
   */
  detail?: string | null
}

export function PageScope({ path, machine, detail }: Props) {
  const where = machine ?? thisMachine()
  // Nothing at all rather than a line reading "on this Mac" over a page that
  // has not been given a subject: a caption with no subject is furniture.
  if (path === null && machine === undefined) return null
  return (
    <p className="page-scope">
      {path !== null && (
        /* The whole path, in mono, because it is data — the characters are exact
           and countable. Truncated from the left in CSS, since the last two
           segments are the half that tells two checkouts apart. */
        <span className="page-scope-path" title={path}>
          {/* The inner wrapper is load-bearing — see `.page-scope-path-text`. */}
          <span className="page-scope-path-text">{path}</span>
        </span>
      )}
      {path !== null && <span className="page-scope-sep" aria-hidden="true" />}
      <span className="page-scope-where">{`on ${where}`}</span>
      {detail ? (
        <>
          <span className="page-scope-sep" aria-hidden="true" />
          <span className="page-scope-detail">{detail}</span>
        </>
      ) : null}
    </p>
  )
}
