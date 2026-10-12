#!/bin/sh
set -eu
export LC_ALL=C

repo_root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ok-telemetry-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
repo=$tmp/repo
check=$repo/scripts/tenant/telemetry.sh
mkdir -p "$repo/deploy" "$repo/scripts/tenant" "$repo/packages/core/src/config" "$repo/packages/server/src" "$repo/packages/app/src"
cp "$repo_root/deploy/Dockerfile" "$repo_root/deploy/Dockerfile.dockerignore" "$repo_root/deploy/compose.yaml" "$repo_root/deploy/no-telemetry.mjs" "$repo/deploy/"
cp "$repo_root/scripts/tenant/telemetry.sh" "$repo_root/scripts/tenant/telemetry.mjs" "$repo_root/scripts/tenant/smoke.sh" "$repo/scripts/tenant/"
awk -F '\t' '$1 == "switch" || $1 == "force" || $1 == "unset"' "$repo_root/scripts/tenant/telemetry.baseline" > "$repo/scripts/tenant/telemetry.baseline"
cp "$repo_root/packages/core/src/config/schema.ts" "$repo/packages/core/src/config/"
for name in local-sink-resolver.ts skills-sh-install-report.ts telemetry.ts; do
  cp "$repo_root/packages/server/src/$name" "$repo/packages/server/src/"
done
cp "$repo_root/packages/app/src/telemetry.ts" "$repo_root/packages/app/src/telemetry-impl.ts" "$repo/packages/app/src/"
printf '%s\n' "export const project = 'https://github.com/example/project';" > "$repo/packages/server/src/link.ts"

commit() {
  git -C "$repo" add .
  git -C "$repo" -c core.hooksPath=/dev/null -c user.name=Fixture -c user.email=fixture@example.com commit -qm "$1"
}

expect_status() {
  wanted=$1
  shift
  actual=0
  "$@" > "$tmp/output" 2>&1 || actual=$?
  if [ "$actual" -ne "$wanted" ]; then
    cat "$tmp/output"
    echo "telemetry test: expected $wanted, got $actual: $*" >&2
    exit 1
  fi
}

expect_line() {
  if ! grep -F -- "$1" "$tmp/output" >/dev/null; then
    cat "$tmp/output"
    echo "telemetry test: the output does not name: $1" >&2
    exit 1
  fi
}

restore() {
  rm -rf "$repo"
  cp -R "$tmp/pristine" "$repo"
}

git -C "$repo" init -q
expect_status 1 "$check"
expect_line 'in the source, not in the baseline: default	telemetry.localSink.enabled	true'
expect_status 0 "$check" update
commit fixture
cp -R "$repo" "$tmp/pristine"
expect_status 0 "$check"
expect_status 0 "$check" check
"$check" list > "$tmp/worktree"
"$check" list --ref HEAD > "$tmp/head"
cmp "$tmp/worktree" "$tmp/head"
for fact in 'default	lossCapture.enabled	true' 'default	telemetry.skillInstallReports.enabled	false' 'host	add-skill.vercel.sh	1' 'host	github.com	1' 'env	VITE_OTEL_ENABLED' 'env	VITE_OTEL_COLLECTOR_URL' 'module	@opentelemetry/exporter-trace-otlp-http' "read	packages/app/src/telemetry.ts	if (env?.VITE_OTEL_ENABLED !== 'true') return;"; do
  grep -Fx -- "$fact" "$tmp/head" >/dev/null || { echo "telemetry test: missing fact: $fact" >&2; exit 1; }
done
for fact in 'default	telemetry.skillInstallReports	{ enabled: false }' 'default	telemetry	' 'env	LANG' 'env	LC_ALL'; do
  if grep -F -- "$fact" "$tmp/head" >/dev/null; then echo "telemetry test: fact that repeats another fact, or locale name: $fact" >&2; exit 1; fi
done
grep -F 'OK_DISABLE_LOCAL_SINK' "$tmp/head" | grep -F "=== 'true'" >/dev/null
grep -F 'DISABLE_TELEMETRY || env.DO_NOT_TRACK' "$tmp/head" >/dev/null
grep -F "OTEL_SDK_DISABLED === 'false'" "$tmp/head" >/dev/null

schema=$repo/packages/core/src/config/schema.ts
awk '/skillInstallReports: z/ { inside = 1 } inside && /\.default\(false\)/ { sub(/false/, "true"); inside = 0 } { print }' "$schema" > "$tmp/schema"
cp "$tmp/schema" "$schema"
expect_status 1 "$check"
expect_line 'in the source, not in the baseline: default	telemetry.skillInstallReports.enabled	true'
expect_line 'in the baseline, not in the source: default	telemetry.skillInstallReports.enabled	false'
restore

awk '/skillInstallReports: z/ { inside = 1 } inside && /\.default\(\{ enabled: false \}\)/ { sub(/false/, "true"); inside = 0 } { print }' "$schema" > "$tmp/schema"
cp "$tmp/schema" "$schema"
expect_status 1 "$check"
expect_line 'in the source, not in the baseline: default	telemetry.skillInstallReports	{ enabled: true }'
restore

awk '/^  lossCapture: z/ { print "  usageReports: z.boolean().default(true),"; } { print }' "$schema" > "$tmp/schema"
cp "$tmp/schema" "$schema"
expect_status 1 "$check"
expect_line 'in the source, not in the baseline: default	usageReports	true'
restore

printf '%s\n' "export const on = process.env.OK_USAGE_REPORT !== '0';" > "$repo/packages/server/src/usage.ts"
expect_status 1 "$check"
expect_line 'OK_USAGE_REPORT'
restore

printf '%s\n' "export const collector = 'https://collector.example.net/v1';" > "$repo/packages/server/src/collector.ts"
expect_status 1 "$check"
expect_line 'in the source, not in the baseline: host	collector.example.net	1'
restore

probe() {
  printf '%s\n' "$2" > "$repo/$1"
  expect_status 1 "$check"
  expect_line "in the source, not in the baseline: $3"
  restore
}
probe packages/app/src/probe.ts "export const on = import.meta.env?.VITE_OTEL_ENABLED !== 'false';" "read	packages/app/src/probe.ts	export const on = import.meta.env?.VITE_OTEL_ENABLED !== 'false';"
scheme=https
probe packages/server/src/probe.ts "export const send = (host: string) => fetch(\`$scheme://\${host}/collect\`);" 'built	packages/server/src/probe.ts	1'
probe packages/server/src/probe.ts "export const send = () => fetch('https://github.com/api/usage', { method: 'POST' });" 'host	github.com	2'
awk '/^  lossCapture: z/ { print "  feedbackSharing: z.boolean().default(true),"; } { print }' "$schema" > "$tmp/schema"
cp "$tmp/schema" "$schema"
expect_status 1 "$check"
expect_line 'in the source, not in the baseline: default	feedbackSharing	true'
restore
probe packages/server/src/probe.ts "export const target = process.env['OK_PING_URL'];" 'env	OK_PING_URL'
probe packages/server/src/probe.ts 'export const target = process.env.OK_PING_URL;' 'env	OK_PING_URL'
probe packages/server/src/probe.ts "export const relay = 'wss://relay.example.org/ws';" 'host	relay.example.org	1'
probe packages/server/src/probe.ts "import { createClient } from 'posthog-js';" 'module	posthog-js'
probe packages/server/src/probe.ts 'const { OK_PING_URL } = process.env;' 'unpack	packages/server/src/probe.ts	const { OK_PING_URL } = process.env;'
probe packages/app/src/probe.ts 'const { VITE_PING } = import.meta.env;' 'unpack	packages/app/src/probe.ts	const { VITE_PING } = import.meta.env;'
probe packages/server/src/probe.ts '} = process.env;' 'unpack	packages/server/src/probe.ts	} = process.env;'
upper=HTTPS
probe packages/server/src/probe.ts "export const collector = '$upper://Collect.Example.NET/x';" 'host	collect.example.net	1'
probe packages/server/src/probe.ts "export const collector = '$scheme://203.0.113.9/collect';" 'host	203.0.113.9	1'
probe packages/server/src/probe.ts "export const collector = '$scheme://127.0.0.1.example.com/x';" 'host	127.0.0.1.example.com	1'
printf '%s\n' "export const own = '$scheme://127.0.0.1:8080/readyz';" > "$repo/packages/server/src/probe.ts"
expect_status 0 "$check"
restore
printf '%s\n' 'export const lang = process.env.LC_MESSAGES ?? process.env.LANG;' > "$repo/packages/server/src/probe.ts"
expect_status 0 "$check"
restore

printf '%s\n' 'ARG VITE_OTEL_ENABLED=true' >> "$repo/deploy/Dockerfile"
expect_status 1 "$check"
expect_line 'deploy/Dockerfile names the build setting VITE_OTEL_ENABLED'
restore
grep -v -F -x '**/.env*' "$repo/deploy/Dockerfile.dockerignore" > "$tmp/edited"
cp "$tmp/edited" "$repo/deploy/Dockerfile.dockerignore"
expect_status 1 "$check"
expect_line 'deploy/Dockerfile.dockerignore does not hold the line **/.env*'
restore
printf '%s\n' '{ "scripts": { "build": "VITE_OTEL_ENABLED=true vite build" } }' > "$repo/packages/app/package.json"
expect_status 1 "$check"
expect_line 'in the source, not in the baseline: setting	packages/app/package.json	{ "scripts": { "build": "VITE_OTEL_ENABLED=true vite build" } }'
restore
mkdir -p "$repo/.gitea/workflows"
printf '%s\n' '      VITE_OTEL_ENABLED: "true"' > "$repo/.gitea/workflows/build.yml"
expect_status 1 "$check"
expect_line '.gitea/workflows/build.yml names the build setting VITE_OTEL_ENABLED'
restore

printf '%s\n' "export const collector = 'https://collector.example.net/v1';" > "$repo/packages/server/src/collector.test.ts"
expect_status 0 "$check"
restore

sed "s/OK_DISABLE_LOCAL_SINK === 'true'/OK_DISABLE_LOCAL_SINK === 'yes'/" "$repo/packages/server/src/local-sink-resolver.ts" > "$tmp/resolver"
cp "$tmp/resolver" "$repo/packages/server/src/local-sink-resolver.ts"
expect_status 1 "$check"
expect_line "=== 'yes'"
restore

for file in deploy/compose.yaml deploy/Dockerfile scripts/tenant/smoke.sh deploy/no-telemetry.mjs; do
  grep -v 'OK_DISABLE_LOCAL_SINK' "$repo/$file" > "$tmp/edited"
  cp "$tmp/edited" "$repo/$file"
  expect_status 1 "$check"
  expect_line "$file does not"
  restore
done
sed 's/OTEL_SDK_DISABLED: "true"/OTEL_SDK_DISABLED: "false"/' "$repo/deploy/compose.yaml" > "$tmp/edited"
cp "$tmp/edited" "$repo/deploy/compose.yaml"
expect_status 1 "$check"
expect_line 'deploy/compose.yaml does not set OTEL_SDK_DISABLED to true'
restore
grep -v "'lossCapture.enabled'" "$repo/deploy/no-telemetry.mjs" > "$tmp/edited"
cp "$tmp/edited" "$repo/deploy/no-telemetry.mjs"
expect_status 1 "$check"
expect_line 'deploy/no-telemetry.mjs does not force lossCapture.enabled'
restore

expect_status 2 "$check" unknown
expect_status 2 "$check" list --ref
printf 'unknown\tline\n' >> "$repo/scripts/tenant/telemetry.baseline"
expect_status 2 "$check"
restore
for kind in switch unset; do
  grep -v "^$kind" "$repo/scripts/tenant/telemetry.baseline" > "$tmp/edited"
  cp "$tmp/edited" "$repo/scripts/tenant/telemetry.baseline"
  expect_status 2 "$check"
  restore
done
rm "$repo/scripts/tenant/telemetry.baseline"
expect_status 2 "$check"
restore
rm "$schema"
expect_status 2 "$check"
restore
expect_status 0 "$check"
echo "telemetry test: ok (defaults, variable reads, variable names, unpacked environment, hosts, built addresses, modules, kit settings, exits 0/1/2)"
