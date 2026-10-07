#!/bin/sh
set -eu
if ! command -v node >/dev/null 2>&1; then
  echo "workflows: missing command: node" >&2
  exit 2
fi
node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null) || node_major=0
case $node_major in ''|*[!0-9]*) node_major=0 ;; esac
if [ "$node_major" -lt 24 ]; then
  echo "workflows: Node.js 24 or newer is required" >&2
  exit 2
fi
script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
exec node "$script_dir/workflows.mjs" "$@"
