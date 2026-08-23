What to test — 0.10.0

Start here: Log in to a server. Last build the add-server page asked for a
"server address" — a token only a machine already running Terminal Deck prints —
and, when you had none, offered a curl command to copy and go and run somewhere
else. That command is gone. The phone signs in to a server over SSH itself now.

Two doors to it. On a phone with nothing on it yet it is "Log in to a server
instead", under the six-digit code field. On a phone that already has something
it is Settings > Machines > Log in to a server.

What it asks for: the address, the port, the username, and a password or a
private key — the four things you already have for any server. Leave the port
empty for 22; a server on another port (2222, say) works and is the case that
used to be impossible.

What should happen next: it signs in, checks the server's identity, and lands on
that server's own page — what the machine is, how much disk and memory, what is
running on it, what is listening — and a card at the top saying whether the
headless host is on it.

If it is not there: an "Install it on this server" button, with the installer's
own output as it happens and the real error if it fails. If it is there: Start,
Stop, and Connect. Connect signs this phone in to the host through the relay and
the server appears as a machine like any other; Disconnect takes that away and
leaves the server itself alone.

Fingerprints: the login shows the server's SHA256 fingerprint once, and it is the
same string `ssh-keyscan <host> | ssh-keygen -lf -` prints. Every later
connection is checked against it, and a server answering with a different key is
refused before your password is offered.

What will not work, and says so rather than failing oddly: an RSA private key —
this phone signs with Ed25519 and ECDSA — and a key with a passphrase on it. Both
are refused by name with what to do instead.

Known gap: what the phone installs comes from the npm registry, and the newest
published host is older than this app. It installs and runs; it is too old to
print the address Connect needs, and the page says so where the button would be.
Installing from a desktop Terminal Deck puts the current host on.

"I have a server address instead" is still at the foot of the login, for a host
somebody sent you an address for.

The rest, unchanged from the last build:

Sign in. The pairing screen also takes a full sign-in link, not only a code.

Devices. Settings > Devices lists every phone, browser and desktop signed in to
the machine you are on. This phone is marked. Removing a row cuts that device off
immediately.

Server settings. Further down Settings are the machine's own settings — the
coding tool it starts sessions with, whether it restores sessions at launch.
They belong to the machine, not the phone, so every device sees the change.

Controls. Open a session with an agent in it, open Controls, and set model,
effort or permission mode. The change lands on the machine running it.

Watch the browser. A machine with a browser window open shows it under Watch
browser. It streams full screen and your keystrokes drive the real browser.

Version. The About row reads 0.10.0, and the app now says when the machine it is
talking to is on a different build than itself.
