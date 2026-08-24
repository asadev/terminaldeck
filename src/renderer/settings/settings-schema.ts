/**
 * Every setting the app stores, declared once.
 *
 * The settings window renders itself from this table: a row exists because a
 * setting is declared here, its control comes from `kind`, and its starting
 * value comes from `default`. Nothing in the UI knows a setting's name.
 *
 * That is the point. The dialog this replaces hand-wrote four rows and a
 * shortcut list, and the shortcut list had already drifted — a printed copy of
 * a fact is the copy that rots, because nothing fails when it lies. The same
 * argument `keymap.ts` makes for chords is made here for settings.
 *
 * ## Two files, one table
 *
 * `store.ts` already persists four preferences and is read by the main process
 * at spawn time (`defaultProvider`) and at launch (`restoreSessions`), so those
 * four keep living there — moving them would mean touching code other agents
 * hold. Every other setting goes to `settings.json` via `settings-extra.ts`.
 * Which file a setting lands in is declared per setting (`store`), and
 * `splitPatch` routes a write to the right side, so a caller never has to know.
 *
 * ## Deliberately not here
 *
 * The default *profile* is a setting in the ordinary sense, but `profiles.ts`
 * already owns it (`profiles:set-default`) and it has to stay there: the main
 * process resolves it while spawning a session, long before any renderer state
 * exists. Same for a provider's install state, which is discovered rather than
 * chosen. Declaring either here would create a second copy of the truth.
 */

import { CUSTOM_SCHEME_PREFIX, FOLLOW_APP_SCHEME_ID } from '../../shared/terminal-theme'
import type { Preferences } from '@shared/types'
import type { UiPlatform } from '../platform'

/* ------------------------------------------------------------- sections -- */

/**
 * ## The rail, and the rule that shapes it
 *
 * Thirteen sections became nine, after one sentence that is worth quoting
 * because it is the whole test a rail entry now has to pass:
 *
 *   > "every part relative parts should be connected to each other… if this is
 *   > related to agent, it should be either inside the agents… everything should
 *   > be in one place so they don't have to think, always they need to go for
 *   > one piece of information into general and for the other piece in agents."
 *
 * Agents, Accounts and Setup were one subject in three places, and General was
 * holding a coding-tool picker (with a link to Agents) and two notification
 * switches whose own help text pointed at Notifications. So the rule is: a
 * section is a *subject*, not a screen, and a row lives where somebody would go
 * looking for its subject — never where it happened to be built.
 *
 * The sections that left the rail are not gone. Accounts and Setup are groups
 * inside Coding AI, About is the masthead at the top of Help, and Shortcuts is
 * a popover off the rail's own footer. `MERGED_SECTIONS` below is what keeps
 * every old name pointing at wherever its contents actually went.
 *
 * Help went the other way in this pass — it was the link in that footer and is a
 * pane again, on his instruction, and it cost the rail nothing: About folded into
 * it as its masthead, so that pass added a pane and no seat.
 *
 * ## How long the rail is, and why that number is not written here
 *
 * It was written here, four times, in words — and then two entries were added on
 * one day, each raised the length by one, and each wrote itself down as *"the
 * eleventh"*. One of them was the twelfth. Nothing failed, because a number in a
 * comment is a claim that nothing checks, and prose beside a test is prose that
 * drifts from it.
 *
 * So the length lives in the one place where being wrong about it fails
 * something: the ceiling in `nothing-dropped.test.tsx`, which asserts
 * {@link sectionsFor} per platform and carries, beside the assertion, the ledger
 * of what every entry that raised it paid for. The list itself is `SECTIONS`
 * below and the way to count it is `sectionsFor`; anything that needs the number
 * should name one of those rather than spell a word that will be wrong by
 * Thursday.
 */
export const SECTIONS = [
  {
    id: 'general',
    label: 'General',
    blurb: 'How sessions behave day to day.',
  },
  {
    id: 'appearance',
    label: 'Appearance',
    blurb: 'The window’s theme, and how a session is drawn.',
  },
  /*
   * Everything the app says without being asked, in one place. It used to be
   * split down the middle — General owned "should we interrupt you at all" and
   * this section owned "how" — which meant the two switches people look for
   * were on a different screen from the sound they play and the banner rules
   * they obey. That split is exactly what the quote above is about.
   */
  {
    id: 'notifications',
    label: 'Notifications',
    blurb: 'What the app tells you, and how.',
  },
  /*
   * One subject, one place: which agent runs, the logins it runs as, and what
   * this machine actually has installed. Three rail entries before this —
   * Agents, Accounts, Setup — each of which spent a paragraph pointing at the
   * other two.
   *
   * The pane is assembled from the three files that used to be those sections
   * rather than rewritten into one, so nothing had to be re-typed to be moved,
   * which is the failure mode he named: *"when you reorganize you mostly miss
   * the things and you drop some stuff."*
   */
  /*
   * "Agents" was the wrong word, "Assistants" was the wrong word, and the id is
   * still not the word.
   *
   * This entry has been renamed twice in two days. Both rounds are kept below,
   * because the second one is only decidable if you can read the first — the
   * argument that chose "Assistants" is also the argument that convicts it.
   *
   * ## Round one — why "Agents" went (2026-08-17)
   *
   *   > "Agents is the wrong name for that section. Needs a better one."
   *
   * He is right, and the reason is the audience the whole pass is written for —
   * *"my audience will be mostly non-technical vibe coders"*. "Agent" is our
   * word, not theirs, and inside this one product it already means three
   * different things: the CLI that runs a session, the model that CLI talks to,
   * and the copilot — which has a rail entry of its own further down the same
   * list. A rail that reads "Agents … Copilot" is asking somebody to know that
   * the copilot is an agent but does not live under Agents.
   *
   * (Round one wrote "two rows down" there. Counted on 2026-08-19 with
   * `sectionsFor`, it is three on macOS and four on Windows, where Linux sits
   * between Tools and Browser. The distance was never the argument, but a number
   * in one of these comments is a claim like any other, and this one was not
   * checked when it was written. Corrected in place rather than left standing:
   * preserving superseded *reasoning* is the rule, not preserving arithmetic
   * that is simply wrong.)
   *
   * ## Round one's answer, kept because it is half of round two
   *
   * *(Superseded. Every clause of it is still true, which is the point.)*
   *
   *   > "Assistants" is what a person who is not a programmer already calls
   *   > Claude Code, Codex and Gemini CLI, it names no vendor (the review's own
   *   > rule — *"you should not mention in any settings or any pop-up a specific
   *   > tool or LLM"*), and it does not collide with **Tools**, which is the
   *   > label he chose himself for the voice pane and expects to grow. "Coding
   *   > tools" and "AI tools" both would have.
   *
   * ## Round two — why "Assistants" went too (2026-08-19)
   *
   *   > "assistant should not be called as assistants actually, it can be a — we
   *   > need to find out some other words for this. Maybe meanwhile we can call
   *   > it as models, something somehow."
   *
   * **He asked, and that is the reason.** It is a sufficient one on its own and
   * it goes first, because the paragraph that stood here on 2026-08-19 invented
   * a better-sounding mechanism instead and got it wrong in three places — the
   * retraction is at the end of this section, kept rather than deleted. What
   * follows is what survives checking, and it is corroboration, not cause.
   *
   * **The rail half — round one's argument with one word swapped.** The rail is
   * drawn beside every pane, so its whole column is on screen whichever section
   * is open. Rendered on Windows it reads:
   *
   *     General · Appearance · Notifications · **Coding AI** · Tools · Linux ·
   *     Browser · **Copilot** · Power · Advanced · Help
   *
   * (macOS is the same without Linux. Shortcuts sits under that column too, but
   * it is the rail *footer's* button and not a section, which is why it is not
   * in `sectionsFor`.) Under the old label the same column said "… Assistants …
   * Copilot …": a category and one member of it, siblings in one list, four
   * rows apart on Windows and three on macOS. Round one rejected exactly that
   * shape for "Agents" — a rail like this one *"is asking somebody to know that
   * the copilot is an agent but does not live under Agents"* — and swapping in a
   * word the product also uses for the copilot left the shape intact.
   *
   * **The vocabulary half.** "Assistant" is a word this product had already
   * spent on the copilot, in copy that reaches a screen:
   *
   *   - `copilot/identity.ts:58` — `COPILOT_BLURB`, *"Your assistant for this
   *     deck — the sessions, the diffs, the prompts."* Grep says it reaches a
   *     screen in exactly one place: `copilot/CopilotEntry.tsx:105`, as the
   *     `title=` of the sidebar's pinned Copilot row, and only while
   *     `stage === null`.
   *   - `settings/sections/CopilotSection.tsx:932` and `:1680` use the common
   *     noun for whatever agent owns a folder — *"it picks up whatever assistant
   *     already lives there"*. Both sit in branches that need a wired copilot
   *     bridge; without one that pane renders a single sentence and no prose,
   *     which is measured rather than assumed (`nothing-dropped.test.tsx` says
   *     what that costs its sweep).
   *
   * So it is one word doing two jobs across the product, not two sentences
   * colliding on one screen. Nowhere does the label sit beside any of those
   * lines — the rail draws `entry.label` and nothing else. That is a weaker
   * claim than the one it replaces, and it is the true one.
   *
   * ## Retracted: what this section said when it was first written (2026-08-19)
   *
   * Kept, because an argument that sounded right and was not is worth more as a
   * warning than as a deletion, and because the next person to rename this entry
   * will reach for it again. It read:
   *
   *   > *"The measurable reason it failed is that it carried round one's defect
   *   > across intact. `copilot/identity.ts` exports the line the sidebar and
   *   > the Copilot pane both print … so the rail read 'Assistants … Copilot'
   *   > with the Copilot pane calling itself an assistant one row down."*
   *
   * Three checkable claims, none of them checked before they were written, all
   * three false:
   *
   *   1. The Copilot pane does not print that line. `grep -rn COPILOT_BLURB src/`
   *      returns `identity.ts`, `CopilotEntry.tsx` and one test — and
   *      `CopilotEntry` is the *sidebar's* pinned row, using it as a tooltip.
   *      Neither `settings/sections/CopilotSection.tsx` nor
   *      `copilot/CopilotView.tsx` imports it.
   *   2. The juxtaposition it describes cannot occur on any screen. This same
   *      comment, in the "Setup" bullet further down, already says correctly
   *      that the rail draws `entry.label` and nothing else — no blurb, no icon
   *      (`SettingsWindow.tsx:527` renders `{entry.label}` and closes the
   *      button) — so no blurb was ever beside the label. The wrong claim and
   *      its own refutation were written into one comment on the same day. (No
   *      line count is given here on purpose: a self-referential distance is one
   *      more claim that goes stale on the next edit, which is how the original
   *      got its row counts wrong.)
   *   3. "One row down" is wrong in the other direction from round one's error:
   *      Copilot is three rows below this entry on macOS, four on Windows.
   *
   * The failure is the one the review names outright: a confident, unmeasured
   * claim written into the file that explains a decision, where the next person
   * has no reason to doubt it. It is worse than no comment at all. The rule it
   * broke, stated here so it is stated somewhere: nothing goes in one of these
   * blocks that has not been grepped, rendered or run — and a claim that turns
   * out to be weaker once checked gets written down weaker.
   *
   * ## Why not "Models", which is what he asked for
   *
   * Because there is not one model on this pane, and there is a control called
   * Model on every session in the app.
   *
   *   - This section declares exactly **one** setting, `agents.defaultProvider`,
   *     and its four options are `Claude Code`, `Codex CLI`, `Gemini CLI` and
   *     `Plain shell` — four programs, no model among them. The rest of the pane
   *     is logins, install state and whatever coding tools this machine has
   *     that cannot start a session. Nothing here would answer somebody who came
   *     looking for a model, so the name would be a promise the pane cannot
   *     keep, which is the same failure as a control drawn where it cannot act.
   *   - `chat/controls/catalog.ts` already spends the word: `controlName('model')`
   *     is `'Model'` and `describeControl('model')` is *"Which model answers in
   *     this session."*, on the controls bar of every session. A rail entry
   *     called Models would be the second Model in one product, which is
   *     precisely the collision that killed "Agents" — one word, three meanings —
   *     rebuilt on purpose.
   *
   * So his word is not taken, and this comment is where that gets argued rather
   * than quietly ignored. He asked for it as a stopgap — *"maybe meanwhile"* —
   * and the half of his instinct that is right is kept below: the family word an
   * ordinary person reaches for is what belongs in the rail, and "Models" is
   * that word everywhere except in an app that already ships a Model button.
   *
   * ## Why it is not split up instead
   *
   * The obvious alternative — model choice on one pane, sign-ins on another,
   * installs on a third — is not available, and not only because the model
   * choice does not exist here. This pane *is* the merge of those three, made
   * two days ago on his own instruction — the quote is at the top of this table
   * and again in `AgentsSection.tsx`:
   *
   *   > "Now see, agents is separate and accounts is separate page, which should
   *   > be one place because they are related to each other and it is one thing."
   *
   * Splitting it back is reversing that. The naming is what is wrong; the
   * grouping was right and was asked for.
   *
   * ## The word, and the ones rejected
   *
   * **"Coding AI"**. It is the family word a non-technical reader already uses
   * for Claude Code, Codex and Gemini CLI, it names no vendor, and — this is the
   * test "Assistants" failed — the rest of the product has not already spent it:
   * `grep -rn "Coding AI" src/` returns only files under
   * `src/renderer/settings/`, and `src/renderer/copilot/` does not contain the
   * phrase at all. The copilot stays a *named feature* in the rail rather than
   * an unnamed instance of the category above it, and a named feature beats a
   * category when somebody is scanning. "Coding" is doing the narrowing work: it
   * is what keeps the entry from meaning every AI thing in the window.
   *
   *   - **"AI"** alone over-claims. Voice dictation on the Tools pane runs on a
   *     transcription model, the copilot is AI, the Model button is AI, and none
   *     of the three is here. A label broader than its pane sends people to the
   *     wrong screen twice: once when they open it and once when they give up
   *     on it.
   *   - **"Setup"** is the one with a real argument for it — the application
   *     menu's *"Setup & Diagnostics"* opens this pane, and `MERGED_SECTIONS`
   *     already routes the id `setup` here, so the label would finally agree with
   *     both. It loses on the rule this rail is built on: a section is a
   *     *subject*, not a stage, and the rail draws `entry.label` and nothing else
   *     — no blurb, no icon — so a vague label has nothing to lean on. "Which AI
   *     runs my sessions" is not a question anybody answers with the word Setup.
   *   - **"Accounts"** would make four rendered cross-references true that are
   *     currently stale: `copilot/CopilotSetup.tsx:381`, `:633` and `:639`, and
   *     `copilot/CopilotView.tsx:243`, all four of which still send somebody to
   *     *"Settings → Accounts"* at a rail that has had no such entry since the
   *     08-17 merge. (Counted, not estimated — an earlier draft of this bullet
   *     said three. `CopilotSetup.tsx:269` says it as well but is a comment, and
   *     `copilot-render.test.tsx:149` pins one of the four.) It still names
   *     neither the default-tool picker nor the install list, which are the two
   *     things at the top of the pane, so it buys accuracy elsewhere by being
   *     wrong here. Those four lines are owed a fix on their own terms.
   *   - **"Coding tools"** and **"AI tools"** stay rejected for round one's
   *     reason, unchanged: **Tools** is the very next entry in the rail — one
   *     row, on all three platforms — and he named it himself. (An earlier draft
   *     of this bullet said two rows; `sectionsFor` says one.)
   *   - **"Providers"**, **"Engines"**, **"CLIs"** are this codebase's own words
   *     (`defaultProvider`, `providers.ts`) and the audience quoted at the top of
   *     this comment is not this codebase.
   *
   * What it costs, stated rather than glossed:
   *
   *   - `Plain shell` is one of the four options and is not AI. It is the "none"
   *     answer to the section's own question, the way a theme can be None, and
   *     the blurb says *what* runs rather than *which AI* runs for exactly that
   *     reason.
   *   - The pane now speaks in three registers: "Coding AI" in the rail, "coding
   *     tool" on the picker and the Setup group, "agent CLI" in two warnings.
   *     The third is deliberate — `neutral-naming.test.ts` pins "agent CLI" as
   *     the category noun the help page uses *in order to* avoid naming a vendor,
   *     and that is a repo-wide vocabulary that does not get rewritten from
   *     inside one pane. Unifying all three is real work and it is owed.
   *
   * The **id stays `agents`** and so does the file name. Ids are storage and
   * routing — `finish.test.ts` names `AgentsSection.tsx` by path, and `App.tsx`
   * is a file no single agent may edit while others are working here — and this
   * table already makes that trade once, deliberately, for `features`/"Tools".
   * A label is what a person reads; an id is what the machine reads; they do
   * not have to agree. Two renames in two days is the argument for that rule,
   * not against it: nothing on disk moved either time.
   */
  {
    id: 'agents',
    label: 'Coding AI',
    /*
     * "Which AI runs your sessions…" was the blurb, and the first two words came
     * off when the title grew them. Under a heading reading "Coding AI" it was
     * the label again in a smaller font — the same duplication `browser.startUrl`
     * has a paragraph about — and "what runs" is the more honest opening anyway,
     * since one of the four answers is a plain shell with no AI in it at all.
     */
    blurb: 'What runs your sessions, the logins it uses, and what is installed.',
  },
  /*
   * The servers, one at a time, with a pill naming which.
   *
   *   > *"build a proper version for scrapping and server control with switching
   *   > pill just like in coding ai page in settings but build proper settings
   *   > inside too exactly like local machine, exactly means exactly and all
   *   > other applicaple places too"*
   *
   * ## Why it is a rail entry and not a group inside Coding AI
   *
   * On this table's own rule — a section is a *subject*. Coding AI answers
   * "which AI runs my sessions, as which login, with what installed", and it
   * already asks that of servers: its `servers` scope lists the coding logins on
   * all of them, and that stays where it is. This entry answers a different
   * question about one machine — its identity, the sign-in this computer holds,
   * the folder its sessions start in, the two permissions it can be given, and
   * whether anything of ours is installed on it. Four of those five are not
   * about AI at all, and folding them under "Coding AI" is where somebody stops
   * finding them.
   *
   * It is also the entry that pays for itself in the other direction: every one
   * of those controls existed already, behind an **Advanced** door on the
   * server's own page in the Machines panel, which is a screen you reach by
   * leaving Settings.
   *
   * ## What it costs, stated rather than glossed
   *
   * It raised the rail's ceiling by one, and it is the **second** entry to do
   * that on 2026-08-22 — Scraping went in the same day, further down this list.
   * Both first claimed to be the eleventh, which is the reason no length is
   * spelled in this file any more. `nothing-dropped.test.tsx` carries the
   * argument for raising it, beside the ceiling itself and beside the number,
   * because that is what that ceiling asks of anything that raises it.
   */
  {
    id: 'servers',
    label: 'Servers',
    /*
     * "What each of your servers is set to do" was the first draft and it says
     * *set* twice by the time the reader gets to the first group heading. This
     * one names the two halves a person arrives with: which machine, and what
     * about it.
     */
    blurb: 'Each server you have added, and what it can be told to do.',
  },
  /*
   * The id stays `features` and the label says Tools.
   *
   * The store is gone — *"they are all necessary basic, they don't need to have
   * uninstall and install button, enable and disable thing"* — and what is left
   * is the one entry he wanted kept: *"instead of only voice dictation… so
   * features or maybe tools, let's actually call it tools and keep this voice
   * dictation here."*
   *
   * The id is storage and routing, the label is what a person reads, and those
   * two do not have to agree: `profiles`/"Accounts" made the same trade for the
   * same reason. Here it is load-bearing rather than cosmetic — `App.tsx` names
   * this id, and `App.tsx` is a file no single agent may edit while others are
   * working in this repo.
   */
  {
    id: 'features',
    label: 'Tools',
    blurb: 'Extra tools a session can use.',
  },
  /*
   * Windows only, and gated below rather than always drawn. A rail entry
   * reading "Linux" on a Mac is a row that can only ever say "nothing here",
   * and this app does not put controls on screen that describe nothing.
   */
  {
    id: 'linux',
    label: 'Linux',
    blurb: 'Which Linux a session in a Linux folder runs inside.',
  },
  {
    id: 'browser',
    label: 'Browser',
    blurb: 'The built-in browser tab and what it remembers.',
  },
  /*
   * Taking a website apart, which had no pane at all until this entry.
   *
   * ## Where it was
   *
   * Behind the browser tab's three-dot menu, and nowhere else. Every knob for
   * the worker fleet, the request rules, passive capture, the asset renditions
   * and their resume ledger, and the coverage self-check lived in one modal a
   * person could only reach by opening a browser tab first and then finding a
   * menu on it. A whole subsystem's configuration behind two clicks that have
   * nothing to do with the subject is the shape of *"install and do some clicks
   * and everything works fine"* failing at the first click.
   *
   * ## Why it is not a group inside Browser
   *
   * The rule this table is built on — a section is a *subject* — and this is a
   * different subject from the one Browser answers. Browser is "the tab I open
   * pages in, what it starts on and what it remembers about me". Scraping is
   * "the fleet, the rules, the ledger and the checks that take a site apart",
   * it is what the harvesting tools read before a run, and its settings are per
   * *profile* where Browser's are per tab. Folding sixty controls under a pane
   * about a start page would bury them exactly as thoroughly as the three-dot
   * menu did.
   *
   * ## It is the same pane in both places, not a second one
   *
   * `ScrapingSection` renders `ScrapingBody` — the identical component the
   * browser's own panel renders — so the two cannot drift apart into a settings
   * screen and a menu screen that disagree about what a switch does. The
   * failure mode this window already names: *"when you reorganize you mostly
   * miss the things and you drop some stuff."*
   *
   * It raised the rail's ceiling by one, and Servers — above, added the same day
   * — raised it again. Neither length is spelled here: both entries once said
   * "the eleventh" and only one of them could be, which is exactly how a number
   * in a comment rots. The ceiling, the ledger entry for this section and the
   * count itself are in `nothing-dropped.test.tsx`, which is the one place being
   * wrong about it fails something.
   */
  {
    id: 'scraping',
    label: 'Scraping',
    blurb: 'Workers, request rules, capture and the checks on what came back.',
  },
  /*
   * The one section in this rail that declares no settings at all, and it is
   * not an oversight — it is the point.
   *
   * *"we should be able to see all of his files, the things it reads before it
   * starts and all those things… so we can see and learn how our copilot is
   * working."* Everything on that pane is a **reading**: the files it loads at
   * startup, its memory, the log of what it did, what it can reach (which is
   * everything the person can — it is not sandboxed), and the three of this
   * app's own records it is refused. There is nothing to store, because the
   * copilot's folder and the account it resolves to are both decided in the
   * main process precisely so that no page can point them somewhere else.
   *
   * It is its own rail entry rather than a group inside Coding AI on the rule
   * this table is built on — a section is a *subject*. Coding AI (the entry
   * above, called Agents and then Assistants while this paragraph was written)
   * is "which one runs, as which login, with what installed". The copilot is one
   * specific agent whose files, memory and audit log a person opens Settings to
   * inspect, and folding six blocks of that under it would bury the answer to
   * the question the whole feature exists to answer.
   */
  {
    id: 'copilot',
    label: 'Copilot',
    blurb: 'Its files, its memory, what it did, and what it can reach.',
  },
  /*
   * There is no GitHub section here, and that is a decision rather than a gap.
   *
   * One existed for exactly one row — "Use classic GitHub sign-in", the switch
   * between this app's GitHub App and an OAuth client borrowed from the GitHub
   * CLI. The OAuth path was deleted on 2026-08-16, so the switch had nothing
   * left to choose between, and a section holding a single row that no longer
   * exists is a rail entry that can only ever say "nothing here". Which
   * credential the app asks GitHub for is now answered by the GitHub panel's
   * own Connect and Disconnect, where the sign-in it describes actually lives.
   */
  /*
   * Remote is not a settings section any more — it is the rail panel called
   * Machines, under Integrations. It was beside Alerts in the foot until
   * 2026-08-19; the note on that entry in `shell/panels.ts` has the reason it
   * moved, and why the id is still `remote` wherever it moves to.
   *
   * Pairing a device is something you do rather than something you configure,
   * and it declared no settings of its own: this entry existed only to give the
   * pairing screen somewhere to render. Putting it back here would put the one
   * live pairing code on two screens, and only one may mint it.
   */
  /*
   * Power sits beside Remote because the two answer the same question from
   * opposite ends — reaching this machine while you are away from it, and
   * keeping it running while you are. It declares no settings of its own on
   * purpose: what its switch reads and writes is a *system* setting, owned by
   * the operating system and changeable from outside this app, so storing a
   * copy of it here would be a cached answer to a question only the OS can
   * answer. See `src/main/lid-awake.ts`.
   */
  {
    id: 'power',
    label: 'Power',
    blurb: 'Keep this machine running when you close it.',
  },
  /*
   * Shortcuts is not a rail entry any more; it is a popover off the rail's
   * footer. *"This is a huge shortcut page — maybe rather than this we can have
   * another pop-up by clicking on this… only an icon here where we click and
   * see the shortcut as pop-up."* It was the longest pane in the window and the
   * one nobody scrolls twice, which is the shape of a reference rather than of
   * a settings screen. See `ShortcutsPopover`.
   *
   * Help *is* one again, and this entry is the reversal. See the block below
   * the Advanced row.
   */
  {
    id: 'advanced',
    label: 'Advanced',
    /*
     * "Files on disk" has gone out of this blurb because it has gone off the
     * pane. See `AdvancedSection.tsx` — what is left is the two things a person
     * actually does here when something is wrong, and neither of them is a
     * path.
     */
    blurb: 'When something is wrong, and starting over.',
  },
  /*
   * Help, back in the rail — and About folded into it.
   *
   *   > "We should have a help page where we can see all the help-related
   *   > features, options — whatever you had before, those kinds of stuff. So
   *   > this can be a separate page."
   *
   * This entry existed, was demoted to a link out to the marketing site, and is
   * now a pane again, which is worth being honest about rather than quietly
   * flipping: the earlier instruction was *"maybe we can make it like help
   * button… it should take to terminal website"*, and this one supersedes it.
   * The site did not lose its link — it is a row **on** this pane now (About's
   * "Website"), so the professional thing he asked for is one click from the
   * help rather than instead of it.
   *
   * ## Why About is inside it rather than beside it
   *
   * The rail's own rule, applied to the last entry that was breaking it: a
   * section is something you *change*. Shortcuts left for being a reference and
   * Help left for being a reference; About — version, licence, source, "check
   * for updates" — is the third reference and the only one still holding a rail
   * seat. It is also the same subject as the help panel's own About card
   * ("Versions, and what to include in a bug report"), which is a duplication
   * this window has removed everywhere else.
   *
   * So the rail did not grow for this, which was the condition of having it back
   * at all: a help page is not worth a rail creeping towards the thirteen entries
   * this reorganisation was asked to cut. (Two entries have been added since —
   * Scraping and Servers — and what each paid for its seat is written in
   * `nothing-dropped.test.tsx`, beside the ceiling it raised.)
   *
   * Nothing was retyped to move it. `AboutSection` is rendered *in place* at the
   * top of the pane — the same assembled-not-rewritten trick `AgentsSection`
   * uses for Accounts and Setup — so `openSettings('about')` from the
   * application menu lands on the masthead it always landed on, and every fact
   * that pane carried is still the first thing on screen.
   */
  {
    id: 'help',
    label: 'Help',
    blurb: 'What this app is, how it works, and what to do when it does not.',
  },
] as const

/** A section that has a pane of its own. */
export type LiveSectionId = (typeof SECTIONS)[number]['id']

/**
 * Sections that no longer have a pane, and the pane that absorbed each.
 *
 * This is the half of a reorganisation that is normally left out, and leaving
 * it out is how a link somewhere else in the app quietly starts landing on the
 * wrong screen. Every id that ever named a section still names a real
 * destination: `App.tsx` opens Settings at `setup` from the application menu
 * and at `profiles` from the account chip, and both of those now mean Coding AI
 * — the entry whose id is still `agents` — because that is where their contents
 * went.
 *
 * Kept in the `SectionId` union rather than deleted so those call sites keep
 * compiling — `App.tsx` may not be edited while several agents are working in
 * this repository, and a union that no longer contains the id they pass would
 * fail the build in a file nobody is allowed to fix.
 */
export const MERGED_SECTIONS = {
  /** Accounts is a group inside Coding AI. */
  profiles: 'agents',
  /** Setup is two groups inside Coding AI. */
  setup: 'agents',
  /** A popover off the rail's footer, not a pane. */
  shortcuts: 'general',
  /*
   * About is the masthead at the top of Help.
   *
   * This entry is the reverse of the one that used to sit here (`help: 'about'`)
   * and it is the reason that one could be inverted safely: the application
   * menu's About item calls `openSettings('about')`, and a menu item that
   * silently lands on General is indistinguishable from a broken menu. Through
   * this table it lands on the pane whose first block is the About card, which
   * is the same thing it always showed.
   */
  about: 'help',
} as const satisfies Readonly<Record<string, LiveSectionId>>

export type MergedSectionId = keyof typeof MERGED_SECTIONS

/** Any id that has ever named a section. Every one of them resolves to a pane. */
export type SectionId = LiveSectionId | MergedSectionId

function isMerged(id: SectionId): id is MergedSectionId {
  return Object.prototype.hasOwnProperty.call(MERGED_SECTIONS, id)
}

/** The pane an id names today, following the merge table exactly once. */
export function resolveSection(id: SectionId): LiveSectionId {
  return isMerged(id) ? MERGED_SECTIONS[id] : id
}

export const SECTION_IDS: readonly LiveSectionId[] = SECTIONS.map((section) => section.id)

export type Section = (typeof SECTIONS)[number]

/**
 * Sections that only exist on one platform, and the platforms they exist on.
 *
 * A separate table rather than a field on every entry, because the exception is
 * one row: `platforms: ['windows', 'mac', 'other']` on every section that has no
 * such constraint is a line of noise per entry and one more place per entry to
 * get it wrong later.
 *
 * The rule for putting something here is narrow: the section must have *nothing*
 * to say elsewhere. Power is on both platforms and says different things on
 * each, so it is not here; Linux genuinely does not exist off Windows.
 */
const SECTION_PLATFORMS: Partial<Record<LiveSectionId, readonly UiPlatform[]>> = {
  linux: ['windows'],
}

/** The rail for one platform: every section that has something to say on it. */
export function sectionsFor(platform: UiPlatform): readonly Section[] {
  return SECTIONS.filter((section) => {
    const only = SECTION_PLATFORMS[section.id]
    return only === undefined || only.includes(platform)
  })
}

/** The pane's own title and blurb. A merged id answers with the pane it went to. */
export function sectionMeta(id: SectionId): Section {
  const live = resolveSection(id)
  const found = SECTIONS.find((section) => section.id === live)
  // Unreachable through the typed API; a runtime id off the wire is not typed.
  if (!found) throw new Error(`settings: no section "${id}"`)
  return found
}

/* --------------------------------------------------------------- shapes -- */

export type SettingKind = 'toggle' | 'select' | 'number' | 'text'

/** Which file on disk holds the value. */
export type SettingStore = 'prefs' | 'extra'

export type SettingValue = boolean | string | number

interface SettingBase {
  /** Stable storage key. Dotted by section so a raw settings.json reads clearly. */
  id: string
  section: LiveSectionId
  label: string
  /**
   * One sentence under the label. Says what changes, not what the control is.
   *
   * Capped at {@link MAX_HELP_LENGTH} by `settingsSchemaProblems`, which is a
   * rule rather than a suggestion for the reason the cap exists at all:
   *
   *   > "we don't need this much of big descriptions under each. The whole page
   *   > is going to be used just because of the big descriptions… let's give
   *   > only one liner or two liner descriptions and one eye buttons next to
   *   > them so they can click or hover over there and they can read the full
   *   > description."
   *
   * Every long line in this table was defensible on its own, which is precisely
   * how they accumulated. The second half of that sentence is `more`.
   */
  help: string
  /**
   * The rest of the explanation, behind the ⓘ beside the label.
   *
   * Not a place to put something a person needs before they touch the control —
   * anything load-bearing belongs in `help`, where it is on screen without a
   * hover. This is for the paragraph that used to be under every row: the
   * mechanism, the caveat, the second case.
   */
  more?: string
  store: SettingStore
  /**
   * The matching key in `store.ts`'s Preferences. Present exactly when
   * `store` is 'prefs' — `settingsSchemaProblems()` enforces both directions.
   */
  prefsKey?: keyof Preferences
}

export interface ToggleSetting extends SettingBase {
  kind: 'toggle'
  default: boolean
}

export interface SelectOption {
  value: string
  label: string
  /** Optional second line in the picker, for options that need one. */
  help?: string
}

export interface SelectSetting extends SettingBase {
  kind: 'select'
  default: string
  options: readonly SelectOption[]
}

export interface NumberSetting extends SettingBase {
  kind: 'number'
  default: number
  min: number
  max: number
  step: number
  /** Rendered after the field — 'px', 'seconds'. */
  unit?: string
}

export interface TextSetting extends SettingBase {
  kind: 'text'
  default: string
  placeholder?: string
  /** What an empty value falls back to, said plainly. */
  emptyMeans?: string
}

export type Setting = ToggleSetting | SelectSetting | NumberSetting | TextSetting

/** Longest string this schema will store. A settings file is not a document. */
export const MAX_TEXT_LENGTH = 512

/**
 * Longest a keyed row's value may be, which is a scheme as JSON.
 *
 * Twenty-one colours, their names and a scheme name comes to a little over six
 * hundred characters. Two thousand is room for a name in any script and still
 * half of the store's own 4096-character cut — the cut that matters, because it
 * is applied *silently*, and a value trimmed there would come back as a scheme
 * with a torn colour in it rather than as an error.
 */
export const MAX_KEYED_LENGTH = 2048

/**
 * The longest a `help` line may be.
 *
 * Measured rather than chosen: at this window's reading measure, 120 characters
 * is two lines of `--t-caption` and the row still reads as a label with a note
 * under it. One character more and the third line starts, which is the point at
 * which a list of settings starts looking like a document — the complaint this
 * whole pass came from. Everything beyond it goes in `more`.
 */
export const MAX_HELP_LENGTH = 120

/**
 * The longest a `more` may be.
 *
 * A tooltip is read in one glance or not at all, and this window's bubble wraps
 * at a fixed measure. Anything past this is a paragraph that has been moved off
 * the pane rather than cut, which is the trick this budget exists to prevent.
 */
export const MAX_MORE_LENGTH = 220

/* ---------------------------------------------------------------- the table -- */

/**
 * Sound ids offered by the notification picker.
 *
 * Kept in step with `notification-sound.ts`, which holds the recipe for each —
 * the app ships no audio files (verified: `src/renderer/assets` contains fonts
 * and nothing else), so every sound here is synthesised. A test asserts the two
 * lists match, because a picker offering a sound that cannot be played is worse
 * than a shorter picker.
 */
export const SOUND_OPTIONS: readonly SelectOption[] = [
  { value: 'chime', label: 'Chime', help: 'Two soft notes.' },
  { value: 'blip', label: 'Blip', help: 'One short tone.' },
  { value: 'knock', label: 'Knock', help: 'Low and dull.' },
]

export const SETTINGS: readonly Setting[] = [
  /* ------------------------------------------------------------- general -- */
  /*
   * What is left in General once every row that belonged to another subject has
   * gone to it: how a *session* behaves while you work, and nothing else. The
   * language row went too — see the block where it used to be.
   *
   * Three rows left this block in this pass. The coding-tool picker went to the
   * `agents` pane — Agents when this was written, Coding AI now — where the list
   * of installed agents and the login each one uses already were; it had been
   * sitting here with a link to that section underneath
   * it, which is the shape of a row in the wrong section. The sound and the
   * banner went to Notifications, whose own help text had been pointing back at
   * Notifications from inside General.
   *
   * One row arrived: "Pick up where you left off" came *back* from Advanced.
   * *"Pick up where you left off on launch — I don't know if this one also need
   * to be not here, it is somewhere at wrong place."* It is: what happens to
   * your sessions is the subject of this section, and diagnostics is not.
   */
  /*
   * `general.language` was here, and it is gone rather than disabled.
   *
   *   > "It will be always English and it is English, so there is no selection.
   *   > The option should not be there."
   *
   * It had already been through the halfway house: the picker was replaced by
   * the *word* "English" beside a help line explaining that English is the only
   * one there is, on the argument that "can I have this in my language" deserves
   * an answer rather than a missing row. That argument was wrong in the way this
   * whole pass is about — a row that states a constant is still a row somebody
   * has to read, in a window being cut down for people who are not programmers,
   * and it answers a question by taking up the space of a setting.
   *
   * Nobody's stored value is lost by this. `mergeSettings` keeps a key it does
   * not recognise, so an existing `general.language: "en"` rides along untouched
   * and would be picked straight back up if a translation ever lands and the row
   * comes back. That is why there is no `RENAMED_IDS` entry: this is not a
   * rename, and inventing a destination for it would be worse than none.
   *
   * The rule the row used to demonstrate — a select with one option is drawn as
   * a value, never as a dropdown — lives in `SettingControl` and is pinned by a
   * test of its own, so removing this row did not remove the behaviour.
   */
  {
    id: 'general.restoreSessions',
    /*
     * Twice wrong before this, and once misfiled.
     *
     * It first said "Restore sessions on launch" and reopened nothing at all —
     * the value was stored and no code on either side of the bridge read it. It
     * was then narrowed to the projects, with help text that stated flatly that
     * sessions are not reopened, on the reasoning that a pty dies with the app.
     *
     * That reasoning was about the wrong thing. The pty does die; the
     * *conversation* does not. Claude Code writes it to a transcript on disk,
     * and `--continue` reads it back, so a session can genuinely be picked up
     * where it was left. `src/main/session-restore.ts` is that, and this label
     * had to stop denying it the moment that shipped.
     *
     * Worded as an outcome rather than a mechanism on purpose. "Continues where
     * you left off" is what happens; "resumes the transcript" is plumbing, and
     * this app does not narrate its plumbing at people.
     */
    section: 'general',
    label: 'Pick up where you left off',
    help: 'Reopens the projects and sessions you had open, continuing each conversation.',
    more: 'Rather than starting each one over. A session whose folder or conversation is gone opens clean instead of failing.',
    store: 'prefs',
    prefsKey: 'restoreSessions',
    kind: 'toggle',
    default: true,
  },
  /*
   * `general.recordHistory` was here — "Record session history when sessions
   * close". Nothing in this app has ever recorded a session. Search and the
   * inspector read Claude Code's own transcripts out of ~/.claude/projects,
   * which are written by the CLI whether or not this app is running, so the
   * switch could not have changed anything even in principle. Removed rather
   * than left as a control over nothing; if an app-side history store is ever
   * built, this row comes back with it.
   */
  {
    id: 'general.autoNameSessions',
    section: 'general',
    label: 'Name sessions from the conversation',
    help: 'A tab takes the conversation’s title once it has one.',
    more: 'Until then it keeps the folder name. Renaming a tab yourself always wins — this only fills in a name nobody has chosen.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'general.confirmCloseWorking',
    section: 'general',
    /*
     * The wording follows the behaviour, which changed on 2026-08-18.
     *
     * *"Always ask before closing anything from the side panel."* — so this is
     * no longer about working sessions in particular, and the old `more` line
     * ("an idle session always closes straight away") had become the opposite of
     * what happens. The id is untouched on purpose: it is what the dialog reads
     * and what every existing install has already written, and renaming a
     * setting id silently resets everybody's answer to the default.
     *
     * This row is also the *only* way back once "Don't ask again" has been
     * ticked in the dialog — *"once ticked there is no way to turn it back on.
     * That has to exist."* It did exist, and nothing said so; the dialog now
     * names this section by name, so the two have to keep agreeing.
     */
    label: 'Confirm before closing a session',
    help: 'Closing a session or a project asks first.',
    more: 'The confirmation says what is at stake: a session mid-task loses that work, one that has already ended loses only its scrollback. Off, everything closes straight away.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'general.copyOnSelect',
    section: 'general',
    label: 'Copy on select',
    help: 'Selecting text in a session copies it.',
    more: 'The way a Unix terminal does. It applies to session terminals only, not to the chat box.',
    store: 'extra',
    kind: 'toggle',
    default: false,
  },

  /* ---------------------------------------------------------- appearance -- */
  {
    id: 'appearance.theme',
    section: 'appearance',
    label: 'Theme',
    help: 'Dark, light, or whatever the desktop is set to.',
    store: 'prefs',
    prefsKey: 'theme',
    kind: 'select',
    default: 'dark',
    options: [
      { value: 'dark', label: 'Dark' },
      { value: 'light', label: 'Light' },
      { value: 'system', label: 'System' },
    ],
  },
  {
    id: 'appearance.density',
    section: 'appearance',
    label: 'Density',
    help: 'Compact tightens rows and spacing.',
    more: 'The text size does not change with it — only the space around it.',
    store: 'extra',
    kind: 'select',
    default: 'comfortable',
    options: [
      { value: 'comfortable', label: 'Comfortable' },
      { value: 'compact', label: 'Compact' },
    ],
  },
  /*
   * The terminal's colours, declared here so the pane has a row for them and
   * `settings.json` has a key — but drawn by hand, like the font below it.
   *
   * A `select` would be the honest kind and it is the wrong control, for the
   * reason `MONO_CANDIDATES` gives about the font it replaced: a scheme is
   * twenty-one colours and a name in a list says nothing about any of them.
   * The pane draws each one as itself instead. The kind is `text` because what
   * is stored is an id — a built-in's, or one of the person's own — and the
   * options are not a fixed list this table could hold: half of them are made
   * by whoever is reading it.
   */
  {
    id: 'appearance.terminalScheme',
    section: 'appearance',
    label: 'Terminal colours',
    help: 'The colour scheme every session is drawn in.',
    more: 'Pick one of the schemes, or edit any colour to make your own. Editing a scheme that came with the app makes you a copy of it rather than changing it for everybody.',
    store: 'extra',
    kind: 'text',
    default: FOLLOW_APP_SCHEME_ID,
  },
  {
    id: 'appearance.terminalFontSize',
    section: 'appearance',
    label: 'Terminal font size',
    help: 'Applies to every session terminal.',
    store: 'extra',
    kind: 'number',
    // 13 is what TerminalView already builds xterm with, so the stored default
    // matches what an untouched install actually shows.
    default: 13,
    min: 9,
    max: 24,
    step: 1,
    unit: 'px',
  },
  {
    id: 'appearance.terminalFontFamily',
    section: 'appearance',
    label: 'Terminal font',
    help: 'A font family name, exactly as your system spells it.',
    store: 'extra',
    kind: 'text',
    default: '',
    placeholder: 'SF Mono',
    emptyMeans: "Leave empty to use the app's own monospace font.",
  },

  /* ------------------------------------------------------- notifications -- */
  /*
   * All six of them, in one place, for the first time.
   *
   * The split this replaces put "should the app interrupt you" in General and
   * "how" here, so the two switches everybody looks for were on a different
   * screen from the sound they play and the rule about when a banner is
   * allowed. Both of the General rows even said the word *Notifications* in
   * their own help text, which is a row telling you it is in the wrong place.
   *
   * The order is when-to-tell-you first, then how: three switches about the
   * three moments something is worth saying, then the two that shape delivery.
   */
  {
    id: 'notifications.onNeedsInput',
    section: 'notifications',
    label: 'Tell me when a session needs me',
    help: 'A banner when a session is waiting on you.',
    more: 'A permission prompt, or a question the agent has asked. This is the one worth leaving on: a session waiting on an answer is a session doing nothing.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'notifications.onComplete',
    section: 'notifications',
    label: 'Tell me when a session finishes',
    help: 'A banner the moment an agent stops working.',
    store: 'prefs',
    prefsKey: 'notifyOnComplete',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'notifications.showInsightAlerts',
    section: 'notifications',
    label: 'Raise insight alerts',
    help: 'What the Alerts panel notices on its own.',
    more: 'A session filling its context window, a tool failing repeatedly, work that has stalled. These appear in the Alerts panel rather than as desktop banners.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },
  {
    id: 'notifications.onFinishSound',
    section: 'notifications',
    label: 'Play a sound when a session finishes',
    help: 'A short sound the moment an agent stops working.',
    more: 'Independent of the banner above: you can have the sound without the banner, or the banner without the sound.',
    store: 'extra',
    kind: 'toggle',
    default: false,
  },
  {
    id: 'notifications.soundName',
    section: 'notifications',
    label: 'Sound',
    help: 'Which sound a finished session plays.',
    more: 'Synthesised by the app — nothing is downloaded, and nothing is read from your sound library.',
    store: 'extra',
    kind: 'select',
    default: 'chime',
    options: SOUND_OPTIONS,
  },
  {
    id: 'notifications.onlyWhenUnfocused',
    section: 'notifications',
    label: 'Only when the app is in the background',
    help: 'Off also banners a tab you are not looking at.',
    more: 'While the window itself is in front. On, nothing interrupts you while you are already looking at the app.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },

  /* -------------------------------------------------------------- agents -- */
  /*
   * Back where it started, and this time with the things it talks about.
   *
   * This row lived in Agents, moved to General when General was rebuilt around
   * "the settings people reach for", and spent that time sitting under a line
   * of help that had to explain that the list of installed tools was on another
   * screen. That is the exact arrangement the reorganisation was asked for:
   * *"default coding tool, agents, accounts are one place thing."*
   */
  {
    id: 'agents.defaultProvider',
    section: 'agents',
    label: 'Default coding tool',
    help: 'Runs when you start a session.',
    more: 'Unless the project or the new-session dialog says otherwise. A tool that is not on your PATH is greyed out here rather than offered and then failing to start.',
    store: 'prefs',
    prefsKey: 'defaultProvider',
    kind: 'select',
    default: 'claude',
    options: [
      { value: 'claude', label: 'Claude Code' },
      { value: 'codex', label: 'Codex CLI' },
      { value: 'gemini', label: 'Gemini CLI' },
      { value: 'shell', label: 'Plain shell' },
    ],
  },

  /* ------------------------------------------------------------- browser -- */
  {
    id: 'browser.startUrl',
    section: 'browser',
    label: 'Start page',
    /*
     * The line stopped restating its own group heading.
     *
     * Under "Where new tabs open" — the heading the Browser pane grew when it
     * was reshaped around start page / cookies / profiles — "Where a new browser
     * tab opens" is the heading again in a smaller font, and the *useful* half
     * was hiding in `emptyMeans`, appended only while the field was empty.
     *
     * Empty is also the default, so what an untouched install used to read was
     * "Where a new browser tab opens. Leave empty to open the start page." —
     * two sentences, one of them a tautology, the other naming "the start page"
     * as if the reader knew that is a page this app has. Now it says what
     * happens and what that page is, once.
     */
    help: 'Type an address, or leave it empty for the page that lists what is running here.',
    store: 'extra',
    kind: 'text',
    // Empty, because a default address is a guess about somebody else's machine.
    //
    // This defaulted to `http://localhost:3000`, so the first browser tab anyone
    // opened navigated there whether or not anything was listening. On a fresh
    // Windows install nothing is, and the tab landed on Chromium's red
    // ERR_CONNECTION_REFUSED page — which is what Asad screenshotted. The start
    // page that exists for precisely this moment only rendered when the URL was
    // empty, so on a default install it was unreachable.
    //
    // 3000 is also just one framework's convention. `dev-ports.ts` already
    // detects what is actually listening on this machine, and the start page
    // offers those — which is a true answer rather than a guess.
    default: '',
    placeholder: 'http://localhost:3000',
    // No `emptyMeans`: the help line above says what empty does, in every state
    // rather than only while the field is empty, and appending it as well is how
    // that row came to say the same thing twice.
  },
  {
    id: 'browser.persistSession',
    section: 'browser',
    label: 'Keep cookies and logins between runs',
    help: 'Off signs the browser tab out every time you quit.',
    more: 'It clears the browser tab’s cookies and storage on quit, so every run starts signed out of everything.',
    store: 'extra',
    kind: 'toggle',
    default: true,
  },

  /* ------------------------------------------------------------ advanced -- */
  /*
   * The one switch on the pane, and it is now the door everything technical is
   * behind — so its line says *when to press it* rather than what it renders.
   *
   * It used to read "Shows the raw stored settings and extra diagnostics here",
   * which is a true description written for somebody who already knows what a
   * stored setting is. The reader this window is being rewritten for does not,
   * and the honest thing to tell them is the only reason they will ever touch
   * it: somebody asked them to.
   */
  {
    id: 'advanced.debugMode',
    section: 'advanced',
    label: 'Debug mode',
    help: 'Turn it on if you are asked for it while reporting a problem.',
    more: 'It adds the diagnostics to this pane: what the app is doing right now, the tail of the log, a support bundle, and where its files are kept. Nothing is sent anywhere.',
    store: 'extra',
    kind: 'toggle',
    default: false,
  },
]

/* --------------------------------------------------------------- lookups -- */

const BY_ID = new Map<string, Setting>(SETTINGS.map((setting) => [setting.id, setting]))

/**
 * A setting by id, old names included.
 *
 * The second lookup is not politeness, it is what makes a reorganisation
 * survivable. A setting's id carries its section, so moving a row between
 * sections renames it — and the readers of that row live all over the renderer,
 * in files a single agent is not allowed to edit while others are working here.
 * `App.tsx` alone reads three of the ids this pass moved. Resolving through the
 * rename table means those keep working, permanently and correctly, instead of
 * throwing `no setting "general.defaultProvider"` at the first render.
 *
 * The value is always read under the setting's *current* id, because
 * `mergeSettings` has already rewritten the stored keys. So an old name is an
 * alias for the row, never a second copy of it.
 */
function lookup(id: string): Setting | undefined {
  const direct = BY_ID.get(id)
  if (direct) return direct
  const renamed = RENAMED_IDS[id]
  return renamed === undefined ? undefined : BY_ID.get(renamed)
}

export function getSetting(id: string): Setting | undefined {
  return lookup(id)
}

export function settingsIn(section: LiveSectionId): Setting[] {
  return SETTINGS.filter((setting) => setting.section === section)
}

/**
 * Values as they are stored.
 *
 * Deliberately `unknown` rather than `SettingValue`: a settings file written by
 * a newer build carries keys this one has never heard of, and `mergeSettings`
 * keeps them. Read through the typed accessors below, which fall back to the
 * declared default for anything that is not the shape the schema promised.
 */
export type SettingValues = Readonly<Record<string, unknown>>

export const DEFAULT_VALUES: SettingValues = Object.freeze(
  Object.fromEntries(SETTINGS.map((setting) => [setting.id, setting.default])),
)

/* -------------------------------------------------------------- coercion -- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * A stored value, forced into the shape the schema declares, or null when it
 * cannot be.
 *
 * Numbers are clamped rather than rejected: a font size of 400 was a real
 * preference typed into a build with a wider range, and snapping it back to the
 * maximum keeps the app readable where discarding it would silently reset it.
 * Everything else is either the declared type or it is not.
 */
export function coerce(setting: Setting, value: unknown): SettingValue | null {
  switch (setting.kind) {
    case 'toggle':
      return typeof value === 'boolean' ? value : null
    case 'select':
      return typeof value === 'string' && setting.options.some((option) => option.value === value)
        ? value
        : null
    case 'number': {
      if (typeof value !== 'number' || !Number.isFinite(value)) return null
      const clamped = Math.min(setting.max, Math.max(setting.min, value))
      const steps = Math.round((clamped - setting.min) / setting.step)
      return Math.min(setting.max, setting.min + steps * setting.step)
    }
    case 'text':
      return typeof value === 'string' ? value.slice(0, MAX_TEXT_LENGTH) : null
  }
}

/* ------------------------------------------------------------ accessors -- */

function declared(id: string, kind: SettingKind): Setting {
  const setting = lookup(id)
  if (!setting) throw new Error(`settings: no setting "${id}"`)
  if (setting.kind !== kind) throw new Error(`settings: "${id}" is a ${setting.kind}, not a ${kind}`)
  return setting
}

/*
 * All three read `values[setting.id]`, never `values[id]`. The difference only
 * shows for a caller using an old name, and there it is the whole point: the
 * merged values are keyed by current ids, so looking up the id the caller
 * happened to type would find nothing and quietly return the default.
 */

export function booleanSetting(values: SettingValues, id: string): boolean {
  const setting = declared(id, 'toggle')
  const value = coerce(setting, values[setting.id])
  return typeof value === 'boolean' ? value : (setting.default as boolean)
}

export function stringSetting(values: SettingValues, id: string): string {
  const setting = lookup(id)
  if (!setting) throw new Error(`settings: no setting "${id}"`)
  if (setting.kind !== 'select' && setting.kind !== 'text') {
    throw new Error(`settings: "${id}" is a ${setting.kind}, not text`)
  }
  const value = coerce(setting, values[setting.id])
  return typeof value === 'string' ? value : setting.default
}

export function numberSetting(values: SettingValues, id: string): number {
  const setting = declared(id, 'number')
  const value = coerce(setting, values[setting.id])
  return typeof value === 'number' ? value : (setting.default as number)
}

/** The current value of any setting, already coerced. For generated controls. */
export function valueOf(values: SettingValues, setting: Setting): SettingValue {
  return coerce(setting, values[setting.id]) ?? setting.default
}

/* ------------------------------------------------------------- migration -- */

/** Bumped when a shipped settings file needs rewriting rather than merging. */
export const SETTINGS_VERSION = 1

/**
 * Ids that have been renamed, old → new.
 *
 * An id carries its section as a prefix, so moving a setting between sections
 * *is* a rename — and a rename with no entry here is a user's choice silently
 * reverting to the default the first time the new build reads their file.
 * `mergeSettings` applies this before defaults are filled in, and takes an
 * override so a test can prove the mechanism independently of the real table.
 *
 * This is the table the regrouping turns on, and it is why *"when you reorganize
 * you mostly miss the things and you drop some stuff"* is a worry this pass can
 * answer with a mechanism rather than with care. Every id below carries a value
 * somebody chose; without its entry, the first launch of the new build reads
 * their file, finds a key no setting owns, and shows them the default while
 * their choice sits in the file next to it.
 *
 * Four of these are the reverse of an earlier move. General was once rebuilt to
 * hold "the settings people reach for", which pulled the default tool out of
 * Agents and the two notification switches out of Notifications, and pushed
 * launch restore into Advanced. All four are back where their subject is, so
 * their original ids are declared again and their entries have gone — which is
 * exactly what a rename table doing its job looks like from the outside.
 *
 * A prefs-backed id (`defaultProvider`, `restoreSessions`, `notifyOnComplete`)
 * keeps its value regardless — `valuesFromPreferences` reads it by `prefsKey`,
 * not by id — but it is listed anyway, because a settings.json written by any
 * build that mirrored those keys would otherwise arrive as an unknown key and
 * sit there.
 */
export const RENAMED_IDS: Readonly<Record<string, string>> = {
  /* Two builds ago the finish sound was `notifications.sound`; it is not called
     that now because `notifications.soundName` — which sound — is beside it,
     and two keys a character apart is a bug waiting for a tired reader. */
  'notifications.sound': 'notifications.onFinishSound',
  /* This pass: the four rows that moved to the section their subject is in. */
  'general.soundOnFinish': 'notifications.onFinishSound',
  'general.notifyOnAttention': 'notifications.onNeedsInput',
  'general.showInsightAlerts': 'notifications.showInsightAlerts',
  'general.defaultProvider': 'agents.defaultProvider',
  'advanced.restoreSessions': 'general.restoreSessions',
}

export interface MergeOptions {
  renames?: Readonly<Record<string, string>>
}

/**
 * Fill in what is missing, fix what is wrong, keep what we do not recognise.
 *
 * The last clause is the load-bearing one. A settings file is shared with
 * whatever version of the app runs next, and dropping a key this build has
 * never heard of is how a downgrade — or one agent's build meeting another's —
 * silently wipes a setting the user chose. Unknown keys ride along untouched;
 * known keys with impossible values fall back to their default rather than
 * poisoning a control.
 */
export function mergeSettings(raw: unknown, options: MergeOptions = {}): SettingValues {
  const renames = options.renames ?? RENAMED_IDS
  const merged: Record<string, unknown> = { ...DEFAULT_VALUES }
  if (!isRecord(raw)) return merged

  for (const [storedKey, storedValue] of Object.entries(raw)) {
    // __proto__ arrives as a plain own key from JSON.parse, but assigning it
    // through a computed property would walk the prototype instead of the map.
    if (storedKey === '__proto__') continue
    const key = renames[storedKey] ?? storedKey
    const setting = BY_ID.get(key)
    if (!setting) {
      merged[key] = storedValue
      continue
    }
    const value = coerce(setting, storedValue)
    merged[key] = value === null ? setting.default : value
  }

  return merged
}

export interface SettingsFile {
  version: number
  values: SettingValues
}

/**
 * Read a settings file of any age.
 *
 * Two shapes exist: the `{ version, values }` envelope, and — for anything
 * written before the envelope — a bare map of ids. Both merge to the same
 * thing, so a file that predates versioning is upgraded rather than discarded.
 */
export function migrateSettingsFile(raw: unknown, options: MergeOptions = {}): SettingsFile {
  if (isRecord(raw) && isRecord(raw.values)) {
    return { version: SETTINGS_VERSION, values: mergeSettings(raw.values, options) }
  }
  return { version: SETTINGS_VERSION, values: mergeSettings(raw, options) }
}

/* --------------------------------------------------------------- routing -- */

export interface SettingsSplit {
  /** Goes to `prefs:set` — store.ts's state.json. */
  prefs: Partial<Preferences>
  /**
   * Goes to `settings:set` — settings-extra.ts's settings.json.
   *
   * `null` is a real value here and means *delete this key*, which is what
   * `applyPatch` in the store already does with one. Only a keyed row can send
   * one — see {@link isKeyedSettingId} — because a declared setting always has
   * a default to go back to and a keyed one is the row itself going away.
   */
  extra: Record<string, SettingValue | null>
  /** Ids that are not in the schema. Never written; returned so a caller can log. */
  unknown: string[]
}

/**
 * The one family of settings keys that is not a row in the table above.
 *
 * Every other setting in this app is declared: one id, one control, one
 * default. A person's own terminal colour schemes cannot be, because there is
 * no fixed number of them — they are made, renamed and deleted while the app is
 * running, and each one is a key of its own so that no single string can grow
 * past the store's 4096-character cut (`terminal-theme.ts` carries that
 * argument in full).
 *
 * So the prefix is declared instead of the ids, and this is the *only* prefix.
 * It is deliberately not a general escape hatch: `splitPatch` accepts a string
 * or a delete under it and nothing else, which keeps the settings file what its
 * store says it is — a list of small choices, not a document store — while
 * still letting one feature keep a list that a person owns.
 */
export function isKeyedSettingId(id: string): boolean {
  return id.startsWith(CUSTOM_SCHEME_PREFIX) && id.length > CUSTOM_SCHEME_PREFIX.length
}

/**
 * Route a patch to the file that owns each key.
 *
 * The cast at the end is checked, not assumed: `settingsSchemaProblems()` runs
 * in a test and fails if a prefs-backed setting's declared kind and options do
 * not match the Preferences field it claims — which is the only way a coerced
 * value could be the wrong type by the time it lands here.
 */
export function splitPatch(patch: Readonly<Record<string, unknown>>): SettingsSplit {
  const prefs: Record<string, SettingValue> = {}
  const extra: Record<string, SettingValue | null> = {}
  const unknown: string[] = []

  for (const [id, raw] of Object.entries(patch)) {
    /*
     * A keyed row — one of somebody's own colour schemes — before the table is
     * consulted, because there is nothing in the table to consult. `null` is
     * kept rather than dropped: it is how the picker deletes a scheme, and
     * `applyPatch` in the store removes a key set to one.
     */
    if (isKeyedSettingId(id)) {
      if (raw === null) extra[id] = null
      else if (typeof raw === 'string') extra[id] = raw.slice(0, MAX_KEYED_LENGTH)
      else unknown.push(id)
      continue
    }
    // Through `lookup`, so a write under an old name lands on the row it now
    // belongs to rather than being rejected as unknown. The value is stored
    // under `setting.id` below either way, so an alias can never split one
    // setting into two keys on disk.
    const setting = lookup(id)
    if (!setting) {
      unknown.push(id)
      continue
    }
    const value = coerce(setting, raw)
    if (value === null) {
      unknown.push(id)
      continue
    }
    if (setting.store === 'prefs' && setting.prefsKey) prefs[setting.prefsKey] = value
    else extra[setting.id] = value
  }

  return { prefs: prefs as Partial<Preferences>, extra, unknown }
}

/** Schema values for the four keys store.ts holds, so the two can be merged on load. */
export function valuesFromPreferences(prefs: unknown): Record<string, SettingValue> {
  const out: Record<string, SettingValue> = {}
  if (!isRecord(prefs)) return out
  for (const setting of SETTINGS) {
    if (setting.store !== 'prefs' || !setting.prefsKey) continue
    const value = coerce(setting, prefs[setting.prefsKey])
    if (value !== null) out[setting.id] = value
  }
  return out
}

/** Every default, as a patch. What "reset all settings" writes. */
export function defaultPatch(): Record<string, SettingValue> {
  return Object.fromEntries(SETTINGS.map((setting) => [setting.id, setting.default]))
}

/* ------------------------------------------------------------ self-check -- */

/**
 * Everything wrong with the table, in English. Run by the test rather than at
 * import time — a broken schema should fail a build, not a user's launch.
 */
export function settingsSchemaProblems(settings: readonly Setting[] = SETTINGS): string[] {
  const problems: string[] = []
  const seen = new Set<string>()

  for (const setting of settings) {
    if (seen.has(setting.id)) problems.push(`duplicate id: ${setting.id}`)
    seen.add(setting.id)

    if (!setting.id.startsWith(`${setting.section}.`)) {
      problems.push(`${setting.id}: id should start with its section`)
    }
    if (setting.help.trim() === '') problems.push(`${setting.id}: no help text`)
    if (setting.label.trim() === '') problems.push(`${setting.id}: no label`)

    /*
     * The word budget, enforced from the table rather than from a render test.
     *
     * A ceiling here is the only version of this rule that cannot be worked
     * around by accident: the rows are generated, so the *only* place a long
     * description can come from is this field, and a new setting written with a
     * paragraph in it fails the build instead of quietly making the pane taller
     * than the last person left it. `more` is the pressure valve, and it is
     * capped too — a tooltip nobody can read in one go is a paragraph that has
     * moved rather than one that has been cut.
     */
    if (setting.help.length > MAX_HELP_LENGTH) {
      problems.push(
        `${setting.id}: help is ${setting.help.length} characters; the cap is ${MAX_HELP_LENGTH} — put the rest in \`more\``,
      )
    }
    if (setting.more !== undefined) {
      if (setting.more.trim() === '') problems.push(`${setting.id}: \`more\` is empty`)
      if (setting.more.length > MAX_MORE_LENGTH) {
        problems.push(
          `${setting.id}: \`more\` is ${setting.more.length} characters; the cap is ${MAX_MORE_LENGTH}`,
        )
      }
      if (setting.more.trim() === setting.help.trim()) {
        problems.push(`${setting.id}: \`more\` only repeats \`help\``)
      }
    }

    const hasPrefsKey = setting.prefsKey !== undefined
    if (setting.store === 'prefs' && !hasPrefsKey) problems.push(`${setting.id}: prefs-backed but no prefsKey`)
    if (setting.store === 'extra' && hasPrefsKey) problems.push(`${setting.id}: extra-backed but has a prefsKey`)

    if (coerce(setting, setting.default) === null) {
      problems.push(`${setting.id}: its own default fails coercion`)
    }

    if (setting.kind === 'select') {
      // One option is allowed and no row uses it today — `general.language`,
      // which did, has gone. The allowance stays because the rule it protects
      // is in `SettingControl`, not here: a one-option select is *drawn as a
      // value*, so a schema that rejected one would push the next person into
      // faking a second option to get a row on screen. Zero options is still a
      // bug — the control renders empty and can store nothing, so `coerce`
      // would reject the setting's own default.
      if (setting.options.length === 0) problems.push(`${setting.id}: a select needs an option`)
      const values = new Set<string>()
      for (const option of setting.options) {
        if (values.has(option.value)) problems.push(`${setting.id}: duplicate option ${option.value}`)
        values.add(option.value)
      }
    }

    if (setting.kind === 'number' && setting.min >= setting.max) {
      problems.push(`${setting.id}: min is not below max`)
    }
  }

  const prefsKeys = settings.filter((s) => s.prefsKey).map((s) => s.prefsKey)
  if (new Set(prefsKeys).size !== prefsKeys.length) problems.push('two settings claim one prefsKey')

  return problems
}
