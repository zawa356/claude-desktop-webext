# AGENTS.md

Instructions for AI coding agents working in this repository.

## Start of every session

1. Read [docs/AISTATE.md](docs/AISTATE.md) (AI-maintained project state).
2. `git fetch` and check whether local `main` is behind `origin/main`.
3. Read [docs/SPEC.md](docs/SPEC.md) before changing `bin/`.

## AISTATE protocol

Every time you do work here (code, docs, config, investigation, test runs), update `docs/AISTATE.md` before finishing, in the same commit as the work.

- AI-optimized: dense, keyed, factual. Keep the section layout. Update `META`, the affected sections, and add one line at the top of `LOG` (`YYYY-MM-DD | agent | what; results; open items`).
- Confidence tags: `V` = you ran it, `U` = the user verified it on a real Claude, `O` = observed or reported, `H` = hypothesis.
- Never write secrets, account or organization IDs, or Claude config contents.

## Rules

- `bin/webext.ps1` and `bin/webext.py` implement the same spec. Change both together, keep the generated manifests byte-identical, and extend `tests/loader.test.mjs`.
- `bin/webext.ps1` must run on Windows PowerShell 5.1. Line endings follow `.gitattributes`: `*.ps1` and `*.bat` CRLF, everything else LF.
- Never modify Claude itself (`app.asar`, MSIX, binaries). Never close, kill or restart Claude: the user restarts it.
- Never delete user files; move them to `backups/`.
- Downstream tools vendor this repo as a git submodule. Keep `tools/package.mjs` arguments and `desktop-webext.json` fields backward compatible, and bump `schema` only with a migration plan.

## Commands

```sh
npm test
```

On the author's Windows VM, Node is not on Git Bash's PATH: `export PATH="/c/Program Files/nodejs:$PATH"`. Python is not installed locally, so `webext.py` is tested in CI.
