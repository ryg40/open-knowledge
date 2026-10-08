#!/bin/sh
set -eu
export LC_ALL=C

repo_root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ok-public-check-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
repo=$tmp/repo
check=$repo/scripts/tenant/public-check.sh
allow=$repo/scripts/tenant/public-check.allow
mkdir -p "$repo/deploy" "$repo/packages/cli" "$repo/scripts/tenant"
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM

commit() {
  git -C "$repo" add .
  git -C "$repo" -c core.hooksPath=/dev/null -c user.name=Fixture -c user.email=fixture@example.com commit -qm "$1"
}

expect_status() {
  wanted=$1
  shift
  actual=0
  (cd "$repo" && "$@") > "$tmp/output" 2>&1 || actual=$?
  if [ "$actual" -ne "$wanted" ]; then
    cat "$tmp/output"
    echo "public-check test: expected $wanted, got $actual: $*" >&2
    exit 1
  fi
}

expect_output() {
  if ! grep -Fqx -- "$1" "$tmp/output"; then
    cat "$tmp/output"
    echo "public-check test: missing output: $1" >&2
    exit 1
  fi
}

refuse_output() {
  if grep -Fq -- "$1" "$tmp/output"; then
    cat "$tmp/output"
    echo "public-check test: unwanted output: $1" >&2
    exit 1
  fi
}

allow_row() {
  hash=$(printf '%s\n' "$3" | git hash-object --stdin)
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$hash" "$4"
}

git -C "$repo" init -q -b main
printf 'ARG OK_VERSION=1.2.3\n' > "$repo/deploy/Dockerfile"
printf '{\n  "version": "1.2.3"\n}\n' > "$repo/packages/cli/package.json"
commit upstream
git -C "$repo" switch -q -c fork
git -C "$repo" config ok.hostRules none
cp "$repo_root/scripts/tenant/public-check.sh" "$check"
printf 'class-3\tmarker\tprivate-[a-z]+\n' > "$repo/scripts/tenant/public-check.rules"
printf 'development/\n' > "$repo/scripts/tenant/public-check.development"
allow_row notes.txt marker 'value private-alpha' 'Fixture value.' > "$allow"
cp "$allow" "$tmp/allow"
printf 'first\nvalue private-alpha\nlast\n' > "$repo/notes.txt"
cp "$repo/notes.txt" "$tmp/notes"

expect_status 0 "$check"
refuse_output 'stale row'
: > "$allow"
expect_status 1 "$check"
expect_output 'notes.txt:2 class-3'
cp "$tmp/allow" "$allow"

printf 'inserted\ninserted\n' | cat - "$tmp/notes" > "$repo/notes.txt"
expect_status 0 "$check"
refuse_output 'stale row'
printf 'value private-alpha\n' | cat "$tmp/notes" - > "$repo/notes.txt"
expect_status 0 "$check"

printf 'first\nvalue private-beta\nlast\n' > "$repo/notes.txt"
expect_status 1 "$check"
expect_output 'notes.txt:2 class-3'
expect_output 'public-check: allow list line 1: stale row, no marker match in notes.txt has this hash'
cp "$tmp/notes" "$repo/notes.txt"

allow_row notes.txt other 'value private-alpha' 'Fixture value.' > "$allow"
expect_status 1 "$check"
expect_output 'notes.txt:2 class-3'
allow_row other.txt marker 'value private-alpha' 'Fixture value.' > "$allow"
expect_status 1 "$check"
expect_output 'notes.txt:2 class-3'

{ cat "$tmp/allow"; allow_row notes.txt marker 'value private-alpha' 'Second reason.'; } > "$allow"
expect_status 2 "$check"
expect_output 'public-check: allow list line 2: duplicate row'
hash=$(printf 'value private-alpha\n' | git hash-object --stdin)
printf 'notes.txt\t2\tmarker\t%s\tFixture value.\n' "$hash" > "$allow"
expect_status 2 "$check"
expect_output 'public-check: allow list line 1: invalid row or empty reason'
printf 'notes.txt\tmarker\t%s\t \n' "$hash" > "$allow"
expect_status 2 "$check"
printf 'notes.txt\thost-marker\t%s\tFixture value.\n' "$hash" > "$allow"
expect_status 2 "$check"
allow_row development/notes.txt marker 'value private-alpha' 'Fixture value.' > "$allow"
expect_status 2 "$check"

{ cat "$tmp/allow"; allow_row notes.txt marker 'value private-gone' 'Deleted line.'; } > "$allow"
expect_status 0 "$check"
expect_output 'public-check: allow list line 2: stale row, no marker match in notes.txt has this hash'
refuse_output 'allow list line 1'
commit fork
expect_status 0 "$check" --tree HEAD
expect_output 'public-check: allow list line 2: stale row, no marker match in notes.txt has this hash'
expect_status 0 "$check" --staged
refuse_output 'stale row'
printf 'inserted\n' | cat - "$tmp/notes" > "$repo/notes.txt"
git -C "$repo" add notes.txt
expect_status 0 "$check" --staged
expect_output 'public-check: allow list line 2: stale row, no marker match in notes.txt has this hash'
echo "public-check test: ok (moved line, changed line, other rule, other file, duplicate row, invalid rows, stale row, tree and staged modes)"
