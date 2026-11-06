# Chat rendering libraries

Original native rendering uses swift-markdown 0.9.0 (Apache-2.0 with Swift Runtime Library Exception), backed by swift-cmark 0.9.0 (BSD-2-Clause and bundled MIT portions). Their notices are included here and the Swift package lock pins their revisions.

Offline drawing assets:

- Mermaid 11.12.0, MIT, https://github.com/mermaid-js/mermaid
- KaTeX 0.16.22, MIT, https://github.com/KaTeX/KaTeX

The files come from the official npm package archives. SHA-512 archive integrity was verified against each package's registry manifest. Mermaid's bundled dependency notices remain in mermaid.min.js. The KaTeX distribution includes its WOFF2 fonts and styles. License files are bundled beside the assets.

These assets are exposed only through an exact private URL-scheme allowlist. Generated content has no file access. No network fetch is needed for Mermaid or math.
