import { useCallback, useState } from 'react'
import { Button, Notice } from '../../settings/controls'
import { ServerCard } from './ServerCard'
import { ServerAdvanced } from './ServerAdvanced'
import { groupReasons } from './group-notes'
import { useServerRoom } from './useServers'
import { asLogLines, asOutcome, asRefusal, succeeded } from './types'
import { asOf, GROUP_HEADING, linkSentence, NOTHING_FOUND, overallSentence, readings } from './words'
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
 *  1. **Is everything OK** — one sentence, a few numbers, one control.
 *  2. **The things they own** — a card per site, app and database, each with the
 *     actions its own facts support.
 *  3. **Advanced** — the terminal, the identity, the sign-in, the permission,
 *     and the way to forget it. Behind a labelled door.
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
      </div>

      {state?.identityChanged === true ? (
        <IdentityChanged state={state} onBack={onBack} />
      ) : (
        <>
          <ServerHealth state={state} now={now} onRefresh={look} />

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
