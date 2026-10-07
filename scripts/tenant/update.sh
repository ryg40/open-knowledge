#!/bin/sh
set -eu
if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' '{"error":"missing command: node","exit_code":2,"ok":false}'
  exit 2
fi
script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
exec node "$script_dir/update.mjs" "$@"
