import { useCallback, useState } from 'react'
import { Button, Notice } from '../../settings/controls'
import { ServerCard } from './ServerCard'
import { ServerAdvanced } from './ServerAdvanced'
import { ServerFolderPicker } from './ServerFolderPicker'
import { ServerSetup } from './ServerSetup'
import { ServerHost } from './ServerHost'
import { groupReasons } from './group-notes'
import { useServerSessionOpener } from './session-context'
import { useServerRoom } from './useServers'
import { asLogLines, asOutcome, asRefusal, succeeded } from './types'
import { asOf, GROUP_HEADING, linkSentence, NOTHING_FOUND, overallSentence, readings } from './words'
import type { ServerSessionOpener } from './session-context'
import type {
  AbsentAction,
  ActionOutcome,
  CardKind,
  Server,
  ServerCard as Card,
  ServerState,
  ServersBridge,
} from './types'

/**
 * One server, as three zones in one order.
 *
 * **The ordering is the design.** Sharp things live one door further in so that
 * the everyday surface stays calm. Somebody who opens this page to check on
 * their website should be able to answer "is everything all right" without
 * reading a single word they do not understand, and without being one mis-click
 * away from stopping it.
 *
 *  1. **Is everything OK** — one sentence, a few numbers, one control — under a
 *     head that carries the one thing a person does with a server they have just
 *     connected: open a terminal on it. See {@link OpenTerminal} for why that
 *     control is here and not one door further in, which is where it used to be.
 *  2. **The things they own** — a card per site, app and database, each with the
 *     actions its own facts support.
 *  3. **Advanced** — the identity, the sign-in, the permission, and the way to
 *     forget it. Behind a labelled door.
 *
 * ## The connection is this page's lifetime
 *
 * Opening this page opens one connection; leaving it closes that connection.
 * There is no background dial, no keep-alive sweep, and nothing connected to a
 * server nobody is looking at.
 */

/** The order the middle zone runs in, and it is deliberate rather than alphabetical. */
const ORDER: readonly CardKind[] = ['site', 'app', 'database', 'other']

interface Props {
  server: Server
  state: ServerState | undefined
  bridge: ServersBridge | null
  now: number
  /** Where this page's answers go, so the list can still show them afterwards. */
  onState(state: ServerState): void
  onBack(): void
  onForget(id: string): void
  onRename(id: string, name: string): void
}

export function ServerPage({
  server,
  state,
  bridge,
  now,
  onState,
  onBack,
  onForget,
  onRename,
}: Props) {
  const { look } = useServerRoom(bridge, server.id, onState)
  /*
   * The window's list of open shells, or null when this page has no window
   * around it.
   *
   * Read from the context rather than threaded down as a prop, for the reason
   * `session-context.ts` sets out in full: the only route from the window to
   * this component is `PanelView`, which draws all ten views from a `PanelId`
   * and takes no per-view props, so a callback would have to be added to the
   * component that draws every panel in order to reach one of them.
   */
  const opener = useServerSessionOpener()

  const run = useCallback(
    (
      cardId: string,
      actionId: string,
    ): Promise<{ ok: boolean; outcome: ActionOutcome; sentence: string }> => {
      if (!bridge) {
        return Promise.resolve({
          ok: false,
          outcome: { done: '', wayBack: null },
          sentence: 'This build cannot do that.',
        })
      }
      return bridge.actOnServer(server.id, cardId, actionId).then((raw) => {
        if (!succeeded(raw)) {
          return { ok: false, outcome: { done: '', wayBack: null }, sentence: asRefusal(raw).sentence }
        }
        /*
         * Measure again, because something changed — and because a press
         * happened, which is the whole distinction the standing rule draws. A
         * card still reading "running" after somebody stopped it is a lie the
         * page told about work the page did.
         *
         * Reading is exempt: opening a site or fetching its recent output
         * changes nothing, so re-measuring afterwards would be a round trip
         * nobody asked for.
         */
        if (actionId !== 'logs' && actionId !== 'open' && actionId !== 'copy-address') look()
        return {
          ok: true,
          outcome: asOutcome((raw as { outcome?: unknown }).outcome),
          sentence: '',
        }
      })
    },
    [bridge, server.id, look],
  )

  const logs = useCallback(
    (cardId: string, lines: number): Promise<string[]> => {
      if (!bridge) return Promise.resolve([])
      return bridge.readServerLogs(server.id, cardId, lines).then(asLogLines)
    },
    [bridge, server.id],
  )

  const link = state?.link ?? 'connecting'
  const view = state?.view

  return (
    <div className="servers-page">
      <div className="servers-page-head">
        <Button onClick={onBack}>Back to machines</Button>
        <div className="servers-page-title">
          <h3 className="servers-page-name">{server.name}</h3>
          <p className="servers-page-where">
            {server.username === '' ? server.address : `${server.username} at ${server.address}`}
          </p>
        </div>
        {state?.identityChanged !== true && link !== 'failed' && (
          /*
           * Under the name, above everything measured — and drawn from the head
           * rather than from inside the branch below so that it sits in the same
           * stack as the title it belongs to.
           *
           * The two conditions are the two states where the page is not offering
           * a way on to the server at all. An identity that changed makes this
           * whole page a warning with no way past it, and a way on to the machine
           * beside that warning is the "connect anyway" button whose absence is
           * the entire value of the check. A connection that failed already says
           * so, with a Try again, in the notice directly below.
           */
          <OpenTerminal server={server} bridge={bridge} opener={opener} />
        )}
      </div>

      {state?.identityChanged === true ? (
        <IdentityChanged state={state} onBack={onBack} />
      ) : (
        <>
          <ServerHealth state={state} now={now} onRefresh={look} />

          {/* Directly under the calm zone, because it is a fact about the
              machine rather than a thing running on it — and because it is the
              answer to the question somebody asks a minute after connecting:
              can I actually work on this one. */}
          <ServerSetup server={server} bridge={bridge} connected={link === 'ready'} />

          {/* Directly under it, because it is the other half of the same
              question. `ServerSetup` answers "can I work on this machine"; this
              answers "can I reach it from somewhere else" — and the two are the
              same shape, the same terminal and the same way back, which is why
              they are two sections rather than two screens. */}
          <ServerHost server={server} bridge={bridge} connected={link === 'ready'} />

          {link === 'failed' && (
            <Notice tone="error">
              {state?.problem ?? 'We could not reach this server.'}{' '}
              <Button onClick={look}>Try again</Button>
            </Notice>
          )}

          {view !== undefined && view.cards.length === 0 && (
            <p className="settings-prose">{NOTHING_FOUND}</p>
          )}

          {ORDER.map((kind) => {
            const cards = (view?.cards ?? []).filter((card) => card.kind === kind)
            if (cards.length === 0) return null
            return (
              <CardGroup
                key={kind}
                kind={kind}
                cards={cards}
                previews={state?.previews}
                absent={view?.absent}
                onRun={run}
                onLogs={logs}
              />
            )
          })}

          <ServerAdvanced
            server={server}
            state={state}
            bridge={bridge}
            now={now}
            onRename={(name) => onRename(server.id, name)}
            onForget={() => onForget(server.id)}
            onGrant={(forMs) => {
              // Re-read the page rather than assume the grant took: `grants.ts`
              // can refuse one, and a screen that drew "allowed" off the press
              // rather than off the answer would be claiming a permission
              // nobody holds.
              if (bridge) void bridge.grantServerCopilot(server.id, forMs).then(look, look)
            }}
            onRevoke={() => {
              if (bridge) void bridge.revokeServerCopilot(server.id).then(look, look)
            }}
          />
        </>
      )}
    </div>
  )
}

/**
 * The one thing a person does with a server they have just connected.
 *
 * ## Why it is under the name and not behind the door
 *
 * Because it was behind the door, and the door works. `ServerAdvanced` is
 * labelled *Advanced*, which tells a reader they do not need to go through it,
 * and it starts shut — so the single most obvious thing to do with a machine you
 * have just signed in to was two clicks in, behind a sign saying it was not for
 * them. Asad, having added a server and landed on this page: *"i cant open a
 * session in connected server i connected it now see there is no way for this."*
 *
 * The argument that put it there was real and it is kept: a shell is unbounded
 * where everything else on this page is a named action with a stated cost, so it
 * does not belong among the cards. That is a reason to keep it *apart* from
 * them. It was never a reason to keep it *out of sight*, and the sharp things it
 * was filed beside — changing the sign-in, forgetting the server — stay behind
 * the door, because those are rare and this is the reason people come here.
 *
 * ## Why this says *terminal* where he said *session*
 *
 * Both words are on screen and neither is a translation of the other. **Session**
 * is this app's own noun for anything it holds open — a row in the rail, a tab
 * along the top — so it names the app's furniture, which is the one thing
 * somebody who has never signed in to a server has no reason to know yet.
 * **Terminal** names what they get. `terminal-is-a-session.test.ts` pins the
 * claim that the one *is* the other, so the button names the terminal and the
 * line under it says where the terminal lands; renaming the button would say
 * half of that and drop the half he was missing.
 *
 * ## What is drawn when it cannot be offered
 *
 * Absent rather than greyed, the same rule the cards follow. Both absences here
 * are about this copy of the app rather than about the server, which is the
 * difference between a task and a bug report, so both are stated in a sentence:
 * a build whose preload carries no server channels, and a page rendered outside
 * a window that could hold a terminal open at all.
 *
 * A connection still dialling does **not** withhold it. `openServerShell` in
 * `App.tsx` mints its own key and opens its own shell rather than borrowing the
 * one this page holds, so the press does not wait on this page's connection —
 * and a primary control that appeared a second after the page did would move out
 * from under the cursor of the person reaching for it.
 *
 * ## The folder, and why it is no longer behind a press
 *
 * The same picker the New session dialog draws is here, because *"choose the
 * path from server to start a session"* is one question and asking it two ways
 * on two screens is how the two drift.
 *
 * It used to be shut behind a *Choose a folder* toggle, and the argument for
 * that was cost: opening it listed a folder, which is a round trip nobody asked
 * for on a page whose entire design is that it measures once and then leaves
 * the server alone. The argument was sound and the control was still wrong —
 * *"I still cannot find the path… there should be a window open where we can
 * drive the folders."* Nobody presses a door they cannot see the point of.
 *
 * What is here now costs the same nothing: one line saying where a session will
 * start — this server's remembered default, when it has one — and a *Browse…*
 * that opens a window. The line reads a stored preference and dials nothing.
 * The first SFTP round trip happens when somebody presses Browse, which is the
 * bargain the old toggle was trying to make and now makes without hiding the
 * control to do it.
 *
 * Pressing *Open a terminal* without touching any of it lands in that default,
 * or — for a server nobody has chosen one for — wherever the sign-in lands,
 * which is what it did before any of this existed.
 */
function OpenTerminal({
  server,
  bridge,
  opener,
}: {
  server: Server
  bridge: ServersBridge | null
  opener: ServerSessionOpener | null
}) {
  /*
   * The folder chosen for the next press, and only for it.
   *
   * Held here rather than on the page, because it is a fact about this control
   * and nothing else on the page reads it — and cleared with the page, which is
   * correct: a folder chosen for one terminal is not an answer about the next
   * one. Null is not *nowhere*: it means nothing has been chosen for this
   * press, and the main process reads this server's remembered default for it.
   * The line the picker draws says which of the two is in force.
   */
  const [folder, setFolder] = useState<string | null>(null)

  if (bridge === null) return <p className="servers-card-why">This build cannot open one.</p>
  if (opener === null) {
    return (
      <p className="servers-card-why">This page is not inside a window that can hold one open.</p>
    )
  }
  const openHere = opener.openOn(server.id)
  return (
    <div className="servers-page-open">
      <div className="servers-card-actions">
        <Button tone="primary" onClick={() => opener.open(server.id, server.name, folder)}>
          Open a terminal
        </Button>
        {openHere > 0 && (
          <span className="servers-card-why">
            {openHere === 1
              ? 'One is already open on this one.'
              : `${openHere} are already open on this one.`}
          </span>
        )}
      </div>
      {/* Always drawn, never behind a door. It is one line and a Browse…, and
          the line is the answer to the question the button above raises: where
          does the terminal I am about to open actually land. */}
      <ServerFolderPicker
        serverId={server.id}
        serverName={server.name}
        bridge={bridge}
        path={folder}
        onChoose={setFolder}
      />
      <p className="servers-card-why">
        {/*
          Where it goes and what it is, both said before the press rather than
          discovered after it. The first sentence is the one that stops a person
          thinking their work has been put somewhere they cannot find it, and it
          was written when the terminal stopped being a rectangle on this page.
          The second is the warning that used to justify keeping the button
          behind the door; the button moved and the warning came with it, because
          this is the one control on the page whose consequence nothing states.
        */}
        It opens like any other session: a row in the list on the left, under this server’s name,
        and a tab along the top. Whatever you type into it runs on this server, and nothing here
        checks it first.
      </p>
    </div>
  )
}

/**
 * One run of cards under one heading — and, for the remainder, one more door.
 *
 * ## Why *Other things running* starts closed
 *
 * Measured on a real Ubuntu server: **fifty-nine** cards under that heading,
 * against three the person actually owns above it. `apparmor`, `apport`,
 * `atd`, `systemd-udevd`, `ufw`, `user@0` — the operating system talking to
 * itself, correctly reported, and a wall. The zone that is supposed to answer
 * *"is my website all right"* could not be read in one screen, and the three
 * rows that mattered were at the top of a page nobody scrolls to the bottom of.
 *
 * Nothing is hidden: the heading says how many, and one press shows every one.
 * That is the difference between this and a filter — a person who wonders what
 * else is on their server can find out, and a person who does not is not made
 * to read it first. The three groups above stay open, because they are the
 * page.
 *
 * The button is the same idiom as Advanced, deliberately. This window already
 * has one gesture for *"there is more here, one click in"*, and inventing a
 * second — a chevron, a twisty — would make two things that mean the same thing
 * look different.
 */
function CardGroup({
  kind,
  cards,
  previews,
  absent,
  onRun,
  onLogs,
}: {
  kind: CardKind
  cards: readonly Card[]
  previews: ServerState['previews'] | undefined
  absent: Record<string, AbsentAction[]> | undefined
  onRun(cardId: string, actionId: string): Promise<{ ok: boolean; outcome: ActionOutcome; sentence: string }>
  onLogs(cardId: string, lines: number): Promise<string[]>
}) {
  const shut = kind === 'other'
  const [open, setOpen] = useState(!shut)
  const { shared, own } = groupReasons(cards, absent)

  return (
    <section className="servers-group" key={kind}>
      {shut ? (
        <div className="servers-group-door">
          <Button onClick={() => setOpen(!open)}>
            {/* The count is on the closed door, because a number is the whole
                reason somebody would or would not open it. */}
            {open ? `Hide ${GROUP_HEADING[kind].toLowerCase()}` : `${GROUP_HEADING[kind]} (${cards.length})`}
          </Button>
        </div>
      ) : (
        <h4 className="settings-group-title">{GROUP_HEADING[kind]}</h4>
      )}

      {open && (
        <>
          {shared.map((because) => (
            // Said once, over the group, because it is true of every card in it.
            <p className="servers-group-why" key={because}>
              {because}
            </p>
          ))}
          {/* No rules between rows: this window separates with space, then
              with a tint, and only then with a line. */}
          <ul className="servers-cards">
            {cards.map((card) => (
              <ServerCard
                key={card.id}
                card={card}
                actions={previews?.[card.id] ?? []}
                absent={own[card.id] ?? []}
                onRun={onRun}
                onLogs={onLogs}
              />
            ))}
          </ul>
        </>
      )}
    </section>
  )
}

/**
 * Zone one: is everything OK.
 *
 * One sentence, at most four numbers, and one control. The sentence is composed
 * from what was measured and never from optimism — a green summary over a fact
 * we could not read is the single most damaging thing this page could do,
 * because it is the thing somebody glances at and then stops thinking about.
 *
 * **Nothing here is clickable except the refresh**, and that exception is
 * deliberate rather than a slip. The moment this zone has buttons it becomes a
 * control surface and has to be read carefully; it is the one part of the page
 * that is allowed to be glanced at. Refresh earns its place because a person who
 * wants to know *now* must be able to ask — and asking on a press is what makes
 * the rest of the arrangement, where nothing asks on a timer, honest rather than
 * merely cheap.
 */
export function ServerHealth({
  state,
  now,
  onRefresh,
}: {
  state: ServerState | undefined
  now: number
  onRefresh(): void
}) {
  const link = state?.link ?? 'connecting'
  const view = state?.view
  const sentence = view === undefined ? linkSentence(link) : overallSentence(view.cards)
  const numbers = readings(view?.facts)

  return (
    <section className="servers-health">
      <div className="servers-health-top">
        <p className="servers-health-say">{sentence}</p>
        <div className="servers-health-ask">
          {view !== undefined && view.measuredAt > 0 && (
            // The age, on screen, next to the numbers it belongs to. This is
            // what makes a page of cached facts honest rather than stale: it is
            // true, it costs nothing, and it beats a figure that is fresh only
            // because something has been asking all night.
            <span className="servers-health-age">as of {asOf(view.measuredAt, now)}</span>
          )}
          <Button onClick={onRefresh} disabled={link === 'connecting'}>
            Check now
          </Button>
        </div>
      </div>
      {numbers.length > 0 && (
        <ul className="servers-readings">
          {numbers.map((reading) => (
            <li className="servers-reading" key={reading.id}>
              <span className="servers-reading-value">{reading.value}</span>
              <span className="servers-reading-label">{reading.label}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

/**
 * The server answered with a different identity than last time, and this is the
 * whole page until somebody leaves it.
 *
 * There is no "connect anyway" button, and its absence is the entire value of
 * the check. A warning that can be clicked through is a warning that will be
 * clicked through, and this is the one condition on the whole screen where
 * continuing could hand a password to somebody who is not who they say they are.
 *
 * Both identities are shown when both are known, because they are checkable
 * elsewhere: the string this app computes is byte-for-byte the one every other
 * tool computes for the same server, so a person can go and compare it against
 * the machine itself and come back knowing rather than guessing.
 */
export function IdentityChanged({ state, onBack }: { state: ServerState; onBack(): void }) {
  return (
    <section className="servers-stop">
      <h4 className="servers-stop-title">This server answered with a different identity</h4>
      <p className="settings-prose">
        {/* The sentence the main process wrote, which is the one that knows what
            actually happened. The paragraphs around it are this screen's own,
            because they are about what to do rather than about what occurred. */}
        {state.problem ??
          'Every server has an identity that does not change, and this one has. We have not signed in and we have not sent your password.'}
      </p>
      {state.identity !== undefined && (
        <div className="servers-facts">
          <div className="servers-fact">
            <span className="servers-fact-label">What we saw the first time</span>
            <span className="servers-fact-value">{state.identity.expected}</span>
          </div>
          <div className="servers-fact">
            <span className="servers-fact-label">What answered now</span>
            <span className="servers-fact-value">{state.identity.offered}</span>
          </div>
        </div>
      )}
      <p className="settings-prose">
        If you rebuilt this server yourself, forget it in this app and add it again. If you did not,
        ask whoever looks after it before you sign in anywhere.
      </p>
      <div className="servers-card-actions">
        <Button onClick={onBack}>Back to machines</Button>
      </div>
    </section>
  )
}
