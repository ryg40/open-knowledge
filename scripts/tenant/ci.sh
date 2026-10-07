#!/bin/sh
set -eu
export LC_ALL=C
container_cli=${OK_CONTAINER_CLI:-docker}

default_image=koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
upstream_url=https://github.com/inkeep/open-knowledge.git

usage() {
  echo "usage: $0 lint | deploy-changed <base> <head> | upstream-remote | upstream-ref | image" >&2
  exit 2
}

fail() {
  echo "ci: $*" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
action=$1
shift
repo_root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd) || fail "cannot find the repository"
cd "$repo_root" || fail "cannot enter the repository"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not a Git working tree"

pinned_version() {
  version=$(awk -F= '/^ARG OK_VERSION=/ { print $2; exit }' deploy/Dockerfile) || fail "cannot read deploy/Dockerfile"
  printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "deploy/Dockerfile gives no upstream version"
}

holds_version() {
  found=$(git show "$1:packages/cli/package.json" 2>/dev/null | awk -F '"' '/"version"[[:space:]]*:/ { print $4; exit }')
  [ "$found" = "$version" ]
}

release_subject() {
  git log -1 --format=%s "$1" | grep -Eq "^main reset: post-stable v$version_pattern(\$|[ (])"
}

find_release_commit() {
  release_commit=
  for ref in refs/heads/main refs/remotes/upstream/main refs/remotes/origin/main; do
    git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || continue
    matches=$(git log --first-parent --format='%H %s' "$ref" | grep -E "^[0-9a-f]+ main reset: post-stable v$version_pattern(\$|[ (])" || true)
    [ -n "$matches" ] || continue
    [ "$(printf '%s\n' "$matches" | wc -l)" -eq 1 ] || fail "more than one post-stable commit of $version in $ref"
    release_commit=${matches%% *}
    return 0
  done
  return 1
}

case $action in
  lint)
    [ "$#" -eq 0 ] || usage
    image=${SHELLCHECK_IMAGE:-$default_image}
    if [ "$image" != "$default_image" ]; then
      echo "ci: shell check image override: $image"
    fi
    files=$(git ls-files -- 'scripts/tenant/*.sh' deploy/entrypoint.sh) || fail "cannot list the kit scripts"
    [ -n "$files" ] || fail "no kit script found"
    set --
    for file in $files; do
      set -- "$@" "$file"
    done
    "$container_cli" run --rm --network none --volume "$repo_root:/mnt:ro" --workdir /mnt "$image" -s sh "$@"
    echo "ci: shell check ok, $# files"
    ;;
  deploy-changed)
    [ "$#" -eq 2 ] || usage
    changed=true
    if merge_base=$(git merge-base "$1" "$2" 2>/dev/null); then
      diff_status=0
      git diff --quiet "$merge_base" "$2" -- deploy/ || diff_status=$?
      [ "$diff_status" -ne 0 ] || changed=false
    fi
    echo "deploy=$changed"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      echo "deploy=$changed" >> "$GITHUB_OUTPUT"
    fi
    ;;
  upstream-remote)
    [ "$#" -eq 0 ] || usage
    if current=$(git config --get remote.upstream.url); then
      [ "$current" = "$upstream_url" ] || fail "the remote upstream has another URL"
    else
      git remote add upstream "$upstream_url"
    fi
    git config remote.upstream.pushurl DISABLED
    git config remote.upstream.tagOpt --no-tags
    echo "ci: remote upstream is set, push disabled"
    ;;
  upstream-ref)
    [ "$#" -eq 0 ] || usage
    pinned_version
    version_pattern=$(printf '%s\n' "$version" | sed 's/[.]/[.]/g')
    for ref in "refs/tags/v$version" "refs/tags/$version" refs/heads/main; do
      candidate=$(git rev-parse --verify --quiet "$ref^{commit}") || continue
      holds_version "$candidate" || continue
      if release_subject "$candidate"; then
        echo "ci: upstream release commit of $version is present: $ref"
        exit 0
      fi
      [ "$ref" = refs/heads/main ] || fail "$ref holds version $version, but it is not the upstream release commit"
      break
    done
    if ! find_release_commit; then
      git fetch --no-tags "$upstream_url" '+refs/heads/main:refs/remotes/upstream/main' || fail "cannot fetch the upstream branch"
      find_release_commit || fail "the upstream branch has no post-stable commit of $version"
    fi
    holds_version "$release_commit" || fail "the post-stable commit does not hold version $version"
    git tag "$version" "$release_commit" || fail "cannot make the local tag $version"
    echo "ci: local tag $version marks the upstream release commit $release_commit"
    ;;
  image)
    [ "$#" -eq 0 ] || usage
    pinned_version
    suffix=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
    image=ok-ci-$suffix:$version
    trap '"$container_cli" image rm "$image" >/dev/null 2>&1 || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    DOCKER_BUILDKIT=1 scripts/tenant/build.sh -v "$version" -t "$image"
    smoke_output=$(scripts/tenant/smoke.sh "$image") || { printf '%s\n' "$smoke_output"; fail "the smoke test failed"; }
    printf '%s\n' "$smoke_output"
    printed=$(printf '%s\n' "$smoke_output" | sed -n 's/^smoke: ok //p' | tail -n 1)
    [ "$printed" = "$version" ] || fail "the image reports the version $printed, not $version"
    echo "ci: image ok $version"
    ;;
  *) usage ;;
esac
