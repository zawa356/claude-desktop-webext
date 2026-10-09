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

## For tool developers

1. Add the loader as a submodule:

   ```sh
   git submodule add https://github.com/zawa356/claude-desktop-webext vendor/claude-desktop-webext
   ```

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

## Development

```sh
npm test   # runs tests for webext.ps1 (Windows) and webext.py (where python3 exists); compares both outputs when both run
```

CI runs on `windows-latest` (both implementations, byte-for-byte comparison) and `ubuntu-latest`.

## License

MIT
