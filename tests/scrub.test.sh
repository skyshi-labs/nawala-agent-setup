# shellcheck shell=bash
# Client-side secret scrubbing (same patterns as the server's src/ingest/scrub.ts).
# Sample secrets are assembled at runtime so no secret-looking literal sits in the repo
# (keeps GitHub push protection and secret scanners quiet).

rnd() { (LC_ALL=C tr -dc "${2:-A-Za-z0-9}" </dev/urandom 2>/dev/null | head -c "$1") || true; }

scrub_prompt() { # text -> scrubbed prompt via hook.sh --print-event
  jq -nc --arg p "$1" '{session_id:"s",cwd:"/tmp",prompt:$p}' >"$HOME/p.json"
  OUT="$(bash "$HOOK" prompt --agent claude --print-event <"$HOME/p.json" | jq -r .prompt)"
}

test_scrubs_sample_secrets() {
  new_home
  local s secrets=(
    "sk-ant-api03-$(rnd 40)"
    "sk-proj-$(rnd 48)"
    "gh""p_$(rnd 36)"
    "github_""pat_$(rnd 60)"
    "glp""at-$(rnd 20)"
    "AK""IA$(rnd 16 'A-Z0-9')"
    "xox""b-$(rnd 12 '0-9')-$(rnd 24)"
    "AI""za$(rnd 35)"
    "sk_""live_$(rnd 24)"
    "nwl_$(rnd 43)"
    "eyJ$(rnd 20).eyJ$(rnd 30).$(rnd 40)"
  )
  for s in "${secrets[@]}"; do
    scrub_prompt "please use $s for this"
    assert_not_contains "$OUT" "$s" "secret survived"
    assert_contains "$OUT" "[REDACTED]"
    assert_contains "$OUT" "please use "
  done
}

test_scrubs_assignments_urls_bearer_and_pem() {
  new_home
  local pw; pw="Hx$(rnd 10)9q"
  scrub_prompt "export DB_PASSWORD=$pw now"
  assert_eq "$OUT" "export DB_PASSWORD=[REDACTED] now"
  scrub_prompt "\"client_secret\": \"$pw\""
  assert_eq "$OUT" "\"client_secret\": \"[REDACTED]"\"
  scrub_prompt "postgres://app:$pw@db.internal:5432/main"
  assert_eq "$OUT" "postgres://app:[REDACTED]@db.internal:5432/main"
  scrub_prompt "curl -H 'Authorization: Bearer $(rnd 30)'"
  assert_eq "$OUT" "curl -H 'Authorization: Bearer [REDACTED]'"
  scrub_prompt "key:
-----BEGIN RSA PRIVATE KEY-----
$(rnd 64)
-----END RSA PRIVATE KEY-----
done"
  assert_eq "$OUT" "key:
[REDACTED PRIVATE KEY]
done"
}

test_scrubs_high_entropy_but_keeps_normal_text() {
  new_home
  local blob; blob="Zq8$(rnd 40)Xw2"
  scrub_prompt "random $blob end"
  assert_eq "$OUT" "random [REDACTED] end"
  local keep="see src/components/UserProfileSettingsPanel.tsx at commit 0123456789abcdef0123456789abcdef01234567 and uuid 3f2a9c1e-5b7d-4e2f-9a1c-8d7e6f5a4b3c"
  scrub_prompt "$keep"
  assert_eq "$OUT" "$keep" "over-scrubbed normal text"
}

test_scrubs_secret_keys_in_raw_hook_payload() {
  new_home
  jq -nc --arg t "$(rnd 24)" '{session_id:"s",cwd:"/tmp",prompt:"hi",api_key:$t,nested:{password:"p4ssw0rd!"}}' >"$HOME/p.json"
  OUT="$(bash "$HOOK" prompt --agent claude --print-event <"$HOME/p.json")"
  assert_eq "$(printf '%s' "$OUT" | jq -r .hook.api_key)" "[REDACTED]"
  assert_eq "$(printf '%s' "$OUT" | jq -r .hook.nested.password)" "[REDACTED]"
}
