What to test — 0.1.8

The last build you had was 0.1.4 from 13 August, which is why the app looked
unchanged: everything below landed after it and none of it had ever reached a
phone. Four days of work, one build.

THE KEY BAR AND THE GRID
The old bar was twenty-six buttons in one horizontal scroll, with "dismiss"
last — so putting the keyboard away meant scrolling past every symbol first.
Now the bar never scrolls. It holds only what you press while typing a command,
with "more" and "dismiss" pinned hard right where they cannot move, and
everything else lives in a grid that opens where the keyboard was, grouped and
labelled. Check: can you reach dismiss without hunting, and does every key in
the grid do what its label says — Ctrl-C, Tab, Esc, arrows, home, end, page
up/down.

ONE FINGER SCROLLS, LONG PRESS SELECTS
Drag with one finger to scroll the scrollback, with momentum. Press and hold for
half a second to select the word under your finger, then drag to extend it, and
let go for the Copy callout. This is the Safari and Notes behaviour. Check that
a plain drag never accidentally selects, and that Copy actually puts the text on
the pasteboard — an earlier attempt reported success and copied nothing.

FIND IN THE SCROLLBACK
The magnifier in the terminal's toolbar. Typing searches backwards from the
bottom, because the interesting line is almost always the most recent one, so
the up arrow walks further back and the down arrow comes forward. Check the
match counter against a long build log.

PINCH TO SIZE THE TEXT
Two fingers on the terminal. This is not a zoom — it changes the real column
count and tells the far end to reflow, so a table that wraps at twelve point
should stop wrapping at ten. The size is one setting for the whole phone, not
per session.

SHARE THE OUTPUT
The share button sends the whole scrollback as a .txt file, not as a message
body — so it arrives as an attachment and AirDrops to the Mac. Copy still takes
the screen or a selection; these are meant to be two different tools.

THE VISUAL PASS
The accent is now the blue from the app icon rather than orange, and dark mode
is a neutral grey with the warm cast taken out. Terminal selection is that same
blue at half strength instead of SwiftTerm's teal, so it matches the iOS drag
handles drawn over it. Tell me anything that still looks like the old colour.

MACHINE NAMES
One phone can hold several machines. Each has a name you can change — the menu
says "Rename this machine" and names the one you are on, and "Forget <name>"
does the same, so unpairing cannot hit the wrong one. Check that the name you
set survives a restart and that the session list always says which machine you
are looking at.

FOLDER GRANTS
New Session now offers exactly the folders that machine granted this device, and
nothing else. Previously it guessed from the sessions it happened to see, which
is the one-folder bug. A machine that granted nothing shows no button and a
sentence saying where to fix it, rather than a button that gets refused.

ALERTS
The app can now tell you when a session stops and wants an answer, or finishes.
It is honest about what it cannot do: there is no push service in this product,
so nothing can wake the app in your pocket. Anything that happened while it was
asleep is caught up on reconnect and reported as one summary line rather than
faked as live. The alerts screen says this on screen — check it is clear rather
than clever.

GITHUB FROM THE PHONE
When git on the Mac wants a GitHub login, the phone can answer with the account
it holds, and a guest session no longer inherits the host's account.

KNOWN AND DELIBERATE
iPhone only — no iPad layout has been designed or tested, so it is not offered.
Direct tailnet connection is written but has still not been driven against a
real desktop; the relay path is the one that has.
