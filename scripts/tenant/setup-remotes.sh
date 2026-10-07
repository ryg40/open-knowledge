#!/bin/sh
set -eu

upstream_url=${UPSTREAM_URL:-https://github.com/inkeep/open-knowledge.git}
push_url=DISABLED
tag_opt=--no-tags
refspec='+refs/heads/*:refs/remotes/upstream/*'
shared_url=${SHARED_URL-}
shared_tag_opt=--no-tags
shared_refspec='+refs/heads/portable:refs/remotes/github/portable'
script_dir=$(cd "$(dirname "$0")" && pwd -P)

usage() {
  echo "usage: $0 [--check]" >&2
}

strip_credentials() {
  printf '%s\n' "$1" | sed -e 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/]*@#\1#'
}

normalize_url() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed -E -e 's#(github\.com)\.?(:[0-9]*)?/+#\1/#g' -e 's#([^:])/+#\1/#g' -e 's#/*$##'
}

is_github_upstream() {
  normalized=$(normalize_url "$1")
  case $normalized in
    *github.com[:/]inkeep/open-knowledge | *github.com[:/]inkeep/open-knowledge.git) return 0 ;;
  esac
  [ "$normalized" = "$(normalize_url "$upstream_url")" ]
}

has_remote() {
  git config --get "remote.$1.url" >/dev/null 2>&1
}

get_all() {
  git config --get-all "$1" 2>/dev/null || true
}

set_key() {
  if [ "$(get_all "$1")" != "$2" ]; then
    git config --replace-all "$1" "$2"
  fi
}

check() {
  failed=0
  if [ "$(get_all remote.upstream.url)" != "$upstream_url" ]; then
    echo "wrong: remote.upstream.url" >&2
    failed=1
  fi
  if [ "$(get_all remote.upstream.pushurl)" != "$push_url" ]; then
    echo "wrong: remote.upstream.pushurl" >&2
    failed=1
  fi
  if [ "$(get_all remote.upstream.tagOpt)" != "$tag_opt" ]; then
    echo "wrong: remote.upstream.tagOpt" >&2
    failed=1
  fi
  if [ "$(get_all remote.upstream.fetch)" != "$refspec" ]; then
    echo "wrong: remote.upstream.fetch" >&2
    failed=1
  fi
  if ! has_remote origin; then
    echo "wrong: remote.origin.url is absent" >&2
    failed=1
  elif is_github_upstream "$(git config --get remote.origin.url)"; then
    echo "wrong: remote.origin.url points to the GitHub upstream" >&2
    failed=1
  fi
  if has_remote github; then
    check_shared || failed=1
  elif [ -n "$shared_url" ]; then
    echo "wrong: SHARED_URL is set, but remote github is absent" >&2
    failed=1
  fi
  if ! "$script_dir/install-hooks.sh" --check; then
    failed=1
  fi
  if [ "$failed" -eq 0 ]; then
    echo "ok: upstream is fetch-only and origin is set"
  fi
  return "$failed"
}

check_shared() {
  shared_failed=0
  github_url=$(git config --get remote.github.url)
  if [ -n "$shared_url" ] && [ "$github_url" != "$shared_url" ]; then
    echo "wrong: remote.github.url is not SHARED_URL" >&2
    shared_failed=1
  fi
  if [ "$(get_all remote.github.pushurl)" != "$github_url" ]; then
    echo "wrong: remote.github.pushurl" >&2
    shared_failed=1
  fi
  if [ "$(get_all remote.github.tagOpt)" != "$shared_tag_opt" ]; then
    echo "wrong: remote.github.tagOpt" >&2
    shared_failed=1
  fi
  if [ "$(get_all remote.github.fetch)" != "$shared_refspec" ]; then
    echo "wrong: remote.github.fetch" >&2
    shared_failed=1
  fi
  if is_github_upstream "$github_url"; then
    echo "wrong: remote.github.url points to the GitHub upstream" >&2
    shared_failed=1
  fi
  if [ "$shared_failed" -eq 0 ]; then
    echo "ok: github is $(strip_credentials "$github_url") and fetches portable only"
  fi
  return "$shared_failed"
}

setup_shared() {
  if is_github_upstream "$shared_url"; then
    echo "refused: SHARED_URL points to the GitHub upstream" >&2
    exit 1
  fi
  if ! has_remote github; then
    git remote add --no-tags -t portable github "$shared_url"
  fi
  set_key remote.github.url "$shared_url"
  set_key remote.github.pushurl "$shared_url"
  set_key remote.github.tagOpt "$shared_tag_opt"
  set_key remote.github.fetch "$shared_refspec"
  echo "github: $(strip_credentials "$shared_url") (portable and portable-v* tags only)"
}

setup() {
  if ! has_remote upstream; then
    git remote add upstream "$upstream_url"
  fi
  set_key remote.upstream.url "$upstream_url"
  set_key remote.upstream.pushurl "$push_url"
  set_key remote.upstream.tagOpt "$tag_opt"
  set_key remote.upstream.fetch "$refspec"
  echo "upstream: $(strip_credentials "$upstream_url") (fetch only)"
  if has_remote origin; then
    origin_url=$(git config --get remote.origin.url)
    echo "origin: $(strip_credentials "$origin_url")"
    if is_github_upstream "$origin_url"; then
      echo "warning: origin points to the GitHub upstream" >&2
    fi
  else
    echo "warning: origin is absent" >&2
  fi
  if [ -n "$shared_url" ]; then
    setup_shared
  fi
}

case $# in
  0) setup ;;
  1)
    case $1 in
      --check) check ;;
      *) usage; exit 2 ;;
    esac
    ;;
  *) usage; exit 2 ;;
esac
