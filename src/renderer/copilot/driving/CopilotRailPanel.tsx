import { useEffect, useMemo } from 'react'
import { ChatComposer } from '../../components/ChatComposer'
import { ChatView } from '../../components/ChatView'
import { useWindowBinding } from '../../browser/binding-view'
import { useAgentTarget } from '../../browser/useAgentTarget'
import { useOptionalStore } from '../../state/store'
import { useCopilotNaming } from '../useCopilotNaming'
import { shortUrl } from './browser-trace'
import { foldRailPanel, useRailCopilot, useRailPanel } from './rail-panel'
import './copilot-rail.css'

/**
 * The side panel, in the rail's own column: a conversation with the session
 * driving the page in front.
 *
 * ## What it replaced, and why
 *
 * Until 2026-08-21 this column held `BrowserWatch` — the driver's action log,
 * one row per `browser.*` call, with no way to say anything back. Asad drove
 * with it and said what it was for instead:
 *
 * > *"it is not actually for the updates. It is actually for the chatting to
 * > Copilot, because we are now in a different page and we cannot go there. I
 * > want to chat here while it is scrapping, so that's why we have this side
 * > panel."*
 *
 * and, later in the same recording, what it is a conversation *with*:
 *
 * > *"whatever the browser it is connected to… that session's chatbox should
 * > come in the side panel, not only the commander, but any session whichever is
 * > connected to any browser."*
 *
 * So the subject is read off the **binding**, not off the copilot: a browser
 * window belongs to at most one session (`browser-binding.ts` is the map, and
 * the `B1` in a drive trace is that session's slot for that window), and this
 * panel is that session's chat. The copilot is the fallback and only the
 * fallback — a driven page with no binding is still a page the copilot is
 * working on, and somebody watching it has to have someone to ask.
 *
 * ## Why it is a `ChatView` and not a second conversation renderer
 *
 * Because there is exactly one conversation and this is a second *view* of it.
 * The messages are read from the session's own transcript by the same reader the
 * full-window chat uses, and what is typed here goes down the same pty — so a
 * question asked from this panel is in the session's transcript, in its terminal
 * and in its own chat pane, and there is no second channel to keep in step. It
 * is the same argument `DriveComposer` made for the scan panel one file over.
 *
 * The composer is the app's, in `plain` mode: *"only one small typing box and
 * send button… only maybe add file thing can be there."* That is the box, the
 * attach menu and send, with the microphone withheld — see `ChatComposer`.
 *
 * ## Where it is
 *
 * A child of `<aside class="sidebar">`, drawn *instead of* the rail's list
 * rather than over it, starting below the New session header:
 *
 * > *"this should actually replace with this instead of coming in front of it"*
 *
 * > *"It will be starting from the first pill of commander, not from the top
 * > with the top header also should not be covering it."*
 *
 * That is the whole fix for the gap he filmed — a fixed panel at a token 264px
 * over a rail at a saved 338px, with the browser page starting at neither. In
 * the rail's flow there is no width to agree on: the panel is the column.
 */
export function CopilotRailPanel() {
  const rail = useRailPanel()
  const page = rail.page
  const binding = useWindowBinding(page?.tabId)
  const copilotSessionId = useRailCopilot()

  /*
   * Who this conversation is with.
   *
   * The binding first, because that is the fact he described — the session
   * *connected to* this browser window. The copilot second, because it is the
   * one driving. Null only when there is neither, and then the panel says so
   * rather than drawing an empty conversation over the rail.
   */
  const sessionId = binding?.session.sessionId ?? copilotSessionId

  /*
   * The list the window already keeps, for the two facts a transcript needs.
   *
   * `useOptionalStore` rather than `useStore` for the reason `useAgentTarget`
   * gives about the same call: this component is also rendered in the harness
   * and in tests, outside any provider, and a throwing hook there is a sidebar
   * that will not render at all.
   */
  const store = useOptionalStore()
  const local = useMemo(
    () => (sessionId === null ? null : (store?.sessions ?? []).find((one) => one.id === sessionId) ?? null),
    [store?.sessions, sessionId],
  )

  /*
   * The picker's own list and its own send, reused whole.
   *
   * It is where a session's *name* is worked out — the rail's rename, the
   * copilot's real name out of its instruction file, `folder · Session 2` for
   * everything else — and where a send is routed: a pty write on this machine, a
   * `session.send` over the wire for one on a paired machine. Writing either of
   * those again here is how the panel comes to call a session something the
   * picker does not, or to report a delivery the far end refused.
   */
  const target = useAgentTarget()
  /* The copilot's real name, for the one row the picker's list cannot name
     before it has arrived. See where the heading is built. */
  const copilot = useCopilotNaming()
  const chosen = target.chosenId
  const choose = target.choose
  useEffect(() => {
    if (sessionId !== null && chosen !== sessionId) choose(sessionId)
  }, [choose, chosen, sessionId])

  if (rail.state !== 'panel' || page === null) return null

  /*
   * What to call this session, and what to do before the list has arrived.
   *
   * The picker's own label whenever it has one, so the panel says the same words
   * the rest of the window says. Before its first `session:list` lands there is
   * one session this window can still name — the copilot, out of its own
   * instruction file — and it is the fallback subject anyway. Everything else
   * gets an empty heading for the fraction of a second before the list arrives,
   * which is the honest alternative to printing `Copilot` over a conversation
   * with something else, or printing the word he renamed away from.
   */
  const row = target.sessions.find((one) => one.id === sessionId) ?? null
  const name = row?.label ?? (sessionId !== null && sessionId === copilotSessionId ? copilot.name : '')
  const where = shortUrl(rail.drive?.url ?? '')
  /*
   * Which machine it runs on, asked of both lists.
   *
   * The binding when there is one, and the picker's row otherwise — and the
   * second half is not belt-and-braces. The fallback subject is the copilot,
   * and a copilot can be running on a paired machine; there is no binding in
   * that case to carry the id, and reading `''` would send this panel looking
   * for a transcript on this disk that is on somebody else's.
   */
  const machineId = binding?.session.machineId || row?.machineId || ''

  return (
    <section
      className="copilot-rail"
      aria-label={name === '' ? 'This page’s session' : `${name} — this page`}
    >
      <header className="cr-head">
        <div className="cr-head-line">
          <p className="cr-name">{name}</p>
          {/*
            Collapse, and it is a real collapse rather than a hide: the rail
            comes back whole, and the Commander row it folds into shows that the
            panel is parked there and brings it back when pressed. *"If we
            collapse, it folds inside here… It should close inside the this
            commander's pill."* It stays folded across pages, tabs and further
            errands — see `rail-panel.ts` for why that is a plain flag now.
          */}
          <button
            type="button"
            className="cr-fold"
            onClick={foldRailPanel}
            title="Fold this into the Commander row"
            aria-label="Fold this into the Commander row"
          >
            <svg
              width="15"
              height="15"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.6"
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
            >
              <path d="M15 6l-6 6 6 6" />
            </svg>
          </button>
        </div>
        {/*
          The page this conversation is about.

          `shortUrl` has already dropped the scheme and the query string — a
          query is where a session token ends up, and this panel is on screen
          while somebody may be recording it. Empty while the drive has a tab
          and nothing in it yet, and then nothing is drawn rather than a heading
          that contradicts the page behind it.
        */}
        {where === '' ? null : <p className="cr-where">{where}</p>}
      </header>

      {sessionId === null ? (
        /*
         * A live drive with nobody to ask. It happens when a page is driven
         * without being attached to a session and this build has no copilot
         * running — rare, and the only honest thing to draw is the sentence,
         * because a composer here would have nowhere to write.
         */
        <p className="cr-nobody">
          Nothing is connected to this page, so there is no conversation to show. Connect a session
          to it from the browser’s toolbar.
        </p>
      ) : machineId !== '' ? (
        /*
         * A session on a **paired machine** — and only that. A terminal on an
         * SSH server can never be this panel's subject: `attachableSessions`
         * (agent-target.ts) refuses server shells a browser window outright, a
         * server row's `machineId` is `''` by construction, and the binding
         * map has no key shape for one. So the sentence below is about paired
         * machines alone, and there it is still true: a paired machine's
         * transcript is a file on that machine's disk, and nothing in this app
         * reads a conversation off a paired machine.
         *
         * That scoping is the 2026-08-22 correction. This comment used to
         * borrow its authority from "the same limit the chat toggle states on
         * a remote session's bar" — stale since 129b890 built the *server*
         * chat reader (`servers/chat.ts`, `ServerChatPane`) and App.tsx
         * stopped blocking chat on a server session. If server shells ever do
         * take a browser window, this branch must route to that reader rather
         * than reuse this sentence: the claim "cannot be read here" would be
         * false for them on the day they arrive.
         *
         * The box underneath still works: `session.send` types into a session on
         * a paired machine without attaching to it, which is the route the
         * browser's own send picker has used since 2026-08-20.
         */
        <div className="cr-elsewhere">
          <p className="cr-note">
            {name} runs on {row?.machineName || 'another machine'}. Its conversation is written on
            that machine, so it cannot be read here — but what you type below still reaches it.
          </p>
          <ChatComposer
            onSend={(text) => void target.send(text, { submit: true })}
            sessionId={sessionId}
            plain
          />
        </div>
      ) : (
        <div className="cr-chat">
          <ChatView
            cwd={local?.cwd ?? null}
            session={
              local === null
                ? null
                : {
                    startedAt: local.createdAt,
                    resumed: local.resumed,
                    ...(local.agentSessionId === undefined
                      ? {}
                      : { agentSessionId: local.agentSessionId }),
                  }
            }
            sessionId={sessionId}
            // `submit`, because this is a chat box: a message that landed on
            // the agent's command line without being sent is a box that did
            // nothing. The picker's other caller sends context to be edited and
            // deliberately does not.
            onSend={(text) => void target.send(text, { submit: true })}
            {...(local?.provider ? { provider: local.provider } : {})}
            plain
          />
        </div>
      )}

      {/*
        The one place a send can fail and say why: a line the far machine
        refused. Shown here rather than swallowed, because a composer that
        cleared itself over a message nobody received is the failure the send
        picker was rewritten to stop.
      */}
      {target.problem === '' ? null : <p className="cr-problem">{target.problem}</p>}
    </section>
  )
}
