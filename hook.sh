#!/usr/bin/env bash
# Nawala hook (nawala-agent-setup) - one script for every supported coding agent.
#
#   usage: hook.sh <prompt|stop|start|end|touch> [--agent <name>] [--print-event]
#          (the agent's hook JSON arrives on stdin)
#
#   --agent        claude|codex|cursor|kiro|antigravity|opencode|grok|muse (default: claude,
#                  which keeps hooks written by the legacy installer working)
#   --print-event  build the event and print it to stdout; send nothing, write no state, no
#                  network (the tracking check uses the cached list only; without a cache every
#                  folder counts as tracked). Use it to audit exactly what would leave your machine
#
# Modes: start/prompt/stop/end send one event each. `touch` (Claude PostToolUse on
# Edit|Write|MultiEdit|NotebookEdit, Cursor afterFileEdit, the OpenCode plugin's edit tools) sends
# nothing: it reads only the edited file's path from the payload (tool_input.file_path /
# notebook_path, or a top-level file_path for Cursor; the file contents, old/new strings and tool
# response in the same payload are only held in memory, never stored or printed), finds that file's git root and,
# only when that repo is tracked, appends the root to ~/.nawala/state/<session>.repos. This is
# how multi-repo workspaces work: the start folder is not a git repo, the repos are opened as
# additional working directories.
#
# Contract:
#  - always exits 0 and never blocks the agent for long; NAWALA_OFF=1 disables everything
#  - work repos only: nothing is sent (no event, no rules request) unless the repo's git remote
#    matches a prefix from GET /v1/tracking (cached in ~/.nawala/tracking.json for 15 min), or
#    the folder is inside a local folder linked to a project (`paths` of the same list).
#    `git config nawala.off true`, or no list (server down, no cache) = nothing sent. A folder
#    without a remote is only sent through `paths`; an old server without /v1/tracking (404)
#    still needs a remote
#  - which folder an event describes (its `cwd` and `git`): the start folder when it is a
#    tracked git repo; else the tracked repo this session last edited (`touch`); else the start
#    folder when it is inside a linked folder (git fields null); else nothing is sent
#  - stdout is empty, except on `start` for agents that document context injection
#    (claude, codex, cursor, kiro): the project's rules are printed in that agent's format
#  - activity metadata only: no prompt text, no transcript, no assistant message, no raw hook
#    payload and no commit messages are ever sent, spooled or printed. Every event is built from
#    an allow-list of fields (clean_event below); the developer's intent reaches Nawala only
#    through the agent's own MCP calls (set_current_story / report_progress / complete_story)
#  - event fields: id, type, clientTs, sessionId, agent, hookSource, dedupeKey, clientVersion,
#    cwd, git {remote, branch, head, root}, model, effort; on `stop` also commits[] (the event's
#    repo) and repos[] ({cwd, git, commits[]} for every OTHER tracked repo this session edited
#    that has new commits; max 20). Commits: sha, author email, date, parents, per-file counts
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

NAWALA_HOOK_VERSION="0.1.4"

MODE="${1:-}"
[ "${NAWALA_OFF:-0}" = "1" ] && exit 0
case "$MODE" in prompt|stop|start|end|touch) shift ;; *) exit 0 ;; esac

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

# GUI apps started from the Dock/launcher (Cursor, OpenCode desktop) get a minimal PATH without
# Homebrew; look there last so a jq/curl the user chose still wins.
PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin"
NAWALA_DIR="${NAWALA_DIR:-$HOME/.nawala}"

# Local diagnostics for `install.sh --doctor`: one line per agent in
# ~/.nawala/state/last-run-<agent> = "<epoch> <mode> <outcome> <hook version>". Nothing else is
# written (no payload, no folder, no prompt) and nothing of it is sent anywhere.
mark_run() { # outcome
  [ "$PRINT_EVENT" = "1" ] && return 0
  [ -d "$NAWALA_DIR" ] || return 0
  ( umask 077; mkdir -p "$NAWALA_DIR/state" \
    && printf '%s %s %s %s\n' "$(date +%s)" "$MODE" "$1" "$NAWALA_HOOK_VERSION" >"$NAWALA_DIR/state/last-run-$AGENT" ) 2>/dev/null
  return 0
}

command -v jq >/dev/null 2>&1 || { mark_run no-jq; exit 0; }
[ "$PRINT_EVENT" = "1" ] || command -v curl >/dev/null 2>&1 || { mark_run no-curl; exit 0; }

CONFIG="$NAWALA_DIR/config"
SPOOL="$NAWALA_DIR/spool.jsonl"
SPOOL_MAX_BYTES=10485760

INPUT="$(cat 2>/dev/null)"
[ -n "$INPUT" ] || INPUT='{}'
printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || { mark_run bad-input; exit 0; }

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
  if [ -z "$TOKEN" ] || [ -z "$URL" ]; then mark_run no-config; exit 0; fi
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
def clean_git: (objects // {}) | { remote: (.remote | text), branch: (.branch | text),
                                   head: (.head | text), root: (.root | text) };
def clean_commits: [ (. // []) | if type == "array" then .[] else empty end | objects | clean_commit ];
# stop, multi-repo workspaces: the commits of the other repos the session edited
def clean_repo: { cwd: (.cwd | text), git: (.git | clean_git), commits: (.commits | clean_commits) };
def clean_event:
  { id: (.id | scalar), type: (.type | scalar), clientTs: (.clientTs | scalar),
    sessionId: (.sessionId | scalar), agent: (.agent | scalar), hookSource: (.hookSource | scalar),
    dedupeKey: (.dedupeKey | scalar), clientVersion: (.clientVersion | scalar),
    cwd: (.cwd | text),
    git: (.git | clean_git) }
  + opt("model"; .model | meta(100)) + opt("effort"; .effort | meta(30))
  + ( .commits | clean_commits | if length > 0 then { commits: . } else {} end )
  + ( [ (.repos // []) | if type == "array" then .[] else empty end | objects | clean_repo
        | select(.commits | length > 0) ] | .[0:20]
      | if length > 0 then { repos: . } else {} end );
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
#   opencode:    model ("<provider>/<model>", set by the Nawala plugin)
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
      elif $agent == "opencode" then first_str($in.model | strings)
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

# describe_dir dir: sets GIT_ROOT / GIT_REMOTE / GIT_BRANCH / GIT_HEAD for dir (all empty when
# dir is not inside a git repo). Every folder the hook looks at goes through here.
GIT_REMOTE=""; GIT_BRANCH=""; GIT_HEAD=""; GIT_ROOT=""
describe_dir() {
  GIT_REMOTE=""; GIT_BRANCH=""; GIT_HEAD=""; GIT_ROOT=""
  [ -n "$1" ] && [ -d "$1" ] && command -v git >/dev/null 2>&1 || return 0
  GIT_ROOT="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null </dev/null)"
  [ -n "$GIT_ROOT" ] || return 0
  GIT_REMOTE="$(git -C "$1" remote get-url origin 2>/dev/null </dev/null)"
  if [ -z "$GIT_REMOTE" ]; then
    local first; first="$(git -C "$1" remote 2>/dev/null </dev/null | head -n 1)"
    [ -n "$first" ] && GIT_REMOTE="$(git -C "$1" remote get-url "$first" 2>/dev/null </dev/null)"
  fi
  GIT_BRANCH="$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null </dev/null)"
  GIT_HEAD="$(git -C "$1" rev-parse HEAD 2>/dev/null </dev/null)"
}

# Folder identity for comparisons: "\" -> "/", lower case, no trailing slashes (git on Windows
# prints D:/x/y, agents may send D:\x\y).
root_key() {
  local k="${1//\\//}"
  k="$(printf '%s' "$k" | tr 'A-Z' 'a-z')"
  while [ "${k%/}" != "$k" ]; do k="${k%/}"; done
  printf '%s' "$k"
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
# --print-event never uses the network: the cache of any age, else "any" (everything counts).
# `touch` runs in the foreground on every edit: a cache of any age, fetched only when there is none
# (prompt/stop refresh it in the background and re-check every repo before anything is sent).
tracking_list() {
  local tmp code=""
  if [ "$PRINT_EVENT" = "1" ]; then
    if valid_tracking_list "$TRACKING_CACHE"; then echo list; else echo any; fi
    return 0
  fi
  if [ "$MODE" = "touch" ] && valid_tracking_list "$TRACKING_CACHE"; then echo list; return 0; fi
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

# The list is decided once per hook run (a down server must not cost 2s per folder).
TRACKING_MODE=""
tracking_mode() { [ -n "$TRACKING_MODE" ] || TRACKING_MODE="$(tracking_list)"; }

# is_tracked_dir dir: 0 when events for dir may be sent. Needs describe_dir dir first.
#  - git repo with `nawala.off`: never (checked before any network)
#  - list: the remote matches a prefix, or dir is inside a linked folder (`paths`); a folder
#    without a remote (not a git repo, or no remote) can only match `paths`
#  - all (old server, 404): needs a remote, as before; none (no usable list): never
is_tracked_dir() {
  local key=""
  if [ -n "$GIT_ROOT" ] && [ "$(git -C "$1" config --bool --get nawala.off 2>/dev/null </dev/null)" = "true" ]; then
    return 1
  fi
  [ -n "$GIT_REMOTE" ] && { key="$(normalize_remote "$GIT_REMOTE")" || key=""; }
  tracking_mode
  case "$TRACKING_MODE" in
    all) [ -n "$GIT_REMOTE" ] ;;
    list) { [ -n "$key" ] && key_in_tracking_list "$key" "$TRACKING_CACHE"; } || cwd_in_tracking_paths "$1" "$TRACKING_CACHE" ;;
    any) return 0 ;;
    *) return 1 ;;
  esac
}

# Outcome for mark_run when resolve_target found nothing to describe.
untracked_reason() { if [ "$TRACKING_MODE" = "none" ]; then echo no-tracking-list; else echo untracked; fi; }

# ---- which folder an event describes ----------------------------------------------------------
# Repos this session edited (`touch`), one root per line, append-only. Read with the agent's own
# session id only (a fallback id is never created just to look).
repos_file() { printf '%s/state/%s.repos' "$NAWALA_DIR" "$(safe_name "$SESSION_ID")"; }
touched_roots() { # most recent first, deduplicated (case-insensitive, "\" = "/", trailing / ignored), max 50
  local f
  [ -n "$SESSION_ID" ] || return 0
  f="$(repos_file)"
  [ -f "$f" ] || return 0
  awk '{ l[NR] = $0 }
    END { n = 0
      for (i = NR; i > 0 && n < 50; i--) {
        r = l[i]; k = tolower(r); gsub(/\\/, "/", k); sub(/\/+$/, "", k)
        if (r == "" || (k in seen)) continue
        seen[k] = 1; n++; print r
      } }' "$f" 2>/dev/null
}

# resolve_target: decides the folder this event describes and sets EV_CWD / EV_REMOTE / EV_BRANCH
# / EV_HEAD / EV_ROOT (and CWD_ROOT, the start folder's git root). 1 = send nothing.
#   1. the start folder is a tracked git repo                -> the start folder (as before)
#   2. the tracked repo this session edited most recently    -> that repo's root
#   3. the start folder is inside a linked folder (`paths`)  -> the start folder, git fields empty
EV_CWD=""; EV_REMOTE=""; EV_BRANCH=""; EV_HEAD=""; EV_ROOT=""; CWD_ROOT=""
set_target() { # cwd ; from the current GIT_* values
  EV_CWD="$1"; EV_REMOTE="$GIT_REMOTE"; EV_BRANCH="$GIT_BRANCH"; EV_HEAD="$GIT_HEAD"; EV_ROOT="$GIT_ROOT"
}
resolve_target() {
  local root
  describe_dir "$CWD"
  CWD_ROOT="$GIT_ROOT"
  if [ -n "$CWD_ROOT" ] && is_tracked_dir "$CWD"; then set_target "$CWD"; return 0; fi
  while IFS= read -r root <&3; do
    [ -n "$root" ] || continue
    describe_dir "$root"
    if [ -z "$GIT_ROOT" ] || [ "$(root_key "$GIT_ROOT")" != "$(root_key "$root")" ]; then continue; fi
    if is_tracked_dir "$GIT_ROOT"; then set_target "$GIT_ROOT"; return 0; fi
  done 3<<EOF
$(touched_roots)
EOF
  if [ -z "$CWD_ROOT" ]; then
    describe_dir ""
    if is_tracked_dir "$CWD"; then set_target "$CWD"; return 0; fi
  fi
  return 1
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

# Needs resolve_target: the rules are those of the folder the events describe (a linked
# workspace folder without a remote gets them too: the server resolves it from cwd / root).
print_rules() {
  local fmt; fmt="$(context_format)"
  [ "$fmt" = "none" ] && return 0
  local rules_dir="$NAWALA_DIR/rules" index resp code body pid md key
  index="$rules_dir/index.tsv"
  (umask 077; mkdir -p "$rules_dir") 2>/dev/null || return 0
  # the folder decides the project (folder links), so the offline cache is per remote + folder
  key="$EV_REMOTE|$EV_CWD"
  auth_file || return 0
  local args=()
  [ -n "$EV_REMOTE" ] && args=(--data-urlencode "remote=$EV_REMOTE")
  [ -n "$EV_ROOT" ] && args=(${args[@]+"${args[@]}"} --data-urlencode "root=$EV_ROOT")
  resp="$(curl -sS -m 2 -G -w '\n%{http_code}' -H @"$AUTH_FILE" ${args[@]+"${args[@]}"} \
    --data-urlencode "sessionId=$SESSION_ID" --data-urlencode "agent=$REAL_AGENT" --data-urlencode "cwd=$EV_CWD" \
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

# ---- `touch` (Claude PostToolUse, Cursor afterFileEdit, OpenCode plugin): remember the edited repo
# Foreground (Stop reads the record right after), silent, sends nothing. Only the edited file's
# path is taken from the payload; nothing else of it is kept. Untracked repo or no repo: nothing
# is written (the tracking cache aside, as in every mode). Kept cheap: no spool work here (the
# other modes tidy the spool in the background), the tracking cache is used whatever its age.
touch_main() {
  local p dir parent i=0 f root
  umask 077
  p="$(printf '%s' "$INPUT" | jq -r '[(.tool_input | objects | (.file_path // .notebook_path)), .file_path] | map(strings) | first // empty' 2>/dev/null | head -n 1)"
  INPUT=""; NORM=""
  [ -n "$p" ] || return 0
  p="${p//\\//}"
  case "$p" in */*) dir="${p%/*}" ;; *) dir="." ;; esac
  [ -n "$dir" ] || dir="/"
  case "$dir" in /*|[A-Za-z]:*) ;; *) dir="${CWD//\\//}/$dir" ;; esac
  while [ ! -d "$dir" ]; do # the file (or its folder) may be gone: walk up to a folder that exists
    i=$((i + 1)); [ "$i" -le 64 ] || return 0
    parent="${dir%/*}"
    if [ -z "$parent" ] || [ "$parent" = "$dir" ]; then return 0; fi
    dir="$parent"
  done
  describe_dir "$dir"
  root="$GIT_ROOT"
  [ -n "$root" ] || return 0
  is_tracked_dir "$root" || return 0
  ensure_session || return 0
  mkdir -p "$NAWALA_DIR/state" 2>/dev/null || return 0
  f="$(repos_file)"
  [ "$(tail -n 1 "$f" 2>/dev/null)" = "$root" ] && return 0
  printf '%s\n' "$root" >>"$f" # one short line, O_APPEND: parallel tool calls cannot interleave
}
if [ "$MODE" = "touch" ]; then
  [ "$PRINT_EVENT" = "1" ] || ( touch_main ) </dev/null >/dev/null 2>&1
  exit 0
fi

# SessionStart decides in the foreground (the rules must be printed now); the other events
# decide in the background. Nothing to describe: stop here, send nothing, write no state (except the
# content-free last-run marker, see mark_run).
if [ "$MODE" = "start" ] && [ "$PRINT_EVENT" != "1" ]; then
  if ! resolve_target; then mark_run "$(untracked_reason)"; ( umask 077; tidy_spool ) </dev/null >/dev/null 2>&1; exit 0; fi
  ensure_session || { mark_run no-session; exit 0; }
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
# Commits on the current branch of a repo since the last head this hook saw for this session in
# that repo (first time: last 24h by the author, max 50). Metadata only: sha, author email, date,
# parents, per-file line counts. The commit message (subject included) is never read. git gets
# 1s; on timeout no commits are sent. The last head is kept per session and repo root
# (state/<session>.<sha256(root)[:16]>.head); the start folder's repo also reads the
# <session>.head of hooks before v0.1.3, so a running session does not resend its history.
head_state_file() { # root
  printf '%s/state/%s.%s.head' "$NAWALA_DIR" "$(safe_name "$SESSION_ID")" "$(root_key "$1" | sha256 | cut -c1-16)"
}
collect_commits() { # dir head statefile [legacy statefile] -> prints a JSON file (array), or nothing
  local dir="$1" head="$2" last out pid i email
  [ -n "$dir" ] && [ -n "$head" ] || return 0
  last="$(cat "$3" 2>/dev/null)"
  [ -z "$last" ] && [ -n "${4:-}" ] && last="$(cat "$4" 2>/dev/null)"
  [ "$last" = "$head" ] && return 0
  out="$(mktemp "${TMPDIR:-/tmp}/nawala.git.XXXXXX")" || return 0
  if [ -n "$last" ] && git -C "$dir" cat-file -e "$last^{commit}" 2>/dev/null; then
    ( git -C "$dir" log --no-color --numstat -n 50 --format='%H%x09%ae%x09%aI%x09%P' "$last..$head" >"$out" 2>/dev/null ) &
  else
    email="$(git -C "$dir" config user.email 2>/dev/null)"
    [ -n "$email" ] || { rm -f "$out"; return 0; }
    ( git -C "$dir" log --no-color --numstat -n 50 --since='24 hours ago' --author="$email" --format='%H%x09%ae%x09%aI%x09%P' "$head" >"$out" 2>/dev/null ) &
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

# prepare_commits (stop only, main shell): COMMITS_FILE = commits of the event's repo; REPOS_FILE
# = one {cwd, git, commits} line per OTHER tracked repo this session edited that has new
# commits (max 20); HEAD_UPDATES = "statefile<TAB>head" lines, written once the event is built.
COMMITS_FILE=""; REPOS_FILE=""; HEAD_UPDATES=""
prepare_commits() {
  local root state legacy pk f n=0
  [ "$MODE" = "stop" ] || return 0
  legacy="$NAWALA_DIR/state/$(safe_name "$SESSION_ID").head"
  pk="$(root_key "$EV_ROOT")"
  if [ -n "$EV_ROOT" ] && [ -n "$EV_HEAD" ]; then
    state="$(head_state_file "$EV_ROOT")"
    if [ "$pk" = "$(root_key "$CWD_ROOT")" ]; then
      COMMITS_FILE="$(collect_commits "$EV_ROOT" "$EV_HEAD" "$state" "$legacy")"
    else
      COMMITS_FILE="$(collect_commits "$EV_ROOT" "$EV_HEAD" "$state")"
    fi
    HEAD_UPDATES="$state	$EV_HEAD"
  fi
  REPOS_FILE="$(mktemp "${TMPDIR:-/tmp}/nawala.repos.XXXXXX")" || { REPOS_FILE=""; return 0; }
  while IFS= read -r root <&3; do
    [ "$n" -lt 20 ] || break
    [ -n "$root" ] || continue
    [ -n "$pk" ] && [ "$(root_key "$root")" = "$pk" ] && continue
    describe_dir "$root"
    if [ -z "$GIT_ROOT" ] || [ -z "$GIT_HEAD" ] || [ "$(root_key "$GIT_ROOT")" != "$(root_key "$root")" ]; then continue; fi
    is_tracked_dir "$GIT_ROOT" || continue
    state="$(head_state_file "$GIT_ROOT")"
    f="$(collect_commits "$GIT_ROOT" "$GIT_HEAD" "$state")"
    HEAD_UPDATES="$HEAD_UPDATES
$state	$GIT_HEAD"
    [ -n "$f" ] || continue
    if jq -e 'type == "array" and length > 0' "$f" >/dev/null 2>&1; then
      jq -nc --arg cwd "$GIT_ROOT" --arg remote "$GIT_REMOTE" --arg branch "$GIT_BRANCH" --arg head "$GIT_HEAD" \
        --arg root "$GIT_ROOT" --slurpfile commits "$f" '
        def nn: if . == "" then null else . end;
        { cwd: $cwd, git: { remote: ($remote|nn), branch: ($branch|nn), head: ($head|nn), root: ($root|nn) },
          commits: $commits[0] }' >>"$REPOS_FILE" 2>/dev/null && n=$((n + 1))
    fi
    rm -f "$f"
  done 3<<EOF
$(touched_roots)
EOF
}
cleanup_commits() { rm -f "$COMMITS_FILE" "$REPOS_FILE"; COMMITS_FILE=""; REPOS_FILE=""; }
save_heads() {
  local state head
  while IFS="	" read -r state head; do
    [ -n "$state" ] && [ -n "$head" ] && printf '%s\n' "$head" >"$state"
  done <<EOF
$HEAD_UPDATES
EOF
}

# ---- build the event (allow-listed, scrubbed) ------------------------------------------------
# Built from the hook's own variables only: the agent's raw payload ($INPUT) is not passed in.
# Needs resolve_target (EV_*) and, on stop, prepare_commits.
build_event() {
  local id ts event
  id="$(new_uuid)" || return 1
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  event="$(jq -nc \
    --arg id "$id" --arg type "$MODE" --arg ts "$ts" --arg cwd "$EV_CWD" --arg sid "$SESSION_ID" \
    --arg agent "$REAL_AGENT" --arg hookSource "$AGENT" --arg dedupe "$DEDUPE_KEY" --arg ver "$NAWALA_HOOK_VERSION" \
    --arg remote "$EV_REMOTE" --arg branch "$EV_BRANCH" --arg head "$EV_HEAD" --arg root "$EV_ROOT" \
    --argjson norm "$NORM" --slurpfile commits "${COMMITS_FILE:-/dev/null}" \
    --slurpfile repos "${REPOS_FILE:-/dev/null}" "$EVENT_JQ"'
      def nn: if . == "" then null else . end;
      {
        id: $id, type: $type, clientTs: $ts, sessionId: $sid, agent: $agent, hookSource: $hookSource,
        dedupeKey: ($dedupe | nn), clientVersion: $ver, cwd: $cwd,
        git: { remote: ($remote|nn), branch: ($branch|nn), head: ($head|nn), root: ($root|nn) },
        model: $norm.model, effort: $norm.effort,
        commits: (if $type == "stop" then ($commits[0] // []) else [] end),
        repos: (if $type == "stop" then $repos else [] end)
      } | clean_event
    ' 2>/dev/null)"
  [ -n "$event" ] || return 1
  printf '%s' "$event"
}

# --print-event: the same decision and event, from the cached tracking list only (no network);
# when nothing would be sent, the start folder is printed as before so there is always output.
if [ "$PRINT_EVENT" = "1" ]; then
  if ! resolve_target; then describe_dir "$CWD"; CWD_ROOT="$GIT_ROOT"; set_target "$CWD"; fi
  ensure_session || exit 0
  DEDUPE_KEY="$(dedupe_key)"
  prepare_commits
  build_event | jq . 2>/dev/null
  cleanup_commits
  exit 0
fi

# ---- everything below runs in the background ------------------------------------------------
nawala_main() {
  umask 077
  tidy_spool # before the tracking check: old spooled prompts go away in any repo
  if [ "$MODE" != "start" ]; then # start already decided in the foreground
    resolve_target || { mark_run "$(untracked_reason)"; return 0; }
    ensure_session || { mark_run no-session; return 0; }
  fi
  mkdir -p "$NAWALA_DIR" "$NAWALA_DIR/state" 2>/dev/null || return 0
  DEDUPE_KEY="$(dedupe_key)"
  claim_once || { mark_run duplicate; return 0; }
  antigravity_new_prompt || return 0
  # housekeeping: forget dedupe keys older than a day (only our own <key>/ts entries)
  local d now; now="$(date +%s)"
  for d in "$NAWALA_DIR"/state/dedupe/*/; do
    [ -f "${d}ts" ] || continue
    [ $((now - $(cat "${d}ts" 2>/dev/null || echo "$now"))) -gt 86400 ] && rm -f "${d}ts" && rmdir "$d" 2>/dev/null
  done

  local event
  prepare_commits
  event="$(build_event)" || { cleanup_commits; return 0; }
  cleanup_commits
  save_heads

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
  if retryable "$code"; then spool_append "$event"; mark_run "spooled:${code:-000}"; else mark_run "sent:$code"; fi
  cleanup_auth
  return 0
}

# Foreground marker: if the agent kills the background job, the doctor shows "started" instead of an outcome.
mark_run started
if [ "${NAWALA_HOOK_SYNC:-0}" = "1" ]; then
  ( nawala_main ) </dev/null >/dev/null 2>&1
else
  ( nawala_main ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
exit 0
