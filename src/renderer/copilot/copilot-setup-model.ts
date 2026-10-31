import { copilotName, type CopilotIdentity } from '../../shared/copilot-identity'

/**
 * The four screens of the setup flow, and what each of them is allowed to
 * claim — kept away from the component so the order, the wording and the
 * skipping can be tested without a DOM.
 *
 * ## What was asked for
 *
 * Asad, 2026-08-17: *"Maybe we can give a few steps flow before someone sets up
 * the copilot. It can ask, what would you call your copilot, give it a name —
 * related to identity setup… So it will ask those questions in the flow, and the
 * copilot will always know about this and act that way always."*
 *
 * Four questions and then Start. They are in the order somebody cares about
 * them rather than the order the app stores them in: the name first, because it
 * is the one that will be said out loud a hundred times a day, and the account
 * last, because it is the one most people will never change.
 *
 * ## There were five, and the fifth was a summary
 *
 * Asad, 2026-08-17: *"This is what it will be — this whole card is not required.
 * Let's remove this card overall. Just Start."* So the array below is four long,
 * the last question's button is the one that acts, and `advanceLabel` names it
 * after what it produces. Nothing else in this file changed shape: the dots, the
 * Back button and the counter all read the array, which is why removing a screen
 * was a one-line edit rather than four places to keep in step.
 *
 * ## Every question is skippable, and skipping is an answer
 *
 * Not "optional" in the sense of a field left blank — each skip writes something
 * true. A skipped name writes *"they have not named you; do not pick one for
 * yourself"* into the copilot's own instructions, which is a better outcome than
 * an agent that invents one. `shared/copilot-identity.ts` carries that argument
 * and the text.
 *
 * The two that are not identity at all — the folder and the account — are
 * skippable in a different sense, because they already have answers: a folder
 * this app made, and whichever account the person's own defaults resolve to.
 * Skipping those steps changes nothing, which is why they are the two that can
 * be answered by doing nothing.
 *
 * ## Nothing is written until the last screen
 *
 * With one deliberate exception: the folder picker is a native panel wired to a
 * channel that stores the choice as soon as it is made, and re-plumbing that so
 * this flow could hold it in memory would mean a second way to change the
 * folder. So the folder screen shows the path the copilot *will* start in rather
 * than a promise about one, and closing the flow after picking one leaves that
 * choice in place. Everything else — the name, what it calls you, the account —
 * is held in the component and applied once, on the last button.
 */

/* ---------------------------------------------------------------- steps -- */

export type SetupStep = 'name' | 'you' | 'folder' | 'account'

/**
 * The order, spelled once.
 *
 * Both the progress dots and the Back/Continue buttons read this array, so a
 * step inserted here appears in the flow and in the counter together — the two
 * cannot come to disagree about how many screens there are, which is the
 * failure a hand-written "Step 3 of 4" always eventually ships.
 */
export const SETUP_STEPS: readonly SetupStep[] = ['name', 'you', 'folder', 'account']

/** The heading over each screen. Short — the question itself does the talking. */
export const STEP_TITLE: Record<SetupStep, string> = {
  name: 'What should it be called?',
  you: 'What should it call you?',
  folder: 'Where should it work?',
  account: 'Which account should it run as?',
}

export function stepIndex(step: SetupStep): number {
  const at = SETUP_STEPS.indexOf(step)
  // An unknown step is treated as the first one rather than as -1: every caller
  // uses this to index a dots row and to decide whether Back exists, and a
  // negative index there draws a flow that has gone backwards past its start.
  return at === -1 ? 0 : at
}

export function nextStep(step: SetupStep): SetupStep {
  const at = stepIndex(step)
  return SETUP_STEPS[Math.min(at + 1, SETUP_STEPS.length - 1)]
}

export function prevStep(step: SetupStep): SetupStep {
  const at = stepIndex(step)
  return SETUP_STEPS[Math.max(at - 1, 0)]
}

/** True on the last screen — the one whose button starts the copilot. */
export function isLastStep(step: SetupStep): boolean {
  return stepIndex(step) === SETUP_STEPS.length - 1
}

/**
 * What the button that moves on says.
 *
 * "Skip" and "Continue" are the same button in two states rather than two
 * buttons, because a screen with both reads as though skipping were the unusual
 * choice — and on a flow where every question is genuinely optional, that would
 * be the interface arguing with the design. The word changes the moment there is
 * something to keep.
 */
export function advanceLabel(
  step: SetupStep,
  answered: boolean,
  identity: CopilotIdentity,
  running = false,
): string {
  // The last screen's button is the one that acts, so it is named after what it
  // will produce — see {@link startLabel}. On a re-run against a copilot that is
  // already up it produces a saved file and nothing else, and says so: a session
  // is handed its instructions at `exec` and this app cannot re-hand them.
  if (isLastStep(step)) return running ? 'Save' : startLabel(identity)
  return answered ? 'Continue' : 'Skip'
}

/**
 * Why a re-run does not change the copilot on screen.
 *
 * The same fact `FOLDER_NEEDS_A_RESTART` states about the working directory, for
 * the same mechanical reason: what a session is told is fixed when it spawns.
 * This app has already had to be stopped three times from describing something
 * it does not do — `copilot-home.ts` keeps the list — so the flow says it rather
 * than letting somebody rename their copilot and wonder why it still answers to
 * the old name.
 */
export const RENAME_TAKES_A_RESTART =
  'It is running now. A session is handed its instructions when it starts, so this applies the ' +
  'next time it starts — nothing about the conversation on screen changes.'

/**
 * What the last button says, and what the sentence under it promises.
 *
 * Named after the copilot when it has a name, because that is the first time the
 * name is used for real and it is worth the person seeing it work before they
 * commit to it.
 */
export function startLabel(identity: CopilotIdentity): string {
  return `Start ${copilotName(identity)}`
}
