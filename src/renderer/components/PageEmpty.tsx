import type { ReactNode } from 'react'

interface Props {
  /** SVG path data on the 24×24 grid the rest of the app draws on. */
  icon?: string
  title: string
  children?: ReactNode
  /**
   * The one thing to do from here, when there is one. `primary` fills it with
   * the accent — reserved for the case where the page cannot do anything at
   * all until it is pressed.
   */
  action?: { label: string; onClick(): void; busy?: boolean; primary?: boolean }
  /** A quieter line under the action, e.g. the chord that does the same thing. */
  hint?: ReactNode
  /**
   * A block after the action, for the rare page whose explanation is not a
   * sentence — GitHub's failures carry the tool's own stderr in a `<details>`,
   * and a disclosure widget cannot live inside the `<p>` that `children` is.
   */
  extra?: ReactNode
}

/**
 * What a page says when it has nothing to show.
 *
 * There is one of these rather than eight, because eight of them is how the
 * app ended up with a bare sentence floating in the middle of Source control,
 * a different bare sentence in GitHub, and two competing ones on Alerts. A
 * page with nothing in it is still a designed page: the view's own glyph, one
 * line in the voice of a title, the explanation under it, and — where one
 * exists — the single thing you would want to do next.
 *
 * It lives in its own module rather than beside the first-run `EmptyState`
 * because that one reads the brand through `@shared/*`, an alias the test
 * runner does not resolve — importing it from a panel takes that panel's whole
 * test file down with it.
 */
export function PageEmpty({ icon, title, children, action, hint, extra }: Props) {
  return (
    <div className="page-blank" role="status">
      {icon && (
        <svg
          className="page-blank-mark"
          width="30"
          height="30"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d={icon} />
        </svg>
      )}
      <h2 className="page-blank-title">{title}</h2>
      {children && <p className="page-blank-body">{children}</p>}
      {action && (
        <button
          type="button"
          className={action.primary ? 'btn-primary page-blank-action' : 'page-blank-action'}
          onClick={action.onClick}
          disabled={action.busy}
        >
          {action.label}
        </button>
      )}
      {hint && <p className="page-blank-hint">{hint}</p>}
      {extra && <div className="page-blank-extra">{extra}</div>}
    </div>
  )
}

/**
 * The one-line half of the same system.
 *
 * `PageEmpty` is for a view with nothing in it. This is for the two cases where
 * that block would be too much: a *section* of a working page that happens to
 * be empty — a board column, one tab of a loaded list — and a page that is
 * still reading. Panels each used to write their own: `gh-message`,
 * `git-message`, `mcp-empty`, `hooks-empty`, `column-empty`, four different
 * sizes and three different greys for the same sentence.
 *
 * `page` puts it where `PageEmpty`'s title lands, so "Reading repository…"
 * and the answer that replaces it occupy the same spot instead of the page
 * jumping when the read comes back.
 */
export function PageNote({
  children,
  page,
  busy,
}: {
  children: ReactNode
  page?: boolean
  busy?: boolean
}) {
  return (
    <p className="page-blank-line" data-page={page || undefined} role="status" aria-busy={busy}>
      {children}
    </p>
  )
}
