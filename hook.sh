#!/usr/bin/env bash
# Nawala hook (nawala-agent-setup) - one script for every supported coding agent.
#
#   usage: hook.sh <prompt|stop|start|end> [--agent <name>] [--print-event]
#          (the agent's hook JSON arrives on stdin)
#
#   --agent        claude|codex|cursor|kiro|antigravity|opencode|grok|muse (default: claude,
#                  which keeps hooks written by the legacy installer working)
#   --print-event  build the event and print it to stdout; send nothing, write no state
#                  (use it to audit exactly what would leave your machine)
#
# Contract:
#  - always exits 0 and never blocks the agent for long; NAWALA_OFF=1 disables everything
#  - work repos only: nothing is sent (no event, no rules request) unless the repo's git remote
#    matches a prefix from GET /v1/tracking (cached in ~/.nawala/tracking.json for 15 min).
#    No remote, `git config nawala.off true`, or no list (server down, no cache) = nothing sent
#  - stdout is empty, except on `start` for agents that document context injection
#    (claude, codex, cursor, kiro): the project's rules are printed in that agent's format
#  - activity metadata only: no prompt text, no transcript, no assistant message, no raw hook
#    payload and no commit messages are ever sent, spooled or printed. Every event is built from
#    an allow-list of fields (clean_event below); the developer's intent reaches Nawala only
#    through the agent's own MCP calls (set_current_story / report_progress / complete_story)
#  - the remaining strings (cwd, git remote/branch/root, commit file paths) are still scrubbed
#    for secrets on this machine as defence in depth (see scrub_* below)
#  - sending happens in the background; if the server is unreachable the event is spooled
#    to ~/.nawala/spool.jsonl (max 10 MB) and retried on the next hook run. Spooled lines are
#    re-built with clean_event before they are sent or kept (v0.1.0 spooled prompts)
#  - the token is read from ~/.nawala/config and passed to curl through a 0600 temp file,
#    never on a command line
#
# Environment: NAWALA_OFF=1 (kill switch), NAWALA_DIR (default ~/.nawala),
#              NAWALA_URL / NAWALA_TOKEN (override the config file),
#              NAWALA_HOOK_SYNC=1 (run in the foreground; for debugging and tests)

NAWALA_HOOK_VERSION="0.1.1"

MODE="${1:-}"
[ "${NAWALA_OFF:-0}" = "1" ] && exit 0
case "$MODE" in prompt|stop|start|end) shift ;; *) exit 0 ;; esac

AGENT="claude"
PRINT_EVENT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="${2:-}"; shift ;;
    --agent=*) AGENT="${1#--agent=}" ;;
    --print-event) PRINT_EVENT=1 ;;
    *) ;;
  esac
  shift
done
case "$AGENT" in claude|codex|cursor|kiro|antigravity|opencode|grok|muse) ;; *) exit 0 ;; esac

command -v jq >/dev/null 2>&1 || exit 0
[ "$PRINT_EVENT" = "1" ] || command -v curl >/dev/null 2>&1 || exit 0

NAWALA_DIR="${NAWALA_DIR:-$HOME/.nawala}"
CONFIG="$NAWALA_DIR/config"
SPOOL="$NAWALA_DIR/spool.jsonl"
SPOOL_MAX_BYTES=10485760

INPUT="$(cat 2>/dev/null)"
[ -n "$INPUT" ] || INPUT='{}'
printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

# ---- config (parsed, never sourced) -------------------------------------------------------
URL=""
TOKEN=""
if [ -f "$CONFIG" ]; then
  URL="$(sed -n 's/^NAWALA_URL=//p' "$CONFIG" | tail -n 1)"
  TOKEN="$(sed -n 's/^NAWALA_TOKEN=//p' "$CONFIG" | tail -n 1)"
fi
URL="${NAWALA_URL:-$URL}"; URL="${URL%/}"
TOKEN="${NAWALA_TOKEN:-$TOKEN}"
if [ "$PRINT_EVENT" != "1" ]; then
  [ -n "$TOKEN" ] && [ -n "$URL" ] || exit 0
fi

# ---- helpers ------------------------------------------------------------------------------
sha256() { # stdin -> hex digest
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else openssl dgst -sha256 2>/dev/null | sed 's/^.*= *//'
  fi
}

new_uuid() {
  local u
  u="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"
  [ -n "$u" ] || u="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  if [ -z "$u" ]; then
    u="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ "${#u}" = 32 ] || return 1
    u="${u:0:8}-${u:8:4}-4${u:13:3}-a${u:17:3}-${u:20:12}"
  fi
  printf '%s' "$u"
}

safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

# ---- secret scrubbing (port of the server's src/ingest/scrub.ts; over-redaction is fine) --
# No prompt or conversation text is sent any more; this only guards the few strings that are
# (a password in a git remote URL, a token in a directory or file name). Kept as one jq program
# so it is easy to audit and to test (tests/scrub.test.sh).
SCRUB_JQ='
def secret_name: "[A-Za-z0-9_.-]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API[_-]?KEY|APIKEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|CLIENT[_-]?SECRET|CREDENTIALS?|SESSION[_-]?KEY|AUTH[_-]?KEY|SIGNING[_-]?KEY|ENCRYPTION[_-]?KEY|DATABASE[_-]?URL|DSN)[A-Za-z0-9_.-]*";
def entropy: explode | length as $n
  | if $n == 0 then 0 else
      (group_by(.) | map(length / $n) | map(. * (log / (2|log))) | add | -.)
    end;
def high_entropy:
  if length < 32 then false
  elif (test("^[0-9a-fA-F]+$") and (length == 40 or length == 64)) then false
  elif (test("[0-9]") and test("[A-Z]") and test("[a-z]")) | not then false
  else entropy >= 4.2 end;
def scrub_candidate:
  if test("/") then split("/") | map(if high_entropy then "[REDACTED]" else . end) | join("/")
  elif high_entropy then "[REDACTED]" else . end;
def scrub_str:
  if type != "string" or . == "" then . else
    gsub("-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\\s\\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|$)"; "[REDACTED PRIVATE KEY]")
    | gsub("\\bsk-ant-[A-Za-z0-9_-]{8,}"; "[REDACTED]")
    | gsub("\\bsk-(?:proj-|live-|test-)?[A-Za-z0-9_-]{20,}"; "[REDACTED]")
    | gsub("\\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"; "[REDACTED]")
    | gsub("\\b(?:glpat|gldt|glrt|glptt|glsoat|glcbt)-[A-Za-z0-9_-]{16,}"; "[REDACTED]")
    | gsub("\\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\\b"; "[REDACTED]")
    | gsub("\\bxox[abposr]-[A-Za-z0-9-]{10,}"; "[REDACTED]")
    | gsub("\\bAIza[0-9A-Za-z_-]{35}\\b"; "[REDACTED]")
    | gsub("\\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}"; "[REDACTED]")
    | gsub("\\b(?:nwl|dp)_[A-Za-z0-9_-]{30,}"; "[REDACTED]")
    | gsub("\\beyJ[A-Za-z0-9_-]{5,}\\.eyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}"; "[REDACTED]")
    | gsub("\\b(?<k>Bearer|Basic|Token)(?<s>\\s+)[A-Za-z0-9._~+/-]{16,}=*"; "\(.k)\(.s)[REDACTED]")
    | gsub("\\b(?<p>[a-z][a-z0-9+.-]*://)(?<u>[^\\s:@/\u0027\"`]+):[^\\s@/\u0027\"`]+@"; "\(.p)\(.u):[REDACTED]@"; "i")
    | gsub("\\b(?<n>" + secret_name + ")(?<s>[\"\u0027]?\\s*(?::|=|:=)\\s*)(?<q>[\"\u0027]?)[^\\s\"\u0027`,;}{)]{3,}"; "\(.n)\(.s)\(.q)[REDACTED]"; "i")
    | gsub("(?<t>[A-Za-z0-9+/_-]{32,}={0,2})"; .t | scrub_candidate)
  end;
def scrub_value:
  if type == "string" then scrub_str
  elif type == "array" then map(scrub_value)
  elif type == "object" then
    with_entries(
      if (.value | type) == "string" and (.value | length) > 0 and (.key | test("^" + secret_name + "$"; "i"))
      then .value = "[REDACTED]" else .value |= scrub_value end)
  else . end;
'

# ---- the event allow-list ---------------------------------------------------------------------
# The ONLY shape that leaves this machine or is written to the spool. Anything else in the input
# (prompt, transcriptTail, hook, commit message, unknown keys) is dropped. Also applied to every
# spooled line, so events spooled by v0.1.0 lose their prompt/transcript/hook before sending.
EVENT_JQ="$SCRUB_JQ"'
def scalar: if type == "string" or type == "number" or type == "boolean" then . else null end;
def meta($max): # model id / effort level: one trimmed line, clipped; null when empty
  if type == "string" then gsub("[[:cntrl:]]+"; " ") | sub("^\\s+"; "") | sub("\\s+$"; "") | .[0:$max]
    | if . == "" then null else . end
  else null end;
def opt($k; $v): if $v == null then {} else { ($k): $v } end;
def text: if type == "string" then scrub_str else null end;
def sha: if type == "string" and test("^[0-9a-fA-F]{7,64}$") then . else null end;
def clean_commit:
  { sha: (.sha | sha), authorEmail: (.authorEmail | scalar), authoredAt: (.authoredAt | scalar),
    parents: [ (.parents // []) | if type == "array" then .[] else empty end | sha | strings ],
    files: [ (.files // []) | if type == "array" then .[] else empty end | objects
             | { path: (.path | text), additions: (.additions | scalar), deletions: (.deletions | scalar) } ] };
def clean_event:
  { id: (.id | scalar), type: (.type | scalar), clientTs: (.clientTs | scalar),
    sessionId: (.sessionId | scalar), agent: (.agent | scalar), hookSource: (.hookSource | scalar),
    dedupeKey: (.dedupeKey | scalar), clientVersion: (.clientVersion | scalar),
    cwd: (.cwd | text),
    git: ((.git | objects) // {} | { remote: (.remote | text), branch: (.branch | text),
                                       head: (.head | text), root: (.root | text) }) }
  + opt("model"; .model | meta(100)) + opt("effort"; .effort | meta(30))
  + ( [ (.commits // []) | if type == "array" then .[] else empty end | objects | clean_commit ]
      | if length > 0 then { commits: . } else {} end );
'

# ---- normalise the agent payload ----------------------------------------------------------
# Each agent names things differently; this maps them onto one shape:
#   claude/codex/kiro: session_id, cwd, prompt
#   cursor:            conversation_id (session_id on sessionStart/End), workspace_roots[0], prompt
#   grok:              sessionId, cwd/workspaceRoot, promptId (no documented prompt text)
#   antigravity:       conversationId, workspacePaths[0], lastUserInput
#   opencode (plugin): sessionID, directory, prompt
#   muse:              Claude-style names assumed (unverified), camelCase accepted too
# Grok also runs hooks from ~/.claude/settings.json and ~/.cursor/hooks.json; a camelCase
# payload arriving through those is re-labelled as grok so the server sees one agent.
# `prompt` stays on this machine: it is only hashed (duplicate detection), never sent.
# model / effort (metadata only), documented fields only; other agents document none:
#   claude:      model (SessionStart only, not always), effort.level (Stop and tool events) or
#                the CLAUDE_EFFORT env var (same value)
#   codex:       model (active model slug)
#   cursor:      model_id (else the legacy model slug), model_params[] {id:"effort"}.value
#   antigravity: modelName
NORMALISE_JQ='
def s: if . == null then "" elif type == "string" then . else tostring end;
def first_str(f): [f | select(. != null and . != "") | s] | first // "";
. as $in
| (if ($declared == "claude" or $declared == "cursor" or $declared == "codex")
      and ($in.sessionId != null) and ($in.session_id == null) and ($in.conversation_id == null)
   then "grok" else $declared end) as $agent
| {
    agent: $agent,
    hookSource: $declared,
    sessionId: (
      if $agent == "cursor" then first_str($in.conversation_id, $in.session_id)
      elif $agent == "antigravity" then first_str($in.conversationId, $in.conversation_id, $in.sessionId)
      elif $agent == "opencode" then first_str($in.sessionID, $in.sessionId, $in.session_id)
      else first_str($in.session_id, $in.sessionId, $in.conversation_id, $in.conversationId, $in.sessionID) end),
    cwd: first_str($in.cwd, ($in.workspace_roots // [])[0], ($in.workspacePaths // [])[0], $in.workspaceRoot, $in.directory),
    prompt: (
      if $agent == "antigravity" then first_str($in.lastUserInput, $in.prompt)
      elif $agent == "kiro" then first_str($in.prompt, $userPrompt)
      else first_str($in.prompt, $in.userPrompt, $in.user_prompt, $in.text) end),
    model: (
      if $agent == "claude" or $agent == "codex" then first_str($in.model | strings)
      elif $agent == "cursor" then first_str(($in.model_id | strings), ($in.model | strings))
      elif $agent == "antigravity" then first_str($in.modelName | strings)
      else "" end),
    effort: (
      if $agent == "claude" then first_str(($in.effort | objects | .level | strings), $claudeEffort)
      elif $agent == "cursor" then
        first_str(($in.model_params // []) | arrays | .[] | objects | select(.id == "effort") | .value | strings)
      else "" end),
    discriminator: first_str($in.prompt_id, $in.promptId, $in.turn_id, $in.generation_id, $in.executionNum)
  }
'

NORM="$(printf '%s' "$INPUT" | jq -c --arg declared "$AGENT" --arg userPrompt "${USER_PROMPT:-}" \
  --arg claudeEffort "${CLAUDE_EFFORT:-}" "$NORMALISE_JQ" 2>/dev/null)"
[ -n "$NORM" ] || exit 0
REAL_AGENT="$(printf '%s' "$NORM" | jq -r '.agent')"
SESSION_ID="$(printf '%s' "$NORM" | jq -r '.sessionId')"
CWD="$(printf '%s' "$NORM" | jq -r '.cwd')"
[ -n "$CWD" ] || CWD="$PWD"

# Fallback session id when the agent does not send one: one id per agent + working directory,
# started on `start`, reused by prompt/stop, dropped on `end`, expired after 12h of silence.
fallback_session() {
  local dir file now ts id
  dir="$NAWALA_DIR/state/sessions"
  file="$dir/$(safe_name "$REAL_AGENT")-$(printf '%s' "$CWD" | sha256 | cut -c1-16)"
  now="$(date +%s)"
  if [ "$PRINT_EVENT" = "1" ]; then printf '%s-pending' "$REAL_AGENT"; return 0; fi
  (umask 077; mkdir -p "$dir") 2>/dev/null || return 1
  if [ "$MODE" != "start" ] && [ -f "$file" ]; then
    ts="$(sed -n '2p' "$file" 2>/dev/null)"
    id="$(sed -n '1p' "$file" 2>/dev/null)"
    if [ -n "$id" ] && [ $((now - ${ts:-0})) -lt 43200 ]; then
      printf '%s\n%s\n' "$id" "$now" >"$file" 2>/dev/null
      [ "$MODE" = "end" ] && rm -f "$file"
      printf '%s' "$id"; return 0
    fi
  fi
  id="$REAL_AGENT-$(new_uuid)" || return 1
  [ "$MODE" = "end" ] || printf '%s\n%s\n' "$id" "$now" >"$file" 2>/dev/null
  printf '%s' "$id"
}
ensure_session() { # sets SESSION_ID (fallback when the agent sent none); 1 when there is none
  [ -n "$SESSION_ID" ] || SESSION_ID="$(fallback_session)"
  [ -n "$SESSION_ID" ]
}

GIT_REMOTE=""; GIT_BRANCH=""; GIT_HEAD=""; GIT_ROOT=""
git_info() {
  [ -d "$CWD" ] && command -v git >/dev/null 2>&1 || return 0
  GIT_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$GIT_ROOT" ] || return 0
  GIT_REMOTE="$(git -C "$CWD" remote get-url origin 2>/dev/null)"
  if [ -z "$GIT_REMOTE" ]; then
    local first; first="$(git -C "$CWD" remote 2>/dev/null | head -n 1)"
    [ -n "$first" ] && GIT_REMOTE="$(git -C "$CWD" remote get-url "$first" 2>/dev/null)"
  fi
  GIT_BRANCH="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  GIT_HEAD="$(git -C "$CWD" rev-parse HEAD 2>/dev/null)"
}

# curl with the bearer token in a 0600 temp file (-H @file) so it never shows up in `ps`
AUTH_FILE=""
auth_file() {
  [ -n "$AUTH_FILE" ] && [ -f "$AUTH_FILE" ] && return 0
  AUTH_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/nawala.auth.XXXXXX")" || return 1
  printf 'Authorization: Bearer %s\n' "$TOKEN" >"$AUTH_FILE"
}
cleanup_auth() { [ -n "$AUTH_FILE" ] && rm -f "$AUTH_FILE"; AUTH_FILE=""; }

# ---- which repos are tracked (work repos only) ----------------------------------------------
# Personal and internal repos must never leave this machine. The server lists the remote
# prefixes this user may send (GET /v1/tracking: client rules + repos of the user's work
# projects); the request carries no repo information. The list is cached for 15 minutes.
TRACKING_CACHE="$NAWALA_DIR/tracking.json"
TRACKING_MAX_AGE_MIN=15

# Port of the server's normalizeRemote() (src/projects/normalize.ts); must give the same key.
#   git@gitlab.com:Org/Repo.git -> gitlab.com/org/repo      prints nothing + returns 1 when none
normalize_remote() {
  local s="$1" host="" path="" rest authority after user re bad='[/[:space:]]' two='//' one='/'
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"   # trim
  [ -n "$s" ] || return 1
  re='^[A-Za-z][A-Za-z0-9+.-]*://'
  if [[ $s =~ $re ]]; then
    # url form: proto://[user[:pass]@]host[:port]/path (also the odd ssh://host:org/repo)
    rest="${s#*://}"
    case "$rest" in
      */*) authority="${rest%%/*}"; path="${rest#*/}" ;;
      *) authority="$rest"; path="" ;;
    esac
    authority="${authority##*@}"
    case "$authority" in
      *:*)
        after="${authority#*:}"; authority="${authority%%:*}"
        case "$after" in *[!0-9]*) path="$after/$path" ;; esac ;;
    esac
    host="$authority"
  else
    # scp-like form: [user@]host:path (user = text before the first @, no / or spaces)
    re='^([^:/[:space:]]+):(.+)$'
    user=""
    case "$s" in *@*) user="${s%%@*}" ;; esac
    if [ -n "$user" ] && ! [[ $user =~ $bad ]] && [[ ${s#*@} =~ $re ]]; then
      host="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[2]}"
    elif [[ $s =~ $re ]]; then
      host="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[2]}"
    fi
    if [ -n "$host" ]; then
      re='^[0-9]+/'   # host:22/org/repo is not valid scp syntax but appears in the wild
      [[ $path =~ $re ]] && path="${path:${#BASH_REMATCH[0]}}"
    else
      # bare "gitlab.com/org/repo"
      rest="${s#*/}"
      re='^[^/[:space:]]+\.[^/[:space:]]+$'
      if [ "$rest" = "$s" ] || [ -z "$rest" ] || ! [[ ${s%%/*} =~ $re ]]; then return 1; fi
      host="${s%%/*}"; path="$rest"
    fi
  fi
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  host="${host#www.}"
  path="${path%%[?#]*}"
  while case "$path" in *//*) true ;; *) false ;; esac; do path="${path//$two/$one}"; done
  path="${path#/}"; path="${path%/}"
  case "$path" in *.[Gg][Ii][Tt]) path="${path%????}" ;; esac
  path="${path%/}"
  path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$host" ] || [ -z "$path" ]; then return 1; fi
  printf '%s/%s\n' "$host" "$path"
}

# Same rule as the server's matchClientRule(): prefix p (lowercased, trailing slashes removed)
# matches when key == p or key starts with p + "/".
key_in_tracking_list() { # key file
  jq -e --arg key "$1" '
    [ (.prefixes // [])[] | strings | ascii_downcase | sub("/+$"; "") | select(. != "") ]
    | any(. as $p | $key == $p or ($key | startswith($p + "/")))' "$2" >/dev/null 2>&1
}
valid_tracking_list() { jq -e '(.prefixes | type) == "array"' "$1" >/dev/null 2>&1; }
# 0 when the folder is (inside) a local parent folder the developer linked to a project (`paths`,
# case-insensitive, "/" separators). Lets repos inside a linked parent folder send events right away.
cwd_in_tracking_paths() { # cwd file
  jq -e --arg cwd "$1" '
    ($cwd | gsub("\\\\"; "/") | ascii_downcase | sub("/+$"; "")) as $c
    | [ (.paths // [])[] | strings | gsub("\\\\"; "/") | ascii_downcase | sub("/+$"; "") | select(. != "") ]
    | any(. as $p | $c == $p or ($c | startswith($p + "/")))' "$2" >/dev/null 2>&1
}

# Prints "list" (use $TRACKING_CACHE), "all" (server predates /v1/tracking: send as before)
# or "none" (no usable list: send nothing). Refreshes the cache when it is older than 15 min.
tracking_list() {
  local tmp code=""
  if valid_tracking_list "$TRACKING_CACHE" \
    && [ -n "$(find "$TRACKING_CACHE" -mmin "-$TRACKING_MAX_AGE_MIN" 2>/dev/null)" ]; then
    echo list; return 0
  fi
  (umask 077; mkdir -p "$NAWALA_DIR") 2>/dev/null
  tmp="$(umask 077; mktemp "$TRACKING_CACHE.XXXXXX" 2>/dev/null)" || tmp=""
  if [ -n "$tmp" ] && auth_file; then
    code="$(curl -sS -m 2 -o "$tmp" -w '%{http_code}' -H @"$AUTH_FILE" "$URL/v1/tracking" 2>/dev/null)"
    cleanup_auth
  fi
  if [ "$code" = "200" ] && valid_tracking_list "$tmp" && mv "$tmp" "$TRACKING_CACHE" 2>/dev/null; then
    echo list; return 0
  fi
  [ -n "$tmp" ] && rm -f "$tmp"
  if [ "$code" = "404" ]; then echo all
  elif valid_tracking_list "$TRACKING_CACHE"; then echo list   # stale cache beats nothing
  else echo none
  fi
}

# 0 when events for this repo may be sent. Needs git_info first.
is_tracked() {
  local key list
  [ -n "$GIT_REMOTE" ] || return 1
  [ "$(git -C "$CWD" config --bool --get nawala.off 2>/dev/null)" = "true" ] && return 1
  key="$(normalize_remote "$GIT_REMOTE")" || key=""
  list="$(tracking_list)"
  case "$list" in
    all) return 0 ;;
    list) { [ -n "$key" ] && key_in_tracking_list "$key" "$TRACKING_CACHE"; } || cwd_in_tracking_paths "$CWD" "$TRACKING_CACHE" ;;
    *) return 1 ;;
  esac
}

# ---- spool hygiene --------------------------------------------------------------------------
# clean_spool_lines in out: every line re-built with clean_event; lines that are not a JSON
# object are dropped. Idempotent, so an already clean spool comes out byte-identical.
clean_spool_lines() {
  jq -R -c "$EVENT_JQ"'fromjson? | objects | clean_event' "$1" >"$2" 2>/dev/null
}

# v0.1.0 spooled prompt text, transcript tails, raw hook payloads and commit subjects. Rewrite
# the spool (and any claim file a crashed run left behind for >10 min) when it holds anything
# but clean events. Runs on every hook run, tracked repo or not; does nothing when clean.
tidy_spool() {
  local f clean claim
  [ -s "$SPOOL" ] || ls "$SPOOL".sending.* "$SPOOL".tidy.* >/dev/null 2>&1 || return 0
  clean="$(umask 077; mktemp "$NAWALA_DIR/.spool-clean.XXXXXX" 2>/dev/null)" || return 0
  for f in "$SPOOL".sending.* "$SPOOL".tidy.*; do
    if [ ! -f "$f" ] || [ -z "$(find "$f" -mmin +10 2>/dev/null)" ]; then continue; fi
    clean_spool_lines "$f" "$clean" && cat "$clean" >>"$SPOOL"
    rm -f "$f"
  done
  if [ -s "$SPOOL" ]; then
    clean_spool_lines "$SPOOL" "$clean"
    if ! cmp -s "$SPOOL" "$clean"; then
      claim="$SPOOL.tidy.$$"
      if mv "$SPOOL" "$claim" 2>/dev/null; then
        clean_spool_lines "$claim" "$clean" && cat "$clean" >>"$SPOOL"
        rm -f "$claim"
      fi
    fi
  fi
  rm -f "$clean"
}

# ---- SessionStart: project rules -> agent context (synchronous, 2s, fail-open) ------------
context_format() {
  case "$REAL_AGENT" in
    claude|codex) echo "hookSpecificOutput" ;;
    cursor) echo "cursor" ;;
    kiro) echo "plain" ;;
    *) echo "none" ;;
  esac
}

print_rules() {
  [ -n "$GIT_REMOTE" ] || return 0
  local fmt; fmt="$(context_format)"
  [ "$fmt" = "none" ] && return 0
  local rules_dir="$NAWALA_DIR/rules" index resp code body pid md key
  index="$rules_dir/index.tsv"
  (umask 077; mkdir -p "$rules_dir") 2>/dev/null || return 0
  # the folder decides the project (folder links), so the offline cache is per remote + folder
  key="$GIT_REMOTE|$CWD"
  auth_file || return 0
  resp="$(curl -sS -m 2 -G -w '\n%{http_code}' -H @"$AUTH_FILE" \
    --data-urlencode "remote=$GIT_REMOTE" --data-urlencode "sessionId=$SESSION_ID" \
    --data-urlencode "agent=$REAL_AGENT" --data-urlencode "cwd=$CWD" --data-urlencode "root=$GIT_ROOT" \
    "$URL/v1/rules" 2>/dev/null)"
  cleanup_auth
  code="$(printf '%s' "$resp" | tail -n 1)"
  body="$(printf '%s' "$resp" | sed '$d')"
  md=""
  if [ "$code" = "200" ]; then
    pid="$(printf '%s' "$body" | jq -r '.projectId // empty' 2>/dev/null)"
    md="$(printf '%s' "$body" | jq -r '.markdown // empty' 2>/dev/null)"
    case "$pid" in *[!0-9a-f-]*|"") pid="" ;; esac
    if [ -n "$pid" ] && [ -n "$md" ]; then
      printf '%s\n' "$md" >"$rules_dir/$pid.md" 2>/dev/null
      { grep -v -F "$key	" "$index" 2>/dev/null; printf '%s\t%s\n' "$key" "$pid"; } >"$index.tmp" 2>/dev/null && mv "$index.tmp" "$index"
    fi
  elif [ "$code" = "204" ]; then
    if [ -f "$index" ]; then grep -v -F "$key	" "$index" >"$index.tmp" 2>/dev/null; mv "$index.tmp" "$index" 2>/dev/null; fi
    return 0
  else
    pid="$(grep -F "$key	" "$index" 2>/dev/null | tail -n 1 | cut -f2)"
    [ -n "$pid" ] && [ -f "$rules_dir/$pid.md" ] && md="$(cat "$rules_dir/$pid.md")"
  fi
  [ -n "$md" ] || return 0
  case "$fmt" in
    hookSpecificOutput) jq -nc --arg ctx "$md" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}' ;;
    cursor) jq -nc --arg ctx "$md" '{additional_context: $ctx}' ;;
    plain) printf '%s\n' "$md" ;;
  esac
}

# Cursor documents a JSON answer for beforeSubmitPrompt; answer "allow" explicitly (in every
# repo: it is only an answer to Cursor, nothing leaves the machine).
if [ "$MODE" = "prompt" ] && [ "$AGENT" = "cursor" ] && [ "$PRINT_EVENT" != "1" ]; then
  printf '{"continue":true}\n'
fi

# SessionStart decides in the foreground (the rules must be printed now); the other events
# decide in the background. Untracked repo: stop here, send nothing, write no state.
if [ "$MODE" = "start" ] && [ "$PRINT_EVENT" != "1" ]; then
  git_info
  if ! is_tracked; then ( umask 077; tidy_spool ) </dev/null >/dev/null 2>&1; exit 0; fi
  ensure_session || exit 0
  print_rules
fi

# ---- duplicate guard ------------------------------------------------------------------------
# The same agent turn can fire twice (e.g. Grok runs its own hooks AND the Claude-compatible
# ones). The first run claims a key (atomic mkdir) and later runs within 10s are dropped.
# The key is also sent as `dedupeKey` so the server can drop duplicates that slip through.
# Without a turn id, the prompt / last message is folded in as a one-way hash (never the text).
DEDUPE_KEY=""
dedupe_key() {
  local disc
  disc="$(printf '%s' "$NORM" | jq -r '.discriminator')"
  if [ -z "$disc" ]; then
    disc="$(printf '%s' "$INPUT" | jq -r '(.prompt // .lastUserInput // .last_assistant_message // .lastAssistantMessage // "") | tostring' 2>/dev/null | sha256 | cut -c1-16)"
  fi
  printf '%s|%s|%s|%s' "$REAL_AGENT" "$SESSION_ID" "$MODE" "$disc" | sha256 | cut -c1-32
}

claim_once() { # returns 1 when another run already handled this key
  local dir="$NAWALA_DIR/state/dedupe" d now ts
  d="$dir/$DEDUPE_KEY"
  now="$(date +%s)"
  (umask 077; mkdir -p "$dir") 2>/dev/null || return 0
  if mkdir "$d" 2>/dev/null; then printf '%s' "$now" >"$d/ts"; return 0; fi
  ts="$(cat "$d/ts" 2>/dev/null)"
  [ -n "$ts" ] || return 1
  if [ $((now - ts)) -ge 10 ]; then printf '%s' "$now" >"$d/ts"; return 0; fi
  return 1
}

# Antigravity has no prompt-submit hook; PreInvocation fires once per model call and repeats
# lastUserInput, so only the first sighting of a given prompt per session counts.
antigravity_new_prompt() {
  [ "$REAL_AGENT" = "antigravity" ] && [ "$MODE" = "prompt" ] || return 0
  local f h
  f="$NAWALA_DIR/state/$(safe_name "antigravity-$SESSION_ID").lastprompt"
  h="$(printf '%s' "$NORM" | jq -r '.prompt' | sha256)"
  [ "$(cat "$f" 2>/dev/null)" = "$h" ] && return 1
  printf '%s' "$h" >"$f" 2>/dev/null
  return 0
}

# ---- commits on stop ------------------------------------------------------------------------
# Commits on the current branch since the last head this hook saw for this session (first time:
# last 24h by the author, max 50). Metadata only: sha, author email, date, parents, per-file
# line counts. The commit message (subject included) is never read. git gets 1s; on timeout no
# commits are sent.
collect_commits() {
  [ -n "$GIT_ROOT" ] && [ -n "$GIT_HEAD" ] || return 0
  local state last out pid i email
  state="$NAWALA_DIR/state/$(safe_name "$SESSION_ID").head"
  last="$(cat "$state" 2>/dev/null)"
  [ "$last" = "$GIT_HEAD" ] && return 0
  out="$(mktemp "${TMPDIR:-/tmp}/nawala.git.XXXXXX")" || return 0
  if [ -n "$last" ] && git -C "$CWD" cat-file -e "$last^{commit}" 2>/dev/null; then
    ( git -C "$CWD" log --no-color --numstat -n 50 --format='%H%x09%ae%x09%aI%x09%P' "$last..HEAD" >"$out" 2>/dev/null ) &
  else
    email="$(git -C "$CWD" config user.email 2>/dev/null)"
    [ -n "$email" ] || { rm -f "$out"; return 0; }
    ( git -C "$CWD" log --no-color --numstat -n 50 --since='24 hours ago' --author="$email" --format='%H%x09%ae%x09%aI%x09%P' HEAD >"$out" 2>/dev/null ) &
  fi
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 10 ]; then kill "$pid" 2>/dev/null; rm -f "$out"; return 0; fi
    sleep 0.1
  done
  local json="$out.json"
  jq -R -s '
    split("\n") | reduce .[] as $l ([];
      if ($l | test("^[0-9a-f]{40}\t")) then
        . + [ ($l | split("\t")) as $f
              | { sha: $f[0], authorEmail: $f[1], authoredAt: $f[2],
                  parents: (($f[3] // "") | split(" ") | map(select(. != ""))), files: [] } ]
      elif ($l | test("^([0-9]+|-)\t([0-9]+|-)\t")) and length > 0 then
        ($l | split("\t")) as $f
        | .[-1].files += [ { path: ($f[2:] | join("\t")),
                             additions: (try ($f[0] | tonumber) catch null),
                             deletions: (try ($f[1] | tonumber) catch null) } ]
      else . end)' "$out" >"$json" 2>/dev/null
  rm -f "$out"
  [ -s "$json" ] && printf '%s' "$json"
}

# ---- build the event (allow-listed, scrubbed) ------------------------------------------------
# Built from the hook's own variables only: the agent's raw payload ($INPUT) is not passed in.
build_event() {
  local id ts commitsfile="" event
  id="$(new_uuid)" || return 1
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ "$MODE" = "stop" ] && commitsfile="$(collect_commits)"
  event="$(jq -nc \
    --arg id "$id" --arg type "$MODE" --arg ts "$ts" --arg cwd "$CWD" --arg sid "$SESSION_ID" \
    --arg agent "$REAL_AGENT" --arg hookSource "$AGENT" --arg dedupe "$DEDUPE_KEY" --arg ver "$NAWALA_HOOK_VERSION" \
    --arg remote "$GIT_REMOTE" --arg branch "$GIT_BRANCH" --arg head "$GIT_HEAD" --arg root "$GIT_ROOT" \
    --argjson norm "$NORM" --slurpfile commits "${commitsfile:-/dev/null}" "$EVENT_JQ"'
      def nn: if . == "" then null else . end;
      {
        id: $id, type: $type, clientTs: $ts, sessionId: $sid, agent: $agent, hookSource: $hookSource,
        dedupeKey: ($dedupe | nn), clientVersion: $ver, cwd: $cwd,
        git: { remote: ($remote|nn), branch: ($branch|nn), head: ($head|nn), root: ($root|nn) },
        model: $norm.model, effort: $norm.effort,
        commits: (if $type == "stop" then ($commits[0] // []) else [] end)
      } | clean_event
    ' 2>/dev/null)"
  [ -n "$commitsfile" ] && rm -f "$commitsfile"
  [ -n "$event" ] || return 1
  printf '%s' "$event"
}

if [ "$PRINT_EVENT" = "1" ]; then
  git_info
  ensure_session || exit 0
  DEDUPE_KEY="$(dedupe_key)"
  build_event | jq . 2>/dev/null
  exit 0
fi

# ---- everything below runs in the background ------------------------------------------------
nawala_main() {
  umask 077
  tidy_spool # before the tracking check: old spooled prompts go away in any repo
  if [ "$MODE" != "start" ]; then # start already decided in the foreground
    git_info
    is_tracked || return 0
    ensure_session || return 0
  fi
  mkdir -p "$NAWALA_DIR" "$NAWALA_DIR/state" 2>/dev/null || return 0
  DEDUPE_KEY="$(dedupe_key)"
  claim_once || return 0
  antigravity_new_prompt || return 0
  # housekeeping: forget dedupe keys older than a day (only our own <key>/ts entries)
  local d now; now="$(date +%s)"
  for d in "$NAWALA_DIR"/state/dedupe/*/; do
    [ -f "${d}ts" ] || continue
    [ $((now - $(cat "${d}ts" 2>/dev/null || echo "$now"))) -gt 86400 ] && rm -f "${d}ts" && rmdir "$d" 2>/dev/null
  done

  local event
  event="$(build_event)" || return 0
  if [ "$MODE" = "stop" ] && [ -n "$GIT_HEAD" ]; then
    printf '%s\n' "$GIT_HEAD" >"$NAWALA_DIR/state/$(safe_name "$SESSION_ID").head"
  fi

  auth_file || return 0
  post() {
    curl -sS -m 3 -o /dev/null -w '%{http_code}' -X POST \
      -H @"$AUTH_FILE" -H "Content-Type: application/json" \
      --data-binary @- "$URL/v1/events" 2>/dev/null
  }
  spool_append() {
    local size
    size="$(wc -c <"$SPOOL" 2>/dev/null | tr -d ' ')"
    [ "${size:-0}" -lt "$SPOOL_MAX_BYTES" ] && printf '%s\n' "$1" >>"$SPOOL"
  }
  retryable() { case "$1" in 000|408|429|5??) return 0 ;; *) return 1 ;; esac; }

  # 1) flush the spool first (atomic claim via mv so parallel hooks don't double-send);
  #    only re-built lines are sent or put back, never the claimed file itself
  if [ -s "$SPOOL" ]; then
    local claim="$SPOOL.sending.$$" code
    if mv "$SPOOL" "$claim" 2>/dev/null; then
      if clean_spool_lines "$claim" "$claim.clean" && [ -s "$claim.clean" ]; then
        code="$(jq -cs '{events: .}' "$claim.clean" 2>/dev/null | post)"
        retryable "$code" && cat "$claim.clean" >>"$SPOOL"
      fi
      rm -f "$claim" "$claim.clean"
    fi
  fi

  # 2) send this event; spool it if the server is unreachable
  local code
  code="$(printf '%s' "$event" | post)"
  retryable "$code" && spool_append "$event"
  cleanup_auth
  return 0
}

if [ "${NAWALA_HOOK_SYNC:-0}" = "1" ]; then
  ( nawala_main ) </dev/null >/dev/null 2>&1
else
  ( nawala_main ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
exit 0
