# Next update — Asad's feedback, 2026-08-15

Captured while shipping 0.1.9. **None of this blocks that release.** He was
explicit: get what exists onto Windows first, he is stuck without it, and these
go out in the update after.

---

## 1. A session with no Claude in it should not wear Claude's controls

Starting a session gives you a plain shell. Today that shell still shows the
**chat/terminal switch** and the **account dropdown** — both of which mean
nothing until an agent is running in it.

- Hide the chat toggle and the account picker while the session is a plain shell.
- Put a **"Run Claude"** button there instead. Pressing it starts Claude in that
  session — his words: *"it automatically types /claude and sends"*, i.e. the app
  runs it for you rather than making you remember the command.
- The moment Claude is running, the chat toggle and the account picker appear.
  He described the pill expanding to reveal them.

The folder dropdown **stays** in both cases — it is useful for a plain terminal
too.

## 2. Accounts cannot be renamed where you actually see them

The account dropdown inside a session shows the name an account was given and
offers no way to change it. Renaming should be possible from there, not only
from the Accounts screen.

## 3. Chat view and terminal view disagree

> *"if you do go for chat mode your chat and terminal is not mostly showing the
> same context and same things sometime terminal is showing some different chat
> and chat view is showing something else"*

Two views of one session showing different conversations. This is a **real bug**,
not a preference, and it is the most serious item here — two windows onto one
thing that disagree is worse than having only one of them. Reproduce it before
designing anything.

## 4. A stray line at the end of chat view

> *"at the end of the chat we have some kind of sentence which should not be
> there ... there should be only last message whoever has said, no great line
> under there"*

The last thing on screen should be the last message. Find whatever is being
appended after it and remove it.

---

## Already decided and done, for context

**Scrollback replay: dropped (Option A).** Claude Code takes the alternate screen
and redraws its own conversation on `--continue`, so anything the app painted sat
underneath it, unseen. And a plain shell has no transcript to replay — there is
no file, its output lives in memory. Saving all terminal output to disk was
considered and rejected: no terminal on any OS does it, the *commands* are
already saved by the shell's own history, and a file holding everything a
terminal ever printed is a security liability of exactly the kind three files
were just locked down to avoid.
