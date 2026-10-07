#!/bin/sh
set -eu
container_cli=${OK_CONTAINER_CLI:-docker}

usage() {
  echo "usage: $0 <image>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
image=$1
[ -n "$image" ] || usage
host_port=${SMOKE_PORT:-}
if [ -n "$host_port" ]; then
  case $host_port in
    *[!0-9]*) usage ;;
  esac
  [ "${#host_port}" -le 5 ] && [ "$host_port" -ge 1 ] && [ "$host_port" -le 65535 ] || usage
fi

wait_seconds=90
probe="fetch('http://127.0.0.1:8080/readyz',{signal:AbortSignal.timeout(2000)}).then(r=>process.exit(r.status===200?0:1)).catch(()=>process.exit(1))"

fail() {
  echo "smoke: $1" >&2
  exit 1
}

suffix=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
name=ok-smoke-$suffix
started=
log_dir=
start_pid=

remove_container() {
  if [ -n "$started" ]; then
    "$container_cli" rm --force --volumes "$name" >/dev/null 2>&1 || true
    started=
  fi
  "$container_cli" rm --force --volumes "$name-version" "$name-probe" >/dev/null 2>&1 || true
  if [ -n "$start_pid" ]; then
    wait "$start_pid" 2>/dev/null || true
    start_pid=
  fi
  if [ -n "$log_dir" ]; then
    rm -r "$log_dir"
    log_dir=
  fi
}

trap remove_container EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "smoke: version of $image"
version_output=$("$container_cli" run --rm --name "$name-version" --network none --entrypoint ok "$image" --version) \
  || fail "ok --version failed"
version=$(printf '%s\n' "$version_output" | sed -n '1p')
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+' \
  || fail "ok --version printed no version"
echo "smoke: version $version"

log_dir=$(mktemp -d "${TMPDIR:-/tmp}/ok-smoke.XXXXXX")
echo "smoke: start container $name"
started=1
"$container_cli" create --rm --read-only \
  --name "$name" \
  --publish "127.0.0.1:$host_port:8080" \
  --volume /data \
  --tmpfs /tmp \
  --tmpfs /home/openknowledge:mode=1777 \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --env PORT=8080 \
  --env OK_BIND=0.0.0.0 \
  --env OK_ALLOW_EXTERNAL=1 \
  --env OK_EXTERNAL_URL=http://127.0.0.1:8080 \
  --env OK_IDLE_SHUTDOWN=off \
  --env DO_NOT_TRACK=1 \
  --env OK_LOG_LEVEL=warn \
  --env OK_MCP_AUTOSTART=0 \
  "$image" >/dev/null || fail "container creation failed"
"$container_cli" start --attach "$name" >"$log_dir/container.log" 2>&1 &
start_pid=$!

host_port=

echo "smoke: wait up to ${wait_seconds}s for /readyz"
ready=
wait_started=$(date +%s)
deadline=$((wait_started + wait_seconds))
while [ "$(date +%s)" -lt "$deadline" ]; do
  state=$("$container_cli" inspect --format '{{.State.Status}}' "$name" 2>/dev/null) || state=removed
  if [ "$state" != running ] && [ "$state" != created ]; then
    wait "$start_pid" 2>/dev/null || true
    start_pid=
    tail -n 20 "$log_dir/container.log"
    fail "container stopped before /readyz answered"
  fi
  if [ "$state" = running ]; then
    if [ -z "$host_port" ]; then
      host_port=$("$container_cli" port "$name" 8080/tcp 2>/dev/null | sed -n '1p') || host_port=
      echo "smoke: published on ${host_port:-no host port}"
    fi
    if "$container_cli" run --rm --name "$name-probe" --network "container:$name" --entrypoint node "$image" -e "$probe" >/dev/null 2>&1; then
      ready=1
      break
    fi
  fi
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || break
  if [ "$remaining" -gt 2 ]; then remaining=2; fi
  sleep "$remaining"
done
if [ -z "$ready" ]; then
  tail -n 20 "$log_dir/container.log"
  elapsed=$(($(date +%s) - wait_started))
  fail "/readyz did not answer 200 after ${elapsed}s (limit ${wait_seconds}s); Docker operations and cleanup can add time"
fi
echo "smoke: /readyz answered 200"

echo "smoke: stop container $name"
"$container_cli" rm --force --volumes "$name" >/dev/null || fail "container removal failed"
started=

echo "smoke: ok $version"
