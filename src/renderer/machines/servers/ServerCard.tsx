import { useState } from 'react'
import { Button } from '../../settings/controls'
import { NO_DETAIL, runningTone, runningWord } from './words'
import type { AbsentAction, ActionOutcome, ActionPreview, ServerCard as Card } from './types'

/**
 * One thing this server keeps running: a site, an app, a database, or something
 * we could not classify.
 *
 * ## What is on a card, and nothing else
 *
 * The name, one line naming what was actually found, whether it is running, and
 * the actions its facts support. There is no fourth thing. A card is a fill with
 * a radius and no outline, and a run of them has no rules between them, because
 * this window separates with space, then with a tint, and only then with a line.
 *
 * ## Every button here is real
 *
 * Not greyed hopefully, not present with a tooltip explaining that it does not
 * work yet. If the facts do not support an action, it is not in the list the
 * main process offered and there is nothing here to draw.
 *
 * What *is* drawn is the **reason** for an absence somebody would otherwise read
 * as a missing feature. A database whose kind we could not recognise has no
 * Backup button, and nobody could work out why from an absent button — while
 * dumping it with the wrong tool would produce a file that looks like a backup
 * and is not one, which is worse than no button by a wide margin. So the
 * absence is stated in a sentence, and the sentence is written where the
 * decision was made.
 *
 * ## Why anything that changes something asks first
 *
 * Because the person pressing it may not know what it is. Every action that is
 * not purely reading shows one sentence saying what will happen and what it
 * costs — and that sentence is composed in the main process beside the code that
 * performs it. It is the same string the action log records and the same string
 * the copilot has to get a yes to. Three surfaces, one sentence, and no chance
 * of approving one thing having read another.
 *
 * There is no "are you sure" here for anything irreversible, because nothing
 * irreversible is offered at all. Every action is one of three classes: it
 * changes nothing, it has a named button that puts it back, or it records the
 * way back before it acts and refuses if it could not.
 */

interface Props {
  card: Card
  /** What each offered action would do, fetched with the page. */
  actions: readonly ActionPreview[]
  /** What is missing from this card and why. */
  absent: readonly AbsentAction[]
  /** Runs one action and answers with what the main process reported. */
  onRun(cardId: string, actionId: string): Promise<{ ok: boolean; outcome: ActionOutcome; sentence: string }>
  /** Reads a bounded window of recent output, newest last. */
  onLogs(cardId: string, lines: number): Promise<string[]>
}

/** The three action ids this screen draws or performs in a particular way, and why. */
const OPEN = 'open'
const LOGS = 'logs'
/**
 * The one action whose *work* happens on this side of the bridge.
 *
 * The main process can compute the address but it cannot put anything on this
 * computer's clipboard from inside an action — `actions.ts` marks the row
 * `where: 'here'` for exactly that reason and answers the url for the window to
 * use. Until this existed the button reported **"Copied."** and copied nothing,
 * which is the one thing a control on this page may never do: a person who
 * pressed it and pasted got whatever had been on their clipboard before, and
 * the screen had told them otherwise.
 */
const COPY = 'copy-address'

/** How much output the first press asks for, and how much each Show older adds. */
export const FIRST_LOG_LINES = 200
export const MORE_LOG_LINES = 400
const MOST_LOG_LINES = 2000

export function ServerCard({ card, actions, absent, onRun, onLogs }: Props) {
  const [asking, setAsking] = useState<ActionPreview | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [said, setSaid] = useState<{ ok: boolean; text: string; wayBack: ActionOutcome['wayBack'] } | null>(null)
  const [log, setLog] = useState<string[] | null>(null)
  const [want, setWant] = useState(FIRST_LOG_LINES)
  const [logBusy, setLogBusy] = useState(false)

  function run(actionId: string) {
    setAsking(null)
    setBusy(actionId)
    setSaid(null)
    onRun(card.id, actionId).then(
      (answer) => {
        setBusy(null)
        setSaid({
          ok: answer.ok,
          text: answer.ok ? answer.outcome.done : answer.sentence,
          wayBack: answer.ok ? answer.outcome.wayBack : null,
        })
      },
      () => {
        setBusy(null)
        // A press that reports nothing is the failure this codebase keeps
        // producing: the screen is unchanged and the person cannot tell whether
        // it worked. Say the one true thing instead — we do not know.
        setSaid({ ok: false, text: 'That did not get an answer, so it may or may not have run.', wayBack: null })
      },
    )
  }

  function fetchLog(lines: number) {
    setLogBusy(true)
    onLogs(card.id, lines).then(
      (got) => {
        setLogBusy(false)
        setWant(lines)
        setLog(got)
      },
      () => {
        setLogBusy(false)
        setLog(['We could not read this.'])
      },
    )
  }

  /**
   * Put the address on the clipboard, and say so only if it went.
   *
   * Guarded the way `settings/sections/AdvancedSection.tsx` guards its own
   * copy: `navigator.clipboard` is absent outside a secure context and
   * `writeText` can be refused, and a build that cannot reach the clipboard has
   * to say that rather than claim the copy. The address is on screen either
   * way, so the fallback is something a person can act on.
   */
  function copyAddress(actionId: string) {
    const url = card.url
    const clipboard = typeof navigator === 'undefined' ? undefined : navigator.clipboard
    if (url === null || !clipboard?.writeText) {
      setSaid({ ok: false, text: 'This build cannot reach the clipboard. Copy the address above by hand.', wayBack: null })
      return
    }
    setBusy(actionId)
    setSaid(null)
    clipboard.writeText(url).then(
      // Only now does the action run, and only now does its "Copied." appear —
      // so the sentence the person reads is a report of something that
      // happened rather than of something that was attempted.
      () => run(actionId),
      () => {
        setBusy(null)
        setSaid({ ok: false, text: 'This computer would not let us use the clipboard. Copy the address above by hand.', wayBack: null })
      },
    )
  }

  function press(action: ActionPreview) {
    if (action.actionId === COPY) {
      copyAddress(action.actionId)
      return
    }
    if (action.actionId === LOGS) {
      if (log !== null) {
        setLog(null)
        return
      }
      fetchLog(FIRST_LOG_LINES)
      return
    }
    // Reading changes nothing, so it does not ask. Everything else does.
    if (action.klass === 'safe') run(action.actionId)
    else setAsking(action)
  }

  /*
   * Whether there is older output behind the window on screen.
   *
   * Asked of the answer rather than tracked: a window that came back full is
   * probably not the whole story, and one that came back short certainly is.
   * That is a guess in exactly one direction — offering a press that turns out
   * to add nothing — and the alternative is a count the far end would have to
   * produce by reading the whole file, which is the expensive thing this bounded
   * window exists to avoid.
   */
  const maybeOlder = log !== null && log.length >= want && want < MOST_LOG_LINES

  return (
    <li className="servers-card">
      <div className="servers-card-head">
        <span className="servers-card-name">{card.name}</span>
        <span className="servers-card-state" data-tone={runningTone(card.running)}>
          {runningWord(card.running)}
        </span>
      </div>
      <p className="servers-card-detail">{card.detail === '' ? NO_DETAIL : card.detail}</p>

      {asking === null ? (
        <div className="servers-card-actions">
          {actions.map((action) =>
            action.actionId === OPEN && card.url !== null ? (
              /*
               * A link, because it is one.
               *
               * Opening a site is the one action whose target is an address, and
               * an anchor is what lets somebody see where they are about to go
               * before they go there. The main process turns this into the real
               * browser. When there is no address the action is not offered at
               * all — an Open button with nothing to open is the dead control
               * this window is not allowed to have.
               */
              <a
                key={action.actionId}
                className="settings-btn"
                data-tone="default"
                href={card.url}
                target="_blank"
                rel="noreferrer"
              >
                {action.label}
              </a>
            ) : (
              <Button
                key={action.actionId}
                onClick={() => press(action)}
                disabled={busy !== null}
                title={action.klass === 'safe' ? undefined : action.sentence}
              >
                {busy === action.actionId ? 'Working…' : action.label}
              </Button>
            ),
          )}
        </div>
      ) : (
        <div className="servers-card-ask" role="group">
          {/* The sentence, verbatim from where the action is implemented. */}
          <p className="servers-card-ask-text">{asking.sentence}</p>
          {asking.keeps !== null && (
            // What gets written down first, for the class that records a way
            // back before it changes anything. Naming it is the difference
            // between "trust us" and a promise somebody can check afterwards.
            <p className="servers-card-why">We will keep {asking.keeps}.</p>
          )}
          <div className="servers-card-actions">
            <Button tone="primary" onClick={() => run(asking.actionId)}>
              {asking.label}
            </Button>
            <Button onClick={() => setAsking(null)}>Cancel</Button>
          </div>
        </div>
      )}

      {absent.map((missing) => (
        // Why something a person might look for is not here. An absence with no
        // explanation reads as a missing feature; this is the explanation, and
        // it is written where the decision was made.
        <p className="servers-card-why" key={`absent-${missing.actionId}`}>
          {missing.because}
        </p>
      ))}

      {said !== null && (
        <div className="servers-card-said" data-ok={said.ok ? 'yes' : 'no'}>
          <p className="servers-card-said-text">{said.text}</p>
          {said.wayBack !== null && (
            // The named button that puts it back, offered the moment it exists
            // rather than hidden behind a second visit to the page. This is what
            // makes the class "reversible" mean something on screen.
            <div className="servers-card-actions">
              <Button onClick={() => run(said.wayBack?.actionId ?? '')}>{said.wayBack.label}</Button>
            </div>
          )}
        </div>
      )}

      {logBusy && log === null && <p className="servers-card-why">Reading…</p>}

      {log !== null && (
        <div className="servers-log">
          {/*
            A bounded window, fetched once, newest last — not a stream that
            stays open. A follow mode is a connection held for as long as
            somebody leaves the page up, which is the standing cost this whole
            area is arranged to avoid. Older output is a press.
          */}
          <pre className="servers-log-body">{log.join('\n')}</pre>
          <div className="servers-card-actions">
            {maybeOlder && (
              <Button onClick={() => fetchLog(Math.min(want + MORE_LOG_LINES, MOST_LOG_LINES))} disabled={logBusy}>
                {logBusy ? 'Reading…' : 'Show older'}
              </Button>
            )}
            <Button onClick={() => setLog(null)}>Hide</Button>
          </div>
        </div>
      )}
    </li>
  )
}
