#!/bin/sh
set -eu
export LC_ALL=C GIT_PAGER=cat

usage() {
  echo "usage: $0 [--staged | --tree <rev> | --development-only <rev> | --identities <source> <portable>]" >&2
  exit 2
}

cannot_run() {
  echo "public-check: cannot run: $*" >&2
  exit 2
}

mode=worktree
revision=HEAD
case $# in
  0) ;;
  1) [ "$1" = --staged ] || usage; mode=staged ;;
  2) case $1 in --tree) mode=tree ;; --development-only) mode=development-only ;; *) usage ;; esac; revision=$2 ;;
  3) [ "$1" = --identities ] || usage; mode=identities; source=$2; portable=$3 ;;
  *) usage ;;
esac
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || cannot_run "not a Git working tree"
cd "$repo_root"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ok-public-check.XXXXXX") || cannot_run "temporary directory"
trap 'rm -rf "$tmp"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
separator=$(printf '\037')

if [ "$mode" = staged ]; then
  snapshot=$(git write-tree 2>/dev/null) || cannot_run "the index has unresolved entries"
elif [ "$mode" = worktree ]; then
  snapshot=HEAD
elif [ "$mode" = identities ]; then
  snapshot=$(git rev-parse --verify --quiet "$source^{commit}") || cannot_run "source does not resolve"
else
  snapshot=$(git rev-parse --verify --quiet "$revision^{commit}") || cannot_run "tree revision does not resolve"
fi

read_policy() {
  policy_file=$1
  policy_output=$2
  if [ "$mode" = worktree ] || [ "$mode" = identities ]; then
    [ -f "$policy_file" ] && [ ! -L "$policy_file" ] || cannot_run "missing policy file"
    cp "$policy_file" "$policy_output" || cannot_run "policy cannot be read"
  else
    git show "$snapshot:$policy_file" > "$policy_output" 2>/dev/null || cannot_run "missing snapshot policy file"
  fi
}

development_only() {
  while IFS= read -r development_path; do
    case $development_path in
      */) case $1 in "${development_path%/}" | "$development_path"*) return 0 ;; esac ;;
      *) [ "$1" != "$development_path" ] || return 0 ;;
    esac
  done < "$tmp/development"
  return 1
}

if [ "$mode" != identities ]; then
  read_policy scripts/tenant/public-check.development "$tmp/development-input"
  awk '
    $0 !~ /^([A-Za-z0-9_.-]+\/)*[A-Za-z0-9_.-]+\/?$/ || $0 ~ /(^|\/)\.\.?(\/|$)/ || seen[$0]++ {
      printf "public-check: development list line %s: invalid path\n", NR > "/dev/stderr"; exit 2
    }
    { count++; print }
    END { if (!count) exit 2 }
  ' "$tmp/development-input" > "$tmp/development" || cannot_run "invalid development-only path list"
fi

if [ "$mode" = development-only ]; then
  git ls-tree -r --name-only -z "$snapshot" > "$tmp/development-z" || cannot_run "release paths cannot be read"
  awk 'BEGIN { RS = "\000" } length($0) { if (index($0, "\n") || index($0, "\t") || index($0, "\r") || index($0, "\033")) exit 2; print }' "$tmp/development-z" > "$tmp/development-files" || cannot_run "unsupported release path"
  development_status=0
  while IFS= read -r file; do
    if development_only "$file"; then
      printf '%s development-only\n' "$file"
      development_status=1
    fi
  done < "$tmp/development-files"
  exit "$development_status"
fi

if [ "$mode" = worktree ]; then
  [ -f deploy/Dockerfile ] || cannot_run "missing deploy/Dockerfile"
  cp deploy/Dockerfile "$tmp/dockerfile" || cannot_run "Dockerfile cannot be read"
else
  git show "$snapshot:deploy/Dockerfile" > "$tmp/dockerfile" 2>/dev/null || cannot_run "missing snapshot Dockerfile"
fi
upstream_version=$(awk -F= '/^ARG OK_VERSION=/ { print $2; exit }' "$tmp/dockerfile") || cannot_run "version cannot be read"
printf '%s\n' "$upstream_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$' || cannot_run "invalid OK_VERSION"
upstream=
for ref in "refs/tags/v$upstream_version" "refs/tags/$upstream_version" refs/heads/main; do
  if candidate=$(git rev-parse --verify --quiet "$ref^{commit}"); then
    git show "$candidate:packages/cli/package.json" > "$tmp/package" 2>/dev/null || cannot_run "upstream version cannot be read"
    candidate_version=$(awk -F '"' '/"version"[[:space:]]*:/ { print $4; exit }' "$tmp/package") || cannot_run "upstream version cannot be parsed"
    if [ "$candidate_version" = "$upstream_version" ]; then
      upstream=$candidate
      break
    fi
  fi
done
[ -n "$upstream" ] || cannot_run "OK_VERSION needs its upstream release commit or a matching main"

identity_allowed() {
  [ "$1" = 'OpenKnowledge Release <noreply@example.com>' ] || grep -Fqx -- "$1" "$tmp/upstream-identities"
}

if [ "$mode" = identities ]; then
  [ "$(git rev-parse --is-shallow-repository)" = false ] || cannot_run "publication identities need full history"
  git replace -l > "$tmp/replacements" || cannot_run "replacement refs cannot be read"
  [ ! -s "$tmp/replacements" ] || cannot_run "publication identities refuse replacement objects"
  common_dir=$(git rev-parse --git-common-dir) || cannot_run "common Git directory cannot be read"
  [ ! -s "$common_dir/info/grafts" ] || cannot_run "publication identities refuse history grafts"
  source=$(git rev-parse --verify --quiet "$source^{commit}") || cannot_run "source does not resolve"
  portable=$(git rev-parse --verify --quiet "$portable^{commit}") || cannot_run "portable does not resolve"
  git log --no-use-mailmap --format='%an <%ae>%n%cn <%ce>' "$upstream" > "$tmp/upstream-identities" || cannot_run "upstream identities cannot be read"
  git log --no-use-mailmap --format='%H%n%an <%ae>%n%cn <%ce>' "$source" "$portable" --not "$upstream" > "$tmp/identities" || cannot_run "commit identities cannot be read"
  status=0
  while IFS= read -r commit && IFS= read -r author && IFS= read -r committer; do
    if ! identity_allowed "$author"; then printf 'commit/%s:1 class-1\n' "$commit"; status=1; fi
    if ! identity_allowed "$committer"; then printf 'commit/%s:2 class-1\n' "$commit"; status=1; fi
  done < "$tmp/identities"
  for role in AUTHOR COMMITTER; do
    identity=$(git var "GIT_${role}_IDENT" 2>/dev/null) || cannot_run "publish identity cannot be read"
    identity=$(printf '%s\n' "$identity" | sed 's/ [0-9][0-9]* [-+][0-9][0-9][0-9][0-9]$//')
    if ! identity_allowed "$identity"; then printf 'identity/%s:1 class-1\n' "$role"; status=1; fi
  done
  git for-each-ref --format='%(refname)' 'refs/tags/portable-v*' > "$tmp/tags" || cannot_run "tags cannot be read"
  while IFS= read -r ref; do
    tip=$(git rev-parse --verify --quiet "$ref^{commit}") || cannot_run "release tag has no commit"
    if ! git merge-base --is-ancestor "$tip" "$source" && ! git merge-base --is-ancestor "$tip" "$portable"; then continue; fi
    object=$(git rev-parse --verify "$ref") || cannot_run "tag object cannot be read"
    object_type=$(git cat-file -t "$object") || cannot_run "tag type cannot be read"
    while [ "$object_type" = tag ]; do
      git cat-file tag "$object" > "$tmp/tag" || cannot_run "tag metadata cannot be read"
      identity=$(awk '/^$/ { exit } /^tagger / { print substr($0, 8) }' "$tmp/tag" | sed 's/ [0-9][0-9]* [-+][0-9][0-9][0-9][0-9]$//')
      if ! identity_allowed "$identity"; then printf '%s:1 class-1\n' "$ref"; status=1; fi
      object=$(awk '/^object / { print $2; exit }' "$tmp/tag") || cannot_run "nested tag cannot be read"
      [ -n "$object" ] || cannot_run "tag has no target"
      object_type=$(git cat-file -t "$object") || cannot_run "nested tag type cannot be read"
    done
  done < "$tmp/tags"
  exit "$status"
fi

read_policy scripts/tenant/public-check.rules "$tmp/generic"
read_policy scripts/tenant/public-check.allow "$tmp/allow"
awk -F '\t' '
  NF != 3 || $1 !~ /^class-[1-4]$/ || $2 !~ /^[a-z][a-z0-9-]+$/ || $3 == "" || seen[$2]++ { exit 2 }
  { count++ }
  END { if (!count) exit 2 }
' "$tmp/generic" || cannot_run "invalid generic rules"
awk -F '\t' '
  FILENAME == ARGV[1] { development[$0] = 1; next }
  $3 ~ /^host-/ {
    printf "public-check: allow list line %s: host rule IDs cannot be allowed\n", FNR > "/dev/stderr"; exit 2
  }
  NF != 5 || $1 == "" || $1 ~ /(^\/|(^|\/)\.\.?(\/|$)|[*?\[\\])/ || $2 !~ /^[1-9][0-9]*$/ || $3 !~ /^[a-z][a-z0-9-]+$/ || $4 !~ /^[a-f0-9]+$/ || (length($4) != 40 && length($4) != 64) || $5 !~ /[^[:space:]]/ || seen[$1 SUBSEP $2 SUBSEP $3]++ {
    printf "public-check: allow list line %s: invalid row or empty reason\n", FNR > "/dev/stderr"; exit 2
  }
  {
    for (path in development) {
      directory = path ~ /\/$/
      root = path; sub(/\/$/, "", root)
      if ($1 == root || (directory && index($1, path) == 1)) {
        printf "public-check: allow list line %s: development-only paths cannot be allowed\n", FNR > "/dev/stderr"; exit 2
      }
    }
    print $1 "\t" $2 "\t" $3 "\t" $4
  }
' "$tmp/development" "$tmp/allow" > "$tmp/allow-keys" || cannot_run "invalid exact-place allow list"
awk -F '\t' -v separator="$separator" '{ print $1 separator $2 separator "" separator $3 }' "$tmp/generic" > "$tmp/rules" || cannot_run "generic rules cannot be read"
host_file=$(git config --type=path --get ok.hostRules || true)
if [ -n "$host_file" ] && [ "$host_file" != none ]; then
  case $host_file in /*) ;; *) cannot_run "ok.hostRules needs an absolute ignored file" ;; esac
  [ -f "$host_file" ] && [ -r "$host_file" ] || cannot_run "ok.hostRules file cannot be read"
  host_dir=$(cd "$(dirname "$host_file")" && pwd -P) || cannot_run "host file directory cannot be read"
  case $host_dir/$(basename "$host_file") in
    "$repo_root"/*)
      host_path=${host_dir#"$repo_root"}/$(basename "$host_file")
      host_path=${host_path#/}
      git check-ignore -q -- "$host_path" || cannot_run "host file inside the repository must be ignored"
      git ls-files --error-unmatch -- "$host_path" >/dev/null 2>&1 && cannot_run "host file must not be tracked"
      ;;
  esac
  "$repo_root/scripts/tenant/scan.sh" --validate-only > "$tmp/validation" 2>&1 || cannot_run "host configuration validation failed"
  awk -v quote="'''" -v separator="$separator" '
    function refuse() { bad = 1; exit 2 }
    function value(line, key,   rest) {
      if (index(line, key " = " quote) != 1 || substr(line, length(line)-2) != quote) refuse()
      rest = substr(line, length(key)+7, length(line)-length(key)-9)
      if (rest == "" || index(rest, quote) || index(rest, separator)) refuse()
      return rest
    }
    function emit() {
      if (!inside) return
      if (id == "" || (regex == "" && path == "")) refuse()
      print "class-1" separator id separator path separator regex
    }
    $0 == "[[rules]]" { emit(); inside = 1; allow = 0; id = ""; regex = ""; path = ""; next }
    $0 ~ /^[[:space:]]*\[\[rules\]\]/ { refuse() }
    $0 ~ /^[[:space:]]*\[\[rules.allowlists\]\]/ { allow = 1; next }
    allow { next }
    /^[[:space:]]*id[[:space:]]*=/ {
      if ($0 !~ /^id = "host-[A-Za-z0-9_-]+"$/) refuse()
      id = substr($0, 7, length($0)-7); next
    }
    /^[[:space:]]*regex[[:space:]]*=/ { regex = value($0, "regex"); next }
    /^[[:space:]]*path[[:space:]]*=/ { path = value($0, "path"); next }
    END { if (bad) exit 2; emit(); if (!inside) exit 2 }
  ' "$host_file" >> "$tmp/rules" || cannot_run "host rules need the single-line forms required by promotion"
else
  printf 'host rules: none\n'
fi

while IFS=$separator read -r class rule path regex; do
  for pattern in "$regex" "$path"; do
    [ -n "$pattern" ] || continue
    pattern_status=0
    printf '\n' | grep -aP -e "$pattern" >/dev/null 2>&1 || pattern_status=$?
    [ "$pattern_status" -le 1 ] || cannot_run "pattern compilation failed"
  done
done < "$tmp/rules"

if [ "$mode" = staged ]; then
  git diff --cached --no-ext-diff --no-renames --name-only -z --diff-filter=ACMT > "$tmp/selected-z" || cannot_run "staged paths cannot be read"
  git diff --no-ext-diff --no-renames --name-only -z --diff-filter=ACMT "$upstream" "$snapshot" > "$tmp/fork-z" || cannot_run "fork paths cannot be read"
else
  if [ "$mode" = worktree ]; then
    git diff --no-ext-diff --no-renames --name-only -z --diff-filter=ACMT "$upstream" > "$tmp/fork-z" || cannot_run "working paths cannot be read"
    git ls-files --others --exclude-standard -z >> "$tmp/fork-z" || cannot_run "new paths cannot be read"
  else
    git diff --no-ext-diff --no-renames --name-only -z --diff-filter=ACMT "$upstream" "$snapshot" > "$tmp/fork-z" || cannot_run "fork paths cannot be read"
  fi
  cp "$tmp/fork-z" "$tmp/selected-z" || cannot_run "selected paths cannot be read"
fi
for list in fork selected; do
  awk 'BEGIN { RS = "\000" } length($0) { if (index($0, "\n") || index($0, "\t") || index($0, "\r") || index($0, "\033")) exit 2; print }' "$tmp/$list-z" > "$tmp/$list" || cannot_run "unsupported file path"
done
awk 'FILENAME == ARGV[1] { fork[$0] = 1; next } fork[$0] && !seen[$0]++ { print }' "$tmp/fork" "$tmp/selected" > "$tmp/files" || cannot_run "fork paths cannot be selected"
: > "$tmp/findings"
while IFS= read -r file; do
  if development_only "$file"; then
    printf '%s development-only\n' "$file"
    continue
  fi
  if [ "$mode" = worktree ]; then
    if [ -L "$file" ]; then
      readlink "./$file" > "$tmp/content" || cannot_run "symlink cannot be read"
    elif [ -f "$file" ]; then
      cp "./$file" "$tmp/content" || cannot_run "file content cannot be read"
    else
      cannot_run "fork path is not a regular file or symlink"
    fi
  else
    object=$(git rev-parse --verify "$snapshot:$file") || cannot_run "file object cannot be read"
    [ "$(git cat-file -t "$object")" = blob ] || cannot_run "fork path is not a blob"
    git cat-file blob "$object" > "$tmp/content" || cannot_run "file blob cannot be read"
  fi
  while IFS=$separator read -r class rule path regex; do
    path_status=0
    if [ -n "$path" ]; then
      printf '%s\n' "$file" | grep -aP -e "$path" >/dev/null 2>&1 || path_status=$?
    fi
    [ "$path_status" -le 1 ] || cannot_run "path filter failed"
    [ "$path_status" -eq 0 ] || continue
    if [ -z "$regex" ]; then
      printf '1\n' > "$tmp/matches"
    else
      match_status=0
      grep -anP -e "$regex" "$tmp/content" > "$tmp/matched-content" 2>/dev/null || match_status=$?
      [ "$match_status" -le 1 ] || cannot_run "content filter failed"
      awk '{ n = index($0, ":"); line = substr($0, 1, n-1); if (!n || line !~ /^[0-9]+$/) exit 2; print line }' "$tmp/matched-content" > "$tmp/matches" || cannot_run "match output cannot be split"
    fi
    while IFS= read -r line; do
      awk -v number="$line" 'NR == number { print; exit }' "$tmp/content" > "$tmp/line" || cannot_run "matched line cannot be read"
      hash=$(git hash-object --stdin < "$tmp/line") || cannot_run "line hash cannot be read"
      allowance=$(printf '%s\t%s\t%s\t%s' "$file" "$line" "$rule" "$hash")
      allow_status=0
      grep -Fqx -- "$allowance" "$tmp/allow-keys" || allow_status=$?
      [ "$allow_status" -le 1 ] || cannot_run "allow list cannot be read"
      if [ "$allow_status" -eq 1 ]; then printf '%s:%s %s\n' "$file" "$line" "$class" >> "$tmp/findings"; fi
    done < "$tmp/matches"
  done < "$tmp/rules"
done < "$tmp/files"
sort -u "$tmp/findings" || cannot_run "findings cannot be sorted"
[ ! -s "$tmp/findings" ] || exit 1
exit 0
