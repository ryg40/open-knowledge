#!/bin/sh
set -eu
export LC_ALL=C

repo_root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ok-pins-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$tmp/repo/deploy/docs" "$tmp/repo/scripts/tenant" "$tmp/bin"
cp "$repo_root/deploy/Dockerfile" "$tmp/repo/deploy/"
cp "$repo_root"/deploy/docs/*.md "$tmp/repo/deploy/docs/"
cp "$repo_root/EXPLAINER.md" "$repo_root/package.json" "$tmp/repo/"
cp "$repo_root/scripts/tenant/pins.sh" "$repo_root/scripts/tenant/build.sh" "$repo_root/scripts/tenant/scan.sh" "$tmp/repo/scripts/tenant/"
cp "$tmp/repo/EXPLAINER.md" "$tmp/facts"
git -C "$tmp/repo" init -q
(
  cd "$tmp/repo"
  git add .
  git -c core.hooksPath=/dev/null -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
)

expect_status() {
  wanted=$1
  shift
  actual=0
  "$@" > "$tmp/output" 2>&1 || actual=$?
  if [ "$actual" -ne "$wanted" ]; then
    cat "$tmp/output"
    echo "pins test: expected $wanted, got $actual: $*" >&2
    exit 1
  fi
}

expect_status 0 "$tmp/repo/scripts/tenant/pins.sh"
for key in 'Upstream version' 'Tarball sha512' 'Base image' 'Scanner image' 'Dockerfile frontend image' 'pnpm version'; do
  awk -F'|' -v key="$key" '
    $2 == " " key " " { $3 = " `wrong` " }
    { print }
  ' OFS='|' "$tmp/facts" > "$tmp/repo/EXPLAINER.md"
  expect_status 1 "$tmp/repo/scripts/tenant/pins.sh"
  cp "$tmp/facts" "$tmp/repo/EXPLAINER.md"
done
awk '$0 !~ /^\| Upstream version \|/' "$tmp/facts" > "$tmp/repo/EXPLAINER.md"
expect_status 1 "$tmp/repo/scripts/tenant/pins.sh"
cp "$tmp/facts" "$tmp/repo/EXPLAINER.md"
awk '{ print; if ($0 ~ /^\| Upstream version \|/) print }' "$tmp/facts" > "$tmp/repo/EXPLAINER.md"
expect_status 1 "$tmp/repo/scripts/tenant/pins.sh"
cp "$tmp/facts" "$tmp/repo/EXPLAINER.md"
version=$(awk -F= '/^ARG OK_VERSION=/ { print $2; exit }' "$tmp/repo/deploy/Dockerfile")
for literal in "upstream version $version" 'upstream version 9.9.9' 'upstream v9.9.9' 'pnpm 9.9.9' '@inkeep/open-knowledge@9.9.9' 'node:99-slim@sha256:wrong' 'docker/dockerfile:99' 'zricethezav/gitleaks:v99' 'scanner sha256:abcdef' 'sha512-wrong'; do
  printf '%s\n' "$literal" > "$tmp/repo/deploy/docs/extra.md"
  expect_status 1 "$tmp/repo/scripts/tenant/pins.sh"
done
rm "$tmp/repo/deploy/docs/extra.md"
expect_status 2 "$tmp/repo/scripts/tenant/pins.sh" --unknown
mv "$tmp/repo/package.json" "$tmp/package.json"
expect_status 2 "$tmp/repo/scripts/tenant/pins.sh"
mv "$tmp/package.json" "$tmp/repo/package.json"
printf '\nARG OK_VERSION=%s\n' "$version" >> "$tmp/repo/deploy/Dockerfile"
expect_status 2 "$tmp/repo/scripts/tenant/pins.sh"
cp "$repo_root/deploy/Dockerfile" "$tmp/repo/deploy/Dockerfile"
mv "$tmp/repo/deploy/docs/ci.md" "$tmp/ci.md"
expect_status 2 "$tmp/repo/scripts/tenant/pins.sh"
mkdir "$tmp/repo/deploy/docs/ci.md"
expect_status 2 "$tmp/repo/scripts/tenant/pins.sh"
rmdir "$tmp/repo/deploy/docs/ci.md"
mv "$tmp/ci.md" "$tmp/repo/deploy/docs/ci.md"
expect_status 0 "$tmp/repo/scripts/tenant/pins.sh"

cat > "$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$BUILD_ARGS"
EOF
chmod +x "$tmp/bin/docker"
PATH=$tmp/bin:$PATH
BUILD_ARGS=$tmp/build-args
export PATH BUILD_ARGS
unset OK_VERSION OK_NPM_INTEGRITY NODE_IMAGE
cd "$tmp/repo"
expect_status 0 scripts/tenant/build.sh -t fixture:local
grep -Fx "OK_RELEASE_VERSION=$version" "$BUILD_ARGS" >/dev/null
expect_status 0 scripts/tenant/build.sh -v "$version" -t fixture:local
expect_status 2 scripts/tenant/build.sh -v 9.9.9 -t fixture:local
expect_status 0 env OK_VERSION=9.9.9 scripts/tenant/build.sh -t fixture:local
grep -Fx 'OK_RELEASE_VERSION=9.9.9' "$BUILD_ARGS" >/dev/null
grep -Fx 'OK_VERSION=9.9.9' "$BUILD_ARGS" >/dev/null
expect_status 2 env OK_VERSION=invalid scripts/tenant/build.sh -t fixture:local
awk '{ sub(/^ARG OK_VERSION=.*/, "ARG OK_VERSION=9.9.9"); print }' deploy/Dockerfile > "$tmp/dockerfile"
mv "$tmp/dockerfile" deploy/Dockerfile
expect_status 0 scripts/tenant/build.sh -t fixture:local
grep -Fx 'OK_RELEASE_VERSION=9.9.9' "$BUILD_ARGS" >/dev/null
awk '{ sub(/\| Upstream version \| `[^`]+`/, "| Upstream version | `9.9.9`"); print }' EXPLAINER.md > "$tmp/explainer"
mv "$tmp/explainer" EXPLAINER.md
expect_status 0 scripts/tenant/pins.sh
echo "pins test: ok (six pins, doc drift, exits 0/1/2, build defaults and overrides)"
