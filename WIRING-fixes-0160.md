# Wiring — lane fixes-0160

**Nothing to paste.** None of the three fixes needs a line in `src/main/index.ts`,
`src/preload/index.ts`, `src/renderer/App.tsx`, `src/shared/types.ts` or `package.json`.

| Fix | Where it lives | Why no wiring |
|---|---|---|
| Isolated tab user agent | `src/main/browser-isolation.ts` `harden()` | Same module, same call `browser-tab.ts` already makes for the shared and worker sessions. |
| Store dev key out of the slots | `src/shared/store-key.ts`, `src/main/store-install-ipc.ts` | `installCommunityStore` (already called from `index.ts`) now asks `storeKeysFor({ env: process.env, packaged: app.isPackaged })`. |
| Close-button guard | `.staysfixed/guards/a-close-either-closes-or-says-why.guard.js`, `.harness/stub.ts` | Test tooling only. |

## Headless host

Nothing to wire. The headless host builds no Community store and opens no Isolated tab.
If it ever builds the store, it must pass `keys: storeKeysFor({ env: process.env, packaged: <is this a published build> })`
the same way, or leave `keys` out (production key only, which is the safe default).

## Local Store preview, after this change

The development key is no longer believed by default. An unpackaged run that should read
the site repository's local preview catalogue needs both variables:

    TERMINALDECK_STORE_API=http://127.0.0.1:<port> TERMINALDECK_STORE_DEV_KEY=1 npm run dev

A packaged build ignores `TERMINALDECK_STORE_DEV_KEY` entirely.

Outside this repo, `terminaldeck-site/store/README.md` and the message printed by
`terminaldeck-site/scripts/sign-index.mjs` still tell a developer to put the key in
"slot two". They should say to set `TERMINALDECK_STORE_DEV_KEY=1` instead.
