# Design brief — 2026-08-15

Asad's direction, in his words where it matters. This is the source of truth for
the UI pass. If a change here disagrees with something already on screen, this
wins.

---

## 1. The feeling

**Terminal *and* deck.** The name is Terminal Deck, so the product should taste
of both: the precision of a terminal, laid out like a deck of things you pick up.

**But simple.** His exact bar: *"stupid simple actually I would say for every
stupid people can easily understand what is what."* Every screen has to be
readable by someone who has never used it. If a choice makes the app cleverer and
harder, it is the wrong choice.

That rules out: dense control strips, options that need a manual, anything that
rewards knowing where to look.

### Terminal in the CONTENT, Apple in the CHROME

Asad also asked for *"apples feel of style"* alongside the terminal feel. Those
sound like opposites and are not, as long as the line is drawn in the right
place. Draw it here:

**The content is a terminal.** Anything that is *data* is set in mono and aligned
to the character: paths, session ids, ports, hostnames, counts, durations, git
refs, command output. Monospace is a promise that the characters are exact and
countable — so it is used where that is true, and nowhere else.

**The chrome is Apple.** The window, the panel, the headers, the settings, the
buttons, the labels. That means, concretely:

- **Whitespace is the layout tool.** Space separates things, not borders. Reach
  for a divider only when space genuinely cannot do the job.
- **Few type sizes.** Hierarchy comes from weight and colour, not from six
  different sizes. Body copy in the system UI face, never mono.
- **One accent, used sparingly.** The blue means "this is the action". A screen
  where four things are blue has no accent at all.
- **Depth by layering, not outlines.** Surfaces sit on surfaces. Avoid boxing
  every element in a 1px rectangle.
- **Motion is short, eased, and earned.** It exists to explain where something
  came from. No decorative movement — his standing rule is strategic motion only.
- **Sentence case, plain words.** "Keep this Mac awake", not "Enable Persistent
  Wake State". No invented product nouns for ordinary things.
- **Real states on everything.** Hover, active, focus, disabled. A control that
  looks pressable must respond — a hover state is a promise.
- **Alignment is not negotiable.** Everything lands on the same grid. Optical
  misalignment is the thing that makes an app feel amateur even when nobody can
  name why.

So: a calm, spacious, unmistakably Mac-native shell — with a precise, dense,
monospaced terminal living inside it. The contrast between the two is the look.
Neither should bleed into the other: no mono labels on buttons, no rounded pastel
chrome around terminal output.

## 2. Colour

**Primary is BLUE.** Not orange.

> *"don't choose the orange color because it's already with Claude and other
> applications and it's not nice to keep their color maybe let's use blue instead
> as we have a blue in our logo also I like the logo by the way"*

The logo is the reference — take the blue from it rather than inventing one.
Orange must not survive anywhere as the accent.

**Dark mode gets a neutral dark grey.** Today it carries a faint orange cast; he
can see it and does not want it. Neutral greys, no warm tint.

## 3. Text with long descriptions

Where an option needs a paragraph to explain itself:

- Title in a **brighter white**
- Description **dimmer**, clearly secondary
- **More space** between them, and around the block

This is the Claude-app treatment and it is already right in places — do not
rewrite screens that already do it. Apply it where it is missing.

## 4. Settings

**Stop opening a full page.** Settings becomes a **large modal**, with its own
**side panel inside the modal** listing the sections. Pick a section on the left,
read it on the right, close the modal and you are back where you were.

## 5. The side panel and its close button

- The close button currently lives **inside the header**. Move it **next to the
  window buttons** (minimise / maximise / close).
- The panel's edge needs a **better separation** — the arrow reveals it on
  approach, and clicking pins it open. The Claude behaviour, exactly.

## 6. Top-right header

A small set of mode switches lives here: **terminal**, **browser**, and the like.
Not a dumping ground — the few things you switch between while working.

## 7. iOS simulator pane

Claude's app embeds an iOS simulator; he wants the same, available in **both**
terminal mode and chat mode.

- If building a native pane is not hard, build it.
- If it is hard, **embed the simulator already installed on the machine** rather
  than shipping our own.
- If neither is honest, say so rather than shipping a pane that half works.

## 8. Starting a session

**A new session starts immediately.** No dialog, no folder picker in the way.

- It opens in the **folder used last**.
- Before anything is typed, the location is still **changeable** — visible and
  one click, the way Claude does it.

## 9. Things that move or go

- **Task board — remove it.** Not wanted.
- **Alerts — move.** Off the top header; put them near Settings.
- **Update notifications — move.** They belong **above Settings**, not in the top
  header.
- **MCP servers — there is no Add button.** Only reload. Either add one, or, if
  servers genuinely cannot be added from here, say that on screen. Silence reads
  as broken.

## 10. Chat composer

> *"it's very messy with a lot of options under the chat box"*

Redesign it as **one large chat box with the options folded neatly inside it** —
the Claude shape. Controls appear when relevant, not all at once, and never as a
row of unexplained icons under the input.

---

## Rules that outrank taste

1. **No dead controls.** Anything that looks clickable must do something. A
   hover state is a promise.
2. **Nothing fake.** No placeholder data, no feature that only appears to work.
3. **Verify in the real app.** A change is not done because the code looks right;
   it is done when it has been rendered and looked at.
4. `src/shared/brand.ts` owns the name. Read `BRAND.name`; never spell it out.
