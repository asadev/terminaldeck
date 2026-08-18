What to test — 0.3.0, build 2608170549

A new version number, not just a new build. The build you have is 0.2.0 from
16 August at 19:36; the desktop has since tagged 0.3.0, and the phone follows it
because they are one product — if the two numbers disagree you cannot tell at a
glance whether your phone is too old to talk to your Mac.

So everything below is new to you. The previous build looked identical to the
one before it; this one does not.

LIGHT MODE, AND A SETTING FOR IT
"Mobile iOS is only dark mode — it should have both, in settings." Settings →
Appearance → System, Light or Dark. System is the default and it really does
follow the phone, including when the phone crosses into its own dark schedule
with the app open.

The app was held dark in three places, not one, and the one that mattered was in
the bundle: an Info.plist key that forces every window dark before any screen gets
a say. Nine screens also stated it for themselves. All of it is gone, so please
be hard on the light half specifically — it is the half that has never shipped.
Worth looking at: a white band where a grey one should be, a card that looks
lighter than the page under it, and text sliced at the top or bottom of a scroll.

The terminal is the part to be hardest on. On paper it is a recessed grey, the
same one the Mac uses, and the sixteen ANSI colours are a different sixteen — a
light terminal wearing dark-mode colours has yellow at 2:1, which is a colour you
cannot read. Put a real agent in a session in Light and check its output: diffs,
prompts, progress bars, anything coloured.

One thing that is a limit rather than a bug, so that it does not get reported as
one: a program that emits 24-bit colour picks its own greys, and a program that
picked them for a black background is hard to read on paper. That is the same on
the Mac in light mode and there is no palette that fixes it — it is the program
choosing, not us. If a specific tool is unreadable, name it and we can talk about
what to do for that one.

Also: switch the setting while a session is open. The terminal should change under
you, immediately, without losing its scrollback.

THREE TABS, MACHINES INSIDE SETTINGS
Sessions, Localhost, Settings. Machines is a row in Settings that pushes to the
same screen it always was. You said "four pills" first and then reconsidered;
this takes the second answer. Say the word if you want it back on the bar.

NO PILL INSIDE A SESSION OR A PAGE
"Inside the session we don't need the pill." Gone in both, and the content took
the space back rather than leaving a gap. Still there on the other four screens,
which is where you said it belongs.

A LITTLE SPACE AT THE BOTTOM OF A SESSION
"At the bottom we cannot see some stuff because of the mobile's round corners and
the running-agents things." Taking the pill's space back had taken the home
indicator's with it, so the last line was drawn onto the strip the indicator
crosses and the corners clip. With the keyboard down there is now a clear 34
points under the last line — put an agent in a session and check its status row
(the spinner, the token count, "esc to interrupt") is readable end to end,
including the first and last characters, which is where the corner radius bites.

With the keyboard *up* the terminal should still run right down to the key bar
with no empty strip above it: the keyboard already covers what the space was for,
and losing a line of output while typing would be the wrong trade.

LOCALHOST: GROUPED, FOLDED, RENAMEABLE
Ports are grouped by what holds them: named by you, dev servers, web runtimes,
this app's own, other services, unidentified. The last three start folded. Tap a
header to open it; the choice is remembered per machine.

Swipe a row from the left to rename it. A named port jumps to the top group and
keeps its name after a restart — the name is also the pin. Swipe from the right
for the row's other action: Start for an idle dev server, its session for a
running one, the address on the clipboard for a plain port. Neither fires on a
full swipe, on purpose.

If something lands in a group you would not have put it in, tell me the port and
the process name.

THE PAGE OPENS SIDEWAYS, AND ITS CHROME IS THE PHONE'S
"Localhost browsing is still not native on iOS." Two things were still ours that
should have been the platform's, and both are fixed.

The screen keeps the normal navigation bar now — a back chevron top left, the
page's name and address in the title, and the left-edge swipe pops the screen the
way it pops every other screen on the phone. It used to walk the page's history
instead, so the one gesture nobody has to be taught did the wrong thing and there
was no way out with a thumb at all.

Everything a browser needs moved to a toolbar along the bottom, which is where
iOS has kept browser controls since the first iPhone: back a page, forward a
page, reload, inspect, and Done last, where you said it belongs. Forward is new,
and it is there because it had to be — back and forward used to be the two edge
swipes, and giving the left edge back to the system took the right one with it.

"The back button here doesn't work at all next to refresh" was real and is still
fixed: it only re-checked itself when WebKit announced a page load, and WebKit
says nothing for a route change inside a single-page app, which is every click on
a dev server. Go two or three routes deep; back should stay live and walk one
route per tap, forward should come alive behind you, and both should go dead at
the ends.

GITHUB SIGN-IN IS OUR OWN APP NOW
It used to borrow the GitHub CLI's OAuth client, so the consent page said "GitHub
CLI" and the only option was read and write over every private repo. It is
Terminal Deck's GitHub App now, and you pick which repos it may touch — the
screen links to that page. Check it finishes even if you close the sheet before
approving the code; it used to give up.

FEWER NOTIFICATIONS
A session now replaces its own notification instead of adding one, and leaving a
session no longer fires a banner about what you just did. Coming back to the list
should be quiet.

ONE FINGER SCROLLS, LONG PRESS SELECTS
Rest a finger, read for a second, then drag: it must scroll and never turn blue.
Third recording you have reported this in, and the first build where a machine
checked it — a UI test drives that exact gesture against a real Mac and passes.

The other half is on you: hold still for seven tenths of a second and it must
select the word, extend on a drag, and offer Copy that really lands on the
pasteboard. No UI test can hold a finger that long.

THE COPILOT, IF YOUR MAC HAS ONE YET
This is the build the release was held for. On the Sessions tab, above
everything, there is a Copilot row — but only when the Mac you are looking at
actually has a copilot to show. Today's desktop does not, so on 0.3.0 of the Mac
app you will see nothing at all there, and that is correct rather than broken:
the phone does not draw a feature it cannot reach, and it does not send you
looking for a switch that machine has not got.

When the Mac side lands, three things to look at. A phone that has not been
given access says so plainly and names where the switch is, in Settings under
Remote, on this phone's own card — it does not hide the feature and it does not
draw a text field that would be refused. A phone that has been given "watch"
shows what the copilot is doing, what it started and what it was refused, and no
composer. A phone given "ask it to work" gets a Start button that says what it
costs before you press it, and then a text field.

And the one to be hardest on: if a confirmation is waiting at the Mac, the phone
shows it with the countdown running, and there is no Allow and no Refuse on it.
That is deliberate and it is not coming — a phone approving what a phone asked
for is the check doing its own checking. If you ever see a button on that card,
it is a bug.

NOT IN THIS BUILD, THAT YOU ASKED FOR
- Swipe on the sessions list. Closing a session needs a verb the wire does not
  have, so it is a change on the Mac first.
- Stopping a dev server from the phone. Start works; stop has no verb either.
  Open its session and stop it there.
- Screenshot-to-agent and the flow recorder inside the localhost page. The phone
  still only has inspect-an-element.
- A chat view per session. Still an open question, not a decision.

KNOWN AND DELIBERATE
iPhone only. The direct tailnet path is still written and still never driven
against a real desktop; the relay is the one that has been.
