#!/bin/sh
set -eu

usage() {
  echo "usage: $0 -t <image-tag> [-s <source-rev>] [-v <upstream-version>]" >&2
  exit 2
}

source_rev=HEAD
release_version=
image_tag=

while getopts "s:v:t:h" opt; do
  case "$opt" in
    s) source_rev=$OPTARG ;;
    v) release_version=$OPTARG ;;
    t) image_tag=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -eq 0 ] || usage
[ -n "$image_tag" ] || usage

repo_root=$(git rev-parse --show-toplevel)
revision=$(git -C "$repo_root" rev-parse --verify "${source_rev}^{commit}")

context=$(mktemp -d "${TMPDIR:-/tmp}/ok-build.XXXXXX")
trap 'rm -rf "$context"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git -C "$repo_root" archive --format=tar "$revision" | tar -x -C "$context"
mkdir -p "$context/deploy"
cp -R "$repo_root/deploy/." "$context/deploy/"

pinned_version=$(awk '/^ARG OK_VERSION=/ { sub(/^ARG OK_VERSION=/, ""); value = $0; count++ } END { if (count != 1) exit 2; print value }' "$context/deploy/Dockerfile") || {
  echo "build: cannot read one OK_VERSION from deploy/Dockerfile" >&2
  exit 2
}
upstream_version=${OK_VERSION:-$pinned_version}
if ! printf '%s\n' "$upstream_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
  echo "build: invalid upstream version: $upstream_version" >&2
  exit 2
fi
if [ -n "$release_version" ] && [ "$release_version" != "$upstream_version" ]; then
  echo "build: -v must be the upstream version $upstream_version, not the portable version" >&2
  exit 2
fi
release_version=$upstream_version

set -- --file "$context/deploy/Dockerfile" --tag "$image_tag" --build-arg "OK_REVISION=$revision" \
  --build-arg "OK_RELEASE_VERSION=$release_version"
for name in OK_VERSION OK_NPM_INTEGRITY OK_SOURCE OK_UID OK_GID NODE_IMAGE; do
  eval "value=\${$name-}"
  if [ -n "$value" ]; then
    set -- "$@" --build-arg "$name=$value"
  fi
done

docker build "$@" "$context"
