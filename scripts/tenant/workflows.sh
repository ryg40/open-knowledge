#!/bin/sh
set -eu
if ! command -v node >/dev/null 2>&1; then
  echo "workflows: missing command: node" >&2
  exit 2
fi
script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
exec node "$script_dir/workflows.mjs" "$@"
