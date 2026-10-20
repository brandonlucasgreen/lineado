#!/bin/bash
#
# What CI runs over scripts/. Cheap, fast, and on Linux.
#
set -euo pipefail
cd "$(dirname "$0")/.."

FAILED=0

for script in scripts/*.sh; do
  if ! bash -n "$script"; then
    echo "syntax error in $script" >&2
    FAILED=1
  fi
  if [ ! -x "$script" ]; then
    echo "$script is not executable" >&2
    FAILED=1
  fi
  if ! head -1 "$script" | grep -q '^#!/bin/bash'; then
    echo "$script has no bash shebang" >&2
    FAILED=1
  fi
  # Every script here assumes it runs from the repo root.
  if ! grep -q 'cd "$(dirname "$0")/\.\."' "$script"; then
    echo "$script does not cd to the repo root" >&2
    FAILED=1
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning scripts/*.sh || FAILED=1
else
  echo "note: shellcheck not installed, skipping"
fi

[ "$FAILED" -eq 0 ] && echo "Shell checks passed." || { echo "Shell checks FAILED." >&2; exit 1; }
