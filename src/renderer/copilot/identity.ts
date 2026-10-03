import { BRAND } from '../../shared/brand'

/**
 * What the assistant is called, in one place, because five surfaces say it.
 * What it is drawn as lives in `HootMark.tsx`.
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

/**
 * Its name on screen when nobody has given it one of their own: Hoot, from
 * `BRAND.assistant`, the one spelling. Nothing else may type it.
 */
export const COPILOT_NAME: string = BRAND.assistant

/*
 * There is no icon constant here any more. The compass rose that used to live
 * here was replaced on 2026-10-03 by the owl, a picture rather than a
 * path, and every surface draws it through one component: `HootMark.tsx`.
 */

/** One line about what it is for. The pinned row's hover label when nothing
    better is known, and the empty state's subtitle. */
export const COPILOT_BLURB = 'Your assistant for this deck — the sessions, the diffs, the prompts.'
