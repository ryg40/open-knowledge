#!/bin/sh
set -eu
if [ ! -d /data/.ok ]
then
  echo "[entrypoint] /data is not initialized. Running ok init --no-mcp --no-skills"
  ok init --no-mcp --no-skills < /dev/null
fi
node /usr/local/lib/ok-no-telemetry.mjs \
  || echo "[entrypoint] a telemetry setting is not applied: the program did not set a key in a configuration file. The lines above name the file and the reason. The server starts." >&2
exec ok start
