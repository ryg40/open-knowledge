#!/bin/sh
set -eu
export LC_ALL=C

repo_root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
builder=$repo_root/scripts/tenant/build-architecture-html.py
if ! command -v python3 >/dev/null 2>&1; then
  echo "architecture test: missing command: python3" >&2
  exit 2
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ok-architecture-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

expect_status() {
  wanted=$1
  shift
  actual=0
  "$@" > "$tmp/output" 2>&1 || actual=$?
  if [ "$actual" -ne "$wanted" ]; then
    cat "$tmp/output"
    echo "architecture test: expected $wanted, got $actual: $*" >&2
    exit 1
  fi
}

cd "$repo_root"
expect_status 0 python3 -I "$builder" --selftest
cat "$tmp/output"
expect_status 0 python3 -I "$builder" --out "$tmp/first.html"
expect_status 0 python3 -I "$builder" --out "$tmp/second.html"
if ! cmp -s "$tmp/first.html" "$tmp/second.html"; then
  echo "architecture test: two builds of one source differ" >&2
  exit 1
fi
cp "$tmp/first.html" "$tmp/changed.html"
printf '\n' >> "$tmp/changed.html"
expect_status 1 python3 -I "$builder" --check --out "$tmp/changed.html"
expect_status 1 python3 -I "$builder" --check --out "$tmp/missing.html"
printf '{"nodes": [{"id": "browser", "group": "unknown"}]}\n' > "$tmp/invalid.json"
expect_status 2 python3 -I "$builder" --overlay "$tmp/invalid.json" --out "$tmp/invalid.html"
expect_status 0 python3 -I "$builder" --check
cat "$tmp/output"
pages=1
while IFS= read -r development_path; do
  overlay=${development_path%/}/architecture-graph.local.json
  [ -f "$overlay" ] || continue
  expect_status 0 python3 -I "$builder" --check --overlay "$overlay"
  cat "$tmp/output"
  pages=$((pages + 1))
done < scripts/tenant/public-check.development
echo "architecture test: ok, $pages pages"
