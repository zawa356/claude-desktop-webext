# AISTATE
<!-- AI-optimized state. Not for humans. Update every work unit (AGENTS.md). Tags: V=AI ran it, U=user verified on real Claude, O=observed/reported, H=hypothesis. LOG newest first, cap ~30. -->

## META
- updated: 2026-10-09
- repo: https://github.com/zawa356/claude-desktop-webext (PRIVATE at creation). MIT, holder zawa356. user replies in Japanese.
- origin: split out of claude-split-ui session (Desktop support). consumers: zawa356/claude-split-ui (planned), zawa356/claude_ctrl-enter (planned 0.4 migration).

## PURPOSE / DECISIONS
- DEC-1 Claude Desktop loads ONE unpacked ext from <userData>/extensions/fmkadmapgofadopljbjfkapdkoienihi when REACT_PROFILE=1 (React DevTools hook; loaded before main window). V (read-only asar scan, Claude 2.31226) + U (split-ui PoC and ctrl-enter).
- DEC-2 user wanted: no inter-plugin dependency, no brand-new convention, minimal dev effort (git submodule). => unit = plain standalone MV3 folder (same as lugia19/Claude-WebExtension-Launcher web-extensions/<folder>), loader merges into slot. launcher itself rejected as base (separate patched Claude, asar mod, admin).
- DEC-3 store outside slot (%LOCALAPPDATA%\ClaudeDesktopWebExt / ~/.local/share/claude-desktop-webext); slot = disposable build output; repair = rebuild.
- DEC-4 strict validation; unmergeable ext skipped so generated manifest is always loadable (invalid manifest/missing file would make Electron drop the whole slot).
- DEC-5 two impls: PowerShell 5.1 (Windows) + Python3 stdlib (Linux); byte-identical manifest required; Linux needs python3 >= 3.8.
- DEC-6 user-chosen: Windows + Linux at once; dedicated store folder; AI creates private repo and pushes.

## FILES
- bin/webext.ps1 (actions diagnose|install|uninstall|rebuild; -Config/-Id/-Source/-Order/-AdoptEnv/-TakeOver/-Yes; test-only -Sandbox/-FailAt). undo records are data (move/env/bytes), NOT closures (GetNewClosure loses script-scope functions).
- bin/webext.py (same CLI in argparse style: action --config ... --sandbox --fail-at), bin/webext.sh (python3 wrapper).
- tools/package.mjs: --config --extension --out [--no-verify] -> folder with install/uninstall/diagnose/repair .bat(CRLF)/.sh, desktop-webext.json(source=extension), extension/, claude-desktop-webext/{bin,LICENSE,README}. verify = sandbox install via python3 or powershell.
- tests/loader.test.mjs: 15 cases per impl + cross-impl byte compare (needs both).
- docs/SPEC.md: paths, files, merge rules, ownership table, transactions, env, exit codes.

## STATUS
- ps1: 15/15 tests pass locally (Windows PowerShell 5.1.26100). V
- py: CI green on ubuntu + windows (cross byte-compare with ps1 on windows). not run locally (no python on dev VM).
- REAL [U]: Windows Claude 2.31226 ENV-VM: ctrl-enter (adopted) + split-ui via loader e39289f -> both work after restart.
- consumers released: claude-split-ui v0.2.0 (desktop zip via tools/package.mjs), claude_ctrl-enter v0.4.0 (own wrappers + bundled loader).

## RELEASES
- v0.1.0 (2026-10-09): first release, tag on the docs commit (README Status/Known limitations, CHANGELOG). consumers should pin submodule to v0.1.0.

## NEXT
1. push + CI green (py on ubuntu and windows, cross-compare on windows).
2. claude-split-ui: add submodule vendor/claude-desktop-webext, desktop-webext.json (id claude-split-ui, order 10, source = WXT chrome build), CI packaging, real Desktop test.
3. claude_ctrl-enter 0.4: move to loader (id claude-ctrl-enter, order 50, adopt.markers ["claude-keys.owner.json"], manifestNames ["Claude Enter Patch - Load Probe"], -AdoptEnv from its state envSetByUs; Linux: remove its own environment.d file after adopt). its settings-ui uses chrome.storage key claudeEnterSettingsV1 -> fine (unique).
4. later: backup pruning; localized messages (ja); per-ext enable/disable.

## LOG (newest first)
- 2026-10-09 | claude-opus-5-5 | docs refresh (README status table, pin instructions, known limitations), CHANGELOG.md; released v0.1.0 (user asked for latest releases in all repos). ctrl-enter 0.4.0 install.bat verified by user on ENV-VM [U].
- 2026-10-09 | claude-opus-5-5 | fixes found by consumers: 8.3 short-path copy (d412421), absolute config source (e39289f), webext.sh real python3 check (b46a222; Windows Store alias). made PUBLIC (user). consumers released.
- 2026-10-09 | claude-opus-5-5 | created repo locally: ps1+py loaders, package tool, tests (ps1 15/15 V), SPEC, README, CI.
