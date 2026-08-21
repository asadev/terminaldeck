/**
 * Whether a saved password may be typed into a page *by itself*.
 *
 * ## The rule, in one sentence
 *
 * **Autofill is a person's action.** A page an agent navigated to is never
 * filled on its own, and there is no call an agent can make that causes a
 * credential to be typed into it.
 *
 * ## Why this is a module and not two lines in `browser-tab.ts`
 *
 * Because it is the piece standing between somebody's bank password and a
 * transcript, and an effect is the one place a rule cannot be tested — the same
 * split `browser-drive.ts` was pulled out of `browser-driver.ts` for, and
 * `shouldComposite` out of the renderer. Everything here is a pure function
 * over plain booleans; `browser-tab.ts` reads the facts off the live page and
 * calls in.
 *
 * ## What this closes
 *
 * `browser-passwords.ts` keeps a password out of the renderer, out of any tool
 * and off every list an agent can read. None of that helps if the agent can
 * simply *ask the page to be filled* and then read the page. Concretely, before
 * this existed:
 *
 *  1. A session calls `browser.open https://github.com/login` on a window the
 *     person attached.
 *  2. The guest preload sees a password field and announces it.
 *  3. The main process finds a saved login for `https://github.com` and fills
 *     it in — username and password, into the page the agent chose.
 *  4. `browser.step` presses Sign in.
 *
 * At no point does the agent see the password, and at no point does it need to:
 * it is signed in as the person on a site it named. That is the same action
 * `session-tools.ts` refuses to build a `browser.lift` for, arrived at from the
 * other end. The refusal has to be in both places or it is in neither.
 *
 * ## How "an agent is holding this page" is known
 *
 * By the **CDP debugger being attached to it**, which is not a proxy for the
 * fact — it *is* the fact. `browser-driver.ts:attach` is the only line in this
 * repository that calls `wc.debugger.attach`, the drive holds the attachment
 * for the whole of a drive rather than per command, and `detach` releases it.
 * So there is no second piece of state to keep in step and no way for a
 * registry to drift out of date behind a page that is still being driven.
 *
 * It is also the widest of the candidate signals, deliberately. It stays true
 * while the drive is parked in `human` — the state `browser.handover` puts it
 * in, where every command is refused and the person is being asked to sign in.
 * That is precisely the moment a credential is wanted, and precisely the moment
 * it must be the person who presses something rather than the page that gets
 * filled because an agent asked for a person.
 *
 * ## Why the document is stamped as well
 *
 * The debugger check alone has a seam a few seconds wide. The guest preload
 * looks for a sign-in form three times — at `DOMContentLoaded`, and again at
 * 700ms and 2200ms, because most sign-in forms are rendered after first paint.
 * A drive that navigated a page and then let go inside that window would leave
 * a page the *agent* chose, now with no debugger on it, about to be filled by
 * the third look.
 *
 * So the commit is stamped: a document that was committed while an agent held
 * the page is marked, and stays marked for as long as it is the document on
 * screen. A person navigating away clears it, because that is a new document
 * and their own.
 *
 * ## What replaces the fill, rather than what is left missing
 *
 * Nothing here refuses a person anything. When automatic fill is withheld the
 * page's own panel says a saved login exists for this site and offers it on one
 * press — `browser-password:fill`, an `ipcMain` channel reachable only from the
 * app's own renderer, which is the same door `browser-workers-ipc.ts` puts
 * session-lifting behind and for the same stated reason. The person gets their
 * password where they are already looking; the agent gets no path to it.
 */

/** Everything the decision is made from. All of it read live, none of it stored. */
export interface FillFacts {
  /**
   * Is the CDP debugger attached to this page right now?
   *
   * True for the whole of a drive, including while it is parked waiting for the
   * person in `human`. See the header for why that is the intended breadth.
   */
  agentHolding: boolean
  /**
   * Was the document currently on screen committed while an agent held it?
   *
   * Stamped by `browser-tab.ts` at `did-navigate`, cleared by any later
   * navigation that happens with no agent on the page.
   */
  documentFromAgent: boolean
  /**
   * Is this tab in a throwaway partition?
   *
   * An Isolated tab has no profile at all, so there is nothing to look up — but
   * it is worth answering with a sentence rather than falling out of a filter,
   * because "my password did not fill" with no explanation is the report this
   * whole round is about.
   */
  isolated: boolean
}

export type FillVerdict =
  | { fill: true }
  | {
      fill: false
      /** Named so the caller can decide what to *offer* instead. */
      reason: 'agent' | 'isolated'
      /** Shown to a person verbatim. Says what happened and what is still possible. */
      message: string
    }

/**
 * The sentence for a page an agent is driving, or navigated to.
 *
 * It says the three things somebody needs and no fourth: that this was a
 * decision rather than a failure, why, and that the password is still one press
 * away. "Blocked" on its own would read as a bug in the store.
 */
export const AGENT_HELD_MESSAGE =
  'An agent opened this page, so the saved login was not filled in automatically. Fill it yourself if you meant to sign in here.'

export const ISOLATED_MESSAGE =
  'This tab is Isolated, so it has no profile and no saved logins. Open the site in a normal tab to use one.'

/**
 * May this page be filled without anybody pressing anything?
 *
 * Ordered so the *narrower* answer wins: an Isolated tab has no store to read
 * at all, which is a different sentence from one that has a login and is
 * withholding it.
 */
export function mayAutofill(facts: FillFacts): FillVerdict {
  if (facts.isolated) return { fill: false, reason: 'isolated', message: ISOLATED_MESSAGE }
  if (facts.agentHolding || facts.documentFromAgent) {
    return { fill: false, reason: 'agent', message: AGENT_HELD_MESSAGE }
  }
  return { fill: true }
}

/**
 * What a freshly committed document inherits.
 *
 * A separate function from {@link mayAutofill} because it answers at a
 * different moment — the commit, not the offer — and because the interesting
 * case is the one that reads backwards: a navigation that happens while an
 * agent is on the page produces an agent's document *even if the person typed
 * the address*, since a driven page can be driven again the instant it lands.
 * There is no way to tell those apart at the commit and the safe direction is
 * the one that withholds and offers, which costs a person one press and costs
 * an agent everything.
 */
export function stampDocument(agentHolding: boolean): boolean {
  return agentHolding
}
