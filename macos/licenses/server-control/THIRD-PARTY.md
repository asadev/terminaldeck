# Apps engine third-party record — checked 2026-10-07

## Railpack

- Source: https://github.com/railwayapp/railpack
- Licence checked directly: [Railway's MIT licence](https://raw.githubusercontent.com/railwayapp/railpack/main/LICENSE), copyright 2025 Railway Corp.
- Integration: invoke an already installed server Railpack binary for automatic builds; no Go code, helper or binary is shipped in the Mac app. BuildKit must already be configured; unavailable otherwise. No silent installation. [Official CLI reference](https://railpack.com/reference/cli) supports `build --name`.
- No Railpack source is copied. Any later vendoring/distribution must include its complete MIT copyright and licence notice.

## Coolify template subset

- Source and credit: Coolify by coolLabs / Andras Bacsai, [repository](https://github.com/coollabsio/coolify).
- Licence checked directly: [Apache License 2.0](https://raw.githubusercontent.com/coollabsio/coolify/main/LICENSE). Repository licence appendix identifies 2025 Andras Bacsai. Root NOTICE URL returned 404 at this check; do not assume later versions lack one.
- Adapted item: [Uptime Kuma template](https://github.com/coollabsio/coolify/blob/main/templates/compose/uptime-kuma.yaml), reviewed on 2026-10-07. Translated its service image, internal port and named-data-volume requirement into `BackendAppsTemplates.swift`.
- Changes: removed Coolify's special URL environment variable and YAML; Terminal Deck manages its own HTTPS address, private network, health gate and immutable deployment tags. No Coolify dashboard/server is installed. The catalogue retains source, credit and licence.
- This adaptation retains attribution here and carries a prominent change notice in the Swift source. Include the complete Apache-2.0 licence in distribution packaging (DKA wiring required); see `BackendApps-Coolify-LICENSE.txt` beside this record. The deployed Uptime Kuma image is separately maintained upstream; its application licence is [MIT](https://github.com/louislam/uptime-kuma/blob/master/LICENSE). The server pulls the image; the Mac does not distribute it.

## Caddy

- No Caddy source copied. [Official API documentation](https://caddyserver.com/docs/api) used for loopback-only administration and per-route updates. Caddy installation is a separate approved server action.
# APD template source and licence record — 2026-10-07

New local evidence for DKA to merge into `THIRD-PARTY.md`. APD has not edited that shared record.

## Coolify adaptation

Credit: **Coolify by coolLabs / Andras Bacsai**. The [primary upstream licence](https://raw.githubusercontent.com/coollabsio/coolify/main/LICENSE) is Apache License 2.0 and its appendix identifies copyright 2025 Andras Bacsai. The [root NOTICE fetch](https://raw.githubusercontent.com/coollabsio/coolify/main/NOTICE) returned HTTP 404 on this check. Recheck NOTICE before refreshing the adapted source.

The reviewed subset adapts these upstream service image, internal port and declared saved-data tuples:

| Template | Reviewed upstream source | Software / internal port | Declared saved data |
| --- | --- | --- | --- |
| Uptime Kuma | [Coolify template](https://github.com/coollabsio/coolify/blob/main/templates/compose/uptime-kuma.yaml) | `louislam/uptime-kuma:2` / 3001 | `/app/data` |
| IT Tools | [Coolify template](https://github.com/coollabsio/coolify/blob/main/templates/compose/it-tools.yaml) | `corentinth/it-tools:latest` / 80 | `/app/data` |
| Excalidraw | [Coolify template](https://github.com/coollabsio/coolify/blob/main/templates/compose/excalidraw.yaml) | `excalidraw/excalidraw:latest` / 80 | None |

Prominent change notice is at the top of `BackendAppsDataTemplates.swift`: Terminal Deck translated a fixed allowlist into Swift; removed Coolify-specific URL environment variables and YAML; kept only the reviewed private data paths. The existing Apps engine provides automatic HTTPS, private networking, health checks and immutable retained deployment tags. No Coolify dashboard is installed or embedded. IT Tools' data mapping is retained because its reviewed Coolify template declares it; this record does not claim that IT Tools' browser features themselves require server persistence. Excalidraw drawings remain in browser storage and a collaboration service is not included.

Tags are resolved to a checked `sha256:` image ID during deployment, then retained under Terminal Deck's own immutable version tag. `latest` here is an upstream initial-source tag, not an unattended-update policy. Updates and rollback of template apps still refuse until APE connects a safe maintenance path.

## Distinct application licences

No application source or binary is shipped in the Mac app; the approved server pulls upstream software. These licences are separate from the Coolify template adaptation:

| Application | Primary licence checked | Source |
| --- | --- | --- |
| Uptime Kuma | [MIT](https://raw.githubusercontent.com/louislam/uptime-kuma/master/LICENSE) | [louislam/uptime-kuma](https://github.com/louislam/uptime-kuma) |
| IT Tools | [GPL version 3](https://raw.githubusercontent.com/corentinth/it-tools/main/LICENSE) | [corentinth/it-tools](https://github.com/corentinth/it-tools) |
| Excalidraw | [MIT](https://raw.githubusercontent.com/excalidraw/excalidraw/master/LICENSE) | [excalidraw/excalidraw](https://github.com/excalidraw/excalidraw) |

No GPL application implementation was copied into Terminal Deck. Any future distribution or modification of the server applications requires its own licence review and source/notice handling.

## Local evidence and packaging

The existing `BackendApps-Coolify-LICENSE.txt` contains the Apache-2.0 terms but omits the upstream appendix/copyright. NEW `BackendAppsData-Coolify-LICENSE.txt` retains those terms and adds the verified appendix. DKA must include this complete licence and the merged attribution/change record in the shipped app's notices. No packaging change was performed by APD.

Local SHA-256:

- `BackendAppsData-Coolify-LICENSE.txt`: `cc4b5dd040f7260d77ca328b8d1f3e9928fdd4588eb10635f8424f08dd18855a`.
- `BackendAppsData-Coolify-Reviewed-Templates.txt`: `d5978dce6912c419e1fd4fc806720582524734c79d092e2dc49a9f3233bc4d32`.

The licence file is a complete semantic transcription, preserving the pre-existing CRLF terms and appending the upstream appendix in LF. Its hash identifies this local file, **not upstream raw bytes**. The reviewed tuple file is a normalized local record, **not upstream YAML bytes**. An upstream commit SHA could not be verified: GitHub's commit API/history was inaccessible to web fetch and the sandbox CLI could not resolve GitHub. URLs above were verified through primary pages; no commit pin or upstream byte hash is claimed. DKA should pin a verified upstream commit when network access allows it.
