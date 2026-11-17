# shellcheck shell=bash
# hook.sh: payload normalisation per agent, output contract, dedupe, spool, kill switch.

hook_home() { # fresh HOME with a ~/.nawala/config for hook.sh
  new_home
  mkdir -p "$HOME/.nawala"
  printf 'NAWALA_URL=%s\nNAWALA_TOKEN=%s\n' "$URL" "$TOKEN" >"$HOME/.nawala/config"
}
hook() { # mode agent fixture [extra args] ; stdout in $OUT
  local mode="$1" agent="$2" fixture="$3"; shift 3
  OUT="$(bash "$HOOK" "$mode" --agent "$agent" "$@" <"$fixture" 2>&1)"
  printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
}

ALLOWED_KEYS='["agent","clientTs","clientVersion","commits","cwd","dedupeKey","effort","git","hookSource","id","model","sessionId","type"]'

test_normalisation_per_agent_from_fixtures() {
  local fixture agent mode exp_agent exp_sid exp_cwd exp_prompt user_prompt exp_model exp_effort n=0
  hook_home
  while IFS="	" read -r fixture agent mode exp_agent exp_sid exp_cwd exp_prompt user_prompt exp_model exp_effort; do
    case "$fixture" in "#"*|"") continue ;; esac
    [ "$exp_prompt" = "<empty>" ] && exp_prompt=""
    if [ "$user_prompt" != "-" ]; then export USER_PROMPT="$user_prompt"; else unset USER_PROMPT; fi
    hook "$mode" "$agent" "$FIX/hooks/$fixture" --print-event
    unset USER_PROMPT
    printf '%s' "$OUT" | jq -e . >/dev/null || fail "not JSON for $fixture/$agent: $OUT"
    assert_eq "$(printf '%s' "$OUT" | jq -r .agent)" "$exp_agent" "agent ($fixture --agent $agent)"
    assert_eq "$(printf '%s' "$OUT" | jq -r .hookSource)" "$agent" "hookSource ($fixture)"
    assert_eq "$(printf '%s' "$OUT" | jq -r .sessionId)" "$exp_sid" "sessionId ($fixture)"
    assert_eq "$(printf '%s' "$OUT" | jq -r .cwd)" "$exp_cwd" "cwd ($fixture)"
    assert_eq "$(printf '%s' "$OUT" | jq -r .type)" "$mode" "type ($fixture)"
    assert_eq "$(printf '%s' "$OUT" | jq -r 'if has("model") then .model else "<none>" end')" "$exp_model" "model ($fixture --agent $agent)"
    assert_eq "$(printf '%s' "$OUT" | jq -r 'if has("effort") then .effort else "<none>" end')" "$exp_effort" "effort ($fixture --agent $agent)"
    # activity metadata only: allow-listed keys, never the prompt text or the raw payload
    printf '%s' "$OUT" | jq -e --argjson ok "$ALLOWED_KEYS" '(keys - $ok) == []' >/dev/null \
      || fail "unexpected keys ($fixture): $(printf '%s' "$OUT" | jq -c keys)"
    case "$exp_prompt" in -|"") ;; *) assert_not_contains "$OUT" "$exp_prompt" "prompt text in the event ($fixture)" ;; esac
    printf '%s' "$OUT" | jq -e '.id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")' >/dev/null || fail "bad id"
    printf '%s' "$OUT" | jq -e '(.dedupeKey | length) == 32 and (.git | type) == "object" and .clientVersion == "0.1.2"' >/dev/null || fail "shape ($fixture)"
    n=$((n + 1))
  done <"$FIX/hooks/expected.tsv"
  [ "$n" -ge 13 ] || fail "only $n fixtures checked"
}

test_model_and_effort_are_trimmed_clipped_and_optional() {
  hook_home
  hook prompt codex "$FIX/hooks/muse-prompt.json" --print-event
  printf '%s' "$OUT" | jq -e 'has("model") or has("effort") | not' >/dev/null || fail "model/effort without a source: $OUT"
  jq -nc --arg m "  $(printf 'm%.0s' $(seq 1 150))  " '{session_id:"s",cwd:"/tmp",model:$m,effort:{level:" high\n"}}' >"$HOME/p.json"
  hook stop claude "$HOME/p.json" --print-event
  assert_eq "$(printf '%s' "$OUT" | jq -r '.model | length')" "100" "model clipped to 100"
  assert_eq "$(printf '%s' "$OUT" | jq -r .effort)" "high" "effort trimmed"
  # Claude Code also exposes the effort level as $CLAUDE_EFFORT; only for --agent claude
  printf '{"session_id":"s","cwd":"/tmp","model":"   "}' >"$HOME/p.json"
  OUT="$(CLAUDE_EFFORT=medium bash "$HOOK" prompt --agent claude --print-event <"$HOME/p.json")"
  assert_eq "$(printf '%s' "$OUT" | jq -r '[.effort, has("model")] | @tsv')" "medium	false"
  OUT="$(CLAUDE_EFFORT=medium bash "$HOOK" prompt --agent codex --print-event <"$HOME/p.json")"
  assert_eq "$(printf '%s' "$OUT" | jq -r 'has("effort")')" "false" "CLAUDE_EFFORT used for codex"
  # undocumented shapes are ignored (effort as an object for codex, model as an object)
  printf '{"session_id":"s","cwd":"/tmp","model":{"id":"x"},"effort":"high","reasoning_effort":"high"}' >"$HOME/p.json"
  hook prompt codex "$HOME/p.json" --print-event
  printf '%s' "$OUT" | jq -e 'has("model") or has("effort") | not' >/dev/null || fail "undocumented model/effort used: $OUT"
}

test_stop_sends_no_transcript_or_assistant_message() {
  hook_home
  sed "s#__TRANSCRIPT__#$FIX/hooks/transcript.jsonl#" "$FIX/hooks/claude-stop.json" >"$HOME/stop.json"
  hook stop claude "$HOME/stop.json" --print-event
  printf '%s' "$OUT" | jq -e 'has("transcriptTail") or has("hook") | not' >/dev/null || fail "transcript/hook in the stop event"
  assert_not_contains "$OUT" "Deployed." "transcript in the stop event"
  assert_not_contains "$OUT" "Sup3rS3cretPw" "transcript in the stop event"
  assert_not_contains "$OUT" "transcript.jsonl" "transcript path in the stop event"
  assert_not_contains "$OUT" "Done." "last assistant message in the stop event"
}

test_fallback_session_id_is_stable_per_agent_session() {
  local s1 s2 s3 f
  hook_home
  new_repo "$HOME/repo"; f="$(in_repo "$FIX/hooks/nosession-prompt.json" "$HOME/repo")"
  : >"$FAKE_CURL_BODIES"
  NAWALA_HOOK_SYNC=1 bash "$HOOK" start --agent opencode <"$f" >/dev/null
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent opencode <"$f" >/dev/null
  NAWALA_HOOK_SYNC=1 bash "$HOOK" end --agent opencode <"$f" >/dev/null
  s1="$(sed -n 1p "$FAKE_CURL_BODIES" | jq -r .sessionId)"
  s2="$(sed -n 2p "$FAKE_CURL_BODIES" | jq -r .sessionId)"
  s3="$(sed -n 3p "$FAKE_CURL_BODIES" | jq -r .sessionId)"
  case "$s1" in opencode-*) ;; *) fail "fallback id not namespaced: $s1" ;; esac
  assert_eq "$s2" "$s1" "prompt reused the session"
  assert_eq "$s3" "$s1" "end reused the session"
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent opencode <"$f" >/dev/null
  [ "$(sed -n 4p "$FAKE_CURL_BODIES" | jq -r .sessionId)" != "$s1" ] || fail "session not reset after end"
}

test_no_stdout_except_documented_context() {
  local a f
  hook_home
  for a in claude codex kiro antigravity opencode grok muse; do
    for f in claude-prompt claude-start; do
      hook "${f#claude-}" "$a" "$FIX/hooks/$f.json"
      assert_eq "$OUT" "" "stdout from $a ${f#claude-} (no rules mapped)"
    done
  done
  hook prompt cursor "$FIX/hooks/cursor-prompt.json"
  assert_eq "$OUT" '{"continue":true}' "cursor beforeSubmitPrompt answer"
}

test_start_injects_rules_in_each_agents_format() {
  local repo
  hook_home
  repo="$HOME/repo"; new_repo "$repo"
  export FAKE_RULES_CODE=200 FAKE_RULES_BODY='{"projectId":"0b6f2c1e-1111-4222-8333-444455556666","markdown":"# Rules\nUse feature branches."}'
  printf '{"session_id":"s1","cwd":"%s"}' "$repo" >"$HOME/start.json"
  hook start claude "$HOME/start.json"
  assert_eq "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)" "# Rules
Use feature branches."
  hook start codex "$HOME/start.json"
  assert_eq "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.hookEventName)" "SessionStart"
  printf '{"session_id":"s1","workspace_roots":["%s"]}' "$repo" >"$HOME/cstart.json"
  hook start cursor "$HOME/cstart.json"
  assert_eq "$(printf '%s' "$OUT" | jq -r .additional_context)" "# Rules
Use feature branches."
  hook start kiro "$HOME/start.json"
  assert_contains "$OUT" "Use feature branches."
  printf '{"sessionId":"s1","cwd":"%s"}' "$repo" >"$HOME/gstart.json"
  hook start grok "$HOME/gstart.json"
  assert_eq "$OUT" "" "grok discards SessionStart stdout; print nothing"
  unset FAKE_RULES_CODE FAKE_RULES_BODY
}

test_kill_switch() {
  hook_home
  : >"$FAKE_CURL_LOG"
  OUT="$(NAWALA_OFF=1 NAWALA_HOOK_SYNC=1 bash "$HOOK" start --agent claude <"$FIX/hooks/claude-start.json")"
  assert_eq "$OUT" ""
  [ ! -s "$FAKE_CURL_LOG" ] || fail "NAWALA_OFF=1 still called the network"
}

test_posts_event_with_agent_and_dedupes_double_fire() {
  local f
  hook_home
  new_repo "$HOME/repo"; f="$(in_repo "$FIX/hooks/grok-prompt.json" "$HOME/repo")"
  : >"$FAKE_CURL_BODIES"
  # Grok fires its own hook and the Claude-compatible one for the same turn
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent grok <"$f" >/dev/null
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent claude <"$f" >/dev/null
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent cursor <"$f" >/dev/null
  assert_eq "$(grep -c . "$FAKE_CURL_BODIES")" "1" "duplicate events posted"
  assert_eq "$(jq -r .agent "$FAKE_CURL_BODIES")" "grok"
  assert_eq "$(jq -r .sessionId "$FAKE_CURL_BODIES")" "grok-sess-1"
  # a different turn of the same session is not a duplicate
  sed 's/gp-1/gp-2/' "$f" | NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent grok >/dev/null
  assert_eq "$(grep -c . "$FAKE_CURL_BODIES")" "2"
}

test_antigravity_counts_each_prompt_once() {
  local f
  hook_home
  new_repo "$HOME/repo"; f="$(in_repo "$FIX/hooks/antigravity-prompt.json" "$HOME/repo")"
  : >"$FAKE_CURL_BODIES"
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent antigravity <"$f"
  sed 's/"invocationNum":1/"invocationNum":2/' "$f" >"$HOME/ag2.json"
  sleep 0 && NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent antigravity <"$HOME/ag2.json"
  assert_eq "$(grep -c . "$FAKE_CURL_BODIES")" "1" "PreInvocation repeats counted twice"
}

test_unreachable_server_spools_and_flushes() {
  hook_home
  new_repo "$HOME/repo"
  FAKE_EVENTS_CODE=503 NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent codex <"$(in_repo "$FIX/hooks/codex-prompt.json" "$HOME/repo")"
  assert_eq "$(grep -c . "$HOME/.nawala/spool.jsonl")" "1" "event not spooled"
  : >"$FAKE_CURL_BODIES"
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent muse <"$(in_repo "$FIX/hooks/muse-prompt.json" "$HOME/repo")"
  assert_eq "$(head -n 1 "$FAKE_CURL_BODIES" | jq -r '.events | length')" "1" "spool not flushed"
  [ ! -s "$HOME/.nawala/spool.jsonl" ] || fail "spool not emptied"
}

test_hook_never_puts_token_on_argv() {
  hook_home
  new_repo "$HOME/repo"
  : >"$FAKE_CURL_LOG"
  NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent claude <"$(in_repo "$FIX/hooks/claude-prompt.json" "$HOME/repo")"
  grep -q '/v1/tracking' "$FAKE_CURL_LOG" || fail "no tracking request made"
  grep -q '/v1/events' "$FAKE_CURL_LOG" || fail "no event request made"
  grep -q "$TOKEN" "$FAKE_CURL_LOG" && fail "token on curl argv"
  ls "${TMPDIR:-/tmp}"/nawala.auth.* >/dev/null 2>&1 && fail "auth temp file left behind"
  return 0
}

test_garbage_input_is_ignored() {
  hook_home
  OUT="$(printf 'not json' | NAWALA_HOOK_SYNC=1 bash "$HOOK" prompt --agent claude; echo "rc=$?")"
  assert_eq "$OUT" "rc=0"
  OUT="$(printf '{}' | bash "$HOOK" bogus --agent claude; echo "rc=$?")"
  assert_eq "$OUT" "rc=0"
}
