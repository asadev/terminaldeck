# Screen recording, 2026-08-16 05:05 — everything he said

Twenty-one minutes walking the macOS app, the web client and the iOS app. His
typed message the same night covered five items; this recording covers about
thirty. Transcribed and cross-checked against the frames, because he points at
things without naming them and the picture settles what "this one" meant.

Quotes are his, lightly cleaned of transcription noise. Where he plainly misspoke
the intent is noted rather than the words.

---

## The pages in the sidebar — most of them are empty

> *"I don't know if we need an overview page at all or not. We don't see that
> much of important stuff here."*

**Overview.** He is not asking to polish the widgets, he is asking what the page
is for. And he answers it himself:

> *"maybe we can have some kind of task lists of all of the running clouds,
> running sessions … a grid here where we can see … who is finished how much and
> we can get inside … if there are multiple running agents or workflows in each
> widget, we can see the overall status of the tasks … and we can accordingly see
> which one we need to go inside and take a review."*

That is a real product idea and a better one than what is there: Overview becomes
a live board of every running session — what each agent is doing, how far along,
which one is waiting on you — and clicking one takes you into it. For somebody
running several agents at once, which is exactly who this app is for, that is the
screen they would leave open.

**Files** — *"I don't see any kind of files here"*, just the "pick something from
the tree" placeholder.

**Source control** — *"also looking empty"*.

**Search** — *"I don't know what I can search here. If there is nothing
important, let's just remove this one and maybe bring **artifacts** over here.
That can be maybe better useful for people and they can review artifacts and
browse."* So: delete Search, put an artifacts browser in its place.

**GitHub** — *"I connected my GitHub, I cannot see anything also here."*
Already covered in the 0.2.0 plan.

## The built-in browser

- **A new browser tab on Windows opens onto a red "connection refused" error.**
  It should open on a real start page: pick which localhost port to visit, or
  type any address.
- **Popups and hover panels render behind the page.** *"this should be in the
  front layer, whatever the message popup is coming, it's hiding behind. I cannot
  even see what it shows."* Same fault on the session flyout: *"this is behind
  the white page, it should be always front layer."* A z-index/stacking bug, and
  it makes controls unreadable rather than merely ugly.
- **An empty browser page is white in dark mode.** It should be dark.
- **A Chrome-like tab strip along the top**, holding the windows you are actually
  looking at, and — the interesting part — *"we should be able to just drag and
  drop in the top whatever we want to see in the top, and the rest we can fold
  inside the side panel."* The side panel keeps every session, browser and
  terminal alike; the top strip is the subset you promoted, by dragging.
- The session header inside a terminal is too tall — *"maybe we can reduce the
  size of this header."*
- **A session's name cannot be edited.** It should be.

## Accounts

> *"I am not able to edit the name of this account and I don't know where it
> belongs to … I should be able to edit the account, delete and add, and rename
> should be about name."*

Add, rename, delete — all three, and the entry should say which login it is. He
confirms signing in works and that several accounts genuinely run side by side.

## Settings

**Remote and Machines are one thing** — *"this full page can be divided into
machines and remote or mobiles … not separately remote."* One page, sections
inside it.

**The prose is too long.** *"we don't need this much of big descriptions under
each. The whole page is going to be used just because of the big descriptions."*
This is the most broadly applicable note in the recording and it applies well
beyond Settings — this app explains itself at paragraph length in places where a
line would do.

**Delete the Tailscale card.** *"we have still here 'direct on your tailnet' …
some people might not understand it … this is confusing … so I think we need to
remove this direct on your tailnet thing and only keep the relay thing."* Not
demoted — removed. That is the third time he has objected to Tailscale being
visible.

**Features is full of things nobody would turn off.** *"alerts, GitHub and these
things you have added here are mostly not choice options, they are all mandatory
things that we need actually always. So let's not keep them like this. Let's
bring here something that some people might not use and it's heavier."* A
feature switch should be for the heavy and the optional, not for the essential.

**Power does not work.** *"I felt that it's not working the way it should work —
after a few seconds I can get disconnected."*

**"Pick up where you left off" works on the Mac, not on Windows.** He closed and
reopened on the Mac and it restored. *"on Windows side it's not doing it that
way."*

**Permission prompts ask for too little to succeed.** *"it is not asking if it
needs full access — let it ask full access in that case rather than asking only
this much, so it can successfully import."* Ask for the access the operation
actually needs, rather than a narrower one that then fails.

## Inside a session

- **Delete the trailing line** — *"read from the session transcript, prompts and
  replies only … this specific thing which I selected should not be there at all.
  We need to completely remove it."* Already on the list; the recording catches
  it selected on screen.
- **Dropdowns do not close each other.** *"see how it looks like — they can all
  open at once, so they come over to each other."*
- **The Options menu is a pile of duplicates.** *"options is having all of the
  things that we already have here and there. So let's keep everything separate
  rather than having everything on one page."*

## The web client (app.terminaldeck.dev)

> *"this is not full page … and it's not terminal experience as well because we
> are taking so much space with this unnecessary stuff — the ESC, Tab — because
> if we are browsing we already have a keyboard. Mostly browsing will be on PCs,
> not on the phone."*

- Make it **full width**. It currently sits in a narrow column.
- **The on-screen key bar (ESC/Tab/arrows) is phone furniture on a desktop
  browser.** Hide it where there is a real keyboard; if it stays, float it.
  *"The downside should be cleaned, nothing extra. Just simple straight
  terminal."*
- **Give it localhost access too**, not just terminals: *"localhost and terminal,
  both are our things that we need to give to everyone."*
- **It is too basic.** *"make the web page properly as much as possible, just
  like the very similar same options as we have in the iOS application."*

**Also found in the recording, unprompted:** the web client's "Start in" list
shows `/home/asad/ClaudeImza` and `/home/asad/ClaudeImzacrm` **twice each**.

## The iOS app

- **It needs a real navigation.** *"we need to give a proper menu … maybe we can
  have some tab bar, and down here like a pill."*
- **Bring the desktop's options across.** *"we have a lot of options on the Mac
  side, maybe we can bring them here on phone also … make it more user friendly."*
- **Stop flashing the connection state.** This one he specified precisely, and it
  is a good spec:
  - On open it shows a yellow "connecting" immediately. Don't. Wait ~5 seconds;
    only if it is *still* not connected does the state appear.
  - Don't display "Connected" permanently either.
  - If it drops for **more than** 5 seconds, then show "connecting", so it is
    visibly trying.
  - A drop shorter than 5 seconds shows nothing at all.
  - (He said "then show connected" where he meant "connecting" — the surrounding
    sentences make the intent unambiguous.)
- **One finger scrolls, it does not select.** *"if I touch with one finger it
  should scroll the page rather than selecting. For selecting maybe we can have
  something else, but with one finger I don't want selection."* He asked for this
  once before, with long-press-and-drag as the selection gesture.
- GitHub on the phone: *"I'll test the GitHub on my phone side later, let's not
  do it now."* Explicitly deferred by him.

---

## One note against the recording

He says in passing *"QR code should be mostly properly working"*, while his typed
message the same night says six-digit codes replace the links and QR everywhere.
Those pull in opposite directions, and the typed instruction is both later and
more specific, so it wins: the QR goes. It is also the coherent choice — a QR
encodes the pairing link, and the link is being deleted, so a QR would have
nothing left to carry but the six digits it would be quicker to read off the
screen and type.
