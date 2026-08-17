# The feature store

> **Withdrawn on 2026-08-17.** The storefront is gone from Settings; the registry
> that backs it stays, and every feature now ships on except voice dictation.
> Asad, after walking through the built app:
>
> > *"still I think they doesn't make any sense to be as a feature. Use or not
> > use. So maybe let's keep them all installed and all active always and remove
> > this section… they are all necessary basic, they don't need to have uninstall
> > and install button, enable and disable thing. Instead of only voice
> > dictation. So features or maybe tools, let's actually call it tools."*
>
> What survives, and why it was worth keeping: `features/registry.ts` is still
> the one table every consumer asks before drawing something optional, so a
> feature cannot be half-switched-off — and voice dictation, the one entry that
> is a real choice, still has its switch, on **Settings → Tools**. The rest of
> this document is the reasoning behind the store, kept because the rules in it
> (a feature is independent; where a feature would have been, offer it; no dead
> controls) are still how this app is built.

Asad, 2026-08-15. The app has a lot of features and the UI is paying for it. The
fix is not to cut features — it is to let each person choose which ones exist for
them.

> *"our app will overall look less complicated less busy and people can choose
> what they want to have and what they don't want to have and it will look like a
> rich app rather than a cheap app"*

---

## What it actually is, said plainly

**Feature flags with a storefront.** Every feature ships inside the app, always.
Installing turns one on; uninstalling turns it off and clears its data. Nothing
is downloaded, nothing is compiled, no third-party code ever runs.

This is deliberate and it is the whole reason it is cheap to build and safe to
ship. It also means **reinstalling is instant** — the code never left.

### Call it Features, not Plugins

"Plugins" promises an ecosystem: third-party authors, an API, things the vendor
did not write. We are not building that, and the word would be a promise the app
breaks. **Features** is honest and describes exactly what it is.

## What goes in, what never does

**The rule:** big, opinionated, or space-taking features that a real person might
genuinely never want. If a feature costs nothing on screen, it stays core — a
store entry for something invisible is just an extra decision.

**Never in the store — REMOTE ACCESS.** Asad was explicit:

> *"don't do this with the remote feature because remote is the main one we are
> differentiating ourselves. so it's not an optional feature."*

Remote and everything that is part of it — the tunnel, clipboard, file transfer,
pairing, device grants — is the product. It is never a choice.

Also core: sessions and the terminal itself, settings, updates, and account
profiles. These are what the app *is*.

**Good candidates for the store:** the browser pane, the iOS simulator pane,
cost and usage analytics, alerts, swarm mode, split view, voice, MCP servers,
hooks, the GitHub integration, Chrome import, keep-awake.

That list is a starting point, not a decision. Judge each one by the same
question: *would a reasonable person want this permanently gone?*

## How it behaves

**Installing.** One click. It turns on, and a short confirmation says **where to
find it** — the menu, the panel, the settings section. That sentence is the whole
onboarding, so it names a real place, not a category.

**A page for what is installed.** One list. Each row can be turned off
temporarily or uninstalled entirely. Off and uninstalled are different: off keeps
your data and your settings, uninstalled removes them.

**Uninstalling.** State exactly what will be deleted, by name and by size where
it is knowable, and require confirmation for anything unrecoverable. *"This will
delete 4 saved sessions and 2 MB of history"* is a decision. "Are you sure?" is
not.

## The defaults decide whether this succeeds

A new install must feel complete, not empty. Ship a sensible starter set on, and
leave the specialist things off. Someone who never opens the store should never
notice it exists — that is the measure of the default being right.

## The failure this feature can cause, and the fix

**A feature store makes things undiscoverable.** Someone looks for a capability,
does not find it, and concludes the app cannot do it. That is strictly worse than
a busy UI, and it is the risk that decides whether this was a good idea.

So: **where a feature would have been, offer it.** An empty panel or a missing
menu entry says *"Split view is available. Install it."* with the button right
there. The dead end is the bug, not the absence.

## Engineering rules

1. **Features are independent.** One being off must never break another. If two
   cannot be separated, they are one feature and get one entry.
2. **Off means gone, cleanly.** No dead menu items, no settings sections for
   something uninstalled, no empty panels. A visible control for an absent
   feature is exactly the dead control the design brief forbids.
3. **Test the extremes.** Everything off and everything on both have to work, and
   both belong in the guard tests. Every combination cannot be tested, so
   independence (rule 1) is what makes the extremes sufficient.
4. **`reachable.test.ts` still applies.** Disabled code still ships and must
   still be reachable from an entry point — being switched off is not an excuse
   for a module nothing imports.
5. **The registry is one file.** Every feature declared in one place: id, name,
   description, default state, what data it owns, where it appears. A feature
   that is half-declared in five files is how this rots.
6. **Data ownership is declared, not guessed.** Uninstall can only be honest
   about what it deletes if each feature says what it owns.

## Naming and tone

Descriptions are for people who do not already know what the thing is. *"See your
dev server on your phone"* — not *"Localhost tunnelling with raw TCP forwarding"*.
Follow `DESIGN-BRIEF.md`: brighter title, dimmer description, generous space, one
accent colour.
