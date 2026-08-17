What to test — 0.2.0, build 2608170342

Same version number as the build you have, new build. 0.2.0 went up on 16 August
at 19:36 and everything below was written after it, so your phone still looks
exactly like the build before it.

THREE TABS, MACHINES INSIDE SETTINGS
Sessions, Localhost, Settings. Machines is a row in Settings that pushes to the
same screen it always was. You said "four pills" first and then reconsidered;
this takes the second answer. Say the word if you want it back on the bar.

NO PILL INSIDE A SESSION OR A PAGE
"Inside the session we don't need the pill." Gone in both, and the content took
the space back rather than leaving a gap. Check the last line of output really
sits on the bottom edge with the keyboard down. Still there on the other four
screens, which is where you said it belongs.

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

THE PAGE OPENS SIDEWAYS AND ITS BACK BUTTON WORKS
It slides in like any other screen now, and the left-edge swipe walks the page's
own history. "The back button here doesn't work at all next to refresh" was real:
it only re-checked itself when WebKit announced a page load, and WebKit says
nothing for a route change inside a single-page app, which is every click on a
dev server. Go two or three routes deep; the arrow should stay live and walk back
one route per tap.

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
