import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { readStaleAgents, resolveAccountsApi, type AgentCliVersion } from '../browser/accounts-bridge'
import {
  dismiss,
  isDismissed,
  MACHINE_SCOPE,
  readDismissed,
  restoreAll,
  writeDismissed,
  type DismissedMap,
} from './readiness-dismissed'
import './AgentCliUpdate.css'

/**
 * An agent CLI on this machine that is too old to sign in, and the button that
 * upgrades it.
 *
 * ## The loop this closes
 *
 * From the recorded review of 2026-08-17, of the in-app browser:
 *
 *   > *"Gemini reports 'authentication successful' while the app shows nothing,
 *   > then fails with 'this client is no longer supported to Gemini Code
 *   > Assist… migrate to the Gravity suite.'"*
 *
 * That is not a browser fault and no browser change can reach it. The OAuth
 * genuinely succeeds; the *client* is then turned away on its first API call,
 * because the installed CLI is behind a moving server and on a packaging route
 * its own maintainers have marked for removal. `main/browser-signin.ts` records
 * the three versions that were read on this machine on 2026-08-18 to establish
 * that, and answers `browser-signin:agents` with the rows that are actually
 * stale — measured from the binary, never guessed from a list.
 *
 * A person who hits this loops: sign in, succeed, fail, retry, succeed, fail.
 * The only way out is an upgrade, and the only two places they are standing
 * when it happens are Accounts and AI readiness. So this appears in both, and
 * this file is one component rather than two so the two cannot drift.
 *
 * ## Why the button runs it rather than copying it
 *
 * The audience, stated outright in the same review: *"my audience will be
 * mostly non-technical vibe coders."* A button that copies `brew upgrade …` to
 * the clipboard is a button that hands somebody homework in a language they did
 * not ask to learn. `readiness.ts` owns the act — it asks the package managers
 * which of them installed the thing, runs that one, and reads the version back
 * out of the binary afterwards so the message is measured rather than asserted.
 *
 * The command is still on screen, in the advice line, for anybody who would
 * rather do it themselves. Nothing here hides what it is about to run.
 *
 * ## And it can be put away
 *
 * Dismissal is keyed to the *version*, which is the point of doing it here
 * rather than with a boolean. Somebody who has decided to live with an old
 * build should not be told again tomorrow — and if that build changes and is
 * still stale, that is a new fact and the row comes back.
 */

/** The two calls this needs, mirrored from the preload rather than imported. */
export interface AgentCliBridge {
  browserSignInAgents?(): Promise<unknown>
  applyReadinessFix?(projectPath: string, fixId: string): Promise<unknown>
}

export interface AgentCliUpdateProps {
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: AgentCliBridge
}

/**
 * The fix id `main/readiness.ts` answers this with.
 *
 * A machine-level fix, so the project path it is sent with is deliberately
 * empty — see `MACHINE_FIX_IDS` there for why that is a contract rather than an
 * oversight.
 */
export const UPGRADE_FIX = 'upgrade-agent-cli'

/** One row, put away for as long as it is *this* version that is stale. */
export function dismissalIdFor(row: AgentCliVersion): string {
  return `agent-cli:${row.command}@${row.version ?? 'unknown'}`
}

/**
 * The advice, with its backticked commands set as commands.
 *
 * `browser-signin.ts` writes the sentence the way every other explanation in
 * this codebase is written — commands inside backticks — because that is the
 * convention its own prose follows and the one the naming sweep's scanner
 * relies on. Rendered raw it reaches the screen as ``Upgrade it: `brew upgrade
 * gemini-cli`, or…`` with the backticks visible, which is the one place in this
 * app where a person is being asked to read a command and copy it. Splitting on
 * the pairs and wrapping the odd pieces in `<code>` is the whole of it; an
 * unclosed backtick sets the tail of the sentence as a command, which is a
 * cosmetic wrong on a string this repo writes itself and nothing worse — the
 * alternative, counting the pairs first and bailing out, trades a rare cosmetic
 * fault for a branch that is never taken and never tested.
 */
export function withCommands(text: string): Array<{ code: boolean; text: string }> {
  return text
    .split('`')
    .map((piece, index) => ({ code: index % 2 === 1, text: piece }))
    .filter((piece) => piece.text !== '')
}

/** What a fix answered, narrowed the way everything crossing the bridge is. */
export function readFixResult(raw: unknown): { ok: boolean; message: string } | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  if (typeof value.message !== 'string') return null
  return { ok: value.ok === true, message: value.message }
}

function resolveBridge(): AgentCliBridge {
  const api = resolveAccountsApi()
  const host =
    typeof window === 'undefined'
      ? undefined
      : (window as unknown as { deck?: Record<string, unknown> }).deck
  const applyReadinessFix = host?.applyReadinessFix
  return {
    ...(api.browserSignInAgents ? { browserSignInAgents: api.browserSignInAgents } : {}),
    ...(typeof applyReadinessFix === 'function'
      ? {
          applyReadinessFix: (applyReadinessFix as (p: string, f: string) => Promise<unknown>).bind(
            host,
          ),
        }
      : {}),
  }
}

export function AgentCliUpdate({ bridge }: AgentCliUpdateProps) {
  const resolved = useMemo(() => bridge ?? resolveBridge(), [bridge])
  const [rows, setRows] = useState<AgentCliVersion[]>([])
  const [put, setPut] = useState<DismissedMap>(() => readDismissed())
  const [busy, setBusy] = useState<string | null>(null)
  const [results, setResults] = useState<Record<string, { ok: boolean; message: string }>>({})

  // Bumped by every read, so an answer for a question asked before an upgrade
  // cannot land on top of the answer asked for after it.
  const askRef = useRef(0)

  const load = useCallback(() => {
    const ask = resolved.browserSignInAgents
    if (!ask) return
    const token = ++askRef.current
    void ask().then(
      (raw) => {
        if (token === askRef.current) setRows(readStaleAgents(raw))
      },
      // A build whose main process predates the channel answers with a throw.
      // Nothing on screen is the right outcome: this block exists only to report
      // a measured problem, and "could not measure" is not one.
      () => undefined,
    )
  }, [resolved])

  useEffect(() => {
    load()
    return () => {
      // Nothing in flight may write after this component has gone.
      askRef.current += 1
    }
  }, [load])

  const upgrade = useCallback(
    async (row: AgentCliVersion) => {
      const apply = resolved.applyReadinessFix
      if (!apply) return
      setBusy(row.command)
      try {
        // The empty path is the contract for a machine-level fix, not a
        // placeholder somebody forgot to fill in. See `UPGRADE_FIX`.
        const answer = readFixResult(await apply('', UPGRADE_FIX))
        setResults((prev) => ({
          ...prev,
          [row.command]: answer ?? { ok: false, message: 'The upgrade gave no answer.' },
        }))
        // Re-read from the binary whatever happened. A row that is still stale
        // stays; one that is not disappears, which is the only confirmation
        // worth showing.
        load()
      } catch (cause) {
        setResults((prev) => ({
          ...prev,
          [row.command]: {
            ok: false,
            message: cause instanceof Error ? cause.message : String(cause),
          },
        }))
      } finally {
        setBusy(null)
      }
    },
    [load, resolved],
  )

  const putAway = useCallback((row: AgentCliVersion) => {
    setPut((prev) => {
      const next = dismiss(prev, MACHINE_SCOPE, dismissalIdFor(row))
      writeDismissed(next)
      return next
    })
  }, [])

  const bringBack = useCallback(() => {
    setPut((prev) => {
      const next = restoreAll(prev, MACHINE_SCOPE)
      writeDismissed(next)
      return next
    })
  }, [])

  const showing = rows.filter((row) => !isDismissed(put, MACHINE_SCOPE, dismissalIdFor(row)))
  const hidden = rows.length - showing.length

  if (rows.length === 0) return null

  return (
    <section className="agent-cli" aria-label="Agent updates">
      {showing.map((row) => {
        const result = results[row.command] ?? null
        const working = busy === row.command
        return (
          <div className="agent-cli-row" key={row.command}>
            <div className="agent-cli-body">
              <p className="agent-cli-title">
                <code>
                  {row.command} {row.version}
                </code>{' '}
                is too old to sign in
              </p>
              <p className="agent-cli-detail">
                {withCommands(row.advice).map((piece, index) =>
                  piece.code ? (
                    <code key={index}>{piece.text}</code>
                  ) : (
                    <span key={index}>{piece.text}</span>
                  ),
                )}
              </p>
              {working && (
                <p className="agent-cli-detail" role="status">
                  Upgrading. This runs your own package manager and can take a few minutes.
                </p>
              )}
              {result && (
                <p className="agent-cli-result" data-ok={result.ok} role="status">
                  {result.message}
                </p>
              )}
            </div>
            <div className="agent-cli-actions">
              {/* Absent rather than inert in a window whose preload predates the
                  fix channel: a control that cannot act is the thing this whole
                  pass is removing. The row still says what is wrong, the advice
                  still carries the command, and it can still be put away. */}
              {resolved.applyReadinessFix && (
                <button
                  type="button"
                  className="agent-cli-fix"
                  disabled={working}
                  onClick={() => void upgrade(row)}
                >
                  {working ? 'Upgrading…' : 'Upgrade it'}
                </button>
              )}
              <button type="button" className="agent-cli-dismiss" onClick={() => putAway(row)}>
                Dismiss
              </button>
            </div>
          </div>
        )
      })}

      {/* The way back. Nothing here is a one-way door — see
          `readiness-dismissed.ts` for the review line that rule comes from. */}
      {hidden > 0 && (
        <p className="agent-cli-hidden">
          {hidden === 1 ? '1 update hidden.' : `${hidden} updates hidden.`}{' '}
          <button type="button" className="agent-cli-link" onClick={bringBack}>
            Show it again
          </button>
        </p>
      )}
    </section>
  )
}
