#!/usr/bin/env bash
# claude-desktop-webext entry point for Linux. The logic lives in webext.py (Python 3.8+, stdlib only).
set -eu
# Run it rather than just look it up: on Windows, a Microsoft Store alias named python3 exists but fails.
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
  echo "python3 3.8 or later is required (it is preinstalled on Ubuntu / Debian desktops)." >&2
  exit 1
fi
exec python3 "$(cd "$(dirname "$0")" && pwd)/webext.py" "$@"
