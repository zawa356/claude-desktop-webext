# claude-desktop-webext

Load several ordinary Chrome-style (MV3) extensions into the **official** Claude Desktop app, without modifying Claude.

> [!IMPORTANT]
> Unofficial. Not affiliated with or endorsed by Anthropic. It relies on undocumented Claude Desktop behaviour and may stop working after any Claude update.

日本語の概要: Claude Desktop が読み込める拡張は1つだけなので、各ツールの「普通の MV3 拡張フォルダ」を1つにまとめて読み込ませる共通ローダーです。各ツールは git submodule で取り込み、`desktop-webext.json` を1つ書くだけで Windows / Linux 用のインストーラー一式を作れます。ツール同士は互いを知る必要がありません。

## Why

Claude Desktop loads exactly **one** unpacked extension, from `<userData>/extensions/fmkadmapgofadopljbjfkapdkoienihi`, and only when the user environment variable `REACT_PROFILE=1` is set (it is the React DevTools hook of the app). If two tools both write that folder, the second one silently replaces the first.

This loader keeps every tool's extension as a normal folder of its own and **generates** that single folder (the "slot") from all of them:

```text
%LOCALAPPDATA%\ClaudeDesktopWebExt\web-extensions\        (Linux: ~/.local/share/claude-desktop-webext/web-extensions/)
  claude-split-ui\     manifest.json + scripts   <- each tool owns only its own folder
  claude-ctrl-enter\   manifest.json + scripts
                 │  merge (content_scripts + permissions)
                 ▼
%APPDATA%\Claude\extensions\fmkadmapgofadopljbjfkapdkoienihi\   (generated, disposable)
  manifest.json  .claude-desktop-webext.json  ext\<id>\...
```

- **No coupling between tools.** A tool ships a standard MV3 extension folder and a 5-line config. It never reads another tool's files.
- **The slot is a build output.** If anything breaks or overwrites it, `repair` regenerates it from the stored folders.
- **One bad extension can't take the others down.** An extension that cannot be merged safely (background worker, unknown permission, missing file, ...) is skipped with a warning, so the generated manifest is always loadable.
- **Never touches Claude itself.** No `app.asar`, MSIX package or binary changes; never closes or restarts Claude; nothing is deleted (old files move to `backups/`).
- **Same folder format as [Claude-WebExtension-Launcher](https://github.com/lugia19/Claude-WebExtension-Launcher)** (one plain MV3 folder per extension), so an extension built for this loader can also be dropped into that launcher's `web-extensions` folder. That launcher is a separate patched Claude install; this project targets the official app.

## Status

| Platform | Status |
|---|---|
| Windows — Claude Desktop 2.31226 (Microsoft Store) | **Manually verified.** [claude-split-ui](https://github.com/zawa356/claude-split-ui) 0.2.x and [claude_ctrl-enter](https://github.com/zawa356/claude_ctrl-enter) 0.4.0 installed side by side: both work after a restart. Migration of a pre-existing standalone claude_ctrl-enter 0.3.0 install kept its saved settings. |
| Linux — Claude Desktop beta | **Untested on a real machine.** `webext.py` is covered by CI only. |
| macOS | Not supported |

Tools built on this loader: [claude-split-ui](https://github.com/zawa356/claude-split-ui) (order 10) and [claude_ctrl-enter](https://github.com/zawa356/claude_ctrl-enter) (order 50).

## For users of a tool built on this

Each tool's release ZIP contains `install` / `uninstall` / `diagnose` / `repair` scripts:

| | Windows | Linux |
|---|---|---|
| Install / update | `install.bat` | `bash install.sh` |
| Remove | `uninstall.bat` | `bash uninstall.sh` |
| Read-only check | `diagnose.bat` | `bash diagnose.sh` |
| Regenerate the slot | `repair.bat` | `bash repair.sh` |

Afterwards, quit Claude completely (tray icon → Quit) and start it again. On Linux, log out and in once after the first install so that `REACT_PROFILE` is picked up.

Requirements: Windows 10/11 with Windows PowerShell 5.1 (built in), or Linux with `python3` ≥ 3.8 (preinstalled on Ubuntu/Debian desktops). No admin/root rights.

## Installation discovery

Windows discovers Claude through MSIX registration, running `claude.exe` processes,
classic installer registry entries, and standard installation directories (including
versioned `app-*` directories). A single running candidate takes precedence. If several
candidates remain, specify the intended executable with `-ClaudePath`:

```powershell
.\diagnose.bat -ClaudePath "D:\Apps\Claude\claude.exe"
.\install.bat -ClaudePath "D:\Apps\Claude\claude.exe"
```

Repeat the selection for repair/uninstall if discovery remains ambiguous. It selects
an installation for diagnostics; it does not change Claude's user-data directory.
On Linux, `--claude-path` accepts the executable, installation directory or `app.asar`.
Finding an installation does not prove that its build supports the extension hook;
classic Windows installations and Linux still require real runtime verification.

The extension destination stays at the existing user-data path, preserving extension
IDs and saved settings. When only MSIX virtualized user data exists, installation can
create the normal `%APPDATA%\Claude\extensions` destination. Diagnosis is read-only.
An existing virtualized extension slot still blocks changes to avoid shadowing it.
Custom `--user-data-dir` profiles are not automatically inferred or relocated.

## For tool developers

1. Add the loader as a submodule:

   ```sh
   git submodule add https://github.com/zawa356/claude-desktop-webext vendor/claude-desktop-webext
   git -C vendor/claude-desktop-webext checkout v0.1.0   # pin a released version
   ```

   Anyone cloning your repository then needs `git clone --recurse-submodules` (or `git submodule update --init`).

2. Add `desktop-webext.json` to your repository:

   ```json
   {
     "id": "my-tool",
     "displayName": "My Tool",
     "source": "path/to/built/extension",
     "order": 100,
     "testedClaudeVersions": { "windows": ["2.31226.0.0"], "linux": [] }
   }
   ```

   | Field | Meaning |
   |---|---|
   | `id` | Folder name, `^[a-z0-9][a-z0-9._-]{0,63}$`. Never change it after release. |
   | `source` | Built MV3 extension folder, relative to this file. Used for local installs. |
   | `order` | Injection order, lower first (default 100). Use a small value only if you must run before other tools, for example to wrap `fetch`. |
   | `testedClaudeVersions` | Versions you checked by hand. Others give a warning, not an error. |
   | `adopt` | Optional, for migrating your own pre-existing standalone install: `{ "markers": ["file-in-old-slot"], "manifestNames": ["old manifest name"] }`. |

3. Build your extension as usual, then package it:

   ```sh
   node vendor/claude-desktop-webext/tools/package.mjs --config desktop-webext.json --extension <built folder> --out dist/my-tool-desktop
   ```

   This copies the extension, the loader and the wrapper scripts into `dist/my-tool-desktop`. Then it installs the result into a throw-away sandbox to prove that it merges cleanly. Zip that folder for your release.

4. In GitHub Actions, check out with submodules: `actions/checkout@v5` with `submodules: true`.

For a local try-out without packaging:

```powershell
powershell -ExecutionPolicy Bypass -File vendor\claude-desktop-webext\bin\webext.ps1 -Action install -Config desktop-webext.json
```

```sh
bash vendor/claude-desktop-webext/bin/webext.sh install --config desktop-webext.json
```

### What an extension may contain

Only what can be merged into one manifest safely:

- `manifest_version: 3`, plain `name` (no `__MSG_` placeholders), `version`, `description`, `icons` and similar descriptive keys
- `content_scripts` with `matches`, `exclude_matches`, `include_globs`, `exclude_globs`, `js`, `css`, `run_at`, `world`, `all_frames`, `match_about_blank`, `match_origin_as_fallback`
- `permissions`: `storage` only

Anything else (`background`, `action`, `options_page`, `host_permissions`, `web_accessible_resources`, `key`, other permissions) makes the extension unmergeable. Install refuses it; a manually placed one is skipped.

### Rules of the road

- All merged extensions share **one extension ID and one `chrome.storage` area**. Prefix your storage keys with your `id`.
- `world: "MAIN"` scripts share the page with every other tool. Don't replace globals destructively. Wrap `fetch` and friends, call the original, and fail open.
- The extension ID depends on the slot path, which never changes. Settings in `chrome.storage` therefore survive updates and reinstalls.

Details: [docs/SPEC.md](docs/SPEC.md).

## Known limitations

- Messages are in English only. Tools may add their own localized lines around the output; claude_ctrl-enter adds Japanese ones.
- Backups under `backups/` are never pruned automatically. They are small, but you can delete old ones by hand.
- If the user profile path is very long, a Windows path can exceed 260 characters; the operation then fails and is rolled back. Normal profile paths are far below that limit.
- A tool that writes the slot folder directly, without this loader, makes the loader refuse to change the slot. `repair` with `-TakeOver` / `--take-over` moves that content to backups and regenerates the slot.
- Claude updates may remove or change the `REACT_PROFILE` hook at any time. Each tool's `testedClaudeVersions` turns untested versions into a warning.

## Development

```sh
npm test   # runs tests for webext.ps1 (Windows) and webext.py (where python3 exists); compares both outputs when both run
```

CI runs on `windows-latest` (both implementations, byte-for-byte comparison) and `ubuntu-latest`.

## License

MIT
