# Credential proxy — bring your own GitHub, leave nothing behind

Decided 2026-08-15. Build this.

---

## The problem it solves

Someone connects to a folder on your machine and works in it. Two things must
both be true, and today neither is:

1. **They never get your GitHub.** A shell on your machine inherits *your* git
   credentials. Right now, anyone you grant a folder to can push as you.
2. **You never hold their GitHub.** They should not have to paste a token onto
   your disk to get work done, and you should not want to be holding it.

Asad's framing, and it is the right one: *"he don't want to give his GitHub
access token to my folder to keep it and I don't want to give him any kind of my
own github to work inside my folder."*

## The shape

Their token stays on **their** device. When git on the host needs credentials,
the request is carried over the encrypted channel that already exists, answered
on their device, and used once — in memory, never written to the host's disk.

```
host: git push
   -> GIT_ASKPASS helper (this repo)
      -> session channel  ->  their device
                              (holds token in its own keychain)
                          <-  answer, for this operation only
   -> git uses it, in memory
```

## Two halves, and the first one ships regardless

**Half 1 — isolate the host's own credentials.** A session started in a granted
folder must not be able to read the host's GitHub login. Give it its own git
configuration and credential helper rather than inheriting the machine's. This
has no downside and no dependency on the rest; it is broken today and should be
fixed even if nothing below gets built.

**Half 2 — the proxy itself.** Everything else in this document.

## What a person does

**Once, on their own device:** they connect GitHub inside their own copy of the
app. Their browser, their machine, ordinary sign-in. This is the only setup.

**When they join a folder:** nothing at all.

**The first push:** a prompt on **their** device.

> Push to `owner/repo` as **@them**?
> Asked by: *the machine that asked, by name*
> [Approve] · [Approve always for this repo] · [Deny]

Then never again for that repo.

### Silent or asked

| Operation | Behaviour |
|---|---|
| fetch, pull, clone | **Silent, always.** Prompting buys nothing. |
| push | **Ask once per repo**, then remember the answer. |

Pushing is the irreversible one, and it is the one where somebody should get to
see whose name goes on the commit.

### No reassurance copy

Deliberately **no** line in settings explaining that the token is never stored.
Asad cut it, and he is right: the approval prompt already names the repo, the
account and the machine that asked. That is the explanation. A sentence in a
settings pane that nobody reads is not security, it is decoration.

## Approvals are per repo, per device

An approval is remembered for **that repository, from that device**. Not "this
person, everywhere". A grant to work in one folder is not consent to push to
everything the account can reach.

Revocation is disconnection: no live channel, no credentials. Nothing to clean
up on the host afterwards, because nothing was left there.

## Failure must be fast and legible

If their device is asleep, offline or has quit the app when git asks:

> Your device isn't reachable — open the app to approve this push.

**Fail in seconds, not by hanging.** A thirty-second stall with no explanation is
how people stop trusting a feature. Git's own timeout is far too long to be the
answer here.

## What this does and does not protect

Say the true thing and no more.

- **True:** their GitHub account stays theirs. The token never touches the host's
  disk, and disconnecting ends all access.
- **NOT true, and must never be implied:** that they are isolated from the host.
  They are running commands on someone else's computer, and the code is pushed
  *from* that computer. Confinement is a separate piece of work
  (`DESIGN-BRIEF.md` and the folder-grant model), and until it exists no wording
  anywhere may suggest a sandbox.

## The fallback, kept on purpose

The proxy needs the app on their device — that is what holds the token and
answers. Someone who will not install anything has a second route, and it is a
good one: a GitHub **fine-grained personal access token**, scoped to the single
repository, with an expiry. If it leaks, the blast radius is one repo they
already chose to share.

Support both. Let them pick. Do not make the proxy the only door.

## Implementation notes

- New wire messages for request and answer. Optional capability, advertised the
  way `create` and `localhost` already are, so an older client is unaffected.
- The askpass helper is a small executable the session's environment points at.
  It must not be able to answer from anything cached on the host.
- Never log a credential. `src/main/redact.ts` already exists — use it.
- An answer is scoped to one operation. No ambient "unlocked" state that a later
  command can ride on.
- Test the refusals as hard as the approvals: denied, timed out, device gone
  mid-operation, approval for a *different* repo than the one being pushed.
