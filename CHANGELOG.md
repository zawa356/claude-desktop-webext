# Changelog

All notable changes are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/). `package.json`, `$LoaderVersion` in `bin/webext.ps1` and `LOADER_VERSION` in `bin/webext.py` must match.

## [Unreleased]

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
