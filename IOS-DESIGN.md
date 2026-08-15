# iOS — design pass

Asad, 2026-08-15: *"on ios side its too basic currently give it a better design
too"*, and one specific bug about the key bar.

Read `DESIGN-BRIEF.md` first — **terminal in the content, Apple in the chrome**
applies here too, and on iOS the Apple half is not a metaphor. Native spacing,
native type scale, native materials.

---

## 1. The key bar — the bug

`ios/TerminalDeck/Terminal/KeyboardAccessory.swift` puts **26 buttons in a single
horizontal `UIScrollView`**, and adds the dismiss button (`keyboard.chevron
.compact.down`) **last**. So the control people reach for most often is the one
furthest away: you scroll past `| / \ - _ ~ : *`, `^C ^D ^Z ^L`, home, end, pgup,
pgdn, copy and paste before you can put the keyboard down.

A long scroll is also the wrong shape for this. You cannot see what is in it, you
cannot build muscle memory for a position that moves, and every key costs a swipe
plus a hunt.

### What replaces it

**A fixed bar that never scrolls, plus a grid that opens below.**

**The fixed bar** holds only the keys used constantly while typing commands, and
two pinned buttons on the right that never move:

- `⊞` **more** — opens the grid
- `⌄` **dismiss** — puts the keyboard away, always visible, never scrolled to

Candidates for the fixed set, in frequency order: **esc, tab, ctrl, ↑, ↓, ←, →**.
Take as many as fit *on the narrowest supported iPhone* and move the rest to the
grid. **The bar must not scroll at all** — if it scrolls, the layout is wrong.
Verify on the smallest device width, not on a Pro Max.

**The grid** opens where the keyboard was:

- Tapping `⊞` **dismisses the keyboard and puts the grid in the space it
  occupied.** Same height, so the terminal above does not jump. This is the whole
  trick: one surface swaps for the other.
- Tapping `⊞` again, or the dismiss button, closes the grid.
- Tapping into the terminal brings the keyboard back and closes the grid.

**Grid contents** — everything not on the fixed bar, in labelled groups so it can
be read rather than hunted:

| Group | Keys |
|---|---|
| Edit | copy, paste |
| Signals | ^C, ^D, ^Z, ^L |
| Navigation | home, end, pgup, pgdn, and whichever arrows did not fit above |
| Symbols | `\|` `/` `\` `-` `_` `~` `:` `*` |
| Modifiers | alt/meta, function keys |

Grouped and spaced, not a wall of identical squares. Group headers in the dim
secondary colour from the design brief.

### Decided: no cmd, no win — alt/meta instead

Asad asked for **cmd** and **win** keys and then left the call to me. **They are
out.**

A PTY cannot receive them. A terminal sees Ctrl, Alt/Meta and Esc sequences, and
there is no byte for Command or the Windows key — so those buttons would send
nothing at all. A control that does nothing is exactly what the rest of this
document is trying to remove, and putting two of them in a brand-new grid would
be a strange way to start.

**`alt`/`meta` takes their place.** It is the real key, it is what most "Cmd-ish"
terminal habits actually map to (`alt-b`, `alt-f`, `alt-.`), and it sends the ESC
prefix a shell genuinely acts on.

Sending Command to the *host operating system* — as opposed to the shell — is a
real and interesting feature, and a completely different one: it means driving
the desktop's GUI from the phone, not typing into a terminal. If that is ever
wanted it gets designed on its own. It does not get smuggled in as a key cap.

### Decided: what stays on the fixed bar

**`esc` `tab` `ctrl` `↑` `↓`**, then pinned hard right: **`⊞` more** and
**`⌄` dismiss**.

Seven targets. At a 44pt touch target that is about 350pt of content, which fits
the narrowest supported iPhone at 375pt with room for the gaps. Adding `←` and
`→` would need roughly 396pt and would bring back the scroll this change exists
to remove, so **the left and right arrows go into the grid's Navigation group.**

The reasoning, so it can be argued with later: `↑`/`↓` recall history and are
pressed constantly; `←`/`→` only matter while editing a line you are already
looking at, which is rarer and survives one extra tap. If that turns out to be
wrong in daily use, swap them — but the bar does not grow, and it never scrolls.

## 2. Gestures in the terminal

Asad: *"let it scroll with one finger and copy with longpress and drag"*. That is
the iOS convention and it is the right call — it is how Safari, Notes and Mail
already behave, so nobody has to be taught it.

| Gesture | Does |
|---|---|
| **One finger, drag** | **Scrolls** the scrollback. With momentum and rubber-band, like any iOS scroll view. |
| **Long press** | Starts a **selection** at that character, and holding-and-dragging extends it. |
| **Drag a selection handle** | Adjusts the selection, with the standard magnifier. |
| **Release** | The system **Copy** callout appears over the selection. |
| **Tap** | Dismisses a selection; otherwise focuses the terminal and raises the keyboard. |

The whole point is that **one finger scrolls**. Scrolling is the common act by a
wide margin, so it gets the cheapest gesture; selecting is deliberate, so it gets
the deliberate one.

### The two traps here

**1. SwiftTerm has its own opinion.** `TerminalView` ships gesture recognisers
for selection and scrolling already, and they are not this arrangement. They have
to be reconciled deliberately — reordered, or replaced — not merely have new
recognisers stacked on top. Two recognisers both claiming a one-finger drag
produces a view that sometimes scrolls and sometimes selects, which is worse than
either behaviour chosen consistently.

**2. A selection dies when you touch outside the terminal.** This is already
documented in `TerminalScreen.swift`: a "Copy Selection" menu item had to be
removed because *reaching the menu destroyed the selection on the way there*.

So the copy affordance must be the **system callout attached to the selection
itself**, which is the one place a selection survives being acted on. Do not add
a copy button elsewhere on the screen and expect it to work — that exact idea has
already failed once in this codebase.

## 3. The rest of the iOS app

*"too basic"* — the fix is the design brief applied natively, not decoration.

- **Spacing before dividers.** The session list is currently rows separated by
  hairlines. Let space do that work; keep a divider only where space cannot.
- **Type hierarchy.** Session name prominent; folder path in **mono, dimmed** —
  it is data, and the brief says data is mono. Status and time quieter still.
- **One accent.** The blue means "act". If several things on a screen are blue,
  none of them are the action.
- **Empty and error states get the same care as the happy path.** They are the
  screens people see when something is wrong, which is when the app is judged.
- **Real states everywhere** — pressed, disabled, loading. A row that looks
  tappable must respond.
- **Native materials for chrome.** Standard iOS bars, sheets and blur. Do not
  hand-roll something that iOS already does better.
- **The terminal stays a terminal.** Mono, tight, exact, character-aligned. None
  of the chrome softening bleeds into it.

## 3. Do not break what is proven

These are verified working against a real desktop and must survive the redesign:
multi-host switching, inspect mode delivering one line to the host PTY, the
localhost tunnel, clipboard both ways, and file upload. Re-test each after the
visual pass rather than assuming a layout change was only a layout change.
