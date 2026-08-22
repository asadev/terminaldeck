What to test — 0.10.0

Start here: Add a server. Last build you looked for a way to pair the phone with
a server and there was none — the wire was in, the screen was not. It is in now,
and it is the first thing to check.

Two doors to it. On a phone with nothing paired yet it is "Add a server instead",
under the six-digit code field. On a phone already paired it is Settings >
Machines > Add a server. Both open the same form.

Getting the address. On a server, run: terminaldeck address — it prints one line
beginning srv1. and nothing else, so it can be copied straight out of the
terminal. On a machine running the desktop app, open its server page and use the
"Address for a phone" block, Copy. terminaldeck status prints the same address
under "Server address". That string is not a secret: it carries a public key and
a name at the relay and grants nothing on its own.

Filling the form. Paste the address (the Paste button beside the label puts it in
without an Allow Paste alert), type the username you would use to SSH into that
machine, then either a password or a private key. Private key is the other half
of the segmented control: it takes a paste, not typing, and it will say how many
characters landed — a key must be unencrypted, one with a passphrase on it cannot
be used here. The server checks the login against its own SSH, then issues this
phone a credential of its own. The password itself is not stored by the app.

What should not happen: a spinner that never ends. Every failure lands on a
sentence and puts the form back underneath it. A bad address is refused at the
field. A wrong login says so after the server has answered. Closing the screen
mid-sign-in does not cancel it; the Stop button does.

Then the machine appears in Settings > Machines like any paired one, with its
sessions on the Sessions tab.

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
