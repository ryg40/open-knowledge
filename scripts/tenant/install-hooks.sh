#!/bin/sh
set -eu

marker=ok_scan_hook=1
old_marker=ok_tenant_hook=1
hooks="pre-commit pre-push"

usage() {
  echo "usage: $0 [--check]" >&2
  exit 2
}

hooks_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/hooks
hooks_path=$(git config --get core.hooksPath || true)

pre_commit_body() {
  cat <<'HOOK'
#!/bin/sh
set -eu
ok_scan_hook=1
: "$ok_scan_hook"
repo_root=$(git rev-parse --show-toplevel)
scan=$repo_root/scripts/tenant/scan.sh
if [ ! -x "$scan" ]; then
  echo "pre-commit: $scan is missing, so the secret scan cannot run" >&2
  exit 1
fi
public_check=$repo_root/scripts/tenant/public-check.sh
if [ ! -x "$public_check" ]; then
  echo "pre-commit: public content check is missing" >&2
  exit 1
fi
"$public_check" --staged
exec "$scan" --staged
HOOK
}

pre_push_body() {
  cat <<'HOOK'
#!/bin/sh
set -eu
ok_scan_hook=1
: "$ok_scan_hook"
remote=$1
url=${2-}
case $remote in
  upstream)
    echo "pre-push: push to upstream is refused" >&2
    exit 1
    ;;
esac
normalize_url() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed -E -e 's#(github\.com)\.?(:[0-9]*)?/+#\1/#g' -e 's#([^:])/+#\1/#g' -e 's#/*$##'
}
case $(normalize_url "$url") in
  *github.com[:/]inkeep/open-knowledge | *github.com[:/]inkeep/open-knowledge.git)
    echo "pre-push: push to the GitHub upstream is refused" >&2
    exit 1
    ;;
esac
repo_root=$(git rev-parse --show-toplevel)
scan=$repo_root/scripts/tenant/scan.sh
if [ ! -x "$scan" ]; then
  echo "pre-push: $scan is missing, so the secret scan cannot run" >&2
  exit 1
fi
case $remote in
  origin) portable_only=0 ;;
  *)
    portable_only=1
    if [ -z "$(git config --get ok.hostRules || true)" ]; then
      echo "pre-push: set ok.hostRules to an absolute host file path, or to none if this clone has no host rules" >&2
      exit 1
    fi
    if [ -z "$(git for-each-ref --count=1 refs/remotes/upstream/)" ]; then
      echo "pre-push: no ref under refs/remotes/upstream/: run scripts/tenant/setup-remotes.sh, then git fetch upstream" >&2
      exit 1
    fi
    ;;
esac
release_identity='OpenKnowledge Release <noreply@example.com>'
is_release_refspec() {
  case $2 in
    refs/heads/portable) [ "$1" = refs/heads/public ] ;;
    refs/tags/portable-v*) [ "$1" = "$2" ] ;;
    *) return 1 ;;
  esac
}
is_public_line() {
  identities=$(git log --no-use-mailmap --format='%an <%ae>%n%cn <%ce>' "$1" --not --remotes=upstream) || return 1
  if printf '%s\n' "$identities" | grep -Fvxq -- "$release_identity"; then return 1; fi
  public_tip=$(git rev-parse -q --verify 'refs/heads/public^{commit}') || return 1
  pushed_tip=$(git rev-parse -q --verify "$1^{commit}") || return 1
  git merge-base --is-ancestor "$pushed_tip" "$public_tip"
}
release_tag_fault() {
  tag_type=$(git cat-file -t "$1" 2>/dev/null) || tag_type=absent
  if [ "$tag_type" != tag ]; then
    echo "it is a lightweight tag (object type $tag_type); a release tag is an annotated tag with the tagger $release_identity"
    return 0
  fi
  tag_text=$(git cat-file tag "$1") || { echo "its tag object cannot be read"; return 0; }
  if [ "$(printf '%s\n' "$tag_text" | sed -n 's/^type //p' | head -n 1)" != commit ]; then
    echo "its tag object does not name a commit"
    return 0
  fi
  tagger=$(printf '%s\n' "$tag_text" | awk '/^$/ { exit } /^tagger / { print substr($0, 8) }' | sed -e 's/ [0-9]* [-+][0-9]*$//')
  if [ "$tagger" != "$release_identity" ]; then
    echo "its tagger is ${tagger:-absent}; a release tag has the tagger $release_identity"
    return 0
  fi
  return 1
}
zero=0000000000000000000000000000000000000000
base=$(git config --get ok.historyBase || true)
if [ -n "$base" ]; then
  if ! base=$(git rev-parse -q --verify "$base^{commit}"); then
    echo "pre-push: the Git config key ok.historyBase does not name a commit" >&2
    exit 1
  fi
  upstream_tips=$(git for-each-ref --format='%(objectname)' refs/remotes/upstream/) || exit 1
  valid_base=0
  for upstream_tip in $upstream_tips; do
    if git merge-base --is-ancestor "$base" "$upstream_tip"; then valid_base=1; break; fi
  done
  if [ "$valid_base" -eq 0 ]; then
    if [ -z "$upstream_tips" ]; then
      echo "pre-push: no ref under refs/remotes/upstream/: run scripts/tenant/setup-remotes.sh, then git fetch upstream" >&2
    else
      echo "pre-push: ok.historyBase is not in upstream history; choose an upstream ancestor, or unset the key to scan the whole range" >&2
    fi
    exit 1
  fi
fi
pushed=$(cat)
known=
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -n "$local_sha" ] || continue
  if [ "$remote_sha" != "$zero" ] && git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
    known="$known $remote_sha"
  fi
done <<EOF
$pushed
EOF
advertised=
remote_read=1
if tips=$(git ls-remote --refs "$url" 2>/dev/null); then
  while read -r sha _ref; do
    [ -n "$sha" ] || continue
    if git cat-file -e "$sha^{commit}" 2>/dev/null; then advertised="$advertised $sha"; fi
  done <<EOF
$tips
EOF
else
  remote_read=0
  echo "pre-push: ls-remote failed; new refs scan the whole range from the history base" >&2
fi
status=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -n "$local_sha" ] || continue
  if [ "$portable_only" -eq 1 ]; then
    if [ "$local_sha" = "$zero" ] || ! is_release_refspec "$local_ref" "$remote_ref"; then
      echo "pre-push: refused $local_ref -> $remote_ref: remote $remote takes only refs/heads/public as refs/heads/portable, and refs/tags/portable-v*" >&2
      status=1
      continue
    fi
    case $remote_ref in
      refs/tags/*)
        if fault=$(release_tag_fault "$local_sha"); then
          echo "pre-push: refused $local_ref -> $remote_ref: $fault" >&2
          status=1
          continue
        fi
        ;;
    esac
    if ! is_public_line "$local_sha"; then
      echo "pre-push: refused $local_ref -> $remote_ref: it is not on the public line; each commit outside refs/remotes/upstream/ must be a release commit of public" >&2
      status=1
      continue
    fi
  fi
  [ "$local_sha" != "$zero" ] || continue
  if [ -n "$base" ] && ! git merge-base --is-ancestor "$base" "$local_sha"; then
    echo "pre-push: ok.historyBase is not an ancestor of $local_ref" >&2
    status=1
    continue
  fi
  if [ "$remote_sha" = "$zero" ] || ! git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
    excluded=$base
    if [ "$remote_read" -eq 1 ]; then excluded="$excluded$known$advertised"; fi
    range="$local_sha"
    if [ -n "$excluded" ]; then range="$range --not $(printf '%s\n' "$excluded" | xargs -n 1 | sort -u | xargs)"; fi
    if [ -z "$base" ]; then
      echo "pre-push: ok.historyBase is not set; no upstream history is excluded"
    fi
  else
    if git merge-base --is-ancestor "$remote_sha" "$local_sha"; then
      range="$remote_sha..$local_sha"
    else
      range="$local_sha --not $remote_sha"
    fi
  fi
  count=$(printf '%s\n' "$range" | xargs git rev-list --count) || exit 1
  echo "pre-push: $local_ref -> $remote_ref, $count commits, range $range"
  "$scan" --history "$range" || status=1
done <<EOF
$pushed
EOF
exit "$status"
HOOK
}

is_ours() {
  grep -qx -e "$marker" -e "$old_marker" "$1"
}

check() {
  failed=0
  if [ -n "$hooks_path" ]; then
    echo "wrong: core.hooksPath is $hooks_path, so Git does not run hooks from $hooks_dir" >&2
    failed=1
  fi
  for name in $hooks; do
    file=$hooks_dir/$name
    if [ ! -f "$file" ]; then
      echo "wrong: $file is absent" >&2
      failed=1
    elif ! is_ours "$file"; then
      echo "wrong: $file was not written by $0" >&2
      failed=1
    elif [ ! -x "$file" ]; then
      echo "wrong: $file is not executable" >&2
      failed=1
    elif ! body_matches "$file"; then
      echo "wrong: $file is out of date" >&2
      failed=1
    fi
  done
  if [ "$failed" -eq 0 ]; then
    echo "ok: pre-commit and pre-push are installed in $hooks_dir"
  fi
  return "$failed"
}

body_matches() {
  case $1 in
    */pre-commit) pre_commit_body | cmp -s - "$1" ;;
    */pre-push) pre_push_body | cmp -s - "$1" ;;
  esac
}

install() {
  if [ -n "$hooks_path" ]; then
    echo "refused: core.hooksPath is $hooks_path, so Git does not run hooks from $hooks_dir" >&2
    echo "refused: run 'git config --unset core.hooksPath' and install again" >&2
    exit 1
  fi
  for name in $hooks; do
    file=$hooks_dir/$name
    if [ -e "$file" ] && ! is_ours "$file"; then
      echo "refused: $file exists and was not written by $0" >&2
      exit 1
    fi
  done
  mkdir -p "$hooks_dir"
  for name in $hooks; do
    file=$hooks_dir/$name
    case $name in
      pre-commit) pre_commit_body > "$file.tmp" ;;
      pre-push) pre_push_body > "$file.tmp" ;;
    esac
    chmod 755 "$file.tmp"
    mv "$file.tmp" "$file"
    echo "installed: $file"
  done
}

case $# in
  0) install ;;
  1)
    case $1 in
      --check) check ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac
