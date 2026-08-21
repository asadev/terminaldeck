import { useState } from 'react'
import { Button } from '../../settings/controls'
import { howLong } from './words'
import type { Fact, Server, ServerState, ServersBridge } from './types'

/**
 * Everything sharp about a server, behind one more click.
 *
 * ## Why these things are here and not on the page above
 *
 * | | |
 * |---|---|
 * | **What is listening** | Explaining it needs the word the calm surface does not use. |
 * | **How you sign in** | Changing the way you get in is how people lock themselves out. |
 * | **This server's identity** | Only ever wanted when checking something specific. |
 * | **Forget this server** | Destructive to *our* record and to nothing else, and "forget" beside a list of somebody's websites will read as "delete" to a person who does not know better. So it says exactly what it removes. |
 *
 * The door is one click and it is labelled. This is a private area, not a
 * secret: the request was for somewhere out of the way to reach, which is not
 * the same as a hidden gesture only the author knows about.
 *
 * ## The way to a terminal used to be the first row of that table
 *
 * It is not here any more. It is the primary control under the server's name,
 * one zone up; {@link OpenTerminal} in `ServerPage.tsx` carries the whole
 * argument and the warning that came with it. The short version is that the
 * reason it was filed here — a shell is unbounded where every other action has a
 * stated cost — is a reason to keep it apart from the cards, and was never a
 * reason to hide it behind a label that tells people they do not need to go
 * through it. Asad connected a server and could find no way to open one.
 *
 * It is not offered in both places. Two controls doing one thing is two things
 * to keep true, and the one further from the reader is the one that rots.
 *
 * ## Why the copilot's permission is granted here
 *
 * Because the place you hand an assistant control of a machine should be the
 * page that shows you what is on it — not a settings pane, and not the
 * assistant's own window, where the thing being granted is furthest from view.
 * The grant is for **this one server**, it covers the named actions only, and it
 * runs out. It never covers anything else at all: not the shell, not the
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
  /**
   * Turn on, or off, whether sessions on this server may act on browser windows
   * here. Absent when the preload does not carry the channel, and then the
   * section is not drawn at all.
   */
  onDrivesWindows?(allowed: boolean): void
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

/**
 * Whether an agent in a terminal on this server may act on the browser windows
 * somebody attached to that terminal.
 *
 * ## Why it is here and not beside the copilot grant above it
 *
 * They point in opposite directions and reading them as one permission is the
 * mistake this separation exists to stop. The grant above lets *this* machine's
 * copilot act on **that** server. This lets an agent on **that** server act on
 * the browser **here** — the one holding this person's logged-in mail, bank and
 * GitHub. Somebody who allowed the first has said nothing at all about the
 * second, and `remote/machines/store.ts` makes the identical split one machine
 * over for exactly this reason.
 *
 * ## Why it does not expire and the grant above it does
 *
 * Because the thing using it is a conversation. An agent in that terminal reads
 * a page, clicks something, reads it again — turn after turn — and a permission
 * that quietly ran out an hour in would stop it mid-sentence with a refusal
 * nobody asked for. The grant above hands out control of somebody's production
 * machine and is right to run out; this is bounded by what the person attached,
 * window by window, with their own hands.
 *
 * ## Why it is a component of its own
 *
 * So it can be rendered by a test. Everything else on this screen is inside a
 * section that starts collapsed, and a control nobody has proved draws unticked
 * is a control whose closed default is a comment rather than a fact.
 */
export function ServerDrivesWindows({
  server,
  disabled,
  onChange,
}: {
  server: Server
  disabled: boolean
  /** Absent when the preload has no channel for it. Then nothing is drawn. */
  onChange?(allowed: boolean): void
}) {
  // Not drawn rather than drawn dead: a switch whose press lands nowhere would
  // show a state nothing behind it holds, which is the defect this round is
  // about. `MachineRow` makes the same call for the same reason.
  if (onChange === undefined) return null
  return (
    <>
      <h4 className="settings-group-title">Let its terminals act on browser windows here</h4>
      <p className="settings-prose">
        {/*
          What this actually hands out, in the terms the person will recognise: a
          window they attached, and only that. Deliberately not "let this server
          control your browser" — the reach is bounded by the attaching, window
          by window, and overstating it would make the honest answer sound like
          the reckless one.
        */}
        Off unless you turn it on. With it on, an agent in a terminal on this server can read and act
        on the browser windows <em>you</em> attach to that terminal — nothing else in the browser,
        and nothing you did not hand it. It works with Claude Code; Codex and Gemini have no setting
        this app can add to a command you type yourself.
      </p>
      <div className="servers-drive">
        <label className="servers-drive-row">
          <input
            type="checkbox"
            checked={server.drivesWindows === true}
            disabled={disabled}
            onChange={(event) => onChange(event.currentTarget.checked)}
          />
          <span>Sessions on {server.name} may act on browser windows here</span>
        </label>
      </div>
    </>
  )
}

export function ServerAdvanced({
  server,
  state,
  bridge,
  now,
  onRename,
  onForget,
  onGrant,
  onRevoke,
  onDrivesWindows,
}: Props) {
  const [open, setOpen] = useState(false)
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

      {/* The terminal was the first thing behind this door and is now the
          primary control under the server's name. See the note at the top of
          this file, and `OpenTerminal` in `ServerPage.tsx`. */}

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
          here has a way back. Somebody who wants to can do it in a terminal,
          which this page no longer opens but the one above it does, and there it
          is plainly their own decision.
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
        the buttons on the cards above and nothing else at all — not the terminal, not the sign-in,
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

      <ServerDrivesWindows
        server={server}
        disabled={bridge === null}
        {...(onDrivesWindows === undefined ? {} : { onChange: onDrivesWindows })}
      />

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
