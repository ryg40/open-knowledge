#!/bin/sh
set -eu
export LC_ALL=C

default_image=zricethezav/gitleaks:v8.28.0@sha256:cdbb7c955abce02001a9f6c9f602fb195b7fadc1e812065883f695d1eeaba854
image=${GITLEAKS_IMAGE:-$default_image}
if [ "$image" != "$default_image" ]; then
  echo "scan: scanner image override: $image"
fi

usage() {
  echo "usage: $0 [--validate-only | --staged | --history [<log-range>]]" >&2
  echo "  --history without <log-range> scans <base>..HEAD; set the base with: git config ok.historyBase <commit or ref>" >&2
  exit 2
}

repo_root=$(git rev-parse --show-toplevel)
git_dir=$(cd "$(git rev-parse --absolute-git-dir)" && pwd -P)
common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
config=$repo_root/.gitleaks.toml
if [ ! -f "$config" ]; then
  echo "scan: $config is missing" >&2
  exit 2
fi

snapshot=
index_file=
merged=
scan_log=
archive_file=
validation_dir=

cleanup() {
  if [ -n "$snapshot" ]; then
    rm -rf "$snapshot"
  fi
  if [ -n "$merged" ]; then
    rm -f "$merged"
  fi
  if [ -n "$scan_log" ]; then
    rm -f "$scan_log"
  fi
  if [ -n "$archive_file" ]; then
    rm -f "$archive_file"
  fi
  if [ -n "$validation_dir" ]; then
    rm -rf "$validation_dir"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

load_rules() {
  host_rules=$(git config --type=path --get ok.hostRules || true)
  if [ -z "$host_rules" ]; then
    echo "scan: no host rules, because the Git config key ok.hostRules is not set; the scan uses the rules of .gitleaks.toml only"
    return 0
  fi
  if [ "$host_rules" = none ]; then
    echo "scan: ok.hostRules is none; the scan uses tracked rules only"
    return 0
  fi
  case $host_rules in
    /*) ;;
    *)
      echo "scan: host rules missing: ok.hostRules is $host_rules, which is not an absolute path" >&2
      exit 2
      ;;
  esac
  if [ ! -f "$host_rules" ] || [ ! -r "$host_rules" ]; then
    echo "scan: host rules missing: ok.hostRules names $host_rules, which is not a readable file" >&2
    exit 2
  fi
  encoding_line=$(awk 'index($0, "\r") { print FNR; exit }' "$host_rules")
  if [ -n "$encoding_line" ]; then
    echo "scan: host file line $encoding_line: CRLF; use LF line endings" >&2
    exit 2
  fi
  if [ "$(od -An -N3 -tx1 "$host_rules" | tr -d ' \n')" = efbbbf ]; then
    echo "scan: host file line 1: BOM; use UTF-8 without a BOM" >&2
    exit 2
  fi
  count=$(awk -v quote="'" '
    function refuse(cause, error_line) {
      if (!bad) {
        if (id != "") printf "scan: host rule %s: %s\n", id, cause > "/dev/stderr"
        else printf "scan: host file line %s: %s\n", error_line ? error_line : FNR, cause > "/dev/stderr"
      }
      bad = 1
      exit 2
    }
    function finish() {
      if (inside && !has_id) refuse("missing id", rule_line)
      if (inside && !has_match) refuse("missing regex or path", rule_line)
    }
    FNR == NR {
      if ($0 ~ /^id[[:space:]]*=/) {
        line = $0
        sub(/^[^=]*=[[:space:]]*/, "", line)
        gsub(/["\047]/, "", line)
        tracked[line] = 1
      }
      next
    }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      if (line == "" || line ~ /^#/) next
      if (line == "[[rules]]") {
        finish(); rule_line = FNR; inside = 1; allow = 0; has_id = 0; has_match = 0; id = ""; table++; count++; next
      }
      if (line == "[[rules.allowlists]]" && inside) { allow = 1; table++; next }
      if (!inside) refuse("the first table must be [[rules]]")
      if (line ~ /^\[/) refuse("unsupported table")
      if (line !~ /^[A-Za-z][A-Za-z0-9]*[[:space:]]*=/) refuse("expected a key and single-line value")
      key = line
      sub(/[[:space:]]*=.*/, "", key)
      if (keys[table, key]++) refuse("repeated key " key)
      val = line
      sub(/^[^=]*=[[:space:]]*/, "", val)
      if (allow) {
        if (key !~ /^(description|condition|commits|paths|regexes|regexTarget|stopwords)$/) refuse("unsupported allowlist key " key)
      } else {
        if (key !~ /^(id|description|regex|path|secretGroup|entropy|keywords)$/) refuse("unsupported rule key " key)
        if (key == "id") {
          if (val !~ /^"[A-Za-z0-9_-]+"$/ && val !~ ("^" quote "[A-Za-z0-9_-]+" quote "$")) refuse("id needs a quoted name using letters, digits, underscores or hyphens")
          gsub(/["\047]/, "", val)
          id = val
          if (id == "host-") refuse("has no name after host-")
          if (id !~ /^host-/) refuse("id must start with host-")
          if (tracked[id]) refuse("id is already in the tracked configuration")
          if (seen[id]++) refuse("duplicate id")
          has_id = 1
        }
        if (key == "regex" || key == "path") has_match = 1
      }
      if (val ~ /^"/ && val !~ /"$/) refuse("unterminated string for " key)
      if (substr(val, 1, 1) == quote && substr(val, length(val)) != quote) refuse("unterminated string for " key)
      if (val ~ /^\[/ && val !~ /\]$/) refuse("unterminated array for " key)
      if (val ~ /^"""/ && val !~ /^""".*"""$/) refuse("unterminated string for " key)
      if (substr(val, 1, 3) == quote quote quote && substr(val, length(val)-2) != quote quote quote) refuse("unterminated string for " key)
    }
    END {
      if (bad) exit 2
      if (!count) { print "scan: host file has no [[rules]] table" > "/dev/stderr"; exit 2 }
      finish(); print count
    }
  ' "$config" "$host_rules") || exit 2
  merged=$(mktemp "${TMPDIR:-/tmp}/ok-scan-rules.XXXXXX")
  {
    cat "$config"
    echo
    cat "$host_rules"
  } > "$merged"
  config=$merged
  echo "scan: $count host rules of ok.hostRules"
}

validate_config_file() {
  validation_status=0
  docker run --rm --network none --tmpfs /work --workdir /work \
    --volume "$1:/config/gitleaks.toml:ro" \
    "$image" dir --no-banner --no-color --redact --config /config/gitleaks.toml . > "$validation_dir/output" 2>&1 || validation_status=$?
  [ "$validation_status" -eq 0 ] && grep -aq 'no leaks found' "$validation_dir/output" && ! grep -aEq '(^|[[:space:]])ERR([[:space:]]|$)' "$validation_dir/output"
}

validate_config() {
  validation_dir=$(mktemp -d "${TMPDIR:-/tmp}/ok-scan-validation.XXXXXX")
  if validate_config_file "$config"; then return 0; fi
  if [ -n "$merged" ]; then
    if ! validate_config_file "$repo_root/.gitleaks.toml"; then
      echo "scan: scanner error: the scanner cannot validate the tracked configuration" >&2
      exit 2
    fi
    rule_total=$count
    rule_number=1
    while [ "$rule_number" -le "$rule_total" ]; do
      awk -v wanted="$rule_number" '
        /^[[:space:]]*\[\[rules\]\][[:space:]]*$/ { number++ }
        number == wanted { print }
      ' "$host_rules" > "$validation_dir/rule"
      validation_id=$(awk '/^[[:space:]]*id[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit }' "$validation_dir/rule")
      { cat "$repo_root/.gitleaks.toml"; echo; cat "$validation_dir/rule"; } > "$validation_dir/config"
      if ! validate_config_file "$validation_dir/config"; then
        echo "scan: host rule $validation_id: the scanner cannot compile its regex or path" >&2
        exit 2
      fi
      rule_number=$((rule_number + 1))
    done
  fi
  echo "scan: scanner error: the scanner cannot validate the merged configuration" >&2
  exit 2
}

run_gitleaks() {
  if [ -n "$snapshot" ]; then
    work=--volume=$snapshot:/work:ro
  else
    work=--tmpfs=/work
  fi
  scan_log=$(mktemp "${TMPDIR:-/tmp}/ok-scan-log.XXXXXX")
  scanner_status=0
  docker run --rm --network none \
    --volume "$common_dir:$common_dir:ro" \
    --volume "$config:/config/gitleaks.toml:ro" \
    "$work" \
    ${index_file:+"--volume=$index_file:$index_file:ro"} \
    ${index_file:+"--env=GIT_INDEX_FILE=$index_file"} \
    --workdir /work \
    --env "GIT_DIR=$git_dir" \
    --env GIT_WORK_TREE=/work \
    --env GIT_CONFIG_COUNT=1 \
    --env GIT_CONFIG_KEY_0=safe.directory \
    --env "GIT_CONFIG_VALUE_0=*" \
    "$image" "$@" --no-banner --no-color --redact --verbose --config /config/gitleaks.toml . > "$scan_log" 2>&1 || scanner_status=$?
  if ! cat "$scan_log"; then
    echo "scan: scanner error: scanner output cannot be read" >&2
    return 2
  fi
  if ! grep -Eq '(^|[[:space:]])(no leaks found|leaks found: [0-9]+)([[:space:]]|$)' "$scan_log"; then
    echo "scan: scanner error: no gitleaks summary (exit $scanner_status)" >&2
    scanner_status=2
  elif grep -aEq '(^|[[:space:]])ERR([[:space:]]|$)' "$scan_log"; then
    echo "scan: scanner error: gitleaks reported an error" >&2
    scanner_status=2
  elif [ "$scanner_status" -eq 0 ] && grep -Eq 'leaks found: [1-9][0-9]*' "$scan_log"; then
    scanner_status=1
  fi
  rm -f "$scan_log"
  scan_log=
  return "$scanner_status"
}

scan_staged() {
  if [ -n "${GIT_INDEX_FILE-}" ]; then
    if [ ! -f "$GIT_INDEX_FILE" ]; then
      echo "scan: GIT_INDEX_FILE names $GIT_INDEX_FILE, which is not a file" >&2
      exit 2
    fi
    index_file=$(cd "$(dirname "$GIT_INDEX_FILE")" && pwd -P)/$(basename "$GIT_INDEX_FILE")
    echo "scan: staged changes in $index_file"
  else
    echo "scan: staged changes"
  fi
  run_gitleaks git --platform none --staged
}

scan_head() {
  echo "scan: tree at HEAD"
  snapshot=$(mktemp -d "${TMPDIR:-/tmp}/ok-scan.XXXXXX")
  archive_file=$(mktemp "${TMPDIR:-/tmp}/ok-scan-archive.XXXXXX")
  if ! git -C "$repo_root" archive --format=tar --output="$archive_file" HEAD; then
    echo "scan: scanner error: git archive failed; no tree scan ran" >&2
    return 2
  fi
  if ! tar -xf "$archive_file" -C "$snapshot"; then
    echo "scan: scanner error: archive extraction failed; no tree scan ran" >&2
    return 2
  fi
  rm -f "$archive_file"
  archive_file=
  status_head=0
  run_gitleaks dir || status_head=$?
  rm -rf "$snapshot"
  snapshot=
  return "$status_head"
}

check_base() {
  configured_base=$(git config --get ok.historyBase || true)
  [ -n "$configured_base" ] || return 0
  configured_base=$(git rev-parse --verify --quiet "$configured_base^{commit}") || {
    echo "scan: ok.historyBase does not name a commit" >&2; exit 2;
  }
  upstream_tips=$(git for-each-ref --format='%(objectname)' refs/remotes/upstream/) || exit 2
  valid_base=0
  for upstream_tip in $upstream_tips; do
    if git merge-base --is-ancestor "$configured_base" "$upstream_tip"; then valid_base=1; break; fi
  done
  if [ "$valid_base" -eq 0 ]; then
    if [ -z "$upstream_tips" ]; then
      echo "scan: no ref under refs/remotes/upstream/: run scripts/tenant/setup-remotes.sh, then git fetch upstream" >&2
    else
      echo "scan: ok.historyBase is not in upstream history; choose an upstream ancestor, or unset the key to scan the whole range" >&2
    fi
    exit 2
  fi
}

check_range() {
  set -f
  tips=
  excluded=0
  check_base
  for word in $1; do
    case $word in
      --not) excluded=1; continue ;;
      ^*) ends=${word#^} ;;
      *...*) echo "scan: symmetric ranges are not supported" >&2; exit 2 ;;
      *..*)
        start=${word%%..*}
        tip=${word#*..}
        start=${start:-HEAD}
        tip=${tip:-HEAD}
        git merge-base --is-ancestor "$start" "$tip" || {
          echo "scan: range start $start is not an ancestor of range tip $tip" >&2; exit 2;
        }
        ends="$start $tip"
        tips="$tips $tip"
        ;;
      -*) echo "scan: unsupported history option $word" >&2; exit 2 ;;
      *) ends=$word; if [ "$excluded" -eq 0 ]; then tips="$tips $word"; fi ;;
    esac
    for end in $ends; do
      if ! git rev-parse --verify --quiet "$end^{commit}" >/dev/null; then
        echo "scan: range $1 does not resolve: $end" >&2
        exit 2
      fi
    done
  done
  [ -n "$tips" ] || { echo "scan: history range has no commit to scan" >&2; exit 2; }
  if [ -n "$configured_base" ]; then
    for tip in $tips; do
      git merge-base --is-ancestor "$configured_base" "$tip" || {
        echo "scan: ok.historyBase is not an ancestor of $tip" >&2; exit 2;
      }
    done
  fi
  set +f
}

scan_history() {
  check_range "$1"
  echo "scan: history $1"
  run_gitleaks git --platform none --log-opts "$1"
}

mode=tree
range=
while [ "$#" -gt 0 ]; do
  case $1 in
    --validate-only) [ "$mode" = tree ] || usage; mode=validate; shift ;;
    --staged) [ "$mode" = tree ] || usage; mode=staged; shift ;;
    --history)
      [ "$mode" = tree ] || usage
      mode=history
      shift
      if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then range=$1; shift; fi
      ;;
    *) usage ;;
  esac
done
if [ "$mode" = history ] && [ -z "$range" ]; then
  base=$(git config --get ok.historyBase || true)
  if [ -z "$base" ]; then
    echo "scan: --history needs a range, or a history base in the Git config key ok.historyBase" >&2
    usage
  fi
  range="$base..HEAD"
fi
load_rules
validate_config
case $mode in
  validate) exit 0 ;;
  staged) scan_staged ;;
  history) scan_history "$range" ;;
  tree)
    status=0
    scan_head || status=$?
    staged_status=0
    scan_staged || staged_status=$?
    if [ "$staged_status" -gt "$status" ]; then status=$staged_status; fi
    exit "$status"
    ;;
esac
