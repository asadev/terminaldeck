# Changelog

Notable changes to Terminal Deck. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add to **Unreleased** as you go — `npm version <patch|minor|major>` moves that
section under the new version, stamps it with the date and creates the tag.
A release with nothing under Unreleased is refused rather than shipped blank.

## [Unreleased]

## [0.1.1] — 2026-08-13

### Added

- Updates install from inside the app. It reads the release feed, verifies the
  archive's sha512, and swaps the bundle — none of which needs Squirrel, which
  refuses unsigned builds. The old app is moved aside, not deleted, and moved
  back if the new one fails to land.
- Remote access over your own tailnet: pair a phone by QR, approve it on the
  Mac, and attach to a running session from it. TLS is terminated by
  `tailscale serve`; the app's own listener is loopback-only.
- A start page for new browser tabs, listing the dev servers actually
  listening, instead of guessing `localhost:3000`.
- Windows packaging, built natively in CI. Not yet run on Windows.

### Fixed

- Sessions no longer inherit a parent agent run's environment, which disabled
  transcript saving and left chat mode and cost tracking blank.
- Four panels printed their own name under the dock's.

## [0.1.0] — 2026-08-12

First cut. macOS 12+, Apple silicon, unsigned.

### Added

- Multiple agent sessions per project, each in its own terminal, with tabs and
  scrollback that survives switching away
- Per-tab status — working / waiting / needs-input / exited — classified from a
  headless emulator's viewport rather than from the raw output stream
- Cost and context tracking read from Claude Code's own transcripts
- Session inspector (`⌘⇧I`): timeline, cost breakdown, tool usage, context meter
- Git panel, file tree and viewer, quick open, command palette
- Kanban board and a customisable dashboard per project
- GitHub panel backed by the `gh` CLI
- Embedded browser workspace with tab isolation and Chrome cookie import
- AI readiness score with one-click fixes
- MCP inspector and hook installation
- Preferences with live dark/light theming
- Session resume (`⌘⇧T`)

[Unreleased]: https://github.com/asadev/terminaldeck/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/asadev/terminaldeck/releases/tag/v0.1.0
