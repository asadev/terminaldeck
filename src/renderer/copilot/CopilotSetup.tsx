import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Modal } from '../components/Modal'
import { HoverNote } from '../components/HoverNote'
import {
  accountLabel,
  accountsBridge,
  profileLoginLabel,
  useAccounts,
  type AccountView,
} from '../accounts'
import { projectDefaultFor } from '../components/ProfilePicker'
import { CHOOSING_A_FOLDER, FOLDER_NEEDS_A_RESTART } from '../../shared/copilot-text'
import {
  cleanIdentity,
  DEFAULT_COPILOT_NAME,
  MAX_ADDRESS_NOTE,
  MAX_CALL_THEM,
  MAX_COPILOT_NAME,
  readCopilotIdentity,
  withCopilotIdentity,
  type CopilotIdentity,
} from '../../shared/copilot-identity'
import {
  resolveCopilotBridge,
  toCopilotFolder,
  toFolderChange,
  toInstructionsRead,
  toInstructionsWrite,
  type CopilotBridge,
  type CopilotFolder,
} from '../settings/sections/copilot-bridge'
import {
  advanceLabel,
  isLastStep,
  nextStep,
  prevStep,
  RENAME_TAKES_A_RESTART,
  SETUP_STEPS,
  stepIndex,
  STEP_TITLE,
  type SetupStep,
} from './copilot-setup-model'
import './CopilotSetup.css'

/**
 * The few steps before somebody's copilot runs for the first time.
 *
 * Asad, 2026-08-17: *"Maybe we can give a few steps flow before someone sets up
 * the copilot. It can ask, what would you call your copilot, give it a name —
 * related to identity setup. And keep it in-app, actually, yes in app. So it
 * will ask those questions in the flow, and the copilot will always know about
 * this and act that way always."*
 *
 * Four questions and then Start. What makes it worth a dialog rather than a
 * settings pane is the moment it happens in: it is the *first* thing, before a
 * CLI has been spawned, before anything has been billed, and before an agent has
 * introduced itself under a name nobody chose.
 *
 * ## There is no summary screen, and there used to be
 *
 * A fifth screen listed every answer back, including the skipped ones, and then
 * printed the literal text the copilot would be handed. It was defensible — it
 * was built to answer *"show what it is about to become before it starts"* — and
 * he removed it on sight:
 *
 *   > *"This is what it will be — this whole card is not required. Let's remove
 *   > this card overall. Just Start."*
 *
 * The reasoning holds up. Every answer on that card was one Back press away, on
 * the screen that asked for it, still filled in. And the card's real content —
 * the composed instruction text — is not a thing to read on the way past; it is
 * a thing to read in Settings → Copilot, in an editor, where it can also be
 * changed. So the last question's button is the one that acts, and it is named
 * after what it produces.
 *
 * The screen's honest half survives in the model: `startLabel` still names the
 * copilot, and `advanceLabel` still says **Save** rather than Start when one is
 * already running, because a session is handed its instructions at `exec` and
 * this app cannot re-hand them.
 *
 * ## It writes into the layer, and nowhere else
 *
 * The answers go into `<userData>/copilot-layer/instructions.md` — the person's
 * half of the file the copilot is handed at spawn — through
 * `copilot:write-instructions`, the same channel the editor in Settings →
 * Copilot saves with. There is no second store and no `copilot.name` setting:
 * `shared/copilot-identity.ts` carries that argument, and the important half of
 * it is that **nothing is ever written into the copilot's working directory**,
 * because that folder can be the person's own and identity on their disk is
 * identity inherited by every ordinary terminal they open there.
 *
 * The other two answers are not identity and already have homes of their own,
 * which this flow reuses rather than duplicates: the folder is
 * `copilot:folder:pick` (a native panel, and the setting it writes), and the
 * account is `profiles:set-project-default` against the copilot's folder — the
 * same pin the New-session dialog sets, resolved by the same `resolveProfile`
 * every session goes through.
 *
 * ## Nothing is written until the last button
 *
 * With one exception, and the folder screen shows it rather than claiming
 * otherwise: the folder picker is a native panel whose channel stores the choice
 * as it is made, so the path on that screen is where the copilot *will* work,
 * and closing the flow after choosing a folder leaves that choice in place.
 * Every other answer is held in this component and applied once.
 *
 * Closing without finishing writes nothing at all, which is what makes the flow
 * safe to dismiss: the copilot does not start, and the next time it is asked for
 * the same questions come back.
 *
 * ## Re-runnable, and the same bytes either way
 *
 * Mounted twice — once by `App.tsx`, in front of the first start, and once by
 * Settings → Copilot behind "Set it up again". Two mounts of one component
 * rather than a flow with a mode, because they differ only in what happens
 * afterwards: the first opens the copilot, the second re-reads the pane.
 */

interface Props {
  open: boolean
  /** Dismissed. Nothing has been written; the flow will be offered again. */
  onClose(): void
  /**
   * The answers are on disk. `App.tsx` starts the copilot and opens its window;
   * Settings re-reads the pane.
   */
  onDone(identity: CopilotIdentity): void
  /** Injectable for tests and the harness; defaults to the preload bridge. */
  bridge?: Partial<CopilotBridge>
}

export function CopilotSetup({ open, onClose, onDone, bridge: injected }: Props) {
  const bridge = useMemo(() => injected ?? resolveCopilotBridge(), [injected])

  const [step, setStep] = useState<SetupStep>('name')
  const [name, setName] = useState('')
  const [callThem, setCallThem] = useState('')
  const [addressNote, setAddressNote] = useState('')
  const [folder, setFolder] = useState<CopilotFolder | null>(null)
  const [accountId, setAccountId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  /** True while a native folder panel is up — see `Modal`'s `hidden`. */
  const [picking, setPicking] = useState(false)

  /*
   * The account list, without asking the CLI which of them are signed in.
   *
   * `probe: false` is the whole reason this call is shaped this way: checking a
   * sign-in spawns the agent's CLI once per account, and a setup flow that
   * started three processes because a dialog opened would be spending somebody's
   * machine on a caption. Any answers another screen has already paid for are
   * still used — `useAccounts` shares them through the store in `accounts.ts`.
   */
  const accounts = useAccounts(open, false)

  const identity = useMemo(
    () => cleanIdentity({ name, callThem, addressNote }),
    [name, callThem, addressNote],
  )

  /*
   * Everything that has to be true before the first screen is drawn.
   *
   * Two reads, both cheap, both idempotent, and neither of them writes: where it
   * will work, and what it has been told about itself already. The second is
   * what makes this re-runnable rather than a one-shot — running it again on a
   * copilot called Nova puts "Nova" in the box, so a person renaming it is
   * editing rather than retyping.
   */
  const loaded = useRef(false)
  useEffect(() => {
    if (!open) {
      loaded.current = false
      return
    }
    if (loaded.current) return
    loaded.current = true

    setStep('name')
    setProblem(null)
    /*
     * Cleared, and this is not tidiness — it was a bug found by running the flow
     * twice.
     *
     * The dialog stays mounted while it is closed, so an account picked in one
     * run was still selected in the next: the review screen named an account
     * nobody had chosen *this* time, and finishing would have pinned it to the
     * folder again. Skipping this screen has to mean leaving the person's own
     * defaults alone, which it cannot mean while a stale selection survives.
     *
     * The two text answers are the opposite case and are re-read below rather
     * than cleared: they are what the copilot is called *now*, so a re-run opens
     * with them in the boxes and a rename is an edit rather than a retype.
     */
    setAccountId(null)

    if (bridge.copilotFolder) {
      void bridge.copilotFolder().then(
        (raw) => setFolder(toCopilotFolder(raw)),
        () => setFolder(null),
      )
    }
    if (bridge.copilotReadInstructions) {
      void bridge.copilotReadInstructions().then(
        (raw) => {
          const result = toInstructionsRead(raw)
          if (!result.ok) return
          const { identity: current } = readCopilotIdentity(result.text)
          setName(current.name ?? '')
          setCallThem(current.callThem ?? '')
          setAddressNote(current.addressNote ?? '')
        },
        () => {
          // No file yet is the ordinary first run, and there is nothing to
          // prefill from. The boxes stay empty, which is the truth.
        },
      )
    }
  }, [open, bridge])

  /**
   * The accounts worth offering: the ones the copilot could actually run as.
   *
   * Claude's, because that is what the copilot runs on — `copilot-session.ts`
   * refuses to start without it — and any account from a build that predates
   * accounts carrying a provider, which were all Claude accounts. Offering a
   * Codex login here would be offering a session that cannot start.
   */
  const claudeAccounts = useMemo(
    () =>
      accounts.snapshot.accounts.filter(
        (account) => account.provider === 'claude' || account.provider === null,
      ),
    [accounts.snapshot.accounts],
  )
  const chosenAccount = useMemo(
    () => claudeAccounts.find((account) => account.id === accountId) ?? null,
    [claudeAccounts, accountId],
  )

  /**
   * Which account it would use if nobody touched this screen.
   *
   * Resolved out of the snapshot the list is already drawn from — a pin on the
   * copilot's own folder if there is one, otherwise the global default,
   * otherwise the person's own install — so the row that says "in use now"
   * cannot disagree with the rows beside it. It is deliberately **not**
   * preselected: selecting it would turn "whatever my default is" into a pin on
   * this folder, which is a different setting that stops following a later
   * change of default. Skipping has to mean leaving things alone.
   */
  const currentAccountId = useMemo(() => {
    const pinned = projectDefaultFor(accounts.snapshot.projectDefaults, folder?.home ?? null)
    return pinned ?? accounts.snapshot.defaultId
  }, [accounts.snapshot, folder])

  /**
   * What one of those rows is called, without naming the agent.
   *
   * The list above is already one agent's — that is what `claudeAccounts` is —
   * so the agent's name distinguishes nothing here, and printing it would put a
   * vendor's product name on a pop-up, which is the sentence the review drew
   * widest:
   *
   *   > *"You should not mention in any settings or any pop-up a specific tool
   *   > or LLM, because they can use some other also."*
   *
   * Settings → Accounts keeps the name and should: that list holds every
   * agent's logins side by side, and there the name is the only thing telling
   * three otherwise identical rows apart. The argument for both halves is
   * written on `profileLoginLabel` itself, next to the flag.
   */
  const label = useCallback(
    (account: AccountView): string =>
      profileLoginLabel(
        { id: account.id, name: account.name, provider: account.provider, system: account.system },
        accounts.signIn[account.id],
        { namesTheAgent: false },
      ),
    [accounts.signIn],
  )

  /** The native panel, with the dialog stepped aside while it is up. */
  const pickFolder = useCallback(() => {
    if (!bridge.copilotPickFolder) return
    setPicking(true)
    setProblem(null)
    void bridge
      .copilotPickFolder()
      .then(
        (raw) => {
          const change = toFolderChange(raw)
          if (change.problem !== null) setProblem(change.problem)
          if (change.folder !== null) setFolder(change.folder)
        },
        () => setProblem('The folder could not be changed.'),
      )
      .finally(() => setPicking(false))
  }, [bridge])

  const useAppFolder = useCallback(() => {
    if (!bridge.copilotClearFolder) return
    setProblem(null)
    void bridge.copilotClearFolder().then(
      (raw) => {
        const change = toFolderChange(raw)
        if (change.folder !== null) setFolder(change.folder)
      },
      () => setProblem('That did not work.'),
    )
  }, [bridge])

  /**
   * Write the answers, then hand back.
   *
   * The order matters and is the order a failure should stop at. The identity
   * goes in first, because it is the answer this flow exists for and the only
   * one that has no other way in; the account pin second, because it is a
   * refinement of a choice that already has a working default. A failure to
   * write the identity therefore never leaves an account pinned for a copilot
   * whose name was not saved.
   */
  const finish = useCallback(() => {
    setBusy(true)
    setProblem(null)

    const readInstructions = async (): Promise<string | null> => {
      if (!bridge.copilotReadInstructions) return null
      const first = toInstructionsRead(await bridge.copilotReadInstructions())
      if (first.ok) return first.text
      /*
       * No file yet — the ordinary first run. Scaffolding writes this build's
       * default instructions (and the folder), which is exactly what the
       * "Create its files" button in Settings does, and then the answers are
       * spliced into that rather than into nothing. Composing a file here
       * instead would put a renderer in charge of what the copilot is told.
       */
      if (!bridge.copilotScaffold) return null
      await bridge.copilotScaffold()
      const second = toInstructionsRead(await bridge.copilotReadInstructions())
      return second.ok ? second.text : null
    }

    void readInstructions()
      .then(async (text) => {
        if (text === null || !bridge.copilotWriteInstructions) {
          setProblem(
            'Its instructions could not be read, so nothing was saved. Settings → Copilot has the file itself.',
          )
          return
        }
        const write = toInstructionsWrite(
          await bridge.copilotWriteInstructions(withCopilotIdentity(text, identity)),
        )
        if (!write.saved || write.error !== null) {
          setProblem(write.error ?? 'Its instructions could not be saved.')
          return
        }
        if (chosenAccount !== null && folder !== null) {
          try {
            /*
             * The same pin the New-session dialog sets, against the copilot's
             * own folder: `resolveProfile` reads a per-project default before
             * the global one, and `copilot-session.ts` resolves the copilot's
             * account with the copilot's folder as the project path. So this is
             * not a copilot-shaped account mechanism — it is the one the app
             * already has, addressed at the one folder that is the copilot's.
             */
            const pin = accountsBridge()?.setProjectDefaultProfile
            if (!pin) throw new Error('no channel')
            await pin(folder.home, chosenAccount.id)
          } catch {
            /*
             * The name is saved and the account is not. Said out loud rather
             * than swallowed, and the flow still finishes: an account pin has a
             * working default behind it and a second home in Settings →
             * Accounts, so refusing to start over it would be the worse trade.
             */
            setProblem(
              'Its name is saved. The account could not be pinned to its folder — set it in Settings → Accounts.',
            )
          }
        }
        onDone(identity)
      })
      .catch(() => setProblem('Nothing was saved — that did not work.'))
      .finally(() => setBusy(false))
  }, [bridge, identity, chosenAccount, folder, onDone])

  /** Whether the screen on show has an answer on it. Decides Skip vs Continue. */
  const answered =
    step === 'name'
      ? identity.name !== null
      : step === 'you'
        ? identity.callThem !== null || identity.addressNote !== null
        : step === 'folder'
          ? folder !== null && !folder.isDefault
          : step === 'account'
            ? chosenAccount !== null
            : true

  /*
   * Whether there is a copilot up right now.
   *
   * `runningIn` rather than a second call to `copilot:state`: the folder report
   * already carries the folder the *running* copilot started in, and it is null
   * when nothing is running. One read, one answer — a second channel answering
   * the same question is a second answer that can differ from the first.
   */
  const running = (folder?.runningIn ?? null) !== null

  const at = stepIndex(step)

  return (
    <Modal
      open={open}
      hidden={picking}
      size="lg"
      title="Set up your copilot"
      /*
       * No description line, and its absence is the instruction rather than an
       * oversight.
       *
       * Asad, 2026-08-17: *"We don't need to keep three different descriptions…
       * nobody needs to know that there are four questions and they are
       * skippable. There is a clear skip button so we don't need to give this
       * explanation."* It said the same thing on all four screens, over the top
       * of the question the screen was actually asking, and the button under it
       * already says Skip. `Modal` drops `aria-describedby` with it, so nothing
       * is left pointing at an element that is gone.
       */
      onClose={onClose}
      footer={
        <>
          <span className="cs-steps" aria-label={`Step ${at + 1} of ${SETUP_STEPS.length}`}>
            {SETUP_STEPS.map((each, index) => (
              <span
                key={each}
                className="cs-dot"
                data-state={index === at ? 'here' : index < at ? 'done' : 'ahead'}
                aria-hidden="true"
              />
            ))}
          </span>
          <button
            type="button"
            className="modal-btn"
            disabled={at === 0 || busy}
            onClick={() => setStep(prevStep(step))}
          >
            Back
          </button>
          <button
            type="button"
            className="modal-btn primary"
            disabled={busy}
            onClick={() => (isLastStep(step) ? finish() : setStep(nextStep(step)))}
          >
            {busy ? 'Saving…' : advanceLabel(step, answered, identity, running)}
          </button>
        </>
      }
    >
      <div className="cs">
        <h3 className="cs-question">{STEP_TITLE[step]}</h3>

        {step === 'name' && (
          <>
            {/*
              One sentence, and it is the one he read back twice — *"You will
              talk to it every day so it's worth a name… this much is enough."*

              What came off is the clause naming the three places the name
              appears and the paragraph under the box explaining what a skipped
              name writes. Both were true. Neither was needed to answer the
              question on screen, and together they turned a one-line question
              into a paragraph and a footnote — which is the shape he asked to
              stop seeing. The skipped-name behaviour is unchanged and still
              stated where it can be read: `copilot-identity.ts` writes it into
              the file, and Settings → Copilot says it on the row.
            */}
            <p className="cs-says">You will talk to it every day, so it is worth a name.</p>
            <label className="cs-field">
              <span className="cs-label">Its name</span>
              <input
                className="cs-input"
                type="text"
                value={name}
                maxLength={MAX_COPILOT_NAME}
                placeholder={DEFAULT_COPILOT_NAME}
                onChange={(event) => setName(event.target.value)}
                autoFocus
              />
            </label>
          </>
        )}

        {step === 'you' && (
          <>
            {/*
              The two halves he kept: what it should call you, and the fact that
              the answer goes into the copilot's own instructions. The sentence
              about writing more of it under Settings → Copilot came off with the
              rest of the scaffolding.
            */}
            <p className="cs-says">It goes into its own instructions, so it reads it before it says a word.</p>
            <label className="cs-field">
              <span className="cs-label">It calls you</span>
              <input
                className="cs-input"
                type="text"
                value={callThem}
                maxLength={MAX_CALL_THEM}
                placeholder="your name"
                onChange={(event) => setCallThem(event.target.value)}
                autoFocus
              />
            </label>
            <label className="cs-field">
              {/*
                The word `optional`, beside the label, because this is the field
                people stop at.

                Asad, 2026-08-17: *"'How you want to be spoken to' is confusing
                and stalls people — mark it optional, visibly, next to the
                field."* Every question in this flow is skippable, but skipping
                is a whole-screen act done with the button in the corner, and
                somebody who wants the *first* box and not the second has no way
                to express that except by leaving it blank and hoping. This is
                that permission, in the one place they are looking.

                A span rather than a "(optional)" inside the label string so the
                two are styled apart — the label stays the label, and the tag is
                quiet enough not to compete with the field above it that has no
                tag and therefore reads as the one that matters.
              */}
              <span className="cs-label">
                How you want to be spoken to
                <span className="cs-optional">optional</span>
              </span>
              <input
                className="cs-input"
                type="text"
                value={addressNote}
                maxLength={MAX_ADDRESS_NOTE}
                placeholder="short answers, no preamble"
                onChange={(event) => setAddressNote(event.target.value)}
              />
            </label>
          </>
        )}

        {step === 'folder' && (
          <>
            {/*
              This step used to spell out a filename — "that folder's own
              CLAUDE.md, its memory, its notes" — and the trimming pass took the
              whole clause out, which settles the naming question here by
              deletion. The rule it was breaking is still worth recording where
              somebody would come looking to add it back: which file an agent
              reads out of a folder is that agent's business, the CLIs this build
              can run each look for a different one, and naming one of them makes
              a sentence that only holds for a third of the people reading it —
              on the one screen where somebody is deciding what to hand over.

              `CHOOSING_A_FOLDER`, behind the dot below, says the same thing the
              neutral way: "the folder's own instructions and memory".
            */}
            <p className="cs-says">
              Point it at a folder you already keep an assistant in and it picks up whatever is
              there.
              {/*
                What choosing a folder costs, moved behind the dot rather than
                dropped.

                It is the one paragraph on this screen that is a *warning* — a
                folder may hold credentials, and that is a thing to be chosen
                rather than discovered — so it could not simply come off with the
                rest of the trimming. It is one hover away instead, and it is the
                same string it always was.

                This is now the *only* place it is shown. The native panel used
                to carry it as its `message`, and that is what made the panel
                tall enough to lose its own buttons off the bottom of the sheet
                it was clipped to — see the note on `pick` in `main/index.ts`.
                A warning read while deciding beats one read mid-decision.
              */}
              <HoverNote label="the folder">{CHOOSING_A_FOLDER}</HoverNote>
            </p>
            <div className="cs-folder">
              <code className="cs-path">{folder?.home ?? '—'}</code>
              <span className="cs-whose">{folder?.isDefault === false ? 'yours' : 'this app’s'}</span>
            </div>
            <div className="cs-row">
              <button
                type="button"
                className="modal-btn"
                disabled={!bridge.copilotPickFolder || busy}
                onClick={pickFolder}
              >
                Choose a folder…
              </button>
              {folder !== null && !folder.isDefault && (
                <button
                  type="button"
                  className="modal-btn"
                  disabled={!bridge.copilotClearFolder || busy}
                  onClick={useAppFolder}
                >
                  Use this app’s folder
                </button>
              )}
            </div>
            {/* Kept, because it is not scaffolding: it only appears when the
                copilot is already running somewhere else, and it is the answer
                to "I changed it and nothing happened". */}
            {folder?.restartNeeded === true && (
              <p className="cs-quiet">{FOLDER_NEEDS_A_RESTART}</p>
            )}
          </>
        )}

        {step === 'account' && (
          <>
            <p className="cs-says">
              It runs as one of your accounts. Leave this and it uses whatever your defaults
              already resolve to.
              <HoverNote label="the account">
                The copilot has no login of its own — it runs as one of your accounts, exactly like
                any other session, and choosing one here pins it to the copilot’s folder. That pin
                is the same one the New-session dialog sets, so it takes effect the next time the
                copilot starts and can be changed later under Settings → Accounts.
              </HoverNote>
            </p>
            {accounts.loading && <p className="cs-quiet">Reading your accounts…</p>}
            {!accounts.loading && claudeAccounts.length === 0 && (
              <p className="cs-quiet">
                No accounts to choose from yet. Settings → Accounts is where they are added, and the
                copilot will use your own install until then.
              </p>
            )}
            <ul className="cs-accounts">
              {claudeAccounts.map((account) => (
                <li key={account.id}>
                  <label className="cs-choice" data-selected={account.id === accountId}>
                    <input
                      type="radio"
                      name="copilot-account"
                      checked={account.id === accountId}
                      onChange={() => setAccountId(account.id)}
                    />
                    <span className="cs-mark" aria-hidden="true" />
                    <span className="cs-choice-main">
                      <span className="cs-choice-name">{label(account)}</span>
                      <span className="cs-choice-note">
                        {[
                          /*
                            Only when the name above has not already said it.
                            With no address to print, the name *is* "Your own
                            install", and this line eight pixels below it would
                            be the same sentence twice — the duplication
                            `AccountsSection` refuses for the same reason, and
                            one the neutral label made possible here by removing
                            the agent's name that used to tell them apart.
                          */
                          account.system && accountLabel(accounts.signIn[account.id]) !== null
                            ? 'your own install'
                            : null,
                          // Which one it is already using, so skipping this
                          // screen is a decision somebody can make rather than
                          // a blank they are guessing about.
                          account.id === currentAccountId ||
                          (currentAccountId === null && account.system)
                            ? 'in use now'
                            : null,
                        ]
                          .filter((part) => part !== null)
                          .join(' · ')}
                      </span>
                    </span>
                  </label>
                </li>
              ))}
            </ul>
            {accountId !== null && (
              <button type="button" className="cs-link" onClick={() => setAccountId(null)}>
                Leave it to my defaults
              </button>
            )}
            {/*
              The one sentence the deleted summary card was carrying that had
              nowhere else to go, shown only in the state that makes it true.

              A session is handed its instructions at `exec`, so answering these
              questions again against a copilot that is already up changes the
              file and not the conversation on screen. The button beside this
              already says **Save** rather than Start for the same reason; this
              is why. On a first run — which is every run that matters — nothing
              is running and this line does not exist.
            */}
            {running && <p className="cs-quiet">{RENAME_TAKES_A_RESTART}</p>}
          </>
        )}

        {problem !== null && <p className="cs-problem">{problem}</p>}
      </div>
    </Modal>
  )
}
