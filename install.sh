#!/usr/bin/env bash
# Nawala agent setup - connects AI coding agents to a Nawala server.
# https://github.com/skyshi-labs/nawala-agent-setup  (MIT)
#
#   install.sh --agent <name>[,<name>...] --url https://nawala.example.com [--dry-run] [--yes]
#   install.sh --uninstall [--agent <name>] [--dry-run] [--yes]
#
# Agents: claude codex cursor kiro antigravity opencode grok muse, or all-detected.
#
# Options
#   --agent LIST       comma-separated agents, or `all-detected` (required for install)
#   --url URL          Nawala server, https:// (http:// only for localhost)   (required for install)
#   --token TOKEN      personal API token nwl_... ; better: env NAWALA_TOKEN or the silent prompt
#   --dry-run          print every file that would change (unified diff, token masked) and every
#                      network call, then exit 0 without changing anything
#   --uninstall        remove exactly what this installer added; restore backups when the file
#                      was not changed since, otherwise remove only the Nawala entries
#   --yes              do not ask for confirmation
#   --experimental     also install hooks whose format is not verified (kiro)
#   --project-dir DIR  muse only: put the instruction block in DIR/AGENTS.md (Muse has no
#                      documented user-global instruction file)
#   --full-diff        also show the full diff of ~/.nawala/hook.sh
#   --print-file NAME  print an embedded file (hook.sh, templates/...) and exit, for auditing
#   --version          print the version and exit
#
# What it never does: run as root, use sudo, download or eval anything, touch files other
# than the ones listed by --dry-run. The only network call is GET <url>/api/auth/me.
set -euo pipefail

NAWALA_SETUP_VERSION="0.1.0"
REPO="skyshi-labs/nawala-agent-setup"
ALL_AGENTS="claude codex cursor kiro antigravity opencode grok muse"

# >>> embedded files: filled by scripts/build-release.sh; the source tree reads files from disk
NAWALA_EMBEDDED=0
embedded_file() { return 1; }
# <<< embedded files

# ---- output -------------------------------------------------------------------------------
die() { printf 'nawala install: %s\n' "$*" | mask >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" | mask >&2; }
say() { printf '%s\n' "$*" | mask; }
mask() {
  # never let a token reach the terminal or a log
  if [ -n "${TOKEN:-}" ]; then
    local t="$TOKEN" line
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "${line//"$t"/nwl_****}"
    done | sed -E 's/nwl_[A-Za-z0-9_-]{8,}/nwl_****/g'
  else
    sed -E 's/nwl_[A-Za-z0-9_-]{8,}/nwl_****/g'
  fi
}

usage() { sed -n '2,29p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//' || true; }

# ---- arguments ----------------------------------------------------------------------------
AGENTS_ARG=""
URL="${NAWALA_URL:-}"
TOKEN="${NAWALA_TOKEN:-}"
DRY_RUN=0
UNINSTALL=0
YES=0
EXPERIMENTAL=0
PROJECT_DIR=""
FULL_DIFF=0
PRINT_FILE=""

need_arg() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 needs a value"; fi; }
while [ $# -gt 0 ]; do
  case "$1" in
    --agent|--agents) need_arg "$@"; AGENTS_ARG="$2"; shift ;;
    --agent=*) AGENTS_ARG="${1#*=}" ;;
    --url) need_arg "$@"; URL="$2"; shift ;;
    --url=*) URL="${1#*=}" ;;
    --token) need_arg "$@"; TOKEN="$2"; shift ;;
    --token=*) TOKEN="${1#*=}" ;;
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --yes|-y) YES=1 ;;
    --experimental) EXPERIMENTAL=1 ;;
    --project-dir) need_arg "$@"; PROJECT_DIR="$2"; shift ;;
    --full-diff) FULL_DIFF=1 ;;
    --print-file) need_arg "$@"; PRINT_FILE="$2"; shift ;;
    --version) echo "nawala-agent-setup $NAWALA_SETUP_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Files shipped with the installer. A release build embeds them, so a stray file next to a
# downloaded install.sh can never change what gets installed.
get_file() {
  case "$1" in *..*|/*) die "bad file name: $1" ;; esac
  if [ "$NAWALA_EMBEDDED" = "1" ]; then
    embedded_file "$1" || die "no embedded file $1"
  else
    if [ -z "$SELF_DIR" ] || [ ! -f "$SELF_DIR/$1" ]; then die "missing $1 next to install.sh (run it from a checkout or use the release asset)"; fi
    cat "$SELF_DIR/$1"
  fi
}

if [ -n "$PRINT_FILE" ]; then get_file "$PRINT_FILE"; exit 0; fi

# ---- preflight ----------------------------------------------------------------------------
[ "$(id -u)" != "0" ] || die "do not run as root (no sudo needed: everything goes into your home directory)"
if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then die "HOME is not set"; fi
command -v jq >/dev/null 2>&1 || die "jq is required (macOS: brew install jq; Debian/Ubuntu: apt install jq)"
command -v diff >/dev/null 2>&1 || die "diff is required"
umask 077

NAWALA_DIR="$HOME/.nawala"
MANIFEST="$NAWALA_DIR/manifest.tsv"
BACKUPS="$NAWALA_DIR/backups"
HOOK_PATH="$NAWALA_DIR/hook.sh"
CONFIG_PATH="$NAWALA_DIR/config"
case "$HOOK_PATH" in *" "*) HOOK_CMD="\"$HOOK_PATH\"" ;; *) HOOK_CMD="$HOOK_PATH" ;; esac

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else openssl dgst -sha256 | sed 's/^.*= *//'
  fi
}
file_sha() { if [ -f "$1" ]; then sha256 <"$1"; else echo "-"; fi; }
path_key() { printf '%s' "$1" | sha256 | cut -c1-24; }
# shellcheck disable=SC2088 # a literal ~ is intended: it is only for display
pretty() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

octal_mode() { # portable octal permission bits of a path (GNU and BSD stat)
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nawala-setup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/plan"
: >"$WORK/plan.tsv"     # op <TAB> path <TAB> perm      (op: write|delete)
: >"$WORK/ops.tsv"      # manifest rows to add: agent kind path op arg

# ---- agent selection ----------------------------------------------------------------------
detect_agent() {
  case "$1" in
    claude) [ -d "$HOME/.claude" ] || [ -f "$HOME/.claude.json" ] || command -v claude >/dev/null 2>&1 ;;
    codex) [ -d "$HOME/.codex" ] || command -v codex >/dev/null 2>&1 ;;
    cursor) [ -d "$HOME/.cursor" ] || command -v cursor-agent >/dev/null 2>&1 ;;
    kiro) [ -d "$HOME/.kiro" ] || command -v kiro-cli >/dev/null 2>&1 ;;
    antigravity) [ -d "$HOME/.gemini/config" ] || command -v agy >/dev/null 2>&1 || command -v antigravity >/dev/null 2>&1 ;;
    opencode) [ -d "$HOME/.config/opencode" ] || command -v opencode >/dev/null 2>&1 ;;
    grok) [ -d "$HOME/.grok" ] || command -v grok >/dev/null 2>&1 ;;
    muse) [ -d "$HOME/.config/muse" ] || command -v muse >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

AGENTS=""
add_agent() { case " $AGENTS " in *" $1 "*) ;; *) AGENTS="${AGENTS:+$AGENTS }$1" ;; esac; }
parse_agents() {
  local a d list
  list="$(printf '%s' "$1" | tr ',' ' ')"
  for a in $list; do
    case "$a" in
      all-detected) for d in $ALL_AGENTS; do if detect_agent "$d"; then add_agent "$d"; fi; done ;;
      claude|codex|cursor|kiro|antigravity|opencode|grok|muse) add_agent "$a" ;;
      *) die "unknown agent '$a' (choose from: $ALL_AGENTS, all-detected)" ;;
    esac
  done
}

# ---- planning primitives ------------------------------------------------------------------
# Every change is planned first (content in $WORK/plan/<key>), shown as a diff, confirmed,
# and only then applied. Several operations on one file build on each other's planned content.
planned_file() { printf '%s/plan/%s' "$WORK" "$(path_key "$1")"; }
current_into() { # path dest : copy the current (planned or on-disk) content
  local p; p="$(planned_file "$1")"
  if [ -f "$p" ]; then cp "$p" "$2"
  elif [ -f "$p.deleted" ]; then : >"$2"
  elif [ -f "$1" ]; then cat "$1" >"$2"
  else : >"$2"
  fi
}
exists_now() { local p; p="$(planned_file "$1")"; [ -f "$p" ] || { [ ! -f "$p.deleted" ] && [ -f "$1" ]; }; }
plan_write() { # path srcfile perm
  local p; p="$(planned_file "$1")"
  cp "$2" "$p"; rm -f "$p.deleted"
  grep -q -F "	$1	" "$WORK/plan.tsv" 2>/dev/null || printf 'write\t%s\t%s\n' "$1" "$3" >>"$WORK/plan.tsv"
}
plan_delete() {
  local p; p="$(planned_file "$1")"
  rm -f "$p"; : >"$p.deleted"
  grep -q -F "	$1	" "$WORK/plan.tsv" 2>/dev/null || printf 'write\t%s\t-\n' "$1" >>"$WORK/plan.tsv"
}
record() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:--}" >>"$WORK/ops.tsv"; }

# Replace the placeholders of a template. Values never pass through argv (token via env).
# The MCP URL carries ?agent=<name> (the template's folder) so the server can attribute MCP-only sessions.
render_json() { # template
  get_file "templates/$1" | NWL_AUTH="Bearer $TOKEN" NWL_URL="$MCP_URL?agent=${1%%/*}" NWL_HOOK="$HOOK_CMD" jq '
    def fill: if type == "object" then map_values(fill)
      elif type == "array" then map(fill)
      elif type == "string" then
        (if . == "__NAWALA_AUTH__" then $ENV.NWL_AUTH else . end)
        | gsub("__NAWALA_MCP_URL__"; $ENV.NWL_URL) | gsub("__NAWALA_HOOK__"; $ENV.NWL_HOOK)
      else . end;
    fill'
}
render_text() { # template
  local s
  s="$(get_file "templates/$1"; printf x)"; s="${s%x}"
  s="${s//__NAWALA_AUTH__/Bearer $TOKEN}"
  s="${s//__NAWALA_MCP_URL__/$MCP_URL?agent=${1%%/*}}"
  s="${s//__NAWALA_URL__/$URL}"
  s="${s//__NAWALA_HOOK__/$HOOK_CMD}"
  printf '%s' "$s"
}

# shellcheck disable=SC2016 # jq program, $vars are jq variables
JQ_LIB='
def is_nawala: (.command // "") | test("\\.nawala/hook\\.sh");
def strip_groups: map(if (type == "object") and ((.hooks | type) == "array") and any(.hooks[]; is_nawala)
                      then (.hooks |= map(select(is_nawala | not))) | select(.hooks | length > 0) else . end);
def strip_flat: map(select((type == "object" and is_nawala) | not));
def drop_empty_hooks: if (.hooks | type) == "object" then
    (.hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0)))
    | if .hooks == {} then del(.hooks) else . end
  else . end;
def drop_empty_parents($p): if ($p | length) > 1 and (getpath($p[:-1]) == {}) then delpaths([$p[:-1]]) | drop_empty_parents($p[:-1]) else . end;
def apply_op($op; $p; $tpl):
  if $op == "set" then setpath($p; $tpl)
  elif $op == "hooks-claude" then
    .hooks = (reduce ($tpl | keys_unsorted[]) as $ev ((.hooks // {});
      .[$ev] = (((.[$ev] // []) | strip_groups) + $tpl[$ev])))
  elif $op == "hooks-cursor" then
    (.version //= 1)
    | .hooks = (reduce ($tpl | keys_unsorted[]) as $ev ((.hooks // {});
      .[$ev] = (((.[$ev] // []) | strip_flat) + $tpl[$ev])))
  else error("unknown op") end;
def remove_op($op; $p):
  if $op == "set" then (if getpath($p) != null then delpaths([$p]) | drop_empty_parents($p) else . end)
  elif $op == "hooks-claude" then
    (if (.hooks | type) == "object" then .hooks |= with_entries(.value |= (if type == "array" then strip_groups else . end)) else . end) | drop_empty_hooks
  elif $op == "hooks-cursor" then
    (if (.hooks | type) == "object" then .hooks |= with_entries(.value |= (if type == "array" then strip_flat else . end)) else . end) | drop_empty_hooks
  else . end;
'

# JSON merge: back up, keep every other entry, idempotent (no write if semantically equal).
plan_json() { # agent path op jsonpath template [seed-json]
  local agent="$1" path="$2" op="$3" jpath="$4" tpl="$5" seed="${6:-}"
  [ -n "$seed" ] || seed='{}'
  local cur="$WORK/cur.json" new="$WORK/new.json" tplf="$WORK/tpl.json"
  current_into "$path" "$cur"
  if [ -s "$cur" ] && ! jq -e 'type == "object"' "$cur" >/dev/null 2>&1; then
    die "$(pretty "$path") is not plain JSON (comments or a syntax error?). Fix it or add the Nawala entry by hand (see templates/$tpl); nothing was changed"
  fi
  [ -s "$cur" ] || printf '%s\n' "$seed" >"$cur"
  render_json "$tpl" >"$tplf" || die "cannot render template $tpl"
  jq --argjson p "$jpath" --arg op "$op" --slurpfile tpl "$tplf" "$JQ_LIB"'apply_op($op; $p; $tpl[0])' "$cur" >"$new" \
    || die "cannot merge into $(pretty "$path")"
  record "$agent" json "$path" "$op" "$jpath"
  if exists_now "$path" && [ "$(jq -S -c . "$cur")" = "$(jq -S -c . "$new")" ]; then return 0; fi
  if [ "$op" = "set" ]; then plan_write "$path" "$new" secret; else plan_write "$path" "$new" 600; fi
}

# Marked block in a text file (TOML or Markdown). Everything outside the markers is kept.
strip_block() { # start end < in > out   (also drops one blank line right before the block)
  awk -v s="$1" -v e="$2" '
    BEGIN { held = 0; inb = 0 }
    { if (inb) { if (index($0, e) == 1) inb = 0; next }
      if (index($0, s) == 1) { inb = 1; if (held && prev == "") held = 0; next }
      if (held) print prev
      prev = $0; held = 1 }
    END { if (held) print prev }'
}
plan_block() { # agent path kind(toml|md) template [conflict-regex]
  local agent="$1" path="$2" kind="$3" tpl="$4" conflict="${5:-}" start end
  local cur="$WORK/cur.txt" new="$WORK/new.txt"
  if [ "$kind" = "toml" ]; then
    start="# nawala:start"; end="# nawala:end"
  else
    start="<!-- nawala:start -->"; end="<!-- nawala:end -->"
  fi
  current_into "$path" "$cur"
  strip_block "$start" "$end" <"$cur" >"$new"
  if [ -n "$conflict" ] && grep -Eq "$conflict" "$new"; then
    die "$(pretty "$path") already configures a 'nawala' MCP server outside the Nawala markers; remove it first (nothing was changed)"
  fi
  {
    [ -s "$new" ] && printf '\n'
    if [ "$kind" = "toml" ]; then
      printf '%s (managed by nawala-agent-setup; remove with install.sh --uninstall)\n' "$start"
    else
      printf '%s\n' "$start"
    fi
    render_text "$tpl"
    printf '%s\n' "$end"
  } >>"$new"
  record "$agent" block "$path" "$kind" "-"
  if exists_now "$path" && cmp -s "$cur" "$new"; then return 0; fi
  if [ "$kind" = "toml" ]; then plan_write "$path" "$new" secret; else plan_write "$path" "$new" 600; fi
}

# A file that belongs to Nawala entirely (e.g. ~/.kiro/steering/nawala.md).
plan_owned() { # agent path template
  local agent="$1" path="$2" tpl="$3" cur="$WORK/cur.txt" new="$WORK/new.txt"
  current_into "$path" "$cur"
  if [ -s "$cur" ] && ! grep -Eq 'nawala:start|\.nawala/hook\.sh' "$cur"; then
    die "$(pretty "$path") exists and was not created by this installer; move it away first (nothing was changed)"
  fi
  render_text "$tpl" >"$new"
  record "$agent" owned "$path" "-" "-"
  if exists_now "$path" && cmp -s "$cur" "$new"; then return 0; fi
  plan_write "$path" "$new" 600
}

TOML_CONFLICT='^[[:space:]]*\[[[:space:]]*mcp_servers\.("nawala"|nawala)[[:space:]]*\]'
NOTES=""
note() { NOTES="${NOTES}  - $*
"; }

# ---- per-agent plans ----------------------------------------------------------------------
# Paths and formats: see templates/README.md and the research notes in SECURITY.md.
plan_agent() {
  case "$1" in
    claude)
      plan_json claude "$HOME/.claude.json" set '["mcpServers","nawala"]' claude/mcp.json
      plan_json claude "$HOME/.claude/settings.json" hooks-claude '[]' claude/hooks.json
      ;;
    codex)
      plan_block codex "$HOME/.codex/config.toml" toml codex/mcp.toml "$TOML_CONFLICT"
      plan_json codex "$HOME/.codex/hooks.json" hooks-claude '[]' codex/hooks.json
      note "codex: open Codex and approve the new hooks once with /hooks (Codex asks you to trust new or changed hooks)"
      ;;
    cursor)
      plan_json cursor "$HOME/.cursor/mcp.json" set '["mcpServers","nawala"]' cursor/mcp.json
      plan_json cursor "$HOME/.cursor/hooks.json" hooks-cursor '[]' cursor/hooks.json '{"version":1}'
      ;;
    kiro)
      plan_json kiro "$HOME/.kiro/settings/mcp.json" set '["mcpServers","nawala"]' kiro/mcp.json
      plan_owned kiro "$HOME/.kiro/steering/nawala.md" kiro/steering.md
      if [ "$EXPERIMENTAL" = "1" ]; then
        plan_owned kiro "$HOME/.kiro/hooks/nawala.json" kiro/hooks.experimental.json
        note "kiro: EXPERIMENTAL hooks written to ~/.kiro/hooks/nawala.json (Kiro CLI only; payload format unverified)"
      fi
      ;;
    antigravity)
      plan_json antigravity "$HOME/.gemini/config/mcp_config.json" set '["mcpServers","nawala"]' antigravity/mcp.json
      plan_block antigravity "$HOME/.gemini/GEMINI.md" md instructions.md
      note "antigravity: no hooks installed (no prompt-submit event); tracking relies on the GEMINI.md block + MCP tools. GEMINI.md is also read by Gemini CLI"
      ;;
    opencode)
      local oc="$HOME/.config/opencode/opencode.json"
      [ -f "$HOME/.config/opencode/opencode.jsonc" ] && [ ! -f "$oc" ] && \
        die "found ~/.config/opencode/opencode.jsonc; jq cannot edit JSONC safely. Add the server by hand (templates/opencode/mcp.json) and re-run with the other agents"
      if [ -f "$oc" ] && jq -e '(.mcp | type) == "object" and (.mcp.nawala != null)' "$oc" >/dev/null 2>&1; then
        die "$(pretty "$oc") has a legacy flat mcp.nawala entry; remove it first (nothing was changed)"
      fi
      plan_json opencode "$oc" set '["mcp","servers","nawala"]' opencode/mcp.json
      plan_block opencode "$HOME/.config/opencode/AGENTS.md" md instructions.md
      note "opencode: no plugin installed (plugin API is changing); tracking relies on AGENTS.md + MCP tools"
      ;;
    grok)
      plan_block grok "$HOME/.grok/config.toml" toml grok/mcp.toml "$TOML_CONFLICT"
      plan_json grok "$HOME/.grok/hooks/nawala.json" hooks-claude '[]' grok/hooks.json
      plan_owned grok "$HOME/.grok/rules/nawala.md" grok/rules.md
      note "grok: Grok also runs Claude Code/Cursor hooks; duplicates are dropped by hook.sh (same session + turn)"
      ;;
    muse)
      plan_json muse "$HOME/.config/muse/settings.json" set '["mcp_servers","nawala"]' muse/mcp.json '{"schema_version":1}'
      if [ -n "$PROJECT_DIR" ]; then
        [ -d "$PROJECT_DIR" ] || die "--project-dir $PROJECT_DIR is not a directory"
        plan_block muse "$(cd "$PROJECT_DIR" && pwd)/AGENTS.md" md instructions.md
      else
        note "muse: Muse Code has no documented user-global instruction file; re-run with --project-dir <repo> to add the block to <repo>/AGENTS.md"
      fi
      note "muse: MCP entry shape is inferred from Muse docs (unverified); check it with /mcp in Muse"
      ;;
  esac
}

plan_core() {
  local cfg="$WORK/config.new" hook="$WORK/hook.new" agents="$AGENTS" old
  if [ -f "$CONFIG_PATH" ]; then
    old="$(sed -n 's/^NAWALA_AGENTS=//p' "$CONFIG_PATH" | tail -n 1 | tr ',' ' ')"
    for a in $old; do case " $agents " in *" $a "*) ;; *) agents="$agents $a" ;; esac; done
  fi
  agents="$(printf '%s' "$agents" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')"
  write_config "$cfg" "$agents"
  current_into "$CONFIG_PATH" "$WORK/cur.cfg"
  cmp -s "$cfg" "$WORK/cur.cfg" || plan_write "$CONFIG_PATH" "$cfg" secret
  get_file hook.sh >"$hook"
  if ! { [ -f "$HOOK_PATH" ] && cmp -s "$hook" "$HOOK_PATH"; }; then plan_write "$HOOK_PATH" "$hook" 700; fi
  record core core "$CONFIG_PATH" - -
  record core core "$HOOK_PATH" - -
}
write_config() { # dest agents
  {
    echo "# Nawala agent setup $NAWALA_SETUP_VERSION - managed by install.sh (keep this file 0600)"
    echo "NAWALA_URL=$URL"
    echo "NAWALA_TOKEN=$TOKEN"
    echo "NAWALA_AGENTS=$2"
  } >"$1"
}

# ---- manifest -----------------------------------------------------------------------------
# One row per change: agent kind path op arg existed restore sha_after
#   restore = backup (file untouched since: uninstall restores the backup byte-for-byte)
#           | surgical (file changed by someone else: uninstall removes only Nawala entries)
manifest_rows() { if [ -f "$MANIFEST" ]; then cat "$MANIFEST"; fi; }
backup_path() { printf '%s/%s.orig' "$BACKUPS" "$(path_key "$1")"; }

# ---- show the plan ------------------------------------------------------------------------
show_plan() {
  local op path perm p label changed=0
  while IFS="	" read -r op path perm; do
    [ -n "$path" ] || continue
    changed=1
    p="$(planned_file "$path")"
    label="$(pretty "$path")"
    if [ -f "$p.deleted" ]; then
      say "--- delete $label"
      if [ "$path" = "$HOOK_PATH" ] && [ "$FULL_DIFF" != "1" ]; then continue; fi
      diff -u --label "a/$label" --label "/dev/null" "$path" /dev/null 2>/dev/null | mask || true
    elif [ "$path" = "$HOOK_PATH" ] && [ "$FULL_DIFF" != "1" ]; then
      if [ -f "$path" ]; then say "--- update $label (mode 0700) -> $(wc -l <"$p" | tr -d ' ') lines, sha256 $(sha256 <"$p")"
      else say "--- create $label (mode 0700): $(wc -l <"$p" | tr -d ' ') lines, sha256 $(sha256 <"$p")"; fi
      say "    (the hook.sh of release v$NAWALA_SETUP_VERSION; view it with: install.sh --print-file hook.sh, or add --full-diff)"
    elif [ -f "$path" ]; then
      say "--- modify $label"
      diff -u --label "a/$label" --label "b/$label" "$path" "$p" | mask || true
    else
      say "--- create $label"
      diff -u --label /dev/null --label "b/$label" /dev/null "$p" | mask || true
    fi
  done <"$WORK/plan.tsv"
  [ "$changed" = "1" ] || say "No file changes needed (already installed)."
}

confirm() {
  [ "$YES" = "1" ] && return 0
  if [ -r /dev/tty ] && [ -w /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
    local ans=""
    printf '%s [y/N] ' "$1" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    case "$ans" in y|Y|yes|YES|Yes) return 0 ;; esac
    die "aborted; nothing was changed"
  fi
  die "no terminal to confirm; re-run with --yes after reviewing --dry-run (nothing was changed)"
}

# ---- apply --------------------------------------------------------------------------------
CREATED_DIRS=""
ensure_dir() { # dir agent
  local d="$1" missing="" x
  while [ ! -d "$d" ]; do missing="$d $missing"; d="$(dirname "$d")"; done
  for x in $missing; do
    mkdir -m 700 "$x" || die "cannot create $(pretty "$x")"
    CREATED_DIRS="$CREATED_DIRS $x"
    printf '%s\tdir\t%s\t-\t-\t0\tbackup\t-\n' "$2" "$x" >>"$MANIFEST"
  done
}

apply_plan() { # used by install and uninstall
  local op path perm p tmp
  while IFS="	" read -r op path perm; do
    [ -n "$path" ] || continue
    p="$(planned_file "$path")"
    if [ -f "$p.deleted" ]; then rm -f "$path"; continue; fi
    ensure_dir "$(dirname "$path")" "$(owner_of "$path")"
    tmp="$path.nawala-tmp.$$"
    if [ -f "$p.restore" ]; then
      # byte-for-byte restore of the original, including its mode
      cp -p "$(cat "$p.restore")" "$tmp"; mv -f "$tmp" "$path"; continue
    fi
    if [ -f "$path" ]; then cp -p "$path" "$tmp"; cat "$p" >"$tmp"; else cp "$p" "$tmp"; fi
    # secret: holds the token -> never readable by others; 700: the hook; keep: leave the mode as is
    case "$perm" in 700) chmod 700 "$tmp" ;; secret) chmod go-rwx "$tmp" ;; esac
    mv -f "$tmp" "$path"
  done <"$WORK/plan.tsv"
}
owner_of() { awk -F'\t' -v p="$1" '$3 == p { print $1; exit }' "$WORK/ops.tsv"; }

do_install() {
  [ -n "$AGENTS_ARG" ] || die "--agent is required (one of: $ALL_AGENTS, all-detected)"
  parse_agents "$AGENTS_ARG"
  [ -n "$AGENTS" ] || die "no supported agent detected; pass --agent explicitly"
  [ -n "$URL" ] || die "--url is required (e.g. --url https://nawala.skyshi.com)"
  URL="${URL%/}"
  printf '%s' "$URL" | grep -Eq '^(https://[A-Za-z0-9.-]+(:[0-9]{1,5})?|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?)(/[A-Za-z0-9._~/-]*)?$' \
    || die "--url must look like https://host[/path] (http:// only for localhost)"
  MCP_URL="$URL/mcp"
  if [ -z "$TOKEN" ] && [ "$DRY_RUN" != "1" ] && [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
    printf 'Nawala API token (nwl_..., input hidden): ' >/dev/tty
    IFS= read -rs TOKEN </dev/tty || TOKEN=""
    printf '\n' >/dev/tty
  fi
  if [ -z "$TOKEN" ] && [ "$DRY_RUN" = "1" ]; then
    TOKEN="nwl_DRYRUNPLACEHOLDERDRYRUNPLACEHOLDER0"
    say "# no token given: the dry run uses a placeholder token"
  fi
  [ -n "$TOKEN" ] || die "a token is required: env NAWALA_TOKEN, --token, or the prompt (create one in the Nawala web app)"
  printf '%s' "$TOKEN" | grep -Eq '^nwl_[A-Za-z0-9_-]{16,200}$' || die "the token does not look like a Nawala token (nwl_...)"

  if [ -f "$CONFIG_PATH" ] && [ ! -f "$MANIFEST" ]; then
    note "found a legacy ~/.nawala (old server installer); its config and hook.sh are backed up and replaced, legacy Claude hooks are upgraded in place"
  fi

  local a
  for a in $AGENTS; do plan_agent "$a"; done
  plan_core

  say "Nawala agent setup v$NAWALA_SETUP_VERSION  (${REPO})"
  say "Agents: $AGENTS    Server: $URL"
  say ""
  show_plan
  say ""
  say "Network calls by this installer:"
  say "  GET $URL/api/auth/me   (Authorization: Bearer nwl_****; checks the token before anything is written)"
  say "Network calls the installed hooks will make (in the background, fail-open):"
  say "  POST $URL/v1/events   (scrubbed prompt text, transcript tail on stop, git remote/branch/HEAD, commit metadata)"
  say "  GET  $URL/v1/rules    (on session start: project rules, 2s timeout)"
  say "MCP clients will connect to: $MCP_URL"
  [ -z "$NOTES" ] || { say ""; say "Notes:"; printf '%s' "$NOTES" | mask; }

  if [ "$DRY_RUN" = "1" ]; then
    say ""
    say "Dry run: nothing was changed and no network call was made."
    exit 0
  fi
  say ""
  confirm "Apply these changes?"

  verify_token
  install_apply
  say ""
  say "Installed Nawala for: $AGENTS ($URL) as $ME_EMAIL. Disable anytime with NAWALA_OFF=1; remove with install.sh --uninstall."
  [ -z "$NOTES" ] || say "Next: see the notes above (restart the agents to load the new MCP server)."
}

ME_EMAIL=""
verify_token() {
  command -v curl >/dev/null 2>&1 || die "curl is required"
  local hdr="$WORK/auth.hdr" body="$WORK/me.json" code
  printf 'Authorization: Bearer %s\n' "$TOKEN" >"$hdr"
  code="$(curl -sS -m 15 -o "$body" -w '%{http_code}' -H @"$hdr" "$URL/api/auth/me" 2>/dev/null)" || code="000"
  rm -f "$hdr"
  [ "$code" = "200" ] || die "token check failed: GET $URL/api/auth/me returned HTTP $code (wrong URL or revoked token?). Nothing was changed"
  ME_EMAIL="$(jq -r '.user.email // .email // "your account"' "$body" 2>/dev/null || echo "your account")"
}

install_apply() {
  local path existed restore before after b agent kind op arg rows
  local orig_dir_mode=""
  if [ -d "$NAWALA_DIR" ] && [ ! -f "$MANIFEST" ]; then orig_dir_mode="$(octal_mode "$NAWALA_DIR")"; elif [ ! -d "$NAWALA_DIR" ]; then mkdir -m 700 "$NAWALA_DIR"; NEW_NAWALA_DIR=1; fi
  mkdir -p "$BACKUPS"; chmod 700 "$NAWALA_DIR" "$BACKUPS"
  # remember the mode of a pre-existing ~/.nawala (old installer) so uninstall can put it back
  if [ -n "$orig_dir_mode" ] && [ ! -f "$BACKUPS/.nawala-dir-mode" ]; then printf '%s\n' "$orig_dir_mode" >"$BACKUPS/.nawala-dir-mode"; fi
  touch "$MANIFEST"; chmod 600 "$MANIFEST"
  if [ "${NEW_NAWALA_DIR:-0}" = "1" ]; then printf 'core\tdir\t%s\t-\t-\t0\tbackup\t-\n' "$NAWALA_DIR" >>"$MANIFEST"; fi

  # back up every file before its first change (never overwrite an earlier backup)
  while IFS="	" read -r _ path _; do
    [ -n "$path" ] || continue
    b="$(backup_path "$path")"
    if [ -f "$path" ] && [ ! -f "$b" ]; then cp -p "$path" "$b"; fi
  done <"$WORK/plan.tsv"

  # remember the sha before applying, to detect files someone else changed since our last run
  rows="$WORK/before.tsv"; : >"$rows"
  while IFS="	" read -r agent kind path op arg; do
    printf '%s\t%s\n' "$path" "$(file_sha "$path")" >>"$rows"
  done <"$WORK/ops.tsv"

  apply_plan

  # update the manifest
  local newm="$WORK/manifest.new"
  cp "$MANIFEST" "$newm"
  while IFS="	" read -r agent kind path op arg; do
    before="$(awk -F'\t' -v p="$path" '$1 == p { print $2; exit }' "$rows")"
    after="$(file_sha "$path")"
    local prev
    prev="$(awk -F'\t' -v a="$agent" -v p="$path" -v o="$op" '$1 == a && $3 == p && $4 == o { print; exit }' "$newm")"
    if [ -n "$prev" ]; then
      existed="$(printf '%s' "$prev" | cut -f6)"
      restore="$(printf '%s' "$prev" | cut -f7)"
      # someone else edited the file since our last write: the backup is no longer a safe restore
      [ "$(printf '%s' "$prev" | cut -f8)" = "$before" ] || restore=surgical
      awk -F'\t' -v a="$agent" -v p="$path" -v o="$op" '!($1 == a && $3 == p && $4 == o)' "$newm" >"$newm.x" && mv "$newm.x" "$newm"
    else
      if [ -f "$(backup_path "$path")" ]; then existed=1; else existed=0; fi
      restore=backup
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$agent" "$kind" "$path" "$op" "$arg" "$existed" "$restore" "$after" >>"$newm"
  done <"$WORK/ops.tsv"
  # other agents' rows on a file we just rewrote point at the new content now
  while IFS="	" read -r _ path _; do printf '%s\t%s\n' "$path" "$(file_sha "$path")"; done <"$WORK/plan.tsv" >"$WORK/shas.tsv"
  awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { sha[$1] = $2; next } ($3 in sha) && $2 != "dir" { $8 = sha[$3] } { print }' \
    "$WORK/shas.tsv" "$newm" >"$newm.x"
  mv "$newm.x" "$MANIFEST"
  chmod 600 "$MANIFEST"
}

# ---- uninstall ----------------------------------------------------------------------------
do_uninstall() {
  [ -f "$MANIFEST" ] || die "nothing to uninstall ($(pretty "$MANIFEST") not found)"
  local installed a sel
  installed="$(awk -F'\t' '$1 != "core" { print $1 }' "$MANIFEST" | sort -u | tr '\n' ' ')"
  if [ -n "$AGENTS_ARG" ]; then parse_agents "$AGENTS_ARG"; sel="$AGENTS"; else sel="$installed"; fi
  local remaining=""
  for a in $installed; do case " $sel " in *" $a "*) ;; *) remaining="${remaining:+$remaining }$a" ;; esac; done
  local shown
  shown="$(printf '%s' "$sel" | xargs)"
  [ -n "$remaining" ] || sel="$sel core"

  TOKEN="$(sed -n 's/^NAWALA_TOKEN=//p' "$CONFIG_PATH" 2>/dev/null | tail -n 1)"
  URL="$(sed -n 's/^NAWALA_URL=//p' "$CONFIG_PATH" 2>/dev/null | tail -n 1)"

  # files: restore the backup when untouched since our write, else remove only our entries
  local path rows
  rows="$WORK/sel.tsv"
  awk -F'\t' -v sel=" $sel " 'index(sel, " " $1 " ") > 0 && $2 != "dir"' "$MANIFEST" >"$rows"
  cut -f3 "$rows" | awk '!seen[$0]++' >"$WORK/paths.txt"
  while IFS= read -r path <&3; do
    if [ -n "$path" ]; then uninstall_path "$path" "$rows"; fi
  done 3<"$WORK/paths.txt"

  if [ -n "$remaining" ]; then
    local cfg="$WORK/config.new"
    write_config "$cfg" "$(printf '%s' "$remaining" | tr ' ' ',')"
    plan_write "$CONFIG_PATH" "$cfg" secret
  fi

  say "Nawala agent setup v$NAWALA_SETUP_VERSION - uninstall: $shown"
  say ""
  show_plan
  if [ -z "$remaining" ]; then
    say "--- delete $(pretty "$NAWALA_DIR")/{manifest.tsv,backups,state,rules,spool.jsonl} (when created by this installer)"
  fi
  [ -z "$NOTES" ] || { say ""; say "Notes:"; printf '%s' "$NOTES" | mask; }
  if [ "$DRY_RUN" = "1" ]; then say ""; say "Dry run: nothing was changed."; exit 0; fi
  say ""
  confirm "Remove Nawala from: $shown?"
  apply_plan

  # manifest bookkeeping and leftovers
  local newm="$WORK/manifest.new"
  awk -F'\t' -v sel=" $sel " 'index(sel, " " $1 " ") == 0' "$MANIFEST" >"$newm"
  local dirs
  dirs="$(awk -F'\t' -v sel=" $sel " 'index(sel, " " $1 " ") > 0 && $2 == "dir" { print length($3) "\t" $3 }' "$MANIFEST" | sort -rn | cut -f2-)"
  if [ -z "$remaining" ]; then
    if awk -F'\t' -v d="$NAWALA_DIR" '$2 == "dir" && $3 == d { f = 1 } END { exit !f }' "$MANIFEST"; then
      rm -rf "$BACKUPS" "$NAWALA_DIR/state" "$NAWALA_DIR/rules" "$NAWALA_DIR/spool.jsonl" "$NAWALA_DIR"/spool.jsonl.sending.* "$MANIFEST"
    else
      local dir_mode=""
      if [ -f "$BACKUPS/.nawala-dir-mode" ]; then dir_mode="$(cat "$BACKUPS/.nawala-dir-mode")"; fi
      rm -rf "$BACKUPS" "$MANIFEST"
      case "$dir_mode" in [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) chmod "$dir_mode" "$NAWALA_DIR" ;; esac
    fi
  else
    mv "$newm" "$MANIFEST"
  fi
  printf '%s\n' "$dirs" >"$WORK/dirs.txt"
  while IFS= read -r path <&3; do
    if [ -n "$path" ]; then rmdir "$path" 2>/dev/null || true; fi
  done 3<"$WORK/dirs.txt"
  say ""
  say "Removed Nawala from: $shown."
}

uninstall_path() { # path rows
  local path="$1" rows="$2" b cur restore existed new="$WORK/un.new" agent kind op arg
  b="$(backup_path "$path")"
  cur="$(file_sha "$path")"
  [ "$cur" != "-" ] || { note "$(pretty "$path") no longer exists; skipped"; return 0; }
  # all rows of this path in the manifest (all agents), and the selected ones
  local all_rows sel_rows
  all_rows="$(awk -F'\t' -v p="$path" '$3 == p' "$MANIFEST")"
  sel_rows="$(awk -F'\t' -v p="$path" '$3 == p' "$rows")"
  restore=backup
  existed="$(printf '%s\n' "$sel_rows" | head -n 1 | cut -f6)"
  while IFS="	" read -r _ _ _ _ _ _ r s; do
    [ "$r" = "backup" ] && [ "$s" = "$cur" ] || restore=surgical
  done <<EOF
$sel_rows
EOF
  # a file shared with agents that stay installed is always edited surgically
  [ "$(printf '%s\n' "$all_rows" | wc -l | tr -d ' ')" = "$(printf '%s\n' "$sel_rows" | wc -l | tr -d ' ')" ] || restore=surgical
  if [ "$restore" = "backup" ]; then
    if [ "$existed" = "1" ] && [ -f "$b" ]; then plan_write "$path" "$b" keep; printf '%s' "$b" >"$(planned_file "$path").restore"
    else plan_delete "$path"
    fi
    return 0
  fi
  note "$(pretty "$path") changed since install: removing only the Nawala entries (no full restore)"
  cp "$path" "$new"
  while IFS="	" read -r agent kind _ op arg _ _ _; do
    case "$kind" in
      json)
        jq -e 'type == "object"' "$new" >/dev/null 2>&1 || { note "$(pretty "$path") is no longer valid JSON; left as is"; return 0; }
        jq --argjson p "$arg" --arg op "$op" "$JQ_LIB"'remove_op($op; $p)' "$new" >"$new.x" && mv "$new.x" "$new" ;;
      block)
        if [ "$op" = "toml" ]; then strip_block "# nawala:start" "# nawala:end" <"$new" >"$new.x"
        else strip_block "<!-- nawala:start -->" "<!-- nawala:end -->" <"$new" >"$new.x"; fi
        mv "$new.x" "$new" ;;
      owned)
        if grep -Eq 'nawala:start|\.nawala/hook\.sh' "$new"; then : >"$new"; fi ;;
      core)
        if [ "$existed" = "1" ] && [ -f "$b" ]; then cp "$b" "$new"; else : >"$new"; fi ;;
    esac
  done <<EOF
$sel_rows
EOF
  if [ ! -s "$new" ] || { [ "$existed" != "1" ] && jq -e '. == {} or . == {"version":1} or . == {"schema_version":1}' "$new" >/dev/null 2>&1; }; then
    plan_delete "$path"
  elif ! cmp -s "$path" "$new"; then
    plan_write "$path" "$new" keep
  fi
}

if [ "$UNINSTALL" = "1" ]; then do_uninstall; else do_install; fi
