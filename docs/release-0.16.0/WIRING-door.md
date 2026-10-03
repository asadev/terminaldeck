# WIRING — lane `mcp-door` (0.16.0)

> **Applied 2026-10-03** in `wip/0.10.0`: §2 (preload) and §3 (checklist) are in
> `a3b6956`; §6 is done in `18d4e41` (keys act as the owner through `actsAsOwner`).
> What is left for the integrator is §5 — deploying the relay and the proof.

The way in for AI apps outside this one, onto the existing `deck-control` MCP:
named access keys, a stable loopback port, internet reach through the relay,
`tools.run`, and Settings → **Connect an AI app**.

Everything in `src/main` is already wired inside files this lane owns or could
edit (`deck-control/index.ts` assembles the keys, the door and the IPC; one
two-line edit in `remote/server.ts` hands the relay link the switchboard). What
is left for the integrator is **the preload** and **the action checklist**.

---

## 1. `src/main/index.ts` — nothing

`registerDeckControlIpc` (already called there) now builds the key store
(`<userData>/remote/access-keys.json`), the `AccessKeyDoor`, hands the door to
the loopback server with a remembered port, installs it behind the relay
switchboard (`remote/relay-mcp.ts`), and registers the `ai-apps:*` channels
gated on the existing `isApprover`. Its `stop()` uninstalls and flushes. No new
deps, no new call.

`remote/server.ts` (`relayFor`) was edited in this lane: it passes
`mcp: relayMcp` to `createRelayClient` and calls `relayMcp.useLink(relay)`.

---

## 2. `src/preload/index.ts` — paste after `onCopilotAction` (≈ line 1635)

```ts
  /* -------------------------------------------------------- ai apps -- */
  // Settings → Connect an AI app. Access keys for AI apps outside this one,
  // and the switch that lets them reach this Mac through the relay. Every
  // channel is refused in main unless the sender is the app's own window.
  // `aiAppsCreate` is the only answer that carries a key, and only once.
  aiAppsState: (): Promise<unknown> => ipcRenderer.invoke('ai-apps:state'),
  aiAppsCreate: (input: { name: string; level: string; askFirst: boolean; folders: string[] | null }): Promise<unknown> =>
    ipcRenderer.invoke('ai-apps:create', input),
  aiAppsRename: (id: string, name: string): Promise<unknown> => ipcRenderer.invoke('ai-apps:rename', id, name),
  aiAppsLevel: (id: string, level: string): Promise<unknown> => ipcRenderer.invoke('ai-apps:level', id, level),
  aiAppsAskFirst: (id: string, on: boolean): Promise<unknown> => ipcRenderer.invoke('ai-apps:ask-first', id, on),
  aiAppsFolders: (id: string, folders: string[] | null): Promise<unknown> =>
    ipcRenderer.invoke('ai-apps:folders', id, folders),
  aiAppsRevoke: (id: string): Promise<unknown> => ipcRenderer.invoke('ai-apps:revoke', id),
  aiAppsInternet: (on: boolean): Promise<unknown> => ipcRenderer.invoke('ai-apps:internet', on),
  onAiAppsChanged: (cb: () => void): (() => void) => {
    const handler = (): void => cb()
    ipcRenderer.on('ai-apps:changed', handler)
    return () => ipcRenderer.off('ai-apps:changed', handler)
  },
```

Until this lands, `src/preload/contract.test.ts › every *Bridge interface … is
fully satisfied` fails on `AiAppsSection.tsx AiAppsBridge.*` — that is the
guard working, and it goes green with the paste. `.harness/stub.ts` already
implements all nine with the same shapes.

---

## 3. `src/main/deck-control/actions/agents.ts` — add with the preload paste

`actions.test.ts` will list these as *missing* the moment the preload has them
(and as *stale* if added before). All nine are honest skips — they are grants,
and grants are changed only by a person at this machine (`COPILOT-REMOTE.md`
§5 rule 9), never by a tool:

```ts
  'ai-apps:ask-first': { skip: 'Whether an outside AI app is asked before big changes is a permission, and permissions are only ever changed by the owner in Settings, never by a tool.' },
  'ai-apps:create': { skip: 'Making an access key hands back a secret and mints a new way into this machine; an AI that could call it could let itself back in.' },
  'ai-apps:folders': { skip: 'Which folders an access key may start sessions in is a permission, changed only by the owner in Settings, never by a tool.' },
  'ai-apps:internet': { skip: 'Opening this machine to AI apps on the internet is a permission, switched only by the owner in Settings, never by a tool.' },
  'ai-apps:level': { skip: 'Raising what an access key may do through a tool would let an AI raise its own key; levels are changed only by the owner in Settings.' },
  'ai-apps:rename': { skip: 'An access key’s name is how the owner recognises it in the activity log, so only the owner renames one, in Settings.' },
  'ai-apps:revoke': { skip: 'Revoking access keys is the owner’s control over outside AI apps, kept in Settings; it is not a tool an AI is handed.' },
  'ai-apps:state': { skip: 'It is the owner’s audit screen of which AI apps hold keys to this machine; an app holding one has no business enumerating the others.' },
```

(`ai-apps:changed` is a push, not an invoke/send, so it is not on the list.)

---

## 4. Headless host — not built (scope change: this release is Mac only)

Dropped at the coordinator's instruction. For the record, it would be: build an
`AccessKeys` + `AccessKeyDoor` in `src/headless/copilot.ts` over its own
`DeckControl`, pass `keys: door` to its server, `relayMcp.install(door)` and
`mcp: relayMcp` on its relay client, and three CLI verbs over `AccessKeys`
(`create`/`list`/`revoke`). Nothing in this lane's code assumes Electron except
`ai-apps-ipc.ts`'s `isApprover` type.

---

## 5. The relay — what changed, and deploying it

**Do not deploy from the lane.** The integrator runs `./relay/deploy.sh`.

Changed:
- `relay/src/mcp-route.ts` (new) — the HTTP route, its caps and the mirror of the
  wire constants. Bundled automatically: `deploy.sh` runs `esbuild --bundle` on
  `relay/src/main.ts`, still zero runtime dependencies (bundled locally to
  25,211 bytes and run: healthz, route 404, OAuth-probe 404 and GET 405 all
  answered, nothing logged but the listen line).
- `relay/src/rendezvous.ts` — each host carries MCP state; `fromHost` routes the
  new envelope family (0x10–0x13) before the channel envelope; the request
  handler hands `/mcp/…` and `/.well-known/…` to the route. Every existing path
  answers exactly as before (`rendezvous.test.ts`: the 23 old tests unchanged
  and green).
- `relay/deploy.sh` — `check()` now also proves the route exists (a JSON 404
  with the route's own sentence for an unknown host, and the JSON OAuth-probe
  404). Run before the deploy, `--check` will fail on that step against the old
  relay — that is the message "this relay predates the AI-app route".

Old desktops are safe: they never send `reach`, so the relay never forwards to
them (fast 404). An old relay drops the new desktop's `reach` frame.

### URL shapes

| Who | URL | Credential |
|---|---|---|
| claude.ai / Claude desktop custom connector, ChatGPT developer-mode connector | `https://relay.terminaldeck.dev/mcp/<hostId>/<key>` | the key is the last path segment (secret link) |
| Claude Code / Codex / Gemini CLI / Cursor / VS Code on another computer | `https://relay.terminaldeck.dev/mcp/<hostId>` | `Authorization: Bearer <key>` |
| Any of those on this Mac | `http://127.0.0.1:<port>/mcp` (port remembered; 47821 on first launch) | `Authorization: Bearer <key>` (or `/mcp/<key>`) |

`<hostId>` is the relay host id (26 chars, the one in the pairing QR). Keys are
`ak_` + 43 base64url characters.

### Proving it end to end after the deploy

On the Mac: Settings → Connect an AI app → switch **Internet reach** on → **New
key** (Look only, name "curl proof") → copy the key and the Claude link (the
part before the key is `$BASE`).

```bash
R=https://relay.terminaldeck.dev
BASE=$R/mcp/<hostId>                 # from the link
KEY=ak_...                           # shown once
H=(-H 'content-type: application/json' -H 'accept: application/json, text/event-stream')

# 1. route is deployed: unknown host → the route's own JSON 404, fast
curl -s -X POST $R/mcp/AAAAAAAAAAAAAAAAAAAAAAAAAA "${H[@]}" -d '{}'

# 2. initialize through the secret link → 200, serverInfo deck-control, instructions mention tools_run
curl -s -X POST "$BASE/$KEY" "${H[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-proof","version":"1"}}}'

# 3. tools/list with the header form → includes tools_run and tools_describe
curl -s -X POST "$BASE" "${H[@]}" -H "authorization: Bearer $KEY" -H 'mcp-protocol-version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | grep -o '"name":"tools_[a-z]*"'

# 4. a real call → the live session list
curl -s -X POST "$BASE/$KEY" "${H[@]}" -H 'mcp-protocol-version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sessions_list","arguments":{}}}'

# 4b. the held-back tools, by area (the index names five areas, not 135 tools)
curl -s -X POST "$BASE/$KEY" "${H[@]}" -H 'mcp-protocol-version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"tools_describe","arguments":{"area":"sessions"}}}'

# 5. a held-back tool through tools_run (what claude.ai/ChatGPT must do)
curl -s -X POST "$BASE/$KEY" "${H[@]}" -H 'mcp-protocol-version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"tools_run","arguments":{"name":"git_status","arguments":{"cwd":"<an open project>"}}}}'

# 6. a Look-only key cannot change anything → isError, "set to Look only"
curl -s -X POST "$BASE/$KEY" "${H[@]}" -H 'mcp-protocol-version: 2025-06-18' \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"tools_run","arguments":{"name":"settings_write","arguments":{"scope":"settings","patch":{"appearance.density":"compact"}}}}}'

# 7. wrong key → byte-identical to step 1; GET → 405; OAuth probe → JSON 404
curl -s -X POST "$BASE/ak_wrongwrongwrongwrongwrongwrongwrongwrongwro" "${H[@]}" -d '{}'
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/$KEY"
curl -s "$R/.well-known/oauth-protected-resource/mcp/<hostId>/$KEY"
```

Then on the Mac: the key row says *Last used just now by curl-proof 1 over the
internet*, and Settings → Copilot's activity shows rows starting
`From “curl proof”:`. Switch internet reach off → step 2 returns the step-1 404
within a second. Revoke the key → same.

For the ask-first path: make a **Full control** key, run step 6 with it — the
desktop dialog (and his phone, if the app is open on it) shows *From “…”:
Change settings…*; ignore it and the call returns after 45 s with *"nobody
answered within 45 seconds — not at their Mac and not on their phone. Nothing
was changed."*

### What claude.ai and ChatGPT need

- **claude.ai / Claude desktop:** Settings → Connectors → Add custom connector →
  paste the secret link; leave the OAuth fields empty. No 401 is ever sent and
  every OAuth discovery probe gets a JSON 404, so it adds as an authless
  connector. The account must allow custom connectors.
- **ChatGPT:** Settings → Apps & Connectors → Advanced → Developer mode on →
  Create → paste the secret link → Authentication: *No authentication*. Write
  tools (anything not `readOnlyHint`) are confirmed by ChatGPT per call, on top
  of our own ask-first. `tools_run`'s hints are set per key (read-only for a
  Look-only key, destructive for Full control).
- Both build the model's tool list from `tools/list` only, so they reach the
  held-back tools through `tools_describe` + `tools_run` — the server
  instructions tell the model so.

---

## 6. Follow-ups this lane did not decide (other lanes' files)

Several tools refuse any caller whose kind is not `local`, and a key caller is
kind `key`, so they refuse keys today — the safe default, but possibly not what
he wants for a key he made for himself:

- `servers/tools.ts` `servers.control` and `servers/grants.ts` (machines lane)
- `browser-tools.ts:654`, `worker-tools.ts:154` (browser lane): a key caller is
  not a session, so it cannot drive browser windows
- `lift-ask-tool.ts:76`, `tour-tool.ts:237` (a tour needs someone watching —
  keep refused)

If a lane wants keys treated as the owner there, the one-line change is
`caller.kind !== 'local' && caller.kind !== 'key'`, decided per tool.
