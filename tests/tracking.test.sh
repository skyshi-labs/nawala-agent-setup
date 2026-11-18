# shellcheck shell=bash
# hook.sh sends only for work repos: GET /v1/tracking prefixes, the tracking cache, nawala.off,
# repos without a remote, old servers (404), failures (fail closed), remote normalisation.

tr_home() { # fresh HOME with a ~/.nawala/config
  new_home
  mkdir -p "$HOME/.nawala"
  printf 'NAWALA_URL=%s\nNAWALA_TOKEN=%s\n' "$URL" "$TOKEN" >"$HOME/.nawala/config"
}
tr_event() { # mode dir [agent]  one hook run (synchronous) for a Claude-style payload; stdout in $OUT
  local n="$RANDOM$RANDOM"
  OUT="$(printf '{"session_id":"s-%s","cwd":"%s","prompt":"hello","prompt_id":"p-%s"}' "$n" "$2" "$n" \
    | NAWALA_HOOK_SYNC=1 bash "$HOOK" "$1" --agent "${3:-claude}" 2>&1)"
  printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
}
sent() { grep -c . "$FAKE_CURL_BODIES" || true; }       # events posted so far
calls() { grep -c -e "$1" "$FAKE_CURL_LOG" || true; }   # requests to a path so far
nawala_tree() { (cd "$HOME/.nawala" && find . -print | LC_ALL=C sort | grep -v '^\./tracking\.json$'); }
hook_fn() { # load one function from hook.sh (two steps: bash 3.2 mis-parses it nested in "$(...)")
  local src
  src="$(sed -n "/^$1() {/,/^}/p" "$HOOK")"
  [ -n "$src" ] || fail "function $1 not found in hook.sh"
  eval "$src"
}

test_normalize_remote_matches_the_server() {
  # every normalizeRemote case of the server's test/normalize.test.ts, then extra edge cases
  # (expected values produced by the server's TypeScript); <null> = no key, <empty> = ""
  local input expected got n=0
  hook_fn normalize_remote
  while IFS="	" read -r input expected; do
    case "$input" in "#"*|"") continue ;; esac
    [ "$input" = "<empty>" ] && input=""
    [ "$input" = "<blank>" ] && input="   "
    got="$(normalize_remote "$input")" || got="<null>"
    assert_eq "$got" "$expected" "normalize_remote [$input]"
    n=$((n + 1))
  done <<'EOF'
# server test/normalize.test.ts
git@gitlab.com:Org/Repo.git	gitlab.com/org/repo
https://user@gitlab.com/org/repo	gitlab.com/org/repo
ssh://git@gitlab.com:22/org/repo.git	gitlab.com/org/repo
https://gitlab.com/org/repo.git/	gitlab.com/org/repo
https://user:secret@github.com/Org/Repo.git	github.com/org/repo
http://gitlab.example.com:8080/group/sub/repo.git	gitlab.example.com/group/sub/repo
git@github.com:a/b	github.com/a/b
ssh://git@gitlab.com/org/repo	gitlab.com/org/repo
git+ssh://git@github.com/org/repo.git	github.com/org/repo
https://www.github.com/org/repo	github.com/org/repo
gitlab.com/org/repo	gitlab.com/org/repo
git@gitlab.com:Org/Sub/Repo.git	gitlab.com/org/sub/repo
https://gitlab.com/org/repo	gitlab.com/org/repo
<empty>	<null>
<blank>	<null>
not a remote	<null>
/local/path/repo	<null>
# extra edge cases
  git@gitlab.skyshi.io:Plexa/api.git  	gitlab.skyshi.io/plexa/api
ssh://host:org/repo	host/org/repo
ssh://git@host:org/repo.git	host/org/repo
git@host:22/org/repo	host/org/repo
HTTPS://GitHub.com/Org/Repo?x=1#frag	github.com/org/repo
https://gitlab.com/org/repo.git?ref=1	gitlab.com/org/repo
https://gitlab.com	<null>
https://gitlab.com/	<null>
file:///local/repo	<null>
https://gitlab.com//org///repo.GIT/	gitlab.com/org/repo
https://gitlab.com/org/repo/.git	gitlab.com/org/repo
https://a@b@host.com/x/y	host.com/x/y
a:b@c:d/e	c/d/e
user@host:path	host/path
u/x@host:path	<null>
host:path	host/path
git@:path	git@/path
www.gitlab.com/Org/Repo.git	gitlab.com/org/repo
repo.git	<null>
.com/org/repo	<null>
a.b/	<null>
a.b/c	a.b/c
git@GitHub.COM:Org/Repo.Git	github.com/org/repo
EOF
  [ "$n" -ge 40 ] || fail "only $n cases checked"
}

test_prefix_match_rule_is_the_servers() {
  local key want got
  hook_fn key_in_tracking_list
  printf '{"version":1,"prefixes":["GitLab.com/Acme/","github.com/acme/shop-api","",42]}' >"$TEST_TMP/list.json"
  while read -r key want; do
    if key_in_tracking_list "$key" "$TEST_TMP/list.json"; then got=yes; else got=no; fi
    assert_eq "$got" "$want" "match [$key]"
  done <<'EOF'
gitlab.com/acme yes
gitlab.com/acme/app yes
gitlab.com/acme/group/app yes
gitlab.com/acmecorp/app no
gitlab.com/acme-tools/app no
github.com/acme/shop-api yes
github.com/acme/shop-api/sub yes
github.com/acme/shop-api-v2 no
github.com/acme no
github.com/other/x no
EOF
}

test_work_repo_sends_events_and_gets_rules() {
  tr_home
  new_repo "$HOME/work" "https://dev@GitLab.com/Acme/App.git"
  export FAKE_RULES_CODE=200 FAKE_RULES_BODY='{"projectId":"0b6f2c1e-1111-4222-8333-444455556666","markdown":"# Rules"}'
  tr_event start "$HOME/work"
  assert_eq "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)" "# Rules"
  tr_event prompt "$HOME/work"
  assert_eq "$(sent)" "2" "events posted for a work repo"
  assert_eq "$(jq -r .git.remote "$FAKE_CURL_BODIES" | sort -u)" "https://dev@GitLab.com/Acme/App.git"
  assert_eq "$(ls -l "$HOME/.nawala/tracking.json" | cut -c1-10)" "-rw-------" "tracking cache mode"
}

test_personal_repo_sends_nothing_and_writes_only_the_cache() {
  local before
  tr_home
  new_repo "$HOME/mine" "$PERSONAL_REMOTE"
  mkdir -p "$HOME/mine/sub"
  export FAKE_RULES_CODE=200 FAKE_RULES_BODY='{"projectId":"0b6f2c1e-1111-4222-8333-444455556666","markdown":"# Rules"}'
  before="$(nawala_tree)"
  tr_event start "$HOME/mine"
  assert_eq "$OUT" "" "rules context for a personal repo"
  tr_event prompt "$HOME/mine/sub"
  tr_event stop "$HOME/mine"
  tr_event end "$HOME/mine" codex
  assert_eq "$(sent)" "0" "events posted for a personal repo"
  assert_eq "$(calls /v1/rules)" "0" "rules requested for a personal repo"
  assert_eq "$(calls /v1/events)" "0" "events requested for a personal repo"
  assert_not_contains "$(cat "$FAKE_CURL_LOG")" "dotfiles" "personal remote sent to the server"
  assert_same_tree "$before" "$(nawala_tree)" "hook wrote state for a personal repo"
  [ -f "$HOME/.nawala/tracking.json" ] || fail "tracking list not cached"
  ls "${TMPDIR:-/tmp}"/nawala.auth.* >/dev/null 2>&1 && fail "auth temp file left behind"
  return 0
}

test_repo_opt_out_with_git_config_sends_nothing() {
  tr_home
  new_repo "$HOME/work"
  git -C "$HOME/work" config nawala.off true
  tr_event start "$HOME/work"
  tr_event prompt "$HOME/work"
  assert_eq "$(sent)" "0" "events posted despite nawala.off"
  [ ! -s "$FAKE_CURL_LOG" ] || fail "network used despite nawala.off: $(cat "$FAKE_CURL_LOG")"
  git -C "$HOME/work" config nawala.off false
  tr_event prompt "$HOME/work"
  assert_eq "$(sent)" "1" "nawala.off=false still blocks"
}

test_no_remote_or_no_repo_sends_nothing() {
  tr_home
  new_repo "$HOME/local" ""
  mkdir -p "$HOME/plain"
  tr_event start "$HOME/local"
  tr_event prompt "$HOME/local"
  tr_event prompt "$HOME/plain"
  assert_eq "$(sent)" "0" "events posted without a remote"
  # since v0.1.3 a folder without a remote may still be inside a linked folder (`paths`), so the
  # tracking list (which carries no repo information) is fetched; nothing else is requested
  assert_eq "$(calls /v1/events)" "0" "events requested without a remote"
  assert_eq "$(calls /v1/rules)" "0" "rules requested without a remote"
  ! grep -q -v '/v1/tracking' "$FAKE_CURL_LOG" || fail "network used without a remote: $(cat "$FAKE_CURL_LOG")"
  assert_eq "$(nawala_tree)" "$(printf '.\n./config')" "state written without a remote"
}

test_old_server_404_sends_as_before() {
  tr_home
  new_repo "$HOME/mine" "$PERSONAL_REMOTE"
  export FAKE_TRACKING_CODE=404
  tr_event prompt "$HOME/mine"
  assert_eq "$(sent)" "1" "404 should behave like before (send)"
  [ ! -e "$HOME/.nawala/tracking.json" ] || fail "404 cached as a list"
}

test_failure_uses_cached_list_of_any_age() {
  local cached
  tr_home
  new_repo "$HOME/work"; new_repo "$HOME/mine" "$PERSONAL_REMOTE"
  tr_event prompt "$HOME/work"
  cached="$(cat "$HOME/.nawala/tracking.json")"
  touch -t 202001010000 "$HOME/.nawala/tracking.json" # years old
  for code in 000 500 401; do
    : >"$FAKE_CURL_BODIES"
    FAKE_TRACKING_CODE=$code tr_event prompt "$HOME/work"
    FAKE_TRACKING_CODE=$code tr_event prompt "$HOME/mine"
    assert_eq "$(sent)" "1" "work repo with stale cache and $code"
  done
  : >"$FAKE_CURL_BODIES"
  FAKE_TRACKING_BODY='not json' tr_event prompt "$HOME/work"
  assert_eq "$(sent)" "1" "work repo with stale cache and a bad body"
  assert_eq "$(cat "$HOME/.nawala/tracking.json")" "$cached" "cache overwritten by a failed refresh"
  [ -z "$(find "$HOME/.nawala" -name 'tracking.json.*')" ] || fail "temp files left behind"
}

test_failure_without_cache_sends_nothing() {
  local code
  tr_home
  new_repo "$HOME/work"
  export FAKE_RULES_CODE=200 FAKE_RULES_BODY='{"projectId":"0b6f2c1e-1111-4222-8333-444455556666","markdown":"# Rules"}'
  for code in 000 500 401 403; do
    FAKE_TRACKING_CODE=$code tr_event prompt "$HOME/work"
    FAKE_TRACKING_CODE=$code tr_event start "$HOME/work"
    assert_eq "$OUT" "" "rules printed with no tracking list ($code)"
  done
  FAKE_TRACKING_BODY='{"version":1}' tr_event prompt "$HOME/work"
  FAKE_TRACKING_BODY='<html>' tr_event prompt "$HOME/work"
  assert_eq "$(sent)" "0" "events posted with no tracking list"
  assert_eq "$(calls /v1/rules)" "0" "rules requested with no tracking list"
  [ ! -e "$HOME/.nawala/tracking.json" ] || fail "bad answer cached"
  [ -z "$(find "$HOME/.nawala" -name 'tracking.json.*')" ] || fail "temp files left behind"
}

test_tracking_list_is_cached_for_15_minutes() {
  tr_home
  new_repo "$HOME/work"
  tr_event prompt "$HOME/work"
  tr_event prompt "$HOME/work"
  tr_event stop "$HOME/work"
  assert_eq "$(calls /v1/tracking)" "1" "tracking list fetched more than once within 15 min"
  assert_eq "$(sent)" "3"
  # older than 15 minutes: refreshed, and the new list applies (acme no longer a work prefix)
  touch -t 202001010000 "$HOME/.nawala/tracking.json"
  FAKE_TRACKING_BODY='{"version":1,"prefixes":["gitlab.com/other"]}' tr_event prompt "$HOME/work"
  assert_eq "$(calls /v1/tracking)" "2" "stale list not refreshed"
  assert_eq "$(sent)" "3" "event sent after the repo left the list"
  assert_eq "$(jq -c .prefixes "$HOME/.nawala/tracking.json")" '["gitlab.com/other"]'
}

test_tracking_request_carries_no_repo_and_no_token_on_argv() {
  tr_home
  new_repo "$HOME/work"
  tr_event prompt "$HOME/work"
  assert_eq "$(grep '/v1/tracking' "$FAKE_CURL_LOG" | grep -c -e 'acme' -e 'remote' -e '/work' || true)" "0" "repo info in the tracking request"
  grep -q "$TOKEN" "$FAKE_CURL_LOG" && fail "token on curl argv"
  grep -q "HEADERFILE Authorization: Bearer $TOKEN" "$FAKE_CURL_HEADERS" || fail "token not sent in a header file"
  return 0
}

test_kill_switch_beats_tracking() {
  tr_home
  new_repo "$HOME/work"
  OUT="$(printf '{"session_id":"s","cwd":"%s","prompt":"x"}' "$HOME/work" | NAWALA_OFF=1 NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent claude)"
  assert_eq "$OUT" ""
  [ ! -s "$FAKE_CURL_LOG" ] || fail "NAWALA_OFF=1 still called the network"
  [ ! -e "$HOME/.nawala/tracking.json" ] || fail "NAWALA_OFF=1 still wrote the cache"
}

test_repo_inside_a_linked_parent_folder_is_sent_and_rules_get_the_folder() {
  tr_home
  new_repo "$HOME/clients/acme/new-svc" "https://gitlab.com/someone-else/new-svc.git"
  new_repo "$HOME/clients/acmex/other" "https://gitlab.com/someone-else/other.git"
  export FAKE_TRACKING_BODY="{\"version\":1,\"prefixes\":[\"gitlab.com/acme\"],\"paths\":[\"$HOME/Clients/Acme/\"]}"
  export FAKE_RULES_CODE=200 FAKE_RULES_BODY='{"projectId":"0b6f2c1e-1111-4222-8333-444455556666","markdown":"# Rules"}'
  tr_event start "$HOME/clients/acme/new-svc"
  assert_eq "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)" "# Rules"
  assert_contains "$(cat "$FAKE_CURL_LOG")" "cwd=" "rules request carries the folder"
  tr_event prompt "$HOME/clients/acme/new-svc"
  assert_eq "$(sent)" "2" "events posted for a repo inside a linked parent folder"
  tr_event prompt "$HOME/clients/acmex/other"
  assert_eq "$(sent)" "2" "a sibling folder with the same name prefix is not inside the linked folder"
}
