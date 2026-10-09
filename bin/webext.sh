#!/usr/bin/env bash
# claude-desktop-webext entry point for Linux. The logic lives in webext.py (Python 3.8+, stdlib only).
set -eu
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required (it is preinstalled on Ubuntu / Debian desktops)." >&2
  exit 1
fi
exec python3 "$(cd "$(dirname "$0")" && pwd)/webext.py" "$@"
