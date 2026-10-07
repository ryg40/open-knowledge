#!/bin/sh
set -eu
export GIT_PAGER=cat LC_ALL=C
container_cli=${OK_CONTAINER_CLI:-docker}

version=
push=0
yes=0
accept_visibility=0
expected=
remote=github
source=local-dev
separator=$(printf '\037')
tab=$(printf '\t')
zero=0000000000000000000000000000000000000000
first_version=0.2.0
release_identity='OpenKnowledge Release <noreply@example.com>'
export GIT_AUTHOR_NAME='OpenKnowledge Release' GIT_AUTHOR_EMAIL=noreply@example.com
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

usage() {
  echo "usage: $0 --version X.Y.Z [--push --visibility public|private] [--yes] [--accept-visibility] [--remote <name>] [--source <branch>]" >&2
  exit 2
}

fail() {
  echo "promote: refused: $*" >&2
  exit 1
}

step() {
  echo
  echo "promote: step $1: $2"
}

strip_credentials() {
  printf '%s\n' "$1" | sed -e 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/]*@#\1#'
}

version_gt() {
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)" = "$1" ]
}

github_slug() {
  printf '%s\n' "$1" | sed -E -n -e 's#\.git$##' -e 's#^(https://([^/@]*@)?|ssh://git@|git@)github\.com[:/]([^/]+/[^/]+)$#\3#p'
}

host_rules() {
  awk -v quote="'''" -v separator="$separator" '
    function value(line,   start, rest, stop) {
      start = index(line, quote)
      if (start == 0) return ""
      rest = substr(line, start + 3)
      stop = index(rest, quote)
      if (stop == 0) return ""
      return substr(rest, 1, stop - 1)
    }
    function refuse(cause, error_line) {
      if (id != "") printf "promote: host rule %s: %s\n", id, cause > "/dev/stderr"
      else printf "promote: host file line %s: %s\n", error_line ? error_line : FNR, cause > "/dev/stderr"
      bad = 1
      exit 1
    }
    function emit() {
      if (!inside) return
      if (id == "") refuse("id must use id = double-quoted name without indentation", rule_line)
      if (id == "host-") refuse("has no name after host-")
      if (regex == "") refuse("regex must use single-line triple-single-quoted text without indentation")
      printf "%s%s%s%s%s\n", id, separator, path, separator, regex
    }
    /^[[:space:]]*\[\[rules\]\][[:space:]]*$/ {
      emit(); rule_line = FNR; id = ""
      if ($0 != "[[rules]]") refuse("the rules table must have no indentation or trailing space")
      inside = 1; count++; regex = ""; path = ""; next
    }
    /^[[:space:]]*id[[:space:]]*=/ {
      if ($0 !~ /^id = "[A-Za-z0-9_-]+"$/) refuse("id must use id = double-quoted name without indentation")
      id = $0; sub(/^id = "/, "", id); sub(/"$/, "", id); next
    }
    /^[[:space:]]*regex[[:space:]]*=/ {
      if (index($0, "regex = " quote) != 1 || substr($0, length($0)-2) != quote) refuse("regex must use single-line triple-single-quoted text without indentation")
      regex = value($0); next
    }
    /^[[:space:]]*path[[:space:]]*=/ {
      if (index($0, "path = " quote) != 1 || substr($0, length($0)-2) != quote || value($0) == "") refuse("path must use nonempty single-line triple-single-quoted text without indentation")
      path = value($0); next
    }
    END {
      if (bad) exit 1
      if (!count) { print "promote: host file has no [[rules]] table" > "/dev/stderr"; exit 1 }
      emit()
    }
  ' "$1"
}

normalize_url() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed -E -e 's#(github\.com)\.?(:[0-9]*)?/+#\1/#g' -e 's#([^:])/+#\1/#g' -e 's#/*$##'
}

scanner_error() {
  echo "promote: scanner error: $*" >&2
  exit 2
}

validate_pattern() {
  pattern_status=0
  printf '\n' > "$tmp/pattern-input"
  grep -a -P -e "$2" "$tmp/pattern-input" >/dev/null 2>&1 || pattern_status=$?
  [ "$pattern_status" -le 1 ] || scanner_error "$1 cannot compile for rule $rule_id"
}

check_filter() {
  [ "$filter_status" -gt 1 ] || return 0
  decode_error='UTF-?8.*(error|invalid)|invalid UTF-?8'
  if [ "$filter_locale" != C ] && grep -aiEq "$decode_error" "$tmp/filter-errors" && ! grep -aviEq "$decode_error" "$tmp/filter-errors"; then
    : > "$1"
    filter_status=1
    return 0
  fi
  scanner_error "$2"
}

in_scope() {
  scope_input=$2
  scope_output=$3
  : > "$scope_output"
  while IFS= read -r scope_line; do
    scope_path=${scope_line%%"$tab"*}
    printf '%s\n' "$scope_path" > "$tmp/scope-path"
    filter_status=0
    if [ -n "$1" ]; then
      LC_ALL="$filter_locale" grep -a -P -e "$1" "$tmp/scope-path" >/dev/null 2> "$tmp/filter-errors" || filter_status=$?
      check_filter /dev/null "path filter failed for rule $rule_id"
    fi
    if [ "$filter_status" -eq 0 ]; then printf '%s\n' "$scope_line" >> "$scope_output"; fi
  done < "$scope_input"
}

allowlist_paths() {
  awk '
    /^paths = \[/ { inside = 1 }
    inside {
      line = $0
      while ((start = index(line, "\047\047\047")) > 0) {
        line = substr(line, start + 3)
        stop = index(line, "\047\047\047")
        if (stop == 0) break
        print substr(line, 1, stop - 1)
        line = substr(line, stop + 3)
      }
    }
    inside && /\]/ { inside = 0 }
  ' "$1"
}

highest_version() {
  sed -n 's#^.*portable-v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

tree_hits() {
  rule_id=$1
  regex=$2
  rule_path=$3
  filter_status=0
  LC_ALL="$filter_locale" git -c core.quotePath=false grep -a -n -z -P -e "$regex" "$new_sha" -- . > "$tmp/hits" 2> "$tmp/filter-errors" || filter_status=$?
  check_filter "$tmp/hits" "git grep failed for rule $rule_id"
  if grep -aiq 'binary file matches' "$tmp/filter-errors"; then scanner_error "binary match output for rule $rule_id"; fi
  awk -v prefix="$new_sha:" '
    {
      first = index($0, "\000")
      if (!first || substr($0, 1, length(prefix)) != prefix) { bad = 1; exit 2 }
      file = substr($0, length(prefix) + 1, first - length(prefix) - 1)
      rest = substr($0, first + 1)
      second = index(rest, "\000")
      number = substr(rest, 1, second - 1)
      if (!second || number !~ /^[0-9]+$/ || file == "" || index(file, "\t")) { bad = 1; exit 2 }
      printf "%s\t%s\n", file, number
    }
    END { if (bad) exit 2 }
  ' "$tmp/hits" > "$tmp/tree-lines" || scanner_error "tree output cannot be split for rule $rule_id"
  in_scope "$rule_path" "$tmp/tree-lines" "$tmp/scoped-tree"
  while IFS="$tab" read -r file line; do
    printf '%s:%s: commit %s, rule %s\n' "$file" "$line" "$new_sha" "$rule_id"
  done < "$tmp/scoped-tree"
}

check_visibility() {
  actual=
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    reason="gh auth status failed; gh is not logged in to github.com"
    return 1
  fi
  if ! private=$(gh repo view "$slug" --json isPrivate --jq .isPrivate 2>/dev/null); then
    reason="gh repo view $slug failed"
    return 1
  fi
  case $private in
    true) actual=private ;;
    false) actual=public ;;
    *)
      reason="gh repo view $slug gave no visibility"
      return 1
      ;;
  esac
}

release_chain() {
  chain_commit=$1
  : > "$tmp/chain"
  while [ -n "$chain_commit" ]; do
    printf '%s\n' "$chain_commit" >> "$tmp/chain"
    git rev-list --parents -n 1 "$chain_commit" > "$tmp/parents" || fail "cannot read the parents of $chain_commit"
    read -r _ first_parent second_parent more_parents < "$tmp/parents" || true
    if [ -n "$more_parents" ] || [ -z "$first_parent" ]; then
      fail "release commit $chain_commit needs one or two parents"
    fi
    if [ -n "$second_parent" ]; then chain_commit=$first_parent; else chain_commit=; fi
  done
}

in_chain() {
  grep -qx -- "$1" "$tmp/chain"
}

identity_of() {
  git show -s --no-use-mailmap --format="$1" "$2"
}

public_worktree() {
  git worktree list --porcelain | awk '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch refs/heads/public" { print path; exit }
  '
}

while [ $# -gt 0 ]; do
  case $1 in
    --version) [ $# -ge 2 ] || usage; version=$2; shift 2 ;;
    --remote) [ $# -ge 2 ] || usage; remote=$2; shift 2 ;;
    --source) [ $# -ge 2 ] || usage; source=$2; shift 2 ;;
    --visibility) [ $# -ge 2 ] || usage; expected=$2; shift 2 ;;
    --push) push=1; shift ;;
    --yes) yes=1; shift ;;
    --accept-visibility) accept_visibility=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$version" ] || usage
printf '%s\n' "$version" | grep -aEqx '[0-9]+\.[0-9]+\.[0-9]+' || fail "version $version is not X.Y.Z"
case $expected in
  "" | public | private) ;;
  *) fail "--visibility is $expected; give public or private" ;;
esac
if [ "$push" -eq 1 ] && [ -z "$expected" ]; then
  fail "--push needs --visibility public or --visibility private"
fi
if [ "$expected" = public ]; then
  [ "$accept_visibility" -eq 0 ] || fail "--accept-visibility is refused with --visibility public"
fi
tag=portable-v$version
case $remote in
  origin) remote_branch=public ;;
  *) remote_branch=portable ;;
esac
remote_ref=refs/heads/$remote_branch

tmp=
cleanup() {
  if [ -n "$tmp" ]; then
    if [ -d "$tmp/src" ]; then
      git worktree remove --force "$tmp/src" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
default_image=$(awk '/^default_image=/ { sub(/^default_image=/, ""); value = $0; count++ } END { if (count != 1 || value == "") exit 2; print value }' scripts/tenant/scan.sh) || scanner_error "cannot read the scanner image from scan.sh"
image=${GITLEAKS_IMAGE:-$default_image}
if [ "$image" != "$default_image" ]; then
  echo "promote: scanner image override: $image"
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ok-promote.XXXXXX")

step 1 "clean working tree, full history, hooks path, host rules, public is not checked out"
if [ -n "$(git status --porcelain)" ]; then
  fail "the working tree of $repo_root has changes; commit them on a topic branch first"
fi
case $source in
  public | portable) fail "the source is $source" ;;
esac
public_dir=$(public_worktree)
if [ -n "$public_dir" ]; then
  fail "the worktree $public_dir holds public; the command moves that branch without a checkout"
fi
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  fail "the repository is shallow; the proof and the scans need the full history"
fi
hooks_path=$(git config --get core.hooksPath || true)
if [ -n "$hooks_path" ]; then
  fail "core.hooksPath is $hooks_path, so the hooks of install-hooks.sh do not run"
fi
rules_file=$(git config --type=path --get ok.hostRules || true)
[ "$rules_file" != none ] || fail "ok.hostRules is none; promotion needs a real host rules file"
[ -n "$rules_file" ] || fail "the Git config key ok.hostRules is not set; the host rules check needs the host rules file"
case $rules_file in
  /*) ;;
  *) fail "ok.hostRules is not an absolute host file path" ;;
esac
if [ ! -f "$rules_file" ] || [ ! -r "$rules_file" ]; then
  fail "ok.hostRules names $rules_file, which is not a readable file"
fi
encoding_line=$(awk 'index($0, "\r") { print FNR; exit }' "$rules_file")
if [ -n "$encoding_line" ]; then scanner_error "host file line $encoding_line: CRLF; use LF line endings"; fi
if [ "$(od -An -N3 -tx1 "$rules_file" | tr -d ' \n')" = efbbbf ]; then scanner_error "host file line 1: BOM; use UTF-8 without a BOM"; fi
host_rules "$rules_file" > "$tmp/rules" || exit 1
source_sha=$(git rev-parse -q --verify "refs/heads/$source^{commit}") || fail "branch $source does not exist"
while IFS=$separator read -r rule_id rule_path rule_regex; do
  case $rule_id in
    host-?*) ;;
    *) fail "host rule ID $rule_id must start with host-" ;;
  esac
  validate_pattern regex "$rule_regex"
  if [ -n "$rule_path" ]; then validate_pattern path "$rule_path"; fi
done < "$tmp/rules"
source_short=$(git rev-parse --short "$source_sha")
echo "ok: $repo_root is clean, source $source is $source_short, $(wc -l < "$tmp/rules" | tr -d ' ') host rules"

step 2 "setup-remotes.sh --check"
"$repo_root/scripts/tenant/setup-remotes.sh" --check || fail "setup-remotes.sh --check failed"

step 3 "upstream release commit and previous public release"
git show "$source_sha:deploy/Dockerfile" > "$tmp/dockerfile" 2>/dev/null || fail "$source has no deploy/Dockerfile"
upstream_version=$(awk -F= '/^ARG OK_VERSION=/ { print $2; exit }' "$tmp/dockerfile")
printf '%s\n' "$upstream_version" | grep -aEqx '[0-9]+\.[0-9]+\.[0-9]+' || fail "OK_VERSION of $source is not a stable X.Y.Z version"
git rev-parse -q --verify 'refs/remotes/upstream/main^{commit}' >/dev/null || fail "refs/remotes/upstream/main is absent: run scripts/tenant/setup-remotes.sh, then git fetch upstream"
git log --first-parent --format='%H%x09%s' refs/remotes/upstream/main > "$tmp/upstream-log" || fail "cannot read the upstream history"
upstream_sha=$(awk -v prefix="main reset: post-stable v$upstream_version" '
  {
    subject = substr($0, index($0, "\t") + 1)
    if (index(subject, prefix) != 1) next
    rest = substr(subject, length(prefix) + 1)
    if (rest == "" || rest ~ /^[ (]/) { print substr($0, 1, index($0, "\t") - 1); count++ }
  }
  END { if (count != 1) exit 1 }
' "$tmp/upstream-log") || fail "upstream main needs exactly one post-stable commit for $upstream_version; run git fetch upstream, then compare ARG OK_VERSION of $source with the upstream releases"
git show "$upstream_sha:packages/cli/package.json" > "$tmp/manifest" 2>/dev/null || fail "the upstream release commit has no package manifest"
manifest_version=$(awk -F '"' '/"version"[[:space:]]*:/ { print $4; exit }' "$tmp/manifest")
[ "$manifest_version" = "$upstream_version" ] || fail "the package manifest of $upstream_sha has version $manifest_version, not $upstream_version"
git merge-base --is-ancestor "$upstream_sha" "$source_sha" || fail "$source does not contain the upstream release commit $upstream_sha; merge that upstream release into $source first"
upstream_short=$(git rev-parse --short "$upstream_sha")
history_base=$(git config --get ok.historyBase || true)
if [ -n "$history_base" ]; then
  history_base=$(git rev-parse --verify --quiet "$history_base^{commit}") || fail "ok.historyBase does not name a commit"
  git merge-base --is-ancestor "$history_base" "$upstream_sha" || fail "ok.historyBase is not an ancestor of the upstream release commit $upstream_short; set the key to an earlier upstream commit"
fi
public_sha=$(git rev-parse -q --verify 'refs/heads/public^{commit}' || true)
resume=0
previous=$public_sha
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  tag_commit=$(git rev-parse -q --verify "refs/tags/$tag^{commit}") || fail "tag $tag has no commit"
  if [ -z "$public_sha" ] || [ "$tag_commit" != "$public_sha" ]; then
    fail "tag $tag exists and is not the head of public; give a new version"
  fi
  tag_type=$(git cat-file -t "refs/tags/$tag")
  if [ "$tag_type" != tag ]; then
    fail "tag $tag is a lightweight tag (object type $tag_type), and a release tag is annotated; delete the local tag and run again, or give a new version"
  fi
  resume=1
  release_chain "$public_sha"
  previous=$(sed -n 2p "$tmp/chain")
fi
echo "ok: upstream release $upstream_version is $upstream_short, previous public release is ${previous:-none}"

step 4 "snapshot commit"
GIT_INDEX_FILE=$tmp/index git read-tree "$source_sha" || fail "cannot read the tree of $source"
development_status=0
"$repo_root/scripts/tenant/public-check.sh" --development-only "$source_sha" > "$tmp/development-only" || development_status=$?
case $development_status in
  0 | 1) ;;
  *) scanner_error "the development-only path check cannot run" ;;
esac
sed -e 's/ development-only$//' "$tmp/development-only" > "$tmp/excluded"
if [ -s "$tmp/excluded" ]; then
  tr '\n' '\000' < "$tmp/excluded" | GIT_INDEX_FILE=$tmp/index git update-index --force-remove -z --stdin || fail "cannot remove the development-only paths from the snapshot"
fi
snapshot_tree=$(GIT_INDEX_FILE=$tmp/index git write-tree) || fail "cannot write the snapshot tree"
if [ -n "$previous" ] && [ "$resume" -eq 0 ] && [ "$(git rev-parse "$previous^{tree}")" = "$snapshot_tree" ]; then
  fail "the last public release $previous already has the snapshot tree of $source $source_short"
fi
release_date="$(git show -s --format=%ct "$source_sha") +0000"
if [ -n "$previous" ]; then
  set -- -p "$previous" -p "$upstream_sha"
else
  set -- -p "$upstream_sha"
fi
new_sha=$(GIT_AUTHOR_DATE=$release_date GIT_COMMITTER_DATE=$release_date git commit-tree "$snapshot_tree" "$@" -m "OpenKnowledge portable $version" -m "Release tree on upstream OpenKnowledge $upstream_version.") || fail "cannot write the snapshot commit"
if [ "$resume" -eq 1 ] && [ "$new_sha" != "$public_sha" ]; then
  fail "tag $tag exists, and public $public_sha differs from the snapshot $new_sha of $source $source_short; give a new version"
fi
echo "ok: snapshot commit $new_sha, tree $snapshot_tree, $(wc -l < "$tmp/excluded" | tr -d ' ') development-only files excluded"
echo "ok: parents: ${previous:-no previous release}, upstream release $upstream_sha"

step 5 "proof of the ancestry"
release_chain "$new_sha"
git rev-list "$new_sha" --not "$upstream_sha" > "$tmp/proof" || fail "cannot list the ancestry"
echo "proof: git rev-list $new_sha --not $upstream_sha"
foreign=0
while IFS= read -r commit; do
  if ! in_chain "$commit" || [ "$(identity_of '%an <%ae>' "$commit")" != "$release_identity" ] || [ "$(identity_of '%cn <%ce>' "$commit")" != "$release_identity" ]; then
    foreign=$((foreign + 1))
    if [ "$foreign" -le 10 ]; then
      echo "  $commit is not a public release commit: $(git show -s --format=%s "$commit")"
    fi
    continue
  fi
  if [ "$commit" = "$new_sha" ]; then
    echo "  $commit $tag, this release"
    continue
  fi
  release_tag=$(git tag --list 'portable-v*' --points-at "$commit" | head -n 1)
  [ -n "$release_tag" ] || fail "the earlier release commit $commit has no portable-v* tag; set public to the last tagged release commit, then promote again"
  echo "  $commit $release_tag"
done < "$tmp/proof"
if [ "$foreign" -gt 10 ]; then
  echo "  and $((foreign - 10)) more commits that are not public release commits"
fi
if [ "$foreign" -gt 0 ]; then
  fail "the proof lists $foreign commits that are not upstream commits and not public release commits; set public to the last public release commit, or delete the branch when no public release exists, then promote again"
fi
git tag --list 'portable-v*' > "$tmp/local-tags"
other_tags=0
while IFS= read -r name; do
  [ "$name" != "$tag" ] || continue
  tip=$(git rev-parse -q --verify "refs/tags/$name^{commit}") || fail "tag $name has no commit"
  if in_chain "$tip"; then continue; fi
  if git merge-base --is-ancestor "$tip" "$new_sha"; then
    fail "tag $name of another chain is an ancestor of the snapshot commit; set public to the last public release commit, then promote again"
  fi
  other_tags=$((other_tags + 1))
done < "$tmp/local-tags"
echo "ok: $(wc -l < "$tmp/proof" | tr -d ' ') release commits, each other ancestor is an upstream commit; $other_tags portable-v* tags of other chains are not ancestors"

step 6 "remote $remote and its refs"
[ "$remote" != upstream ] || fail "the remote is upstream"
git config --get "remote.$remote.url" >/dev/null 2>&1 || fail "remote $remote does not exist; set SHARED_URL and run setup-remotes.sh"
remote_url=$(git remote get-url --push "$remote")
shown_url=$(strip_credentials "$remote_url")
case $(normalize_url "$remote_url") in
  *github.com[:/]inkeep/open-knowledge | *github.com[:/]inkeep/open-knowledge.git)
    fail "remote $remote points to the GitHub upstream"
    ;;
esac
git ls-remote --refs "$remote_url" > "$tmp/remote-before" || fail "cannot read remote $remote ($shown_url)"
if awk -v ref="refs/tags/$tag" '$2 == ref { found = 1 } END { exit !found }' "$tmp/remote-before"; then
  fail "tag $tag exists on $remote"
fi
remote_tip=$(awk -v ref="$remote_ref" '$2 == ref { print $1 }' "$tmp/remote-before")
if [ -n "$remote_tip" ] && ! in_chain "$remote_tip"; then
  fail "$remote_branch on $remote is $remote_tip, which is not a release commit of the public line; that history is another chain; replace or empty that repository yourself before the first push, because the command never forces a push"
fi
if [ "$remote" != origin ]; then
  awk '$2 ~ /^refs\/tags\/portable-v/ { print $1 "\t" $2 }' "$tmp/remote-before" > "$tmp/remote-release-tags"
  while IFS="$tab" read -r object ref; do
    name=${ref#refs/tags/}
    local_object=$(git rev-parse -q --verify "$ref" || true)
    if [ -z "$local_object" ]; then
      fail "$name on $remote has no local tag of that name; fetch it with git fetch $remote tag $name and examine it, or replace or empty that repository yourself"
    fi
    if [ "$local_object" != "$object" ]; then
      fail "the tag objects differ: $name on $remote is $object, and the local tag is $local_object; examine both tags, and never move a pushed release tag"
    fi
    tip=$(git rev-parse -q --verify "$ref^{commit}" || true)
    if [ -z "$tip" ] || ! in_chain "$tip"; then
      fail "$name on $remote is not a release of the public line; that history is another chain; replace or empty that repository yourself before the first push, because the command never forces a push"
    fi
  done < "$tmp/remote-release-tags"
fi
if [ -z "$remote_tip" ] && [ -z "$history_base" ]; then
  fail "$remote has no $remote_branch, and the Git config key ok.historyBase is not set, so the first push has no history base; set the key to an upstream commit before the release commit"
fi
echo "ok: $remote is $shown_url and has $(wc -l < "$tmp/remote-before" | tr -d ' ') refs"

step 7 "visibility of $remote"
actual=
reason=
slug=$(github_slug "$remote_url")
if [ -z "$slug" ]; then
  reason="$shown_url is not a GitHub URL"
elif ! command -v gh >/dev/null 2>&1; then
  reason="gh is not installed"
else
  check_visibility || true
fi
if [ -n "$actual" ]; then
  echo "ok: $slug is $actual"
  if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
    fail "$slug is $actual, but --visibility is $expected"
  fi
else
  echo "not verified: visibility, $reason"
  if [ "$expected" = public ]; then
    echo "ok: the checks treat $remote as public, because --visibility is public"
  elif [ "$push" -eq 1 ] && [ "$accept_visibility" -eq 0 ]; then
    fail "--push with --visibility private needs --accept-visibility when the visibility is not verified"
  fi
fi

step 8 "tag $tag and version order"
last=$(grep -vx -- "$tag" "$tmp/local-tags" | highest_version)
if [ -n "$last" ] && ! version_gt "$version" "$last"; then
  fail "version $version is not greater than the last tag portable-v$last; a release never takes the name of an earlier tag"
fi
if [ -z "$public_sha" ] && [ "$version" != "$first_version" ] && ! version_gt "$version" "$first_version"; then
  fail "version $version is below $first_version; the public line starts at portable-v$first_version, and its first release takes no lower number"
fi
if git ls-remote --tags "$remote_url" 'portable-v*' > "$tmp/remote-tags" 2>/dev/null; then
  remote_last=$(sed -e 's/\^{}$//' "$tmp/remote-tags" | highest_version)
  if [ -n "$remote_last" ] && ! version_gt "$version" "$remote_last"; then
    fail "version $version is not greater than the last tag portable-v$remote_last on $remote ($shown_url)"
  fi
  echo "ok: the last portable-v* tag on $remote ($shown_url) is portable-v${remote_last:-none}"
else
  echo "not verified: remote tags"
  if [ "$push" -eq 1 ]; then
    fail "--push needs the portable-v* tags of $remote ($shown_url), and git ls-remote --tags failed"
  fi
fi
if [ "$resume" -eq 1 ]; then
  echo "ok: $tag exists on the head of public; the run pushes that release"
else
  echo "ok: $tag is new, the last tag is portable-v${last:-none}"
fi

step 9 "scan of the snapshot"
git worktree prune
git worktree add -q --detach "$tmp/src" "$new_sha" || fail "cannot check out the snapshot commit in a temporary worktree"
scan_dir=$tmp/src
[ -x "$scan_dir/scripts/tenant/scan.sh" ] || fail "the snapshot has no scripts/tenant/scan.sh"
validation_status=0
(cd "$scan_dir" && ./scripts/tenant/scan.sh --validate-only) || validation_status=$?
[ "$validation_status" -eq 0 ] || scanner_error "host configuration validation failed (exit $validation_status)"
if ! scanner=$("$container_cli" run --rm --network none "$image" --version 2>/dev/null); then
  echo "promote: the scanner cannot run: $container_cli run $image --version failed" >&2
  exit 2
fi
echo "ok: the scanner runs, $scanner"
run_scan() {
  description=$1
  shift
  scan_status=0
  (cd "$scan_dir" && ./scripts/tenant/scan.sh "$@") || scan_status=$?
  case $scan_status in
    0) ;;
    1) fail "$description has a finding" ;;
    *) echo "promote: scanner error in $description (exit $scan_status)" >&2; exit 2 ;;
  esac
}
run_scan "the tree scan of the snapshot"
set -- --history "$new_sha --not $upstream_sha${previous:+ $previous}"
run_scan "the history scan of the snapshot commit" "$@"

step 10 "host rules on the snapshot"
findings=$tmp/findings
: > "$findings"
utf8_locale=$(locale -a 2>/dev/null | awk 'tolower($0) ~ /^c\.utf-?8$/ { print; exit }')
if [ -z "$utf8_locale" ]; then echo "not verified: utf-8 pass"; fi
for filter_locale in C "$utf8_locale"; do
  [ -n "$filter_locale" ] || continue
  while IFS=$separator read -r rule_id rule_path rule_regex; do
    tree_hits "$rule_id" "$rule_regex" "$rule_path" >> "$findings"
  done < "$tmp/rules"
done
sort -u "$findings" > "$tmp/unique-findings" || scanner_error "finding sort failed"
mv "$tmp/unique-findings" "$findings"
if [ -s "$findings" ]; then
  cat "$findings" >&2
  fail "the host rules found $(wc -l < "$findings" | tr -d ' ') lines in the snapshot; fix them on $source, then promote again"
fi
echo "ok: no host value and no host wording in the snapshot"

check_identities() {
  identity_status=0
  (cd "$scan_dir" && ./scripts/tenant/public-check.sh --identities "$new_sha" "$new_sha") || identity_status=$?
  case $identity_status in
    0) ;;
    1) fail "the public line needs the release identity or an upstream identity on each commit and tag" ;;
    *) scanner_error "the public identity check cannot run" ;;
  esac
}

step 11 "public content and identities"
development_status=0
(cd "$scan_dir" && ./scripts/tenant/public-check.sh --development-only "$new_sha") || development_status=$?
case $development_status in
  0) ;;
  1) fail "the snapshot contains development-only paths" ;;
  *) scanner_error "the development-only path check cannot run" ;;
esac
public_status=0
(cd "$scan_dir" && ./scripts/tenant/public-check.sh --tree "$new_sha") || public_status=$?
case $public_status in
  0) ;;
  1) fail "the public content check has a finding; fix it on $source" ;;
  *) scanner_error "the public content check cannot run" ;;
esac
check_identities
echo "ok: commit author and committer: $(identity_of '%an <%ae>' "$new_sha"), $(identity_of '%cn <%ce>' "$new_sha")"
echo "tagger: $(git var GIT_COMMITTER_IDENT | sed -e 's/ [0-9]* [-+][0-9]*$//')"

step 12 "plan"
echo "mode: snapshot"
echo "source: $source $source_sha"
echo "snapshot: $new_sha (tree $snapshot_tree)"
echo "parents: ${previous:-no previous release}, upstream release $upstream_version $upstream_sha"
echo "version: $version (last portable-v${last:-none})"
echo "remote: $remote $shown_url (visibility: ${actual:-not verified}, expected: ${expected:-not given})"
echo "refspecs: refs/heads/public:$remote_ref refs/tags/$tag:refs/tags/$tag"
if [ -n "$remote_tip" ]; then
  echo "remote $remote_branch: $remote_tip"
  echo "commits that leave: $(git rev-list --count "$new_sha" --not "$remote_tip" "$upstream_sha") release commits, and $(git rev-list --count "$upstream_sha" --not "$remote_tip") upstream commits"
else
  echo "first push: $remote has no $remote_branch; the upstream history to $upstream_short and $(wc -l < "$tmp/proof" | tr -d ' ') release commits leave"
fi
echo "remote refs before the push:"
grep -av '	refs/pull/' "$tmp/remote-before" || echo "  none"
awk -v branch="$remote_ref" '$2 != branch && $2 !~ /^refs\/(tags\/portable-v|pull\/)/ { print "warning: foreign ref on the remote: " $2 }' "$tmp/remote-before"
allowlist_paths "$scan_dir/.gitleaks.toml" | sed -e 's/^(?[a-z]*)//' -e 's/(?:/(/g' -e 's/\\s/[[:space:]]/g' -e 's/\\W/[^[:alnum:]_]/g' -e 's/\\d/[0-9]/g' > "$tmp/allowlist"
if [ -s "$tmp/allowlist" ]; then
  git diff --name-only "${previous:-$upstream_sha}" "$new_sha" | grep -aE -f "$tmp/allowlist" | while IFS= read -r file; do
    echo "warning: $file is in an allowlist of .gitleaks.toml and changed since ${previous:-the upstream release}; examine it"
  done || true
fi
if [ "$push" -eq 0 ]; then
  echo
  echo "promote: dry run, no ref changed; add --push and --visibility to write public, tag and push"
  exit 0
fi

if [ "$yes" -eq 0 ]; then
  if ! ( : </dev/tty ) 2>/dev/null; then
    echo "promote: no terminal for the question; pass --yes after you confirmed the plan" >&2
    exit 1
  fi
  printf 'Continue? [y/N] ' >/dev/tty
  read -r answer </dev/tty || answer=
  case $answer in
    y | Y | yes | YES) ;;
    *) fail "the answer was not y" ;;
  esac
fi

step 13 "branch public and tag $tag"
if [ "$resume" -eq 0 ]; then
  git update-ref -m "promote: portable $version" refs/heads/public "$new_sha" "${previous:-$zero}" || fail "public moved during the run; nothing was tagged or pushed"
  if ! GIT_COMMITTER_DATE=$release_date git tag -a --no-sign -m "portable $version" "$tag" "$new_sha"; then
    echo "promote: public is $new_sha, and the tag failed; nothing was pushed" >&2
    echo "promote: to undo, run: git update-ref refs/heads/public ${previous:-$zero} $new_sha" >&2
    exit 1
  fi
fi
tag_sha=$(git rev-parse "refs/tags/$tag")
[ "$(git cat-file -t "$tag_sha")" = tag ] || fail "$tag is not an annotated tag"
git cat-file tag "$tag_sha" > "$tmp/tag"
tagger=$(awk '/^$/ { exit } /^tagger / { print substr($0, 8) }' "$tmp/tag" | sed -e 's/ [0-9]* [-+][0-9]*$//')
[ "$tagger" = "$release_identity" ] || fail "$tag does not carry the release identity; nothing was pushed"
[ "$(git rev-parse "refs/tags/$tag^{commit}")" = "$new_sha" ] || fail "$tag is not on the snapshot commit; nothing was pushed"
check_identities
echo "ok: public is $new_sha, $tag is $tag_sha, tagger $tagger"

step 14 "push to $remote"
git -c push.followTags=false push --dry-run "$remote" "refs/heads/public:$remote_ref" "refs/tags/$tag:refs/tags/$tag" || fail "the dry run of the push failed; the local branch public and the tag stay"
git -c push.followTags=false push "$remote" "refs/heads/public:$remote_ref" "refs/tags/$tag:refs/tags/$tag" || fail "the push failed; the local branch public and the tag stay; run the same command again after the cause is fixed"

step 15 "refs on $remote"
git ls-remote "$remote_url"
git ls-remote --refs "$remote_url" > "$tmp/remote-after" || { echo "promote: cannot read $remote after the push" >&2; exit 3; }
problem=0
if [ "$(awk -v ref="$remote_ref" '$2 == ref { print $1 }' "$tmp/remote-after")" != "$new_sha" ]; then
  echo "promote: $remote_branch on $remote is not $new_sha" >&2
  problem=1
fi
if [ "$(awk -v ref="refs/tags/$tag" '$2 == ref { print $1 }' "$tmp/remote-after")" != "$tag_sha" ]; then
  echo "promote: $tag on $remote is not $tag_sha" >&2
  problem=1
fi
if [ "$remote" = origin ]; then
  echo "not checked: foreign refs, because origin can hold other branches"
else
  awk 'NR == FNR { seen[$2] = 1; next } !($2 in seen) { print $2 }' "$tmp/remote-before" "$tmp/remote-after" > "$tmp/new-refs"
  while IFS= read -r ref; do
    case $ref in
      "$remote_ref" | "refs/tags/$tag" | refs/pull/*) ;;
      *) echo "promote: foreign ref, new after the push: $ref" >&2; problem=1 ;;
    esac
  done < "$tmp/new-refs"
fi
if [ -n "$actual" ]; then
  before=$actual
  check_visibility 2>/dev/null || true
  if [ "$actual" != "$before" ] || [ "$actual" != "$expected" ]; then
    echo "promote: the visibility of $slug after the push is ${actual:-not verified: $reason}, and --visibility is $expected" >&2
    problem=1
  else
    echo "ok: $slug is $actual after the push"
  fi
else
  echo "not verified: visibility after the push, $reason"
fi
if [ "$problem" -eq 1 ]; then
  echo "promote: nothing was deleted; examine the refs of $remote" >&2
  exit 3
fi
echo
echo "promote: done, $remote has $remote_branch $new_sha and $tag"
