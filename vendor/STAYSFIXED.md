# Stays Fixed, as this app ships it

`staysfixed-0.15.0-neutral.tgz` is the published `staysfixed@0.15.0` with example
names in three files changed to the neutral placeholder this repository uses.
Nothing that runs is different.

| | |
|---|---|
| Source | `https://registry.npmjs.org/staysfixed/-/staysfixed-0.15.0.tgz` |
| Source integrity | `sha512-/DhMtPbkRMwtXNYZz8kiqIqoI1WxgKmoXv8JnWWBblIjnXSc+y4LzxT8JRN1zydwX7l32xOffqHxDPiKk8XcSA==` (the integrity the lockfile carried before) |
| This file's integrity | `sha512-bVgqUsA2s65tjKqISJGADAAgeb5zN1ZKkj5i4UPxjGtbtDN8YdKCPLHptbfZS/+rKiyH8cU9/wDcG0Pvpt+dbg==` |
| Version inside | `0.15.0` — `package.json` is byte-for-byte the published one |
| Licence | MIT — `LICENSE` is byte-for-byte the published one |
| Files changed | `CHANGELOG.md` (one line), `docs/design-v2.md` (two lines), `src/v2/doctor.js` (three comment lines) |

Rebuild it with `node scripts/vendor-staysfixed.mjs`: it fetches the source from
the public registry, refuses it unless the source integrity matches, changes
comment and Markdown lines only (and refuses to touch any other kind of line),
and refuses the result unless it matches the integrity above. Two runs give
the same bytes.

When a Stays Fixed release on npm carries the same wording, point
`package.json` back at it and delete this folder.
