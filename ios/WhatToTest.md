What to test — 0.4.0, build 2608180034

This is the whole 17 August review, on the phone. Your last build is 0.3.0 from
16 August; the desktop has since tagged 0.4.0 and the phone follows it, because
they are one product and two numbers that disagree cannot tell you at a glance
whether your phone is too old to talk to your Mac.

FOUR TABS, COPILOT FIRST
"Copilot · Sessions · Localhost · Settings", copilot leftmost, as you asked
after looking at it with the copilot in place. The pinned copilot row is gone
from the session list — its badge moved onto the pill, which is strictly better,
because a consent question expires into a refusal after two minutes and a badge
on the session list could only ever be seen from the session list.

Open a session from inside the copilot conversation and press Back: you should
land back in the conversation, not on the session list.

SWIPE, AND IT DOES SOMETHING NOW
Swipe was opening the session, which tapping already did. Now: swipe right to
Pin or Unpin, swipe left for Archive, Details and Close. Neither edge does a
full-swipe, so nothing fires from a careless drag.

Archive is a shelf, not an ending — the session keeps running, and the Archived
screen says so in as many words. Bring one back with the same swipe. Close
genuinely ends the session and asks first, because it cannot be undone.

Two things worth being hard on. Pin and archive cancel each other, so pinning an
archived session should unarchive it; and if you archive everything the empty
state should say "All archived" rather than blaming your Mac for an empty list.

Move became Pin, deliberately. On a phone there is nowhere for a session to move
to — it is a shell in a folder fixed when it started. What somebody dragging a
row in a list of forty actually wants is that row at the top.

LOCALHOST TAKES AN ADDRESS
The "+" replaces the old Refresh button: type "3000", or "localhost:3000", or
"127.0.0.1:3000/admin", and it opens on the machine you are inside. That reaches
ports the list has folded away or has not rescanned, and paths — neither was
reachable before.

A live link is refused on purpose, and it says so, naming the machine. Driving
your Mac's browser from a phone is a way to put any page you like in front of
somebody in trusted chrome, and loading it in the phone's own web view instead
would be the web-view-pretending you said you did not want.

REFRESH AND RECONNECT ARE GONE
You asked what they actually did. Refresh sent exactly the frame that pulling
the list down already sends — a duplicate of a gesture you named yourself.
Reconnect asked for something the app already does on foreground, on a network
change, and on a backoff; a button for it is an admission it might not work.
The one manual retry left appears only when the connection is down AND is not
already retrying, which is the one moment you are staring at nothing.

So: pull both lists down to refresh, and please try to catch the app failing to
come back by itself — turn off Wi-Fi, wait, turn it on; lock the phone for five
minutes; switch to cellular mid-session.

PAIRING NOW ASKS WHOSE DEVICE THIS IS
"My device" is you at another keyboard: every session, any folder, the copilot.
"Guest" reaches only the folders you tick and is never offered the copilot at
all. You cannot change one into the other afterwards — that means pairing again,
which is the honest cost of not making an escalation one tap deep.

IMPORTANT: this phone will need re-pairing. A device paired by an older build
has no kind recorded, and the app now reads that as a guest with nothing rather
than as permission for everything. That is deliberate.

THE COPILOT, IN FULL
Its own connection, separate from the one carrying sessions, with its chat, its
tools and its consent prompts. Driving is not here — text is enough on a phone
for now.

WHAT IS NOT HERE
The driving tour and its scanning view are desktop and web only.
