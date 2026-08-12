# Security Policy

Terminal Deck runs AI coding agents against your source tree, holds a local
HTTP endpoint, and embeds a browser. Those are exactly the places where a
mistake here becomes your problem, so vulnerability reports are genuinely
welcome.

## Supported versions

Alpha. Only the tip of `main` is supported — there are no published releases
and no backports. Report against the latest commit.

## Reporting a vulnerability

**Do not open a public issue, pull request or discussion for a security
problem.** That publishes the exploit before there is a fix.

Report privately, by either route:

1. **GitHub private vulnerability reporting** — the *Report a vulnerability*
   button under this repository's **Security** tab. This is preferred: it keeps
   the report, the discussion and the eventual advisory in one private thread.
2. **Email** — **asadiqbalonline@gmail.com**, with `SECURITY` in the subject.

### What to include

- What an attacker gains, and what they need in order to start
- Steps to reproduce, or a proof of concept
- The commit you tested, your macOS version, and which agent CLI was running
- Anything you think makes it worse or less bad than it looks

### What to expect

- **Acknowledgement within 7 days.** This is a one-person project; that is a
  realistic promise rather than an ambitious one
- An assessment, including a plain statement if the answer is "working as
  intended" and why
- Credit in the advisory and the changelog, unless you would rather not
- Please give a fix a reasonable window before disclosing publicly. If a report
  goes unanswered for 30 days, treat that as the window having expired

There is no bug bounty.

## In scope

The security boundaries this app actually claims. Anything that crosses one of
these is a vulnerability:

**The renderer↔main bridge.** `src/preload/` is the only path between the two,
and no raw `ipcRenderer` is meant to escape it. Anything that lets renderer code
reach a main-process capability the bridge does not deliberately expose, or that
lets an IPC argument drive a path, a shell command or a file write outside its
intended root, is in scope.

**The embedded browser.** Pages loaded there run with context isolation, no node
integration, and a scheme deny-list — `file:`, `javascript:`, `data:` and
Chrome's internal schemes are refused, because a page that can talk the view
into `file:///Users/...` can read the disk. Any escape from that sandbox, any
bypass of the scheme rules, and any leak of state between isolated tabs is in
scope.

**The local hook server.** It binds `127.0.0.1` only, requires a per-run token
compared in constant time, and rejects rebound `Host` headers. Reaching it
without the token, reaching it from off-machine, or getting it to execute
something it should not, is in scope.

**The support bundle and log redaction.** The bundle is designed to be pasted
into a public issue. If any input can carry a token, API key, authorization
header, cookie or home-directory path through `src/main/redact.ts` and into a
bundle or the log, that is a vulnerability — treat it as one even though the
consequence looks mild.

**Credential-adjacent paths.** Chrome cookie import, agent profile isolation
(the per-profile config directories that keep work and personal logins apart),
and MCP server credentials. Any crossing of profile boundaries counts.

**Untrusted repository content.** Opening a project should never execute
anything from it. If a crafted `.deckignore`, board file, MCP server definition,
git remote, branch name or session title can achieve code execution, command
injection or a file read outside the project, that is the most serious class of
bug this app can have — say so loudly.

**Content Security Policy** in the packaged build.

## Out of scope

- **The agent CLIs themselves.** Claude Code, Codex and Gemini are separate
  products. Terminal Deck launches the binary you already have and inherits its
  authentication; it never handles your API keys. Report their bugs to them
- **What an agent does to your files.** An agent editing, deleting or committing
  something you did not want is the agent's behaviour, not a vulnerability here
- **The unsigned build.** Packaging is unsigned and un-notarised, and macOS will
  warn you. This is a known state, tracked as Phase 8 in
  [ROADMAP.md](ROADMAP.md), not a finding
- **The dev-mode CSP.** It is deliberately permissive so Vite can serve the
  renderer, and it does not apply to a packaged build
- **Attacks that presume local code execution as the same user.** If an attacker
  can already run code as you, they can already read the hook token, the config
  and the transcripts — the app is not a boundary against that, and does not
  claim to be
- **Dependency CVEs with no demonstrated path through this app.** Still worth
  mentioning, but as an issue rather than an advisory, and with the reachable
  call path if you have one
- Missing hardening headers with no exploit, social engineering, physical
  access, and reports produced solely by a scanner with no analysis attached

## A note on what this app can see

Terminal Deck reads Claude Code's JSONL transcripts under `~/.claude/projects/`
to compute cost and context. Those transcripts contain your prompts and the
agent's replies. Nothing is uploaded — there is no telemetry, no analytics and
no network call the app makes on its own behalf. If you ever see it doing
otherwise, that is a report worth making.
