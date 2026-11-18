# shellcheck shell=bash
# hook.sh sends activity metadata only: no prompt text, transcript, assistant message, raw hook
# payload or commit message ever reaches a request body, the spool, any file under ~/.nawala or
# --print-event. Old (v0.1.0) spool lines are re-built before they are sent or kept.

PV_KEYS='["agent","clientTs","clientVersion","commits","cwd","dedupeKey","effort","git","hookSource","id","model","repos","sessionId","type"]'
OLD_MARK="OLDSPOOL-MARKER" # in tests/fixtures/spool-v0.1.0.jsonl (written by the v0.1.0 hook)

pv_home() {
  new_home
  mkdir -p "$HOME/.nawala"
  printf 'NAWALA_URL=%s\nNAWALA_TOKEN=%s\n' "$URL" "$TOKEN" >"$HOME/.nawala/config"
}

# a tracked repo whose branch name is fine to send (no commits: this sandbox blocks `git commit`;
# commit messages are covered by test_commit_messages_are_never_read_or_sent)
pv_repo() { # dir
  new_repo "$1"
}

# the agent's fixture, cwd set to dir, with the marker in every conversation field an agent may send
pv_payload() { # agent dir mark transcript
  jq -c --arg m "$3" --arg tp "$4" '. + {
      prompt: ("prompt " + $m), lastUserInput: ("input " + $m), userPrompt: $m, user_prompt: $m, text: $m,
      last_assistant_message: ("reply " + $m), lastAssistantMessage: ("reply " + $m),
      transcript_path: $tp, transcriptPath: $tp, message: {content: $m}, note: $m
    }' "$(in_repo "$FIX/hooks/$1-prompt.json" "$2")"
}

# leak checks over everything the hook can have written or sent
pv_assert_no_leak() { # mark
  local f
  for f in "$FAKE_CURL_BODIES" "$FAKE_CURL_LOG" "$FAKE_CURL_HEADERS"; do
    if grep -q -F "$1" "$f"; then fail "marker in $(basename "$f"): $(grep -F "$1" "$f" | head -c 300)"; return 1; fi
  done
  if grep -r -q -F "$1" "$HOME/.nawala"; then fail "marker under ~/.nawala: $(grep -r -l -F "$1" "$HOME/.nawala")"; return 1; fi
  return 0
}

pv_assert_allowed_keys() { # file of events (one per line, or {events:[...]} batches)
  jq -e --argjson ok "$PV_KEYS" '(.events // [.]) | all(.[]; (keys - $ok) == []
      and ([(.commits // [])[], ((.repos // [])[] | .commits[])] | all(.[]; has("message") | not))
      and ((.repos // []) | all(.[]; (keys - ["cwd","git","commits"]) == [])))' "$1" >/dev/null \
    || { fail "event outside the allow-list: $(head -c 400 "$1")"; return 1; }
}

pv_run_all_agents() { # repo mark transcript ; every agent, every mode, synchronous
  local a m
  for a in $ALL_AGENTS; do
    pv_payload "$a" "$1" "$2" "$3" >"$HOME/$a.json"
    for m in start prompt stop end; do
      OUT="$(USER_PROMPT="kiro $2" NAWALA_HOOK_SYNC=1 bash "$HOOK" "$m" --agent "$a" <"$HOME/$a.json" 2>&1)"
      printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
      assert_not_contains "$OUT" "$2" "marker on stdout ($a $m)"
    done
  done
}

test_no_conversation_content_is_sent_for_any_agent() {
  local mark="NWL-LEAK-$RANDOM$RANDOM" repo
  pv_home
  repo="$HOME/work"; pv_repo "$repo"
  printf '{"type":"user","message":{"content":"transcript %s"}}\n' "$mark" >"$HOME/t.jsonl"
  pv_run_all_agents "$repo" "$mark" "$HOME/t.jsonl"
  # antigravity: start/stop/end + its first prompt; every other agent: four events
  [ "$(grep -c . "$FAKE_CURL_BODIES")" -ge 32 ] || fail "only $(grep -c . "$FAKE_CURL_BODIES") events sent"
  pv_assert_no_leak "$mark"
  pv_assert_allowed_keys "$FAKE_CURL_BODIES"
  [ ! -s "$HOME/.nawala/spool.jsonl" ] || fail "spool written although the server accepted"
}

test_no_conversation_content_is_spooled_for_any_agent() {
  local mark="NWL-LEAK-$RANDOM$RANDOM" repo
  pv_home
  repo="$HOME/work"; pv_repo "$repo"
  printf '{"type":"assistant","message":{"content":"transcript %s"}}\n' "$mark" >"$HOME/t.jsonl"
  export FAKE_EVENTS_CODE=503
  pv_run_all_agents "$repo" "$mark" "$HOME/t.jsonl"
  unset FAKE_EVENTS_CODE
  [ "$(grep -c . "$HOME/.nawala/spool.jsonl")" -ge 32 ] || fail "events not spooled"
  pv_assert_no_leak "$mark"
  pv_assert_allowed_keys "$HOME/.nawala/spool.jsonl"
  pv_assert_allowed_keys "$FAKE_CURL_BODIES"
}

test_print_event_has_no_conversation_content_for_any_agent() {
  local mark="NWL-LEAK-$RANDOM$RANDOM" repo a m
  pv_home
  repo="$HOME/work"; pv_repo "$repo"
  printf '{"type":"user","message":{"content":"transcript %s"}}\n' "$mark" >"$HOME/t.jsonl"
  for a in $ALL_AGENTS; do
    pv_payload "$a" "$repo" "$mark" "$HOME/t.jsonl" >"$HOME/$a.json"
    for m in start prompt stop end; do
      OUT="$(USER_PROMPT="kiro $mark" bash "$HOOK" "$m" --agent "$a" --print-event <"$HOME/$a.json" 2>&1)"
      printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
      printf '%s' "$OUT" | jq -e . >/dev/null || fail "no event printed ($a $m)"
      assert_not_contains "$OUT" "$mark" "marker in --print-event ($a $m)"
      printf '%s' "$OUT" | jq -c . >"$HOME/ev.json"
      pv_assert_allowed_keys "$HOME/ev.json"
    done
  done
  [ ! -s "$FAKE_CURL_LOG" ] || fail "--print-event used the network"
}

test_old_spool_is_cleaned_before_sending() {
  pv_home
  new_repo "$HOME/work"
  { cat "$FIX/spool-v0.1.0.jsonl"; printf 'not json {\n'; } >"$HOME/.nawala/spool.jsonl"
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent codex <"$(in_repo "$FIX/hooks/codex-prompt.json" "$HOME/work")"
  pv_assert_no_leak "$OLD_MARK"
  pv_assert_allowed_keys "$FAKE_CURL_BODIES"
  assert_eq "$(head -n 1 "$FAKE_CURL_BODIES" | jq -r '[.events[].id] | join(" ")')" \
    "$(jq -r .id "$FIX/spool-v0.1.0.jsonl" | paste -sd ' ' -)" "old events (ids) not flushed"
  assert_eq "$(head -n 1 "$FAKE_CURL_BODIES" | jq -r '.events[1].commits[0].sha')" "3096b4971fdc7a142451e29e1a9334e8578ef6d4"
  assert_eq "$(head -n 1 "$FAKE_CURL_BODIES" | jq -r '.events[0] | [.type, .sessionId, .git.remote] | @tsv')" \
    "prompt	old-sess-1	git@gitlab.com:acme/app.git"
  [ ! -s "$HOME/.nawala/spool.jsonl" ] || fail "spool not emptied"
}

test_old_spool_is_cleaned_when_the_server_is_down() {
  pv_home
  new_repo "$HOME/work"
  cp "$FIX/spool-v0.1.0.jsonl" "$HOME/.nawala/spool.jsonl"
  FAKE_EVENTS_CODE=503 NAWALA_HOOK_SYNC=1 bash "$HOOK" stop --agent codex <"$(in_repo "$FIX/hooks/codex-prompt.json" "$HOME/work")"
  assert_eq "$(grep -c . "$HOME/.nawala/spool.jsonl")" "3" "old events + this one kept for later"
  pv_assert_no_leak "$OLD_MARK"
  pv_assert_allowed_keys "$HOME/.nawala/spool.jsonl"
  assert_eq "$(ls -l "$HOME/.nawala/spool.jsonl" | cut -c1-10)" "-rw-------" "spool mode"
}

test_old_spool_is_cleaned_in_untracked_repos_without_sending() {
  local mode
  for mode in prompt start; do
    pv_home
    new_repo "$HOME/mine" "$PERSONAL_REMOTE"
    { cat "$FIX/spool-v0.1.0.jsonl"; printf 'garbage\n'; } >"$HOME/.nawala/spool.jsonl"
    # a claim file a crashed v0.1.0 run left behind long ago
    cp "$FIX/spool-v0.1.0.jsonl" "$HOME/.nawala/spool.jsonl.sending.4242"
    touch -t 202001010000 "$HOME/.nawala/spool.jsonl.sending.4242"
    NAWALA_HOOK_SYNC=1 bash "$HOOK" "$mode" --agent claude <"$(in_repo "$FIX/hooks/claude-prompt.json" "$HOME/mine")" >/dev/null
    assert_eq "$(calls_to /v1/events)" "0" "events sent for a personal repo ($mode)"
    pv_assert_no_leak "$OLD_MARK"
    pv_assert_allowed_keys "$HOME/.nawala/spool.jsonl"
    assert_eq "$(grep -c . "$HOME/.nawala/spool.jsonl")" "4" "old events kept, without content ($mode)"
    [ ! -e "$HOME/.nawala/spool.jsonl.sending.4242" ] || fail "stale claim file left behind ($mode)"
    [ -z "$(find "$HOME/.nawala" -name '*.tidy.*' -o -name '.spool-clean.*')" ] || fail "temp files left behind ($mode)"
  done
}

test_clean_spool_is_left_untouched() {
  local before
  pv_home
  new_repo "$HOME/mine" "$PERSONAL_REMOTE"
  new_repo "$HOME/work"
  FAKE_EVENTS_CODE=503 NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent codex <"$(in_repo "$FIX/hooks/codex-prompt.json" "$HOME/work")"
  before="$(ls -li "$HOME/.nawala/spool.jsonl"; hash_file "$HOME/.nawala/spool.jsonl")"
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent claude <"$(in_repo "$FIX/hooks/claude-prompt.json" "$HOME/mine")"
  assert_eq "$(ls -li "$HOME/.nawala/spool.jsonl"; hash_file "$HOME/.nawala/spool.jsonl")" "$before" "clean spool rewritten"
}

test_commit_messages_are_never_read_or_sent() {
  local formats
  # git is never asked for the subject or body (%s %b %B %f) ...
  formats="$(grep -o -e "--format='[^']*'" "$HOOK")"
  assert_eq "$(printf '%s\n' "$formats" | sort -u)" "--format='%H%x09%ae%x09%aI%x09%P'" "git log formats"
  # ... and a message in a commit object (e.g. an old spool line) is dropped by the allow-list
  pv_home
  printf '%s\n' '{"id":"0b6f2c1e-1111-4222-8333-444455556666","type":"stop","sessionId":"s","commits":[{"sha":"3096b4971fdc7a142451e29e1a9334e8578ef6d4","message":"OLDSPOOL-MARKER","body":"OLDSPOOL-MARKER","parents":["OLDSPOOL-MARKER",1],"files":[{"path":"a.txt","additions":1,"deletions":0,"x":"OLDSPOOL-MARKER"}]}]}' >"$HOME/.nawala/spool.jsonl"
  new_repo "$HOME/mine" "$PERSONAL_REMOTE"
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent claude <"$(in_repo "$FIX/hooks/claude-prompt.json" "$HOME/mine")"
  pv_assert_no_leak "OLDSPOOL-MARKER"
  assert_eq "$(jq -c '.commits' "$HOME/.nawala/spool.jsonl")" \
    '[{"sha":"3096b4971fdc7a142451e29e1a9334e8578ef6d4","authorEmail":null,"authoredAt":null,"parents":[],"files":[{"path":"a.txt","additions":1,"deletions":0}]}]'
}

calls_to() { grep -c -e "$1" "$FAKE_CURL_LOG" || true; }

# Claude PostToolUse (`touch`) carries the edited file's contents, old/new strings and the tool
# response. Only the path is used (to find the git root); none of the rest reaches a request,
# the spool, any file under ~/.nawala or stdout - for tracked and untracked repos alike.
test_posttooluse_payload_is_never_sent_stored_or_printed() {
  local ws f code
  pv_home
  ws="$HOME/ws"; mkdir -p "$ws"
  pv_repo "$ws/work"; new_repo "$ws/mine" "$PERSONAL_REMOTE"
  for code in 202 503; do
    for f in "$ws/work/src/app.js" "$ws/mine/src/app.js" "$ws/notes.md"; do
      jq -c --arg c "$ws" --arg f "$f" '.cwd = $c | .tool_input.file_path = $f | .tool_response.filePath = $f' \
        "$FIX/hooks/claude-posttooluse.json" >"$HOME/touch.json"
      OUT="$(NAWALA_HOOK_SYNC=1 bash "$HOOK" touch --agent claude <"$HOME/touch.json" 2>&1)"
      printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
      assert_eq "$OUT" "" "touch printed something"
      OUT="$(bash "$HOOK" touch --agent claude --print-event <"$HOME/touch.json" 2>&1)"
      assert_eq "$OUT" "" "touch --print-event printed something"
    done
    # the turn is then sent under the edited work repo (and spooled when the server is down)
    for f in prompt stop; do
      OUT="$(jq -c --arg c "$ws" --arg t "$f-$code" '{session_id: .session_id, cwd: $c, prompt_id: $t}' "$FIX/hooks/claude-posttooluse.json" \
        | FAKE_EVENTS_CODE=$code NAWALA_HOOK_SYNC=1 bash "$HOOK" "$f" --agent claude 2>&1)"
      printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
      assert_not_contains "$OUT" "NWL-SENTINEL" "sentinel on stdout ($f)"
    done
  done
  assert_eq "$(grep -c . "$HOME/.nawala/state/claude-sess-1.repos")" "1" "work repo not recorded"
  grep -q -e '/mine' -e 'notes' "$HOME/.nawala/state/claude-sess-1.repos" && fail "untracked path recorded"
  [ "$(grep -c '"type":"prompt"' "$FAKE_CURL_BODIES")" -ge 2 ] || fail "turn not sent under the edited repo"
  [ -s "$HOME/.nawala/spool.jsonl" ] || fail "nothing spooled with the server down"
  pv_assert_no_leak "NWL-SENTINEL"
  pv_assert_no_leak "app.js"
  pv_assert_allowed_keys "$FAKE_CURL_BODIES"
  pv_assert_allowed_keys "$HOME/.nawala/spool.jsonl"
}

test_repos_entries_are_allow_listed_and_scrubbed_in_the_spool() {
  local before
  pv_home
  # a stop event as an old or tampered spool line: unknown keys, a commit message, a password in a
  # remote, an entry without commits and 25 entries (max 20 are kept)
  jq -nc '{id: "0b6f2c1e-1111-4222-8333-444455556666", type: "stop", sessionId: "s",
      repos: ([{cwd: "/w/a", note: "OLDSPOOL-MARKER",
                git: {remote: "https://dev:hunter2pass@gitlab.com/acme/a.git", branch: "main", x: "OLDSPOOL-MARKER"},
                commits: [{sha: "3096b4971fdc7a142451e29e1a9334e8578ef6d4", message: "OLDSPOOL-MARKER",
                           files: [{path: "a.txt", additions: 1, deletions: 0, patch: "OLDSPOOL-MARKER"}]}]},
               {cwd: "/w/empty", commits: []}, "OLDSPOOL-MARKER"]
             + [range(24) | {cwd: "/w/n\(.)", commits: [{sha: "3096b4971fdc7a142451e29e1a9334e8578ef6d4"}]}])}' \
    >"$HOME/.nawala/spool.jsonl"
  new_repo "$HOME/mine" "$PERSONAL_REMOTE"
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent claude <"$(in_repo "$FIX/hooks/claude-prompt.json" "$HOME/mine")"
  pv_assert_no_leak "OLDSPOOL-MARKER"
  pv_assert_no_leak "hunter2pass"
  pv_assert_allowed_keys "$HOME/.nawala/spool.jsonl"
  assert_eq "$(jq -c '.repos[0]' "$HOME/.nawala/spool.jsonl")" \
    '{"cwd":"/w/a","git":{"remote":"https://dev:[REDACTED]@gitlab.com/acme/a.git","branch":"main","head":null,"root":null},"commits":[{"sha":"3096b4971fdc7a142451e29e1a9334e8578ef6d4","authorEmail":null,"authoredAt":null,"parents":[],"files":[{"path":"a.txt","additions":1,"deletions":0}]}]}'
  assert_eq "$(jq '.repos | length' "$HOME/.nawala/spool.jsonl")" "20" "repos capped / empty entries dropped"
  # already clean: left byte-identical
  before="$(hash_file "$HOME/.nawala/spool.jsonl")"
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent claude <"$(in_repo "$FIX/hooks/claude-prompt.json" "$HOME/mine")"
  assert_eq "$(hash_file "$HOME/.nawala/spool.jsonl")" "$before" "clean spool with repos rewritten"
}
