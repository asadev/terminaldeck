What to test — 0.10.3

**Start here: start a session on a server that has nothing open on it.** Last
build this was impossible. Every first session on a fresh Linux host came back
"This machine could not keep a session inside that folder, so it did not start
one. Check it on the machine itself." Nothing was wrong with the folder and
nothing was wrong with the server.

The cause was the safety check itself. Before every session the host puts two
marker files *outside* the boundary it is about to build, then proves neither
can be read from inside it. One of those markers goes in the account's home
directory — and on a server with nothing open, the folder you are given **is**
the home. So the marker landed inside the boundary, the check decided it could
not prove anything, and refused. It now refuses only when *both* markers are
inside; one inside is fine, because the other is still outside and still doing
the job. Measured on a real rented Ubuntu box, both ways round.

**Then: choose a folder.** The other half of the same complaint — the phone
offered exactly one folder on a bare server, the account's home, and no way to
reach a project three directories down.

It turns out the phone could always *start* a session anywhere; it had no way to
*look*. Tap **+ → Choose a folder…** and walk the machine's directories. Tapping
a folder goes into it, the button at the bottom starts a session in the one you
are standing in, and it names it. Folders your account cannot open are shown
dimmed with a lock rather than hidden — a folder you know is there and cannot
see reads as a broken picker.

This is offered only to a device paired as one of your own, never to a guest.

**The server page is back.** Sign in to a server and it appeared in Machines
having apparently never connected: no details, and no way to disconnect. The
line that recorded which machine your server had become was attached to a piece
of the screen that gets replaced at the exact moment the connection succeeds, so
it never ran. It is on the screen itself now. While it was open: the server can
be **renamed** — the app could always do it and offered it nowhere — and a
headless box draws as a server rather than as an iMac.

**Localhost and Watch browser are now one tab: Browser.** They were two places
to look at a page living on your machine, one of them three rows deep in
Settings. There is one pill now, with the address bar **on the screen** instead
of behind a `+`. Type a port and it opens through a tunnel exactly as before;
type a real site and it opens in the machine's own browser and appears under
**Windows** further down the same screen, which you can watch and drive.

**It stops calling your Linux server a Mac.** Twenty-one sentences across
transport, tunnels, uploads, the browser and the session list said "the Mac"
whatever was actually at the other end. The app knows the difference now and
says server, Mac or PC accordingly.

**And it looks like itself.** The app wore white paper with grey cards, which is
iOS's own default grouped-list look and therefore no character at all. It is
warm paper with white cards floating on it now, with larger corner radii and
lighter, larger row icons throughout. Worth a look in both light and dark, and
worth telling us if any screen reads worse than it did.

Also fixed: the last row of the Terminal appearance screen and the scheme editor
sat behind the floating tab bar.

Known: the six desktop panels — Files, Source control, Artifacts, Store, AI
readiness, MCP servers — are still desktop-only. They are the next release.
