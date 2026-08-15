# You are on a real Linux machine

Everything you type in this window runs on a small server in Germany. Nothing
runs on the phone — the phone is drawing characters and sending keystrokes, the
way an SSH client does.

Some things worth trying:

    uname -a          which machine this is
    ls -la            this folder
    git log           this folder is a real git repository
    top               it is a real kernel with real processes
    cat /etc/os-release

## What is different about this particular machine

It is yours alone, and it is thrown away when you disconnect. Break whatever you
like — `rm -rf`, a fork bomb, filling the disk. The next visitor gets a new
container built from the same read-only image, so there is nothing here you can
damage for anybody else.

Outbound network is deliberately switched off apart from the connection that
carries this session. `git clone`, `npm install`, `curl` and `ping` will not
reach the internet from here. That is the demo being careful; it is not the app
failing.

## What this is a demo *of*

Terminal Deck runs on a computer you own — your Mac, your PC, a Linux server —
and this app is how you reach the sessions on it from a phone. The desktop app
is at <https://terminaldeck.dev>. Once it is running on your own machine, the
pairing you just did is the same pairing, and the folder you land in is a folder
you chose.
