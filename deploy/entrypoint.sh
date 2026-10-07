#!/bin/sh
set -eu
if [ ! -d /data/.ok ]
then
  echo "[entrypoint] /data is not initialized. Running ok init --no-mcp --no-skills"
  ok init --no-mcp --no-skills < /dev/null
fi
exec ok start
