/**
 * Stays Fixed's name, and the version this app carries.
 *
 * Stays Fixed is a separate product — the owner's own open-source regression
 * safety net (`npm i staysfixed`, MIT) — that this app ships inside itself. It
 * is not this app's brand, so it does not belong in `brand.ts`; it lives here so
 * the page, the tools and the agents' server all say the same words, and so a
 * rename is one line rather than a search.
 *
 * `STAYS_FIXED_VERSION` is the exact version the main process expects to find in
 * `node_modules/staysfixed`. It is pinned, not a range: the page reads files the
 * engine writes (`.staysfixed/v2/last-check.json`) and imports two of its
 * modules by path for progress, and a minor version that moved either would
 * otherwise turn into a page that silently shows nothing. `engine.ts` compares
 * the two and says so in a sentence when they differ.
 */

export const STAYS_FIXED = 'Stays Fixed'

export const STAYS_FIXED_VERSION = '0.15.0'

/** The name an agent sees the server under, in every agent's configuration. */
export const STAYS_FIXED_SERVER = 'staysfixed'

/**
 * The agents a session can be given the server in — every agent this app runs.
 * `src/main/staysfixed/agents.ts` has how each one takes it, and
 * `agents.test.ts` fails if one of these has no way in.
 */
export const STAYS_FIXED_AGENTS = ['claude', 'codex', 'gemini'] as const
