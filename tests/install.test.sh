# shellcheck shell=bash
# install.sh: dry-run, idempotency, byte-for-byte uninstall, preservation, failure modes.

test_version_and_help() {
  install_sh --version
  assert_contains "$OUT" "nawala-agent-setup "
  install_sh --help
  assert_contains "$OUT" "--dry-run"
}

test_dry_run_changes_nothing_for_every_agent() {
  local a seed before
  for seed in "" existing; do
    for a in $ALL_AGENTS; do
      new_home "$seed"
      before="$(snapshot)"
      install_sh --agent "$a" --url "$URL" --dry-run --project-dir "$HOME"
      assert_same_tree "$before" "$(snapshot)" "dry-run changed files ($a, seed=${seed:-empty})"
      assert_contains "$OUT" "Dry run: nothing was changed"
      assert_contains "$OUT" "GET $URL/api/auth/me"
      assert_contains "$OUT" "+++ b/~/"
      [ ! -s "$FAKE_CURL_LOG" ] || fail "dry-run made a network call ($a)"
    done
  done
}

test_dry_run_shows_unified_diff_of_existing_file() {
  new_home existing
  install_sh --agent cursor --url "$URL" --dry-run
  assert_contains "$OUT" "--- a/~/.cursor/mcp.json"
  assert_contains "$OUT" "+++ b/~/.cursor/mcp.json"
  assert_contains "$OUT" '"Authorization": "Bearer nwl_****"'
}

test_install_is_idempotent_for_every_agent() {
  local a seed first
  for seed in "" existing; do
    for a in $ALL_AGENTS; do
      new_home "$seed"
      install_sh --agent "$a" --url "$URL" --yes --experimental --project-dir "$HOME" || { printf '%s\n' "$OUT" >&2; fail "install failed ($a)"; }
      first="$(snapshot)"
      install_sh --agent "$a" --url "$URL" --yes --experimental --project-dir "$HOME"
      assert_contains "$OUT" "No file changes needed"
      assert_same_tree "$first" "$(snapshot)" "second install changed files ($a, seed=${seed:-empty})"
    done
  done
}

test_uninstall_restores_byte_for_byte_for_every_agent() {
  local a seed before
  for seed in "" existing; do
    for a in $ALL_AGENTS; do
      new_home "$seed"
      before="$(snapshot)"
      install_sh --agent "$a" --url "$URL" --yes --experimental --project-dir "$HOME"
      [ "$(snapshot)" != "$before" ] || fail "install changed nothing ($a)"
      install_sh --uninstall --yes
      assert_same_tree "$before" "$(snapshot)" "uninstall did not restore ($a, seed=${seed:-empty})"
    done
  done
}

test_uninstall_all_agents_at_once_and_one_by_one() {
  local before a
  new_home existing
  before="$(snapshot)"
  install_sh --agent "$(echo "$ALL_AGENTS" | tr ' ' ',')" --url "$URL" --yes --experimental --project-dir "$HOME"
  install_sh --uninstall --yes
  assert_same_tree "$before" "$(snapshot)" "full uninstall"

  install_sh --agent "$(echo "$ALL_AGENTS" | tr ' ' ',')" --url "$URL" --yes --project-dir "$HOME"
  for a in $ALL_AGENTS; do
    install_sh --uninstall --agent "$a" --yes
  done
  assert_same_tree "$before" "$(snapshot)" "one-by-one uninstall"
}

test_uninstall_dry_run_changes_nothing() {
  local mid
  new_home existing
  install_sh --agent claude,codex --url "$URL" --yes
  mid="$(snapshot)"
  install_sh --uninstall --dry-run
  assert_contains "$OUT" "Dry run: nothing was changed"
  assert_contains "$OUT" "--- a/~/.claude/settings.json"
  assert_same_tree "$mid" "$(snapshot)" "uninstall --dry-run changed files"
}

test_other_mcp_entries_and_hooks_are_preserved() {
  new_home existing
  install_sh --agent "$(echo "$ALL_AGENTS" | tr ' ' ',')" --url "$URL" --yes --project-dir "$HOME"
  # claude
  assert_eq "$(json_get "$HOME/.claude.json" '.mcpServers.github.url')" "https://api.githubcopilot.com/mcp/"
  assert_eq "$(json_get "$HOME/.claude.json" '.numStartups')" "12"
  assert_eq "$(json_get "$HOME/.claude.json" '.mcpServers.nawala.url')" "$URL/mcp?agent=claude"
  assert_eq "$(json_get "$HOME/.claude/settings.json" '.model')" "opus"
  assert_eq "$(json_get "$HOME/.claude/settings.json" '[.hooks.Stop[].hooks[].command] | map(select(. == "say done")) | length')" "1"
  assert_eq "$(json_get "$HOME/.claude/settings.json" '.hooks.PreToolUse[0].hooks[0].command')" "~/bin/guard.sh"
  assert_eq "$(json_get "$HOME/.claude/settings.json" '[.hooks[][].hooks[].command | select(test("nawala"))] | length')" "4"
  # codex
  grep -q '^\[mcp_servers.docs\]' "$HOME/.codex/config.toml" || fail "codex docs server lost"
  grep -q '^model = "gpt-5-codex"' "$HOME/.codex/config.toml" || fail "codex model lost"
  assert_eq "$(grep -c '^\[mcp_servers.nawala\]' "$HOME/.codex/config.toml")" "1"
  assert_eq "$(json_get "$HOME/.codex/hooks.json" '.hooks.Stop[0].hooks[0].command')" "notify-send codex"
  # cursor
  assert_eq "$(json_get "$HOME/.cursor/mcp.json" '.mcpServers.linear.url')" "https://mcp.linear.app/mcp"
  assert_eq "$(json_get "$HOME/.cursor/hooks.json" '.hooks.stop[0].command')" "./hooks/audit.sh"
  assert_eq "$(json_get "$HOME/.cursor/hooks.json" '.version')" "1"
  # kiro, antigravity, opencode, grok, muse
  assert_eq "$(json_get "$HOME/.kiro/settings/mcp.json" '.mcpServers["aws-docs"].command')" "uvx"
  assert_eq "$(json_get "$HOME/.gemini/config/mcp_config.json" '.mcpServers.figma.serverUrl')" "https://mcp.figma.com/mcp"
  assert_eq "$(json_get "$HOME/.gemini/config/mcp_config.json" '.mcpServers.nawala.serverUrl')" "$URL/mcp?agent=antigravity"
  grep -q 'Always answer in English.' "$HOME/.gemini/GEMINI.md" || fail "GEMINI.md content lost"
  assert_eq "$(json_get "$HOME/.config/opencode/opencode.json" '.mcp.servers.sentry.url')" "https://mcp.sentry.dev/mcp"
  assert_eq "$(json_get "$HOME/.config/opencode/opencode.json" '.mcp.servers.nawala.type')" "remote"
  assert_eq "$(json_get "$HOME/.config/opencode/opencode.json" '.theme')" "tokyonight"
  grep -q 'Prefer small diffs.' "$HOME/.config/opencode/AGENTS.md" || fail "opencode AGENTS.md content lost"
  grep -q '^\[mcp_servers.local\]' "$HOME/.grok/config.toml" || fail "grok local server lost"
  assert_eq "$(json_get "$HOME/.config/muse/settings.json" '.mcp_servers.tools.command')" "my-tools"
  assert_eq "$(json_get "$HOME/.config/muse/settings.json" '.schema_version')" "1"
  assert_eq "$(json_get "$HOME/.config/muse/settings.json" '.mcp_servers.nawala.mode')" "optional"
  grep -q 'set_current_story' "$HOME/AGENTS.md" || fail "muse project AGENTS.md block missing"
}

test_files_with_token_are_private() {
  new_home existing
  chmod 644 "$HOME/.cursor/mcp.json"
  install_sh --agent cursor,codex --url "$URL" --yes
  assert_eq "$(ls -l "$HOME/.cursor/mcp.json" | cut -c1-10)" "-rw-------"
  assert_eq "$(ls -l "$HOME/.nawala/config" | cut -c1-10)" "-rw-------"
  assert_eq "$(ls -l "$HOME/.nawala/hook.sh" | cut -c1-10)" "-rwx------"
  # a file without the token keeps its mode
  assert_eq "$(ls -l "$HOME/.claude/settings.json" | cut -c1-10)" "$(ls -l "$FIX/homes/existing/.claude/settings.json" | cut -c1-10)"
}

test_surgical_uninstall_keeps_later_user_changes() {
  local before
  new_home existing
  before="$(snapshot)"
  install_sh --agent cursor,codex,antigravity --url "$URL" --yes
  # the user edits the files after installing
  jq '.mcpServers.extra = {"url": "https://extra.example.com/mcp"}' "$HOME/.cursor/mcp.json" >"$HOME/x" && mv "$HOME/x" "$HOME/.cursor/mcp.json"
  printf '\n[profiles.fast]\nmodel = "o4-mini"\n' >>"$HOME/.codex/config.toml"
  printf '\nUser line added later.\n' >>"$HOME/.gemini/GEMINI.md"
  install_sh --uninstall --yes
  assert_contains "$OUT" "changed since install"
  assert_eq "$(json_get "$HOME/.cursor/mcp.json" '.mcpServers | keys | join(",")')" "extra,linear"
  grep -q 'nawala' "$HOME/.codex/config.toml" && fail "codex block left behind"
  grep -q '^\[profiles.fast\]' "$HOME/.codex/config.toml" || fail "user TOML change lost"
  grep -q '^\[mcp_servers.docs\]' "$HOME/.codex/config.toml" || fail "codex docs server lost"
  grep -q 'nawala' "$HOME/.gemini/GEMINI.md" && fail "GEMINI.md block left behind"
  grep -q 'User line added later.' "$HOME/.gemini/GEMINI.md" || fail "user GEMINI.md change lost"
  grep -q 'Always answer in English.' "$HOME/.gemini/GEMINI.md" || fail "original GEMINI.md content lost"
  # untouched files are still restored byte-for-byte
  [ "$(hash_file "$HOME/.cursor/hooks.json")" = "$(hash_file "$FIX/homes/existing/.cursor/hooks.json")" ] || fail "cursor hooks.json not restored"
  [ ! -e "$HOME/.nawala" ] || fail "~/.nawala left behind"
  : "$before"
}

test_reinstall_after_user_edit_then_uninstall_keeps_edit() {
  new_home existing
  install_sh --agent claude --url "$URL" --yes
  jq '.model = "sonnet"' "$HOME/.claude/settings.json" >"$HOME/x" && mv "$HOME/x" "$HOME/.claude/settings.json"
  install_sh --agent claude --url "$URL" --yes
  install_sh --uninstall --yes
  assert_eq "$(json_get "$HOME/.claude/settings.json" '.model')" "sonnet" "edit made between two installs was lost"
  assert_eq "$(json_get "$HOME/.claude/settings.json" '[.. | .command? // empty | select(test("nawala"))] | length')" "0"
}

test_legacy_install_is_upgraded_and_restored() {
  local before
  new_home legacy
  before="$(snapshot)"
  install_sh --agent claude --url "$URL" --yes
  assert_contains "$OUT" "legacy"
  assert_eq "$(json_get "$HOME/.claude/settings.json" '[.hooks[][].hooks[].command | select(test("nawala"))] | length')" "4"
  assert_eq "$(json_get "$HOME/.claude/settings.json" '.hooks.UserPromptSubmit[0].hooks[0].command | endswith("prompt --agent claude")')" "true"
  cmp -s "$HOME/.nawala/hook.sh" "$HOOK" || fail "hook.sh not replaced"
  install_sh --uninstall --yes
  assert_same_tree "$before" "$(snapshot)" "legacy state not restored"
}

test_all_detected_picks_present_agents() {
  new_home
  mkdir -p "$HOME/.codex" "$HOME/.grok"
  PATH="$ROOT/tests/bin:/usr/bin:/bin" install_sh --agent all-detected --url "$URL" --dry-run
  assert_contains "$OUT" "Agents: codex grok"
}

test_token_check_failure_changes_nothing() {
  local before
  new_home existing
  before="$(snapshot)"
  FAKE_ME_CODE=401 install_sh --agent claude --url "$URL" --yes && fail "install should fail on 401"
  assert_contains "$OUT" "HTTP 401"
  assert_same_tree "$before" "$(snapshot)" "files changed although the token check failed"
}

test_token_is_sent_via_header_file_not_argv() {
  new_home
  install_sh --agent claude --url "$URL" --yes
  grep -q "$TOKEN" "$FAKE_CURL_LOG" && fail "token visible in curl argv"
  grep -q "HEADERFILE Authorization: Bearer $TOKEN" "$FAKE_CURL_HEADERS" || fail "token not sent in a header file"
}

test_rejects_bad_input() {
  new_home
  install_sh --agent claude --url "http://evil.example.com" --yes && fail "accepted plain http"
  assert_contains "$OUT" "https://"
  install_sh --agent vim --url "$URL" --yes && fail "accepted unknown agent"
  install_sh --url "$URL" --yes && fail "accepted missing --agent"
  NAWALA_TOKEN="not-a-token" install_sh --agent claude --url "$URL" --yes && fail "accepted a malformed token"
  assert_not_contains "$OUT" "not-a-token" "echoed the token"
  [ ! -e "$HOME/.nawala" ] || fail "created files on bad input"
}

test_refuses_root() {
  new_home
  mkdir -p "$HOME/fakebin"
  printf '#!/bin/sh\n[ "$1" = "-u" ] && echo 0 || /usr/bin/id "$@"\n' >"$HOME/fakebin/id"; chmod +x "$HOME/fakebin/id"
  PATH="$HOME/fakebin:$PATH" install_sh --agent claude --url "$URL" --yes && fail "ran as root"
  assert_contains "$OUT" "do not run as root"
  rm -rf "$HOME/fakebin"
}

test_invalid_json_is_not_touched() {
  local before
  new_home
  mkdir -p "$HOME/.cursor"
  printf '{ // comment\n "mcpServers": {} }\n' >"$HOME/.cursor/mcp.json"
  before="$(snapshot)"
  install_sh --agent cursor --url "$URL" --yes && fail "edited invalid JSON"
  assert_contains "$OUT" "not plain JSON"
  assert_same_tree "$before" "$(snapshot)"
}

test_foreign_toml_nawala_entry_is_a_conflict() {
  new_home
  mkdir -p "$HOME/.codex"
  printf '[mcp_servers.nawala]\nurl = "https://old.example.com/mcp"\n' >"$HOME/.codex/config.toml"
  install_sh --agent codex --url "$URL" --yes && fail "duplicated the nawala TOML table"
  assert_contains "$OUT" "outside the Nawala markers"
}

test_no_tty_without_yes_aborts() {
  local before
  new_home
  before="$(snapshot)"
  # no controlling terminal (setsid where available) and no --yes: must not install
  if command -v setsid >/dev/null 2>&1; then
    run setsid bash "$INSTALL" --agent claude --url "$URL" </dev/null && fail "installed without confirmation"
    assert_same_tree "$before" "$(snapshot)"
  fi
}

test_print_file_matches_repo() {
  install_sh --print-file hook.sh
  [ "$OUT" = "$(cat "$HOOK")" ] || fail "--print-file hook.sh differs from hook.sh"
  install_sh --print-file templates/claude/hooks.json
  assert_contains "$OUT" "__NAWALA_HOOK__ prompt --agent claude"
}

test_installed_hook_runs_end_to_end() {
  new_home
  install_sh --agent claude --url "$URL" --yes
  : >"$FAKE_CURL_BODIES"
  NAWALA_HOOK_SYNC=1 "$HOME/.nawala/hook.sh" prompt --agent claude <"$FIX/hooks/claude-prompt.json" >/dev/null
  assert_eq "$(jq -r '.sessionId' "$FAKE_CURL_BODIES")" "claude-sess-1"
  assert_eq "$(jq -r '.agent' "$FAKE_CURL_BODIES")" "claude"
}
