What to test — 0.2.0, build 2608170733

Same version number as the build you already have, new build. 0.2.0 went up on
16 August at 19:36 and everything below was written after it, so the app on your
phone right now looks exactly like the one before this list existed. Two of these
are things you reported three recordings in a row.

THREE TABS, AND MACHINES MOVED INSIDE SETTINGS
The bar is Sessions · Localhost · Settings. Machines is a row inside Settings
that pushes to the same screen it always was — nothing was taken off it, it is
one tap further away, and switching between machines was never done there anyway
(that is the name at the top of the session list, which is still a menu).

You said "four pills" first and then reconsidered on the recording. This build
takes the second answer. If you want Machines back on the bar say so — it is one
line — but walk it first, because the argument for three is that pairing is a
thing you do once per machine and a bottom tab is for the surfaces you move
between all day.

THE PILL IS GONE INSIDE A SESSION AND INSIDE A PAGE
"When this keyboard is down, see the pill is still there. So inside the session
we don't need the pill." It is gone in both places now, and the content took the
space back rather than leaving a gap where the pill used to be — check the last
line of terminal output really does sit on the bottom edge, keyboard down. It is
still there on Sessions, Localhost, Settings and Machines, which is where you
said it belongs.

THE LOCALHOST TAB — GROUPED, FOLDED, RENAMEABLE
"I can already see a big list of local hosts… maybe we can categorize and we can
keep some in the list and we can keep some folded."

Ports are now grouped by what is holding them: things you have named, dev servers
this machine started, web-server runtimes, this app's own ports, other services,
and ones nothing could identify. The last three start folded. Tap a header to
open or close it and the choice is remembered per machine, so a work PC where the
noisy group is the interesting one stays open.

Swipe a row from the left to rename it. A named port jumps to the top group and
keeps its name after the app is closed and reopened — the name is also the pin,
which is why there is no separate pin control. Swipe from the right for the row's
other action: Start for a dev server that is idle, its session for one that is
running, the address on the clipboard for a plain port. Neither swipe fires on a
full swipe, deliberately: the first actions are "rename" and "start a process on
your computer" and neither is a thing to do by accident with a thumb.

Check the grouping against what you know is running — if something lands in a
group you would not have put it in, tell me the port and the process name.

THE PAGE FROM YOUR MAC OPENS SIDEWAYS, AND ITS BACK BUTTON WORKS
"It should not come like this up… feels like a browser opens inside. So give it a
native feel." It slides in from the side now, like any other screen, and the
left-edge swipe goes back through the page's own history the way a browser does.

"The back button here doesn't work at all next to refresh." That one was real and
the cause is worth knowing, because it explains why it looked so dead: the button
only ever re-checked itself when WebKit told it a page had loaded, and WebKit does
not say anything for a route change inside a single-page app — which is every
click in every modern dev server. Click into a site two or three routes deep and
the back arrow should be live the whole way, and should walk back one route per
tap.

GITHUB SIGN-IN IS THIS APP'S OWN REGISTRATION NOW
It used to borrow the GitHub CLI's OAuth client, so GitHub's own consent page said
"GitHub CLI" and the only permission on offer was read-and-write over every
private repository on the account. It is Terminal Deck's GitHub App now, the same
one the Mac signs into: it names this product, and you choose which repositories
it may touch. Signing in is half of it — the screen links to the page where you
pick the repositories, and a token with no installation behind it reaches nothing.

Check: Settings → GitHub, sign in, and let the sheet close before the code is
approved. It should finish anyway and come back signed in; it used to give up the
moment the sheet went away.

FEWER NOTIFICATIONS, AND NONE ABOUT WHAT YOU JUST DID
Two changes. A session now replaces its own notification instead of adding one, so
a session that goes waiting → working → waiting three times in a morning leaves
one banner saying what it is now rather than three, two of them wrong. And leaving
a session no longer fires a banner about it: the Mac takes about a second to
decide what a screen means, which used to land just after you had backed out to
the list, so the app was telling you about something you had done on purpose a
second earlier. Coming back into the list should now be quiet.

ONE FINGER SCROLLS, LONG PRESS SELECTS — STILL THE ONE ONLY YOU CAN CHECK
Rest your finger on the terminal, read for a second, then drag. It must scroll and
never turn blue. This is the third recording in a row you have reported it in, and
this is the first build where a machine has actually checked it: a UI test now
drives that exact gesture — finger down, 0.65 s still, then a slow drag — against
a real Mac and asserts the screen moved and nothing was selected. It passes.

What no machine can check is the other half: press and hold for seven tenths of a
second, and it must select the word, extend on a drag, and offer Copy that really
puts text on the pasteboard. XCUITest cannot hold a finger still that long,
measured. So that half is on you.

WHAT IS NOT IN THIS BUILD, THAT YOU ASKED FOR
Said plainly, because you test from this list.

- **Swipe on the sessions list.** Localhost has it; Sessions does not. Closing a
  session from the phone is not a screen problem — there is no verb on the wire
  for it, so the Mac would have nothing to be told. It needs a change on the
  desktop first.
- **Stopping a dev server from the phone.** Start works. Stop does not exist, for
  the same reason: `dev.start` has no opposite on the wire, and a blind Ctrl-C
  would leave a row advertising an address nothing is answering on. Open its
  session and stop it there.
- **Screenshot-to-agent and the flow recorder inside the localhost page.** The
  Mac's browser has all three; the phone still has only inspect-an-element and
  send it to a session.
- **A chat view per session.** You asked it as a question on the recording and it
  is still a question — there is no Terminal/Chat switch on the phone.

KNOWN AND DELIBERATE
iPhone only — no iPad layout has been designed or tested, so it is not offered.
The direct tailnet connection is still written and still never driven against a
real desktop; the relay is the path that has been.
