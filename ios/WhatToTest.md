What to test — 0.6.0, build TBD

Your last build is 0.5.0 from yesterday. The headline is that the copilot no
longer has a connection of its own, and most of what to test is that absence.

THERE IS NOTHING TO CONNECT ANY MORE
"Instead of giving mobile app separate connection for copilot, just make it like
— if we are connecting as my device, copilot automatically comes. If we connect
as guest then copilot don't come." That is now exactly what happens. The six
digit copilot code is gone, the Connect screen is gone, the Settings row for it
is gone, and there is no state where this phone is paired, trusted, and told to
connect something first.

So the test is: pair this phone again as MY DEVICE, and the Copilot tab should
simply be there, first press, nothing typed. Then pair a second device — an old
phone, a friend's — as a GUEST, and it should have no Copilot tab at all. Not a
greyed one, not one that explains itself. Absent.

Worth being hard on: the credential this app used to keep for the copilot is
deleted from the Keychain the first time you open this build, not merely stopped
being written. And if you were connected on 0.5.0, this build should carry on
working with no ceremony — if it asks you for anything, that is a bug.

THE SAME CHANGE ON THE MAC AND IN THE BROWSER
The desktop's "Connect the copilot" panel is gone with its code and its three
tier checkboxes; the approval screen is where the whole decision is made now. Try
app.terminaldeck.dev too — same rule there, and it clears its old stored key on
every launch.

A SERVER IS A MACHINE LIKE ANY OTHER
New on the desktop, and you will feel it from here: a rented server gets a group
in the sidebar, its shells are ordinary sessions with tab pills, and its private
localhost opens through the same browser window. You add one with an address, a
username, and a password or a key.

Signing in with a key no longer tells you to open the file in a text editor —
the app reads your key folder and offers what it finds by name, and never offers
the .pub sitting next to it.

WINDOWS
A sweep found sixty-two places where the Windows build behaved differently from
the Mac, four of them serious, and this build closes the ones that were
accidents. If you have the PC to hand, the two worth trying are attaching a file
to a chat message — which did not work on Windows at all — and letting a
scheduled routine run, which always failed there. Windows now runs the same test
suite as the Mac on every change, which it never did before.

WHAT IS STILL NOT DONE, SO YOU ARE NOT LOOKING FOR IT
Sessions started from a phone are still not confined on Windows the way they are
on a Mac — the machinery is built and tested, and the button that switches it on
is the missing piece. And the Windows download is still unsigned, so SmartScreen
will still stop you on first run until there is a certificate.
