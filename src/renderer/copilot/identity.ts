/**
 * What the copilot is called and what it is drawn as — in one place, because
 * five surfaces now say it.
 *
 * ## Why this is not in `panels.ts` any more
 *
 * It was, and being there was the same claim as being a *view*: `PanelId` is the
 * set of places the window can travel to, `showPanel` takes one, `PanelView`
 * renders one, and `isPanelId` is what lets a remembered id fill the window at
 * the next launch. That was the right shape while the copilot was a page.
 *
 * It is not a page now. Asad, 2026-08-17:
 *
 *   > *"Give the copilot a full window like the other windows. It is not that
 *   > much of a big window, it is like a small box inside the copilot page. Let
 *   > it have a proper window like others — proper dropdowns on the top, like
 *   > changing the counts, efforts, models, all those things should be there,
 *   > exactly like the other sessions. It should have all of those things,
 *   > nothing should be less than that. And it can stay as a window pill with
 *   > the other windows."*
 *
 * The copilot has been a real session since the day it was designed — that was
 * the founding decision in `COPILOT-DESIGN.md`, made because it is what buys the
 * transcript, the account, the folder and the pty for free. What it did not have
 * was the *chrome* every other session gets: a pill in the strip, a name in the
 * bar, an account chip, and the model / effort / fast-mode / connectors /
 * usage cluster. It had a bespoke bar with two of those things spelled a second
 * way, on a page that squeezed its terminal into the middle third of the window.
 *
 * So it is a window, and the three facts below are what a window needs to be
 * named and drawn. They live here rather than in `panels.ts` because a member of
 * `PanelId` with no case in `PanelView` is a dead route by construction — that
 * file says so about `alerts`, in those words — and leaving the entry there
 * would have re-created the page the moment anybody wired `showPanel('copilot')`
 * again.
 */

/** The one spelling of its name. Nothing else may type it. */
export const COPILOT_NAME = 'Copilot'

/**
 * A compass rose — a ring with a needle through it.
 *
 * Chosen against the two marks it has to be told apart from at a glance in the
 * same rail and now in the same tab strip: the session's `>_` and the browser's
 * globe. Not a sparkle, which is what every product draws beside the word "AI"
 * and says nothing about what this one does, and not a speech bubble, which
 * would promise a chatbot when the whole argument of `COPILOT-DESIGN.md` is that
 * this is a window onto machinery.
 *
 * SVG path data on a 24×24 grid at 1.5 stroke, like every other glyph here.
 */
export const COPILOT_ICON =
  'M12 3.4a8.6 8.6 0 1 0 0 17.2 8.6 8.6 0 0 0 0-17.2zM15.2 8.8l-1.9 4.5-4.5 1.9 1.9-4.5z'

/** One line about what it is for. The pinned row's hover label when nothing
    better is known, and the empty state's subtitle. */
export const COPILOT_BLURB = 'Your assistant for this deck — the sessions, the diffs, the prompts.'
