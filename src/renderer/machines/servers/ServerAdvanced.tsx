import { useState } from 'react'
import { Button, Notice } from '../../settings/controls'
import { useServerSessionOpener } from './session-context'
import { howLong } from './words'
import type { Fact, Server, ServerState, ServersBridge } from './types'

/**
 * Everything sharp about a server, behind one more click.
 *
 * ## Why these things are here and not on the page above
 *
 * | | |
 * |---|---|
 * | **The way to a terminal** | It is unbounded. Everything above is a named action with a known consequence; this is a shell, and a shell has none. The *door* is what is behind Advanced — the terminal itself opens as an ordinary session, in the window, with a row in the rail and a tab of its own. |
 * | **What is listening** | Explaining it needs the word the calm surface does not use. |
 * | **How you sign in** | Changing the way you get in is how people lock themselves out. |
 * | **This server's identity** | Only ever wanted when checking something specific. |
 * | **Forget this server** | Destructive to *our* record and to nothing else, and "forget" beside a list of somebody's websites will read as "delete" to a person who does not know better. So it says exactly what it removes. |
 *
 * The door is one click and it is labelled. This is a private area, not a
 * secret: the request was for somewhere out of the way to reach, which is not
 * the same as a hidden gesture only the author knows about.
 *
 * ## Why the copilot's permission is granted here
 *
 * Because the place you hand an assistant control of a machine should be the
 * page that shows you what is on it — not a settings pane, and not the
 * assistant's own window, where the thing being granted is furthest from view.
 * The grant is for **this one server**, it covers the named actions only, and it
 * runs out. It never covers anything else on this page: not the shell, not the
 * sign-in, not the identity, not forgetting it.
 */

interface Props {
  server: Server
  state: ServerState | undefined
  bridge: ServersBridge | null
  now: number
  onRename(name: string): void
  onForget(): void
  onGrant(forMs: number): void
  onRevoke(): void
}

/**
 * How long a grant lasts.
 *
 * An hour, because a permission that has to be re-given every ten minutes gets
 * given carelessly — the dialog stops being a decision and becomes a step. It is
 * also short enough that an assistant's permission does not quietly outlive the
 * afternoon somebody granted it for.
 */
export const GRANT_MS = 60 * 60 * 1000

/**
 * One measured thing, said honestly — including when it was not measured.
 *
 * Four outcomes and four different sentences, which is the entire point of the
 * three-state model reaching the screen intact. A dash would collapse the last
 * three into each other, and a person reading a dash reads it as zero.
 */
function FactLine<T>({
  label,
  fact,
  say,
  none,
}: {
  label: string
  fact: Fact<T> | undefined
  say(value: T): string
  /** What it means for this fact to have come back empty. */
  none: string
}) {
  const value = ((): string => {
    if (fact === undefined) return 'We have not asked yet.'
    if (fact.known === 'cannot') return fact.why === '' ? 'This sign-in could not find out.' : fact.why
    if (fact.known === 'no') return none
    return say(fact.value)
  })()
  return (
    <div className="servers-fact">
      <span className="servers-fact-label">{label}</span>
      <span className="servers-fact-value" data-known={fact === undefined ? 'unasked' : fact.known}>
        {value}
      </span>
    </div>
  )
}

export function ServerAdvanced({ server, state, bridge, now, onRename, onForget, onGrant, onRevoke }: Props) {
  const [open, setOpen] = useState(false)
  /*
   * The window's list of open shells, or null when this page is not inside one.
   *
   * Read here rather than passed down through `ServerPage` and `MachinesPanel`,
   * because the only route from the window to this component is `PanelView`,
   * which draws all ten views from a `PanelId` and takes no per-view props.
   * `session-context.ts` carries the argument.
   */
  const opener = useServerSessionOpener()
  const openHere = opener?.openOn(server.id) ?? 0
  const [confirmForget, setConfirmForget] = useState(false)
  const [name, setName] = useState(server.name)
  const facts = state?.view?.facts
  const grant = state?.grant ?? null
  const granted = grant !== null && grant.expiresAt > now

  if (!open) {
    return (
      <div className="servers-door">
        <Button onClick={() => setOpen(true)}>Advanced</Button>
      </div>
    )
  }

  return (
    <section className="servers-advanced">
      <div className="servers-door">
        <Button onClick={() => setOpen(false)}>Hide advanced</Button>
      </div>

      <h4 className="settings-group-title">A terminal on this server</h4>
      <p className="settings-prose">
        Everything else on this page does one named thing and tells you what it costs. This does
        whatever you type, and nothing checks it first.
      </p>
      <p className="settings-prose">
        {/*
          Where it goes, said before the press rather than discovered after it.

          The terminal used to appear in a box on this page, which meant it only
          existed while this page was the thing on screen. It opens as an
          ordinary session now — a row in the side list and a tab along the top —
          so it behaves like every other one, and a person who has only ever seen
          the old behaviour needs one sentence to know their work has not been
          put somewhere they cannot find it.
        */}
        It opens like any other session: a row in the list on the left, under this server’s name,
        and a tab along the top. You can look at something else and come back to it.
      </p>
      {bridge === null ? (
        <Notice tone="warn">This build cannot open one.</Notice>
      ) : opener === null ? (
        /*
          Absent rather than dead. The window is what holds open sessions, so a
          copy of this page rendered without one — the harness, a test — has
          nowhere to put a terminal, and a button here could only ever swallow
          the press. Said once, plainly, for the same reason the missing-channels
          notice above is: the difference between "you cannot" and "this copy
          cannot" is the difference between a task and a bug report.
        */
        <Notice tone="warn">This page is not inside a window that can hold one open.</Notice>
      ) : (
        <div className="servers-card-actions">
          <Button onClick={() => opener.open(server.id, server.name)}>Open a terminal</Button>
          {openHere > 0 && (
            <span className="servers-card-why">
              {openHere === 1
                ? 'One is already open on this one.'
                : `${openHere} are already open on this one.`}
            </span>
          )}
        </div>
      )}

      <h4 className="settings-group-title">What this server is</h4>
      <div className="servers-facts">
        <FactLine label="System" fact={facts?.os} say={(value) => value} none="It did not say." />
        <FactLine
          label="Its own name for itself"
          fact={facts?.hostname}
          say={(value) => value}
          none="It did not say."
        />
        <FactLine label="Signed in as" fact={facts?.user} say={(value) => value} none="It did not say." />
        <FactLine
          label="Accepting connections"
          fact={facts?.listeners}
          say={(value) => (value === 1 ? '1 thing' : `${value} things`)}
          none="Nothing."
        />
        <FactLine
          label="Installs software with"
          fact={facts?.packageManager}
          say={(value) => value}
          none="Nothing we recognise."
        />
      </div>
      <p className="settings-prose">
        {/*
          Stated rather than offered, and the reason is the rule the rest of this
          area is built on: installing updates cannot be undone, and everything
          here has a way back. Somebody who wants to can do it in the terminal
          above, where it is plainly their own decision.
        */}
        Installing updates is not something this app does — there is no way to undo it, and
        everything here has a way back.
      </p>

      {state?.view !== undefined && state.view.cannot.length > 0 && (
        <>
          <h4 className="settings-group-title">What we could not find out</h4>
          <div className="servers-facts">
            {state.view.cannot.map((gap) => (
              <div className="servers-fact" key={gap.what}>
                <span className="servers-fact-label">{gap.what}</span>
                <span className="servers-fact-value" data-known="cannot">
                  {gap.why}
                </span>
              </div>
            ))}
          </div>
        </>
      )}

      <h4 className="settings-group-title">How you sign in</h4>
      <div className="servers-facts">
        <div className="servers-fact">
          <span className="servers-fact-label">Name you sign in with</span>
          <span className="servers-fact-value">{server.username}</span>
        </div>
        <div className="servers-fact">
          <span className="servers-fact-label">Kept on this computer</span>
          <span className="servers-fact-value">
            {server.credential === undefined
              ? 'This build did not say.'
              : server.credential === 'none'
                ? 'Nothing is kept. You will be asked again next time.'
                : server.credential === 'key'
                  ? 'A key, sealed by this computer and never shown on any screen.'
                  : 'A password, sealed by this computer and never shown on any screen.'}
          </span>
        </div>
      </div>
      <p className="settings-prose">
        To sign in a different way, forget this server below and add it again. Nothing on the server
        changes either way.
      </p>

      <h4 className="settings-group-title">This server's identity</h4>
      <p className="settings-prose">
        Every server has one, and it does not change. If it ever does, this app stops and says so
        rather than signing in — the whole point is that it cannot be waved past. You can compare
        what is below against the server itself, because every other tool prints the same thing.
      </p>
      <div className="servers-facts">
        <div className="servers-fact">
          <span className="servers-fact-label">Identity</span>
          <span
            className="servers-fact-value"
            data-known={server.fingerprint === undefined ? 'unasked' : 'yes'}
          >
            {server.fingerprint ?? 'It has not told us one yet.'}
          </span>
        </div>
      </div>

      <h4 className="settings-group-title">Let the copilot use this server</h4>
      <p className="settings-prose">
        Off unless you turn it on, and then only for this one server and only for a while. It covers
        the buttons on the cards above and nothing on this page — not the terminal, not the sign-in,
        not forgetting it. Without it the copilot can still look, and has to ask you before it
        changes anything.
      </p>
      <div className="servers-card-actions">
        {granted ? (
          <>
            <span className="servers-grant">
              Allowed for another {howLong(Math.max(0, Math.floor((grant.expiresAt - now) / 1000)))}
            </span>
            <Button onClick={onRevoke} disabled={bridge === null}>
              Stop allowing it
            </Button>
          </>
        ) : (
          <Button onClick={() => onGrant(GRANT_MS)} disabled={bridge === null}>
            Allow it for an hour
          </Button>
        )}
      </div>

      <h4 className="settings-group-title">What to call it here</h4>
      <div className="servers-card-actions">
        <input
          className="settings-input wide"
          value={name}
          aria-label="What to call this server"
          onChange={(event) => setName(event.target.value)}
        />
        <Button onClick={() => onRename(name.trim())} disabled={name.trim() === ''}>
          Save
        </Button>
      </div>

      <h4 className="settings-group-title">Forget this server</h4>
      {confirmForget ? (
        <div className="servers-card-ask">
          <p className="servers-card-ask-text">
            {/*
              Not a consequence sentence from the main process, because this is
              not an action on the server: it changes nothing out there. It is
              this app forgetting a row, and the sentence has to say so — beside
              a list of somebody's websites, "forget" reads as "delete".
            */}
            This removes {server.name} from this list and forgets the sign-in kept on this computer.
            Nothing on the server changes, and you can add it again with the same details.
          </p>
          <div className="servers-card-actions">
            <Button tone="danger" onClick={onForget}>
              Forget it
            </Button>
            <Button onClick={() => setConfirmForget(false)}>Cancel</Button>
          </div>
        </div>
      ) : (
        <div className="servers-card-actions">
          {/* Not "Forget this server" again — that is the heading directly above
              it, and a button that repeats its own heading reads as two
              controls to somebody scanning the column. */}
          <Button onClick={() => setConfirmForget(true)}>Forget it</Button>
        </div>
      )}
    </section>
  )
}
