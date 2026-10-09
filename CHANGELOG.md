# Changelog

All notable changes are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/). `package.json`, `$LoaderVersion` in `bin/webext.ps1` and `LOADER_VERSION` in `bin/webext.py` must match.

## [Unreleased]

### Fixed

- Windows: a running Claude Code CLI (`claude.exe`, e.g. from the VS Code extension) was counted as a second Claude Desktop installation, so install stopped with "Multiple installations found". A `claude.exe` now counts only when `resources\app.asar` sits next to it (as on Linux); the running-process count uses the same rule.

## [0.2.0] - 2026-10-09

Installs on Windows machines where Claude's normal user-data folder does not exist yet, and finds Claude wherever it is installed.

### Fixed

- Accept an existing MSIX virtual user-data directory when the normal roaming directory
  does not yet exist, preserving the stable extension destination and saved settings.
- Apply preflight checks to uninstall as well as install/repair, including virtual slot conflicts.

### Added

- Windows installation discovery from packages, running processes, classic installer
  registry entries and standard locations; show candidates and reject ambiguous selection.
- Explicit `-ClaudePath` / `--claude-path` selection for nonstandard installations.
  Linux now rejects multiple detected installations instead of silently choosing the first.

### Verified

- Windows, Claude Desktop 2.31226 (MSIX) with only the virtualized user-data folder: `diagnose` now succeeds where 0.1.0 reported "start Claude once first". Installing and restarting with this version, classic (non-MSIX) Windows installations and Linux have not been tested on a real machine yet.

## [0.1.0] - 2026-10-09

First release.

### Added

- `bin/webext.ps1` (Windows PowerShell 5.1) and `bin/webext.py` (Linux, Python 3.8+), with the actions `diagnose`, `install`, `uninstall` and `rebuild`. Each tool's plain MV3 extension is kept in its own store folder, and the single Claude Desktop extension slot is generated from all of them. The two implementations produce byte-identical manifests ([docs/SPEC.md](docs/SPEC.md)).
- Safety:
  - Strict merge validation: an extension that cannot be merged is skipped, so the slot stays loadable.
  - Every change runs as a transaction with rollback, and old files are moved to backups instead of being deleted.
  - Slot ownership detection: a real React DevTools install or another tool's slot is never overwritten.
  - `REACT_PROFILE` is removed only by the loader that set it, and only after the last extension is uninstalled.
  - A loader refuses to change anything written by a newer schema.
- Migration from standalone installs (`adopt` in `desktop-webext.json`, `-AdoptEnv` / `--adopt-env`).
- `tools/package.mjs`: builds a ready-to-ship folder with install, uninstall, diagnose and repair scripts for Windows and Linux. It then verifies the result by installing it into a sandbox.
- Tests for both implementations, including a cross-implementation comparison, run in CI on Windows and Ubuntu.

### Verified

- Windows, Claude Desktop 2.31226: claude-split-ui and claude_ctrl-enter 0.4.0 work side by side after a restart. Linux has not been tested on a real machine.
