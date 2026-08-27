# Integration hand-off — host-owned GitHub (lane B / `lane/b-github`)

The GitHub login was flipped so the **machine (host) owns it**, not the phone.
Asad, verbatim: *"Every device that is actually running the app is the one that
owns the GitHub settings — not the mobile application, because the mobile
application is just driving it. So the HOST owns everything, everywhere."*

The phone no longer holds a GitHub account or answers git logins. It **triggers
and views** the login the host holds, over a new `github` capability. This lane
delivered the host side and a self-contained connect component for **each phone
client**. The **server/machine detail page lane** mounts that component — that is
the only thing owed.

---

## What the server-page lane mounts

### iOS
`ConnectGitHubView(host:)` — `ios/TerminalDeck/Screens/ConnectGitHubView.swift`.

```swift
ConnectGitHubView(host: hostLink)
```

- Self-contained `Theme.surface` card (matches `ServerDetailView`'s idiom).
- Reads `host.github`, calls its own `ensureRead()` on appear — **no setup call
  needed from the page.**
- Renders **nothing** when the host did not advertise `github` (guest, or a build
  with no authenticator), so it is safe to place unconditionally.
- Draws every state itself: loading · Connect button · signing-in (device code +
  Copy + Open-in-browser + Cancel) · connected (`@login`, avatar, Disconnect) ·
  no-GitHub-App-configured (host's `failure` sentence, no button).

### Android
`ConnectGitHubSection(...)` — `android/app/src/main/java/dev/terminaldeck/android/ui/ConnectGitHubSection.kt`.

```kotlin
state.github?.let {
    ConnectGitHubSection(
        view = it,
        onConnect = viewModel::connectGitHub,
        onCancel = viewModel::cancelGitHub,
        onDisconnect = viewModel::disconnectGitHub,
    )
}
// and once, when the server page appears:
viewModel.openGitHub()
```

- `DeckUiState.github` is null until `openGitHub()` reads it and while the host
  did not advertise `github`, so the `?.let` is both the gate and the guard.
- `github.changed` keeps it fresh after that; the composable draws every state
  above.

### PWA
No GitHub UI, by design (`pwa/src/credential.ts` — a browser has no keychain).
**Left untouched.** Do not add a connect card there.

---

## The wire (already built on the host — nothing for the page to wire)

Capability **`github`**, advertised to the owner's own devices when the host has
a GitHub authenticator (desktop always; a headless server unless it is a public
demo box). Withheld from guests, the same as `settings`/`logins`.

Client → host (each carries a client-minted `rid`):
`github.read` · `github.connect` · `github.cancel` · `github.disconnect`.

Host → client:
`github.state {rid, github: GitHubHostWire}` (answer to any verb) ·
`github.changed {github}` (unsolicited push when the host login changes, incl.
when a device-flow sign-in a phone started finally completes in the host's poll).

`GitHubHostWire = { connected, login, name, avatarUrl, source, appConfigured,
installUrl, pending: {userCode, verificationUri, expiresAt} | null, failure,
disconnect }`.

---

## Consequence worth stating on the page (optional copy)

Once the host is connected, **git push/pull on that machine works with no phone
connected** — the machine answers its own git from its own login. Before this,
a push from a phone-driven session waited on the phone to approve it.

## Open decision flagged to Asad

A **guest** granted a folder on someone's machine is **refused** the owner's
GitHub (git says *"This machine's GitHub account is not shared with other
devices. Push with a token scoped to that one repository."*). This keeps the one
promise of the old proxy — a guest never pushes as the owner — but it does mean
the old "guest brings their own GitHub" flow is gone, replaced by "the host owns
GitHub." If Asad wants guests to use the host's GitHub too, it is a one-line
change (drop the `ownDevice` gate in `src/main/remote/credentials.ts`).
