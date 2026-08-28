// Relative, not '@shared/…': vitest runs without the electron-vite resolver, so
// the alias is not there. See the note in `bridge.ts`.
import { AGENT_CATALOG } from '../../shared/agent-catalog'
import {
  MANIFEST_AGENTS,
  NEED_WORDS,
  type ManifestAgent,
  type StoreNeed,
} from '../../shared/store-manifest'
import { HoverNote } from '../components/HoverNote'
import { Modal } from '../components/Modal'
import { installable, tierWord, type CommunityAgent, type CommunityItem } from './bridge'
import './community.css'

/**
 * What a person is agreeing to, before anything is written.
 *
 * ## Four lines, and every value computed
 *
 * *Lands in*, *Read by*, *Needs*, *Not ours*. Nothing else, and no paragraph
 * anywhere in it — house rule 1, and `settings/one-info-dot.test.tsx` says the
 * same thing mechanically: anything longer than a line lives behind the ⓘ or it
 * does not live on the screen at all.
 *
 * Every value here arrives from the main process, computed by the code that will
 * do the writing. That is the whole design of this sheet rather than a
 * convenience: a dialog that composed its own list of paths would be a promise
 * made by a component that installs nothing, and the failure mode of it — a
 * sheet naming three folders while the installer writes a fourth — is silent,
 * looks correct, and is exactly the thing somebody pressing Install is trusting.
 *
 * ## The line at the top, and why the long version is behind a dot
 *
 * One sentence: the tier, in the words `TIER_WORDS` holds. *Runs a program on
 * this machine* is what somebody has to read; what starts it, as whom, when, and
 * for how long is four more sentences that would push the four rows below the
 * fold. `HoverNote` is the only sanctioned way to keep a paragraph on a screen
 * in this app, so that is where it goes.
 *
 * ## All three agents, always
 *
 * Drawn from `MANIFEST_AGENTS` rather than from what the main process happened
 * to send, so an older half that answers with an empty list still draws three
 * rows. That is house rule 4 made structural: *"where we can have an option
 * between Claude, Codex, Gemini, in those places don't name only Claude."* An
 * agent that is not on this machine gets no checkbox — absent, never a disabled
 * one — and one short line saying so, which is the honest substitute for a
 * control that could not act.
 */

/* ---------------------------------------------------------------- the body -- */

/**
 * The longer half of the tier sentence, behind the dot.
 *
 * Three strings and no fourth: `StoreTier` is a closed union of three, so a
 * lookup rather than a chain, and a tier that is not one of them cannot exist.
 */
const TIER_NOTES: Readonly<Record<1 | 2 | 3, string>> = {
  1: 'Nothing in it is a program. The files sit on your disk and an agent reads them when it needs them. This app never runs any of it.',
  2: 'It ships scripts. This app does not run them; your agent may, during a session, as you, with everything you can reach.',
  3: 'It starts a program on this machine when a session begins. That program runs as you, with everything you can reach, and it keeps running until the session ends.',
}

export interface InstallSheetBodyProps {
  item: CommunityItem
  /** What the main process found on this machine. May be short or empty. */
  agents: readonly CommunityAgent[]
  /** Which agents are ticked. The container holds it so a re-read cannot lose it. */
  chosen: readonly ManifestAgent[]
  onChoose(next: readonly ManifestAgent[]): void
}

/**
 * Everything a person reads in the sheet, as a pure function of the item.
 *
 * Split from {@link InstallSheet} for the reason every screen in this store is:
 * the dialog around it goes through a portal into `document.body`, and there is
 * no DOM in this project's test setup, so a test that rendered the dialog would
 * be asserting on nothing. This is what a person actually reads.
 */
export function InstallSheetBody({ item, agents, chosen, onChoose }: InstallSheetBodyProps) {
  const presence = new Map(agents.map((one) => [one.id, one]))
  const toggle = (id: ManifestAgent, on: boolean): void => {
    onChoose(on ? [...chosen, id] : chosen.filter((one) => one !== id))
  }

  return (
    <div className="cs-sheet">
      {/*
        The one line at the top: what this item can reach on this machine. It is
        the same sentence the row wears, from the same table, because three
        spellings of one fact is how somebody learns the words do not mean
        anything.
      */}
      <p className="cs-sheet-tier" data-tier={item.tier}>
        {tierWord(item)}
        <HoverNote label={tierWord(item)}>{TIER_NOTES[item.tier]}</HoverNote>
      </p>

      <dl className="cs-sheet-facts">
        <div>
          <dt>Lands in</dt>
          <dd>
            {item.lands.length === 0 ? (
              /*
                Not a shrug. The installer computes this list and hands it over;
                an empty one means this build's main half could not say, and the
                honest line is that rather than a folder guessed at from the id.
                The Install button is drawn all the same — refusing to install
                over a missing disclosure would be a dead control where the
                sentence is the thing that is missing, not the capability.
              */
              <span className="cs-quiet">This build could not name the folders.</span>
            ) : (
              <ul className="cs-sheet-paths">
                {item.lands.map((path) => (
                  <li key={path}>
                    <code>{path}</code>
                  </li>
                ))}
              </ul>
            )}
          </dd>
        </div>

        <div>
          <dt>Read by</dt>
          <dd>
            <ul className="cs-sheet-agents">
              {MANIFEST_AGENTS.map((id) => {
                const found = presence.get(id)
                const name = found?.name ?? AGENT_CATALOG[id].label
                const here = found?.found === true
                const listed = item.agents.includes(id)
                return (
                  <li key={id}>
                    {here ? (
                      <label className="cs-sheet-agent">
                        <input
                          type="checkbox"
                          checked={chosen.includes(id)}
                          onChange={(event) => toggle(id, event.target.checked)}
                        />
                        {name}
                      </label>
                    ) : (
                      /*
                        No checkbox at all, rather than one that is ticked and
                        cannot be pressed. The name still appears, because the
                        list of three is the promise; what is missing is the
                        control, and a control that cannot act is absent.
                      */
                      <span className="cs-sheet-agent cs-quiet">{name}</span>
                    )}
                    {!here && <span className="cs-sheet-aside">not on this machine</span>}
                    {here && !listed && (
                      <span className="cs-sheet-aside">the publisher did not test this one</span>
                    )}
                    {/*
                      One short line, and only where the answer is genuinely
                      unusual. The sentence is written once, in the main process,
                      beside the code that makes it true — a second copy here is
                      a second copy that can be right about a build that shipped
                      last month.
                    */}
                    {here && found !== undefined && found.note !== '' && (
                      <span className="cs-sheet-aside">{found.note}</span>
                    )}
                  </li>
                )
              })}
            </ul>
          </dd>
        </div>

        <div>
          <dt>Needs</dt>
          <dd>
            {item.needs.length === 0 ? (
              'Nothing you do not already have.'
            ) : (
              <ul className="cs-sheet-needs">
                {item.needs.map((need) => (
                  <li key={need} data-missing={item.missing.includes(need) || undefined}>
                    {NEED_WORDS[need as StoreNeed] ?? need}
                    {item.missing.includes(need) && (
                      <span className="cs-sheet-aside">not found here</span>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </dd>
        </div>

        {/*
          Per-kind, and each of them is a fact the four rows above cannot carry.

          The command is the important one: a community item can never supply a
          command string — the app's own compiled code composes it from a runtime
          and a package name — and printing the result is what makes that
          checkable by the person it protects rather than only by a reviewer.
        */}
        {item.kind === 'mcp' && item.command !== '' && (
          <div>
            <dt>Runs</dt>
            <dd>
              <code>{item.command}</code>
            </dd>
          </div>
        )}
        {item.kind === 'mcp' && item.variables.length > 0 && (
          <div>
            <dt>Wants</dt>
            <dd>
              <code>{item.variables.join(', ')}</code>
            </dd>
          </div>
        )}
        {item.kind === 'routine' && item.trigger !== '' && (
          <div>
            <dt>Trigger</dt>
            <dd>
              {item.trigger} <span className="cs-sheet-aside">arrives switched off</span>
            </dd>
          </div>
        )}
        {item.kind === 'extension' && item.reach.length > 0 && (
          <div>
            <dt>Reaches</dt>
            <dd>
              <code>{item.reach.join(', ')}</code>
            </dd>
          </div>
        )}

        <div>
          <dt>Not ours</dt>
          {/*
            The one sentence this app owes anybody pressing Install on somebody
            else's work, and it is deliberately the last thing read before the
            button.
          */}
          <dd>Terminal Deck did not write this and has not run it.</dd>
        </div>
      </dl>
    </div>
  )
}

/* -------------------------------------------------------------- the dialog -- */

export interface InstallSheetProps extends InstallSheetBodyProps {
  open: boolean
  /** Something is in flight for this item, so the confirm says so. */
  busy: boolean
  onClose(): void
  onConfirm(): void
}

/**
 * The confirm's own words.
 *
 * At tier 3 it names the publisher — *Install from @acme* — because that is the
 * decision being made: a program on this machine, on a stranger's word. At tier
 * 1 and 2 it is Install, because dressing every button in the same warning is
 * how a warning stops being read.
 */
export function confirmLabel(item: CommunityItem, busy: boolean): string {
  if (busy) return 'Installing…'
  return item.tier === 3 ? `Install from @${item.handle}` : 'Install'
}

export function InstallSheet({
  open,
  item,
  agents,
  chosen,
  busy,
  onChoose,
  onClose,
  onConfirm,
}: InstallSheetProps) {
  return (
    <Modal
      open={open}
      title={item.name}
      onClose={onClose}
      footer={
        <>
          <button type="button" className="modal-btn" disabled={busy} onClick={onClose}>
            Cancel
          </button>
          {/*
            Only when there is something to install. An off-site listing never
            reaches this sheet — its row has no Install to open one — and this is
            the second half of that rule rather than a duplicate of it: a dialog
            that could be opened some other way must not grow a button the row
            deliberately refused to draw.
          */}
          {installable(item) && (
            <button
              type="button"
              className="modal-btn primary"
              disabled={busy}
              onClick={onConfirm}
            >
              {confirmLabel(item, busy)}
            </button>
          )}
        </>
      }
    >
      <InstallSheetBody item={item} agents={agents} chosen={chosen} onChoose={onChoose} />
    </Modal>
  )
}
