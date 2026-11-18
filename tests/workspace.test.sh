# shellcheck shell=bash
# hook.sh v0.1.3, multi-repo workspaces: the start folder is not a git repo and the repos are
# opened as additional working directories. Claude's PostToolUse (`touch`) records which tracked
# repo the agent edits; events describe that repo, and stop sends the commits of every edited repo.

ws_home() { # fresh HOME (physical path: git prints /private/var for /var on macOS) + ~/.nawala/config
  new_home
  HOME="$(cd "$HOME" && pwd -P)"; export HOME
  mkdir -p "$HOME/.nawala"
  printf 'NAWALA_URL=%s\nNAWALA_TOKEN=%s\n' "$URL" "$TOKEN" >"$HOME/.nawala/config"
}
ws_repo() { # dir [remote] : a tracked repo (default remote) with a local author identity
  new_repo "$1" "${2-$WORK_REMOTE}"
  git -C "$1" config user.email dev@example.com
  git -C "$1" config user.name Dev
}
ws_commit() { # dir file : one commit touching file (message is a marker that must never be sent)
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$RANDOM" >>"$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "WS-COMMIT-MESSAGE-MARKER $2"
}
ws_event() { # mode sid cwd [turn] : one synchronous Claude hook run; stdout in $OUT
  OUT="$(jq -nc --arg s "$2" --arg c "$3" --arg t "${4:-t-$RANDOM$RANDOM}" \
      '{session_id: $s, cwd: $c, prompt: "hello", prompt_id: $t}' \
    | NAWALA_HOOK_SYNC=1 bash "$HOOK" "$1" --agent claude 2>&1)"
  printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
}
ws_touch() { # sid cwd file_path : Claude PostToolUse (Edit); stdout in $OUT
  OUT="$(jq -c --arg s "$1" --arg c "$2" --arg f "$3" \
      '.session_id = $s | .cwd = $c | .tool_input.file_path = $f' "$FIX/hooks/claude-posttooluse.json" \
    | NAWALA_HOOK_SYNC=1 bash "$HOOK" touch --agent claude 2>&1)"
  printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
}
ws_sent() { grep -c . "$FAKE_CURL_BODIES" || true; }
ws_calls() { grep -c -e "$1" "$FAKE_CURL_LOG" || true; }
ws_last() { tail -n 1 "$FAKE_CURL_BODIES" | jq -r "$1"; }
ws_tree() { (cd "$HOME/.nawala" && find . -print | LC_ALL=C sort | grep -v -E '^\./(tracking\.json|state|state/last-run-[a-z]+)$'); }  # last-run-<agent>: local diagnostics, see test_last_run_marker_holds_no_content
ws_sha16() { printf '%s' "$1" | tr 'A-Z' 'a-z' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -c1-16; }

test_non_git_folder_inside_linked_paths_sends_with_git_null() {
  ws_home
  mkdir -p "$HOME/ws/notes"
  ws_repo "$HOME/ws/local" ""
  export FAKE_TRACKING_BODY="{\"version\":1,\"prefixes\":[],\"paths\":[\"$HOME/WS\"]}"
  export FAKE_RULES_CODE=200 FAKE_RULES_BODY='{"projectId":"0b6f2c1e-1111-4222-8333-444455556666","markdown":"# WS rules"}'
  ws_event start s1 "$HOME/ws"
  assert_eq "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)" "# WS rules" "rules for a linked non-git folder"
  assert_contains "$(grep /v1/rules "$FAKE_CURL_LOG")" "cwd=$HOME/ws"
  assert_not_contains "$(grep /v1/rules "$FAKE_CURL_LOG")" "remote=" "empty remote sent to /v1/rules"
  ws_event prompt s1 "$HOME/ws/notes"
  assert_eq "$(ws_sent)" "2" "events for a non-git folder inside a linked folder"
  assert_eq "$(ws_last '[.cwd, (.git | [.remote, .branch, .head, .root] | map(. == null) | all)] | @tsv')" "$HOME/ws/notes	true"
  # a git repo without a remote inside the linked folder: sent too, git root known, remote null
  ws_event prompt s1 "$HOME/ws/local"
  assert_eq "$(ws_sent)" "3"
  assert_eq "$(ws_last '[.git.remote == null, .git.root] | @tsv')" "true	$HOME/ws/local"
}

test_non_git_folder_with_old_server_or_no_link_sends_nothing() {
  local before
  ws_home
  mkdir -p "$HOME/plain"
  export FAKE_RULES_CODE=200 FAKE_RULES_BODY='{"projectId":"0b6f2c1e-1111-4222-8333-444455556666","markdown":"# Rules"}'
  before="$(ws_tree)"
  # old server (404): a folder without a remote never sends, even though `paths` cannot be known
  export FAKE_TRACKING_CODE=404
  ws_event start s1 "$HOME/plain"; assert_eq "$OUT" "" "rules printed for a non-git folder (404)"
  ws_event prompt s1 "$HOME/plain"
  ws_event stop s1 "$HOME/plain"
  # list without a matching path
  unset FAKE_TRACKING_CODE
  export FAKE_TRACKING_BODY="{\"version\":1,\"prefixes\":[\"gitlab.com/acme\"],\"paths\":[\"$HOME/other\"]}"
  ws_event start s2 "$HOME/plain"; assert_eq "$OUT" "" "rules printed for an unlinked non-git folder"
  ws_event prompt s2 "$HOME/plain"
  assert_eq "$(ws_sent)" "0" "events posted for a non-git folder"
  assert_eq "$(ws_calls /v1/rules)" "0" "rules requested for a non-git folder"
  assert_same_tree "$before" "$(ws_tree)" "state written for a non-git folder"
}

test_touch_records_only_tracked_roots_and_prints_nothing() {
  local before root
  ws_home
  mkdir -p "$HOME/ws"
  ws_repo "$HOME/ws/work"
  ws_repo "$HOME/ws/mine" "$PERSONAL_REMOTE"
  ws_repo "$HOME/ws/off"; git -C "$HOME/ws/off" config nawala.off true
  root="$(git -C "$HOME/ws/work" rev-parse --show-toplevel)"
  before="$(ws_tree)"
  ws_touch s1 "$HOME/ws" "$HOME/ws/mine/src/a.js"; assert_eq "$OUT" "" "stdout (untracked)"
  ws_touch s1 "$HOME/ws" "$HOME/ws/off/a.js"; assert_eq "$OUT" "" "stdout (nawala.off)"
  ws_touch s1 "$HOME/ws" "$HOME/ws/notes.md"; assert_eq "$OUT" "" "stdout (no repo)"
  ws_touch s1 "$HOME/ws" ""
  assert_same_tree "$before" "$(ws_tree)" "touch wrote state for an untracked / opted-out / non-git path"
  ws_touch s1 "$HOME/ws" "$HOME/ws/work/src/deep/new-dir/new.js" # folder does not exist yet: walks up
  assert_eq "$OUT" "" "stdout (tracked)"
  ws_touch s1 "$HOME/ws" "$HOME/ws/work/README.md"
  assert_eq "$(cat "$HOME/.nawala/state/s1.repos")" "$root" "tracked root recorded once"
  assert_eq "$(ls -l "$HOME/.nawala/state/s1.repos" | cut -c1-10)" "-rw-------" "repos file mode"
  assert_eq "$(ws_calls /v1/events)" "0" "touch sent an event"
  assert_eq "$(ws_calls /v1/rules)" "0" "touch requested rules"
  # --print-event: nothing printed, nothing written
  OUT="$(jq -c --arg f "$HOME/ws/work/b.js" '.session_id = "s9" | .tool_input.file_path = $f' "$FIX/hooks/claude-posttooluse.json" \
    | bash "$HOOK" touch --agent claude --print-event 2>&1)"
  assert_eq "$OUT" "" "touch --print-event output"
  [ ! -e "$HOME/.nawala/state/s9.repos" ] || fail "touch --print-event wrote state"
  # every edit runs touch in the foreground: a cached list of any age is used, no refresh
  touch -t 202001010000 "$HOME/.nawala/tracking.json"
  : >"$FAKE_CURL_LOG"
  FAKE_TRACKING_CODE=000 ws_touch s3 "$HOME/ws" "$HOME/ws/work/a.js"
  assert_eq "$(cat "$HOME/.nawala/state/s3.repos")" "$root" "stale cache not used by touch"
  [ ! -s "$FAKE_CURL_LOG" ] || fail "touch refreshed the tracking list: $(cat "$FAKE_CURL_LOG")"
}

test_touch_accepts_windows_style_backslash_paths() {
  local root winpath
  ws_home
  mkdir -p "$HOME/ws"
  ws_repo "$HOME/ws/api"
  root="$(git -C "$HOME/ws/api" rev-parse --show-toplevel)"
  winpath="$HOME/ws/api/src/new/handler.ts"; winpath="${winpath//\//\\}"
  ws_touch s1 "${HOME//\//\\}\\ws" "$winpath"
  assert_eq "$OUT" "" "stdout"
  assert_eq "$(cat "$HOME/.nawala/state/s1.repos" 2>/dev/null)" "$root" "root of a backslash path"
  # a relative path is taken from the session's folder
  ws_touch s2 "$HOME/ws" "api/src/x.ts"
  assert_eq "$(cat "$HOME/.nawala/state/s2.repos" 2>/dev/null)" "$root" "root of a relative path"
}

test_workspace_events_carry_the_last_touched_repo() {
  local a b
  ws_home
  mkdir -p "$HOME/ws"
  ws_repo "$HOME/ws/a"
  ws_repo "$HOME/ws/b" "https://github.com/acme/shop-api.git"
  a="$(git -C "$HOME/ws/a" rev-parse --show-toplevel)"; b="$(git -C "$HOME/ws/b" rev-parse --show-toplevel)"
  ws_event start s1 "$HOME/ws"
  ws_event prompt s1 "$HOME/ws"
  assert_eq "$(ws_sent)" "0" "events before any edit in an unlinked workspace"
  ws_touch s1 "$HOME/ws" "$HOME/ws/a/x.js"
  ws_event prompt s1 "$HOME/ws"
  assert_eq "$(ws_sent)" "1"
  assert_eq "$(ws_last '[.cwd, .git.remote, .git.root] | @tsv')" "$a	$WORK_REMOTE	$a"
  ws_touch s1 "$HOME/ws" "$HOME/ws/b/y.js"
  ws_event stop s1 "$HOME/ws"
  assert_eq "$(ws_sent)" "2"
  assert_eq "$(ws_last '[.type, .cwd, .git.remote, .git.root] | @tsv')" "stop	$b	https://github.com/acme/shop-api.git	$b"
  # b leaves the tracking list: the most recent repo that is still tracked is used
  touch -t 202001010000 "$HOME/.nawala/tracking.json"
  export FAKE_TRACKING_BODY='{"version":1,"prefixes":["gitlab.com/acme"]}'
  ws_event prompt s1 "$HOME/ws"
  assert_eq "$(ws_last .cwd)" "$a" "untracked repo used as the target"
  # another session has touched nothing: dropped
  ws_event prompt s2 "$HOME/ws"
  assert_eq "$(ws_sent)" "3" "event for a session that edited no repo"
  # a tracked start folder wins over touched repos (as before v0.1.3)
  ws_event prompt s1 "$HOME/ws/a/sub-does-not-exist"
  ws_event prompt s1 "$HOME/ws/a"
  assert_eq "$(ws_last .cwd)" "$HOME/ws/a"
}

test_stop_sends_commits_per_touched_repo_once() {
  local a b ha hb
  ws_home
  mkdir -p "$HOME/ws"
  ws_repo "$HOME/ws/a"
  ws_repo "$HOME/ws/b" "https://github.com/acme/shop-api.git"
  ws_commit "$HOME/ws/a" src/a1.txt; ws_commit "$HOME/ws/a" src/a2.txt
  ws_commit "$HOME/ws/b" b1.txt
  a="$(git -C "$HOME/ws/a" rev-parse --show-toplevel)"; b="$(git -C "$HOME/ws/b" rev-parse --show-toplevel)"
  ha="$(git -C "$a" rev-parse HEAD)"; hb="$(git -C "$b" rev-parse HEAD)"
  ws_touch s1 "$HOME/ws" "$HOME/ws/a/src/a1.txt"
  ws_touch s1 "$HOME/ws" "$HOME/ws/b/b1.txt"
  ws_event stop s1 "$HOME/ws" turn-1
  assert_eq "$(ws_sent)" "1"
  # primary = the last edited repo (b); the other edited repo (a) goes to repos[]
  assert_eq "$(ws_last '[.cwd, (.commits | length), .commits[0].sha] | @tsv')" "$b	1	$hb"
  assert_eq "$(ws_last '.repos | length')" "1"
  assert_eq "$(ws_last '.repos[0] | [.cwd, .git.remote, .git.root, .git.head, .git.branch != null, (.commits | length)] | @tsv')" \
    "$a	$WORK_REMOTE	$a	$ha	true	2"
  assert_eq "$(ws_last '[.repos[0].commits[].files[].path] | sort | join(",")')" "src/a1.txt,src/a2.txt"
  assert_not_contains "$(cat "$FAKE_CURL_BODIES")" "WS-COMMIT-MESSAGE-MARKER" "commit message sent"
  # head state per session and repo root
  assert_eq "$(cat "$HOME/.nawala/state/s1.$(ws_sha16 "$a").head")" "$ha" "head state of a"
  assert_eq "$(cat "$HOME/.nawala/state/s1.$(ws_sha16 "$b").head")" "$hb" "head state of b"
  # next turn without new commits: no commits, no repos
  ws_event stop s1 "$HOME/ws" turn-2
  assert_eq "$(ws_sent)" "2" "second stop not sent"
  assert_eq "$(ws_last '[has("commits"), has("repos")] | @tsv')" "false	false" "commits resent"
  # a new commit in a only: one repos entry with exactly that commit
  ws_commit "$HOME/ws/a" src/a3.txt
  ws_event stop s1 "$HOME/ws" turn-3
  assert_eq "$(ws_sent)" "3"
  assert_eq "$(ws_last '[has("commits"), (.repos | length), (.repos[0].commits | length), .repos[0].commits[0].files[0].path] | @tsv')" \
    "false	1	1	src/a3.txt"
  # prompt events never carry repos
  ws_event prompt s1 "$HOME/ws"
  assert_eq "$(ws_last 'has("repos")')" "false"
}

test_start_folder_repo_reads_the_legacy_head_state() {
  local repo head
  ws_home
  ws_repo "$HOME/repo"
  ws_commit "$HOME/repo" a.txt
  head="$(git -C "$HOME/repo" rev-parse HEAD)"
  mkdir -p "$HOME/.nawala/state"
  printf '%s\n' "$head" >"$HOME/.nawala/state/s1.head" # written by hook <= v0.1.2
  ws_event stop s1 "$HOME/repo" turn-1
  assert_eq "$(ws_last 'has("commits")')" "false" "history resent after the upgrade"
  repo="$(git -C "$HOME/repo" rev-parse --show-toplevel)"
  assert_eq "$(cat "$HOME/.nawala/state/s1.$(ws_sha16 "$repo").head")" "$head" "per-root head state"
  ws_commit "$HOME/repo" b.txt
  ws_event stop s1 "$HOME/repo" turn-2
  assert_eq "$(ws_last '[.cwd, (.commits | length), .commits[0].files[0].path] | @tsv')" "$HOME/repo	1	b.txt"
}

test_print_event_shows_the_touched_repo_and_its_commits() {
  local a b
  ws_home
  mkdir -p "$HOME/ws"
  ws_repo "$HOME/ws/a"; ws_commit "$HOME/ws/a" a.txt
  ws_repo "$HOME/ws/b"; ws_commit "$HOME/ws/b" b.txt
  a="$(git -C "$HOME/ws/a" rev-parse --show-toplevel)"; b="$(git -C "$HOME/ws/b" rev-parse --show-toplevel)"
  ws_touch s1 "$HOME/ws" "$HOME/ws/a/a.txt"
  ws_touch s1 "$HOME/ws" "$HOME/ws/b/b.txt"
  : >"$FAKE_CURL_LOG"
  OUT="$(printf '{"session_id":"s1","cwd":"%s"}' "$HOME/ws" | bash "$HOOK" stop --agent claude --print-event 2>&1)"
  printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '[.cwd, (.commits | length), .repos[0].cwd, (.repos[0].commits | length)] | @tsv')" "$b	1	$a	1"
  [ ! -s "$FAKE_CURL_LOG" ] || fail "--print-event used the network"
  [ -z "$(find "$HOME/.nawala/state" -name '*.head')" ] || fail "--print-event wrote head state"
}

# hook v0.1.4: Cursor afterFileEdit (top-level file_path) is a `touch`, so a Cursor workspace whose
# first root is a plain parent folder (not linked, not a repo) still describes the edited repo.
cursor_event() { # mode conv root [extra-jq] : one synchronous Cursor hook run; stdout in $OUT
  OUT="$(jq -nc --arg s "$2" --arg c "$3" \
      "{conversation_id: \$s, generation_id: (\"g-\" + (now | tostring)), hook_event_name: \"x\", workspace_roots: [\$c], prompt: \"hello\", model: \"auto\"} ${4:-}" \
    | NAWALA_HOOK_SYNC=1 bash "$HOOK" "$1" --agent cursor 2>&1)"
  printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
}
test_cursor_after_file_edit_targets_the_edited_repo() {
  local a
  ws_home
  mkdir -p "$HOME/ws"
  ws_repo "$HOME/ws/a"
  a="$(git -C "$HOME/ws/a" rev-parse --show-toplevel)"
  cursor_event start c1 "$HOME/ws"
  cursor_event prompt c1 "$HOME/ws"
  assert_eq "$(ws_sent)" "0" "cursor events before any edit in an unlinked parent folder"
  cursor_event touch c1 "$HOME/ws" "| .file_path = \"$HOME/ws/a/src/x.js\" | .edits = [{old_string: \"SECRET-OLD\", new_string: \"SECRET-NEW\"}]"
  assert_eq "$OUT" "" "afterFileEdit must print nothing"
  assert_eq "$(ws_sent)" "0" "touch must send nothing"
  cursor_event stop c1 "$HOME/ws"
  assert_eq "$(ws_sent)" "1"
  assert_eq "$(ws_last '[.type, .agent, .sessionId, .cwd, .git.remote, .git.root] | @tsv')" "stop	cursor	c1	$a	$WORK_REMOTE	$a"
  assert_not_contains "$(cat "$FAKE_CURL_BODIES" "$HOME"/.nawala/state/* 2>/dev/null)" "SECRET-" "edit contents left the payload"
}

# hook v0.1.4: the OpenCode plugin (templates/opencode/plugin.js) sends {sessionID, directory, model,
# prompt_id | turn_id | tool_input.file_path}; never the prompt text.
oc_event() { # mode sid dir [extra-jq] : what the plugin pipes into hook.sh
  OUT="$(jq -nc --arg s "$2" --arg d "$3" "{sessionID: \$s, directory: \$d, model: \"openrouter/anthropic/claude-haiku-4.5\"} ${4:-}" \
    | NAWALA_HOOK_SYNC=1 bash "$HOOK" "$1" --agent opencode 2>&1)"
  printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
}
test_opencode_plugin_payloads_become_opencode_events() {
  local a
  ws_home
  mkdir -p "$HOME/ws"
  ws_repo "$HOME/ws/a"
  a="$(git -C "$HOME/ws/a" rev-parse --show-toplevel)"
  oc_event start ses_1 "$HOME/ws/a"
  oc_event prompt ses_1 "$HOME/ws/a" '| .prompt_id = "msg_1"'
  oc_event prompt ses_1 "$HOME/ws/a" '| .prompt_id = "msg_1"'   # same message twice: one event
  oc_event stop ses_1 "$HOME/ws/a" '| .turn_id = "evt_1"'
  assert_eq "$OUT" "" "the plugin ignores stdout, hook.sh must print nothing for opencode"
  assert_eq "$(jq -r '.type' "$FAKE_CURL_BODIES" | tr '\n' ' ')" "start prompt stop "
  assert_eq "$(ws_last '[.agent, .sessionId, .model, .cwd, .git.root] | @tsv')" "opencode	ses_1	openrouter/anthropic/claude-haiku-4.5	$a	$a"
  # a workspace started in a plain parent folder: the edited repo (plugin touch) becomes the target
  oc_event prompt ses_2 "$HOME/ws" '| .prompt_id = "msg_2"'
  assert_eq "$(ws_sent)" "3" "opencode prompt in an unlinked parent folder"
  oc_event touch ses_2 "$HOME/ws" "| .tool_input.file_path = \"$HOME/ws/a/b.txt\""
  oc_event stop ses_2 "$HOME/ws" '| .turn_id = "evt_2"'
  assert_eq "$(ws_last '[.type, .sessionId, .git.root] | @tsv')" "stop	ses_2	$a"
}
