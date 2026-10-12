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

suffix=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
name=ok-no-telemetry-$suffix

remove_containers() {
  "$container_cli" rm --force --volumes "$name-edit" "$name-full" >/dev/null 2>&1 || true
}

trap remove_containers EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cases=$(cat <<'CASES'
set -eu
group=$1
program=/usr/local/lib/ok-no-telemetry.mjs
config=/data/.ok/config.yml
global=$HOME/.ok/global.yml
other=/data/other
keys='telemetry:\n  localSink:\n    enabled: false\nlossCapture:\n  enabled: false\n'
report='telemetry:\n  skillInstallReports:\n    enabled: false\n'
passed=0
title=start

fail() {
  echo "no-telemetry test: $title: $1" >&2
  [ ! -f /work/output ] || cat /work/output >&2
  exit 1
}

begin() {
  title=$1
  rm -rf /data/.ok "$other" "$HOME/.ok" /work/output
  mkdir /data/.ok "$other" "$HOME/.ok"
  printf '%b' "$report" > "$global"
}

run() {
  status=0
  node "$program" ${3:+"$3"} > /work/output 2>&1 || status=$?
  [ "$status" -eq "$1" ] || fail "exit code $status, not $1"
  [ -z "${2:-}" ] || grep -F -- "$2" /work/output >/dev/null || fail "the output does not name: $2"
}

holds() {
  printf '%b' "$2" > /work/expected
  cmp -s /work/expected "$1" || fail "$1 does not hold the expected bytes"
}

state() {
  find /data "$HOME" /tmp -exec stat -c '%n %F %s %i' {} + | sort
  find /data "$HOME" /tmp -type f -exec cksum {} + | sort
}

unchanged() {
  state > /work/before
  run 1 "$1"
  state > /work/after
  cmp -s /work/before /work/after || fail "a file or a directory changed"
}

pass() {
  passed=$((passed + 1))
}

edit_cases() {
  begin 'new file'
  rm -r "$HOME/.ok"
  run 0 'lines added at the end'
  holds "$config" "$keys"
  holds "$global" "$report"
  [ ! -e /data/.ok/local ] || fail "the program made /data/.ok/local"
  run 0 'no-telemetry: ok' --check
  pass

  begin 'lines added at the end'
  printf 'a: 1\n' > "$config"
  inode=$(stat -c %i "$config")
  run 0 'lines added at the end'
  holds "$config" "a: 1\n$keys"
  [ "$(stat -c %i "$config")" = "$inode" ] || fail "the file has another inode"
  pass

  title='second run'
  state > /work/before
  run 0
  state > /work/after
  cmp -s /work/before /work/after || fail "the second run changed a file"
  [ ! -s /work/output ] || fail "the second run printed a line"
  pass

  begin 'lines with CRLF'
  printf 'a: 1\r\n' > "$config"
  run 0 'lines added at the end'
  holds "$config" 'a: 1\r\ntelemetry:\r\n  localSink:\r\n    enabled: false\r\nlossCapture:\r\n  enabled: false\r\n'
  pass

  begin 'value replaced'
  printf 'lossCapture:\n  enabled: true # why\ntelemetry: {localSink: {enabled: "yes"}}\n' > "$config"
  run 0 'value replaced'
  holds "$config" 'lossCapture:\n  enabled: false # why\ntelemetry: {localSink: {enabled: false}}\n'
  pass

  begin 'lines added in the mapping'
  printf 'telemetry:\n    # note\n    other: 1\nlossCapture:\n  enabled: false\n' > "$config"
  run 0 'lines added in the mapping'
  holds "$config" 'telemetry:\n    # note\n    localSink:\n      enabled: false\n    other: 1\nlossCapture:\n  enabled: false\n'
  pass

  begin 'file written again by the parser'
  printf 'keep: [1, 2]\ntelemetry: ~\nlossCapture:\n  enabled: false\n' > "$config"
  run 0 'file written again by the parser'
  holds "$config" 'keep: [ 1, 2 ]\ntelemetry:\n  localSink:\n    enabled: false\nlossCapture:\n  enabled: false\n'
  pass

  begin 'file with only null'
  printf 'null\n' > "$config"
  run 0 'set to false'
  holds "$config" "$keys"
  pass

  begin 'number that the parser writes with another text'
  printf 'size: 12345678901234567890\ntelemetry: ~\n' > "$config"
  run 1 'telemetry.localSink.enabled is not set'
  holds "$config" 'size: 12345678901234567890\ntelemetry: ~\nlossCapture:\n  enabled: false\n'
  pass

  begin 'file with two documents'
  printf 'a: 1\n---\nb: 2\n' > "$config"
  unchanged 'not changed: the YAML parser reports an error'
  pass

  begin 'link inside .ok'
  printf 'a: 1\n' > /data/.ok/real.yml
  ln -s real.yml "$config"
  run 0 'lines added at the end'
  [ -L "$config" ] || fail "the link is not a link any more"
  holds /data/.ok/real.yml "a: 1\n$keys"
  pass

  begin 'link to a file outside .ok'
  printf 'key: value\n' > "$other/settings.yml"
  ln -s ../other/settings.yml "$config"
  unchanged 'not changed: a symbolic link leads out of the .ok directory'
  run 1 'a symbolic link leads out of the .ok directory' --check
  pass

  begin 'link to a file of a repository'
  printf 'ref: refs/heads/main\n' > "$other/HEAD"
  ln -s ../other/HEAD "$config"
  unchanged 'not changed: a symbolic link leads out of the .ok directory'
  pass

  begin 'link to a JSON file'
  mkdir /data/.ok/local
  printf '{ "id": "abc" }\n' > /data/.ok/local/state.json
  ln -s local/state.json "$config"
  unchanged 'not changed: the name of the link target does not end in .yml or .yaml'
  pass

  begin 'link to a file that does not exist'
  ln -s ../other/new/deep/file.yml "$config"
  unchanged 'not changed: the symbolic link leads to no file'
  pass

  begin 'link in the home directory'
  rm "$global"
  ln -s /tmp/global.yml "$global"
  printf '%b' "$keys" > "$config"
  unchanged 'not changed: the symbolic link leads to no file'
  pass

  begin 'local directory that is a link'
  printf '%b' "$keys" > "$config"
  printf 'lossCapture:\n  enabled: true\n' > "$other/config.yml"
  ln -s ../other /data/.ok/local
  unchanged 'not changed: a symbolic link leads out of the .ok directory'
  pass

  begin '.ok directory that is a link'
  rmdir /data/.ok
  printf 'a: 1\n' > "$other/config.yml"
  ln -s other /data/.ok
  unchanged 'is a symbolic link or not a directory'
  rm /data/.ok
  pass

  begin 'hard link to a page outside .ok'
  printf '# Notes\n\nSome text: with colon\n' > "$other/note.md"
  ln "$other/note.md" "$config"
  unchanged 'not changed: the file has more than one hard link'
  run 1 'the file has more than one hard link' --check
  pass

  begin 'configuration file that is a directory'
  mkdir "$config"
  unchanged 'not changed: the path is not a regular file'
  pass

  begin 'configuration file that is a FIFO'
  mkfifo "$config"
  unchanged 'not changed: the path is not a regular file'
  pass

  begin 'old temporary file'
  printf '%b' "$keys" > "$config"
  printf 'old\n' > "$config.no-telemetry.tmp"
  printf 'keep\n' > "$config.7.tmp"
  run 0
  [ ! -e "$config.no-telemetry.tmp" ] || fail "the old temporary file is present"
  holds "$config.7.tmp" 'keep\n'
  holds "$config" "$keys"
  pass

  begin 'old temporary file in a directory without write permission'
  printf 'a: 1\n' > "$config"
  printf 'old\n' > "$config.no-telemetry.tmp"
  chmod 555 /data/.ok
  run 0 'lines added at the end'
  holds "$config" "a: 1\n$keys"
  holds "$config.no-telemetry.tmp" 'old\n'
  printf 'lossCapture: {enabled: true}\n' > "$config"
  unchanged 'not changed: EEXIST'
  chmod 755 /data/.ok
  pass
}

full_disk() {
  begin "full disk: $1"
  printf '%b' "$2" > /work/body
  {
    printf '#'
    head -c "$((65536 - $3 - $(stat -c %s /work/body) - 2))" /dev/zero | tr '\0' 'x'
    printf '\n'
    cat /work/body
  } > "$config"
  dd if=/dev/zero of="$other/fill" bs=4096 2>/dev/null || true
  unchanged 'not changed: ENOSPC'
  pass
}

full_cases() {
  full_disk 'lines added at the end, no free byte' 'keep: 1\n' 0
  full_disk 'lines added at the end, some free bytes' 'keep: 1\n' 20
  full_disk 'value replaced' 'lossCapture: {enabled: true}\ntelemetry: {localSink: {enabled: false}}\n' 0
  full_disk 'lines added in the mapping' 'telemetry:\n  other: 1\nlossCapture:\n  enabled: false\n' 0
  full_disk 'file written again by the parser' 'telemetry: ~\nlossCapture:\n  enabled: false\n' 0
}

[ -f "$program" ] || fail "the image does not hold $program"
case $group in
  edit) edit_cases ;;
  full) full_cases ;;
  *) fail "unknown group $group" ;;
esac
echo "no-telemetry test: $group ok, $passed cases"
CASES
)

run_group() {
  printf '%s\n' "$cases" | "$container_cli" run --rm --interactive \
    --name "$name-$1" \
    --network none \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs "/data:$2" \
    --tmpfs /tmp \
    --tmpfs /work:mode=1777 \
    --tmpfs /home/openknowledge:mode=1777 \
    --entrypoint sh \
    "$image" -s "$1" || { echo "no-telemetry test: the group $1 failed" >&2; exit 1; }
}

echo "no-telemetry test: edit cases in $image"
run_group edit mode=1777
echo "no-telemetry test: full disk cases in $image"
run_group full mode=1777,size=1m
echo "no-telemetry test: ok"
