#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
cd "$repo_root"

# This command only reads Git HEAD and the host/runtime facts used by ClaudioCore. It never
# calls integrations connect/repair/disconnect, writes a host config, or previews audio.
exec swift run --quiet --package-path "$repo_root/helper" claudio acceptance workbuddy-preflight "$@"
