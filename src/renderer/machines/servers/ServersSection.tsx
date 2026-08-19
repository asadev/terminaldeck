import { Button, Group, Notice } from '../../settings/controls'
import { SERVER_ICON } from './glyph'
import { asOf, overallSentence } from './words'
import type { Server, ServerState } from './types'

/**
 * The servers half of Machines: a list, and the way to add one.
 *
 * ## Why a list and not a dashboard
 *
 * Because the list is drawn with nothing connected. A row here is a stored
 * name, an address and a username; painting it dials no machine, wakes nothing
 * up and costs nothing at all. Everything that requires a connection lives one
 * click in, on the server's own page, which is where a connection is opened and
 * where it is closed again on the way out.
 *
 * That is also why a row that has never been opened during this launch says
 * **nothing** about how the server is doing, rather than a grey "unknown" chip
 * or a hopeful green one. There is no state to report, so none is reported. A
 * row that has been opened shows the last thing that server actually said, with
 * how long ago it said it, which is true and cheap — and better than a number
 * that is fresh because something has been asking all night.
 *
 * ## The words on this screen
 *
 * A person who has never signed in to a server has to be able to read every
 * line here. So: *address*, not host; *sign-in*, not credentials; *add*, not
 * provision. The one place a technical word is allowed is where it names
 * something we actually measured on their machine, and none of those are on
 * this screen — they are on the card that found them.
 */

/* The glyph moved to `glyph.ts` when the side rail started drawing it too. See
   the note there: three copies of a path is two paths after the next change. */

interface Props {
  /** False when this build's preload carries no server channels at all. */
  wired: boolean
  /** Which channels are missing, when only some of them are. */
  missing: readonly string[]
  reading: boolean
  problem: string | null
  servers: readonly Server[]
  states: ReadonlyMap<string, ServerState>
  /** Rendered from, never measured here, so this component stays a function. */
  now: number
  onOpen(id: string): void
  onAdd(): void
  onRetry(): void
}

export function ServersSection({
  wired,
  missing,
  reading,
  problem,
  servers,
  states,
  now,
  onOpen,
  onAdd,
  onRetry,
}: Props) {
  return (
    <Group title="Servers">
      <p className="settings-prose">
        Computers that run things for other people — a website, an app, the place your information
        is kept. You do not sit at one; you sign in to it from here.
      </p>

      {!wired && (
        /*
         * Said once, plainly, rather than by drawing an empty list.
         *
         * An area that renders its "nothing yet" state when the channels behind
         * it are simply absent teaches the reader that the app cannot do the
         * thing, and they never look again. The distinction between "you have
         * no servers" and "this copy of the app has no way to reach one" is the
         * difference between a task and a bug report.
         */
        <Notice tone="warn">
          This copy of the app cannot reach servers yet. Nothing here is missing from your account —
          the part of the app that does the connecting is not in this build.
        </Notice>
      )}

      {wired && missing.length > 0 && (
        // Half-wired is worse than unwired, because it looks like it works.
        <Notice tone="error">
          This build is missing {missing.length} of the server channels ({missing.join(', ')}).
          Anything that needs one will say so rather than appear to have worked.
        </Notice>
      )}

      {wired && problem !== null && (
        <Notice tone="error">
          {problem}{' '}
          {/* Every terminal state on this screen has a way out of it. A failure
              with nothing to press is a loading line one sentence longer. */}
          <Button onClick={onRetry}>Try again</Button>
        </Notice>
      )}

      {wired && problem === null && reading && servers.length === 0 && (
        <p className="settings-prose">Reading your servers…</p>
      )}

      {servers.length > 0 && (
        <ul className="servers-list">
          {servers.map((server) => (
            <ServerRow
              key={server.id}
              server={server}
              state={states.get(server.id)}
              now={now}
              onOpen={onOpen}
            />
          ))}
        </ul>
      )}

      {wired && !reading && problem === null && servers.length === 0 && (
        <p className="settings-prose">
          You have not added a server yet. You will need its address, the name you sign in with, and
          either a password or a key — nothing else, and nothing to set up first.
        </p>
      )}

      <div className="servers-add">
        <Button onClick={onAdd} disabled={!wired} tone="primary">
          Add a server
        </Button>
      </div>
    </Group>
  )
}

/**
 * One row.
 *
 * The right-hand side is the only interesting decision on it. It shows the last
 * sentence this server produced *and how old that sentence is*, or nothing at
 * all. There is no third option — no "checking…", no "unknown", no grey dot —
 * because both of those would be a claim, and the honest answer for a server
 * nobody has opened is silence.
 */
export function ServerRow({
  server,
  state,
  now,
  onOpen,
}: {
  server: Server
  state: ServerState | undefined
  now: number
  onOpen(id: string): void
}) {
  const view = state?.view
  const summary = view === undefined ? '' : overallSentence(view.cards)
  const measuredAt = view === undefined || view.measuredAt === 0 ? undefined : view.measuredAt
  return (
    <li className="servers-row">
      <button className="servers-row-hit" type="button" onClick={() => onOpen(server.id)}>
        <svg
          className="servers-row-mark"
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d={SERVER_ICON} />
        </svg>
        <span className="servers-row-text">
          <span className="servers-row-name">{server.name}</span>
          <span className="servers-row-where">
            {server.username === '' ? server.address : `${server.username} at ${server.address}`}
          </span>
        </span>
        {summary !== '' && (
          <span className="servers-row-state">
            <span className="servers-row-summary">{summary}</span>
            {measuredAt !== undefined && (
              <span className="servers-row-age">{asOf(measuredAt, now)}</span>
            )}
          </span>
        )}
        <svg
          className="servers-row-go"
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d="M9 6l6 6-6 6" />
        </svg>
      </button>
    </li>
  )
}
