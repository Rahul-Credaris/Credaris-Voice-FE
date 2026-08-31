#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"
# Enable versioned hooks
git config core.hooksPath .githooks
chmod +x .githooks/* || true
echo "Installed .githooks as git hooks path"
