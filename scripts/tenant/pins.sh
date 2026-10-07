#!/bin/sh
set -eu
export LC_ALL=C

fail() {
  echo "pins: $*" >&2
  exit 2
}

[ "$#" -eq 0 ] || fail "usage: $0"
for tool in git awk dirname; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing command: $tool"
done
repo_root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd) || fail "cannot find the repository"
cd "$repo_root" || fail "cannot enter the repository"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not a Git working tree"
for file in deploy/Dockerfile scripts/tenant/scan.sh package.json EXPLAINER.md deploy/docs/deployment.md deploy/docs/ci.md deploy/docs/hardening.md; do
  [ -r "$file" ] || fail "cannot read $file"
done

pins=$(awk '
  function save(key, value, source) {
    if (seen[key]++ || value == "") bad = 1
    values[key] = value
    sources[key] = source
  }
  FILENAME == "deploy/Dockerfile" {
    if ($0 ~ /^ARG OK_VERSION=/) save("Upstream version", substr($0, 16), FILENAME " ARG OK_VERSION")
    if ($0 ~ /^ARG OK_NPM_INTEGRITY=/) save("Tarball sha512", substr($0, 22), FILENAME " ARG OK_NPM_INTEGRITY")
    if ($0 ~ /^ARG NODE_IMAGE=/) save("Base image", substr($0, 16), FILENAME " ARG NODE_IMAGE")
    if ($0 ~ /^# syntax=/) save("Dockerfile frontend image", substr($0, 10), FILENAME " # syntax=")
  }
  FILENAME == "scripts/tenant/scan.sh" && /^default_image=/ {
    save("Scanner image", substr($0, 15), FILENAME " default_image")
  }
  FILENAME == "package.json" && /"packageManager"[[:space:]]*:/ {
    line = $0
    sub(/^[[:space:]]*"packageManager"[[:space:]]*:[[:space:]]*"pnpm@/, "", line)
    sub(/"[[:space:]]*,?[[:space:]]*$/, "", line)
    save("pnpm version", line, FILENAME " packageManager")
  }
  END {
    order[1] = "Upstream version"; order[2] = "Tarball sha512"; order[3] = "Base image"
    order[4] = "Scanner image"; order[5] = "Dockerfile frontend image"; order[6] = "pnpm version"
    for (i = 1; i <= 6; i++) {
      key = order[i]
      if (seen[key] != 1) bad = 1
      value = values[key]
      if (i == 1 || i == 6) {
        if (value !~ /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$/) bad = 1
      } else if (i == 2) {
        if (value !~ /^sha512-[A-Za-z0-9+\/]+==$/ || length(value) != 95) bad = 1
      } else {
        split(value, parts, "@sha256:")
        if (parts[1] == "" || parts[2] !~ /^[0-9a-f]+$/ || length(parts[2]) != 64 || parts[3] != "") bad = 1
      }
      printf "%s\t%s\t%s\n", key, value, sources[key]
    }
    if (bad) exit 2
  }
' deploy/Dockerfile scripts/tenant/scan.sh package.json) || fail "missing, repeated or invalid pin source"

printf 'Pin\tValue\tSource\n%s\n' "$pins"
set -- EXPLAINER.md deploy/docs/*.md
for file do
  [ -r "$file" ] || fail "cannot read $file"
done
status=0
awk -v pins="$pins" '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }
  function mismatch(reason) {
    printf "pins: %s:%d: %s\n", FILENAME, FNR, reason > "/dev/stderr"
    bad = 1
  }
  BEGIN {
    count = split(pins, records, "\n")
    for (i = 1; i <= count; i++) {
      split(records[i], record, "\t")
      expected[record[1]] = record[2]
    }
  }
  FNR == 1 { facts = 0 }
  /^## / { facts = FILENAME == "EXPLAINER.md" && $0 == "## Release facts" }
  {
    if (facts && $0 ~ /^\|/) {
      split($0, cells, "|")
      key = trim(cells[2])
      if (key in expected) {
        seen[key]++
        if (trim(cells[3]) != "`" expected[key] "`") mismatch(key " disagrees with its source")
        next
      }
    }
    for (pin in expected) {
      if (index($0, expected[pin])) mismatch(pin " literal outside its Release facts row")
    }
    line = $0
    gsub(/[`"\047()|,;=]/, " ", line)
    words = split(line, tokens, /[[:space:]]+/)
    for (i = 1; i <= words; i++) {
      token = tokens[i]
      if (token ~ /^(node:[0-9]|([^[:space:]]*\/)?gitleaks:v?[0-9]|docker\/dockerfile:[0-9]|sha512-[A-Za-z0-9+\/]+)/ || token ~ /(@sha256:|^sha256:)[0-9a-f]+/) {
        mismatch("pin literal outside its Release facts row: " token)
      } else if (token ~ /^(pnpm@|@inkeep\/open-knowledge@|open-knowledge:)[0-9]+\.[0-9]+\.[0-9]+/) {
        mismatch("version literal outside its Release facts row: " token)
      } else if (token ~ /^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?[.:]?$/ && line ~ /([Uu]pstream|OK_VERSION|smoke: ok|pnpm|packageManager)/) {
        mismatch("version literal outside its Release facts row: " token)
      }
    }
  }
  END {
    for (key in expected) {
      if (seen[key] != 1) {
        printf "pins: EXPLAINER.md: expected one Release facts row for %s, found %d\n", key, seen[key] > "/dev/stderr"
        bad = 1
      }
    }
    if (bad) exit 1
  }
' "$@" || status=$?
case $status in
  0) echo "pins: ok" ;;
  1) exit 1 ;;
  *) fail "cannot check the documentation" ;;
esac
