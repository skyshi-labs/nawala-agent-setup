# shellcheck shell=bash
# shellcheck disable=SC2034 # variables used by the sourced *.test.sh files
# Shared helpers for the plain-bash test suite (no bats needed). Sourced by tests/run.sh.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
# test the source tree by default; CI also runs the suite against the built release asset
INSTALL="${NAWALA_INSTALL_SH:-$ROOT/install.sh}"
HOOK="$ROOT/hook.sh"
ALL_AGENTS="claude codex cursor kiro antigravity opencode grok muse"
TOKEN="nwl_TestTokenDoNotUse_0123456789abcdefghijKLMN"
LEGACY_TOKEN="nwl_LegacyTokenDoNotUse_0123456789abcdefghij"
URL="https://nawala.example.com"
export PATH="$ROOT/tests/bin:$PATH"
# the installer asks `opencode --version`; pin it so tests never depend on (or run) a local OpenCode
export NAWALA_OPENCODE_VERSION="${NAWALA_OPENCODE_VERSION:-2.3.0}"
# what the fake server's GET /v1/tracking returns unless a test sets FAKE_TRACKING_BODY
export FAKE_TRACKING_DEFAULT='{"version":1,"prefixes":["github.com/acme/shop-api","gitlab.com/acme"]}'
WORK_REMOTE="git@gitlab.com:acme/app.git"        # tracked by the default list
PERSONAL_REMOTE="git@github.com:dev/dotfiles.git" # not tracked
export NAWALA_TOKEN="$TOKEN"
unset NAWALA_URL NAWALA_OFF NAWALA_DIR USER_PROMPT CLAUDE_EFFORT 2>/dev/null || true

# every byte any command printed during the run; checked for the token at the end
ALL_OUTPUT="$TEST_TMP/all-output.log"
: >"$ALL_OUTPUT"

new_home() { # [seed]  fresh HOME (optionally seeded from tests/fixtures/homes/<seed>)
  HOME="$(mktemp -d "$TEST_TMP/home.XXXXXX")"
  export HOME
  export FAKE_CURL_LOG="$HOME.curl.log" FAKE_CURL_BODIES="$HOME.bodies.jsonl" FAKE_CURL_HEADERS="$HOME.headers.log"
  : >"$FAKE_CURL_LOG"; : >"$FAKE_CURL_BODIES"; : >"$FAKE_CURL_HEADERS"
  unset FAKE_ME_CODE FAKE_EVENTS_CODE FAKE_RULES_CODE FAKE_RULES_BODY FAKE_TRACKING_CODE FAKE_TRACKING_BODY
  if [ -n "${1:-}" ]; then
    cp -Rp "$FIX/homes/$1/." "$HOME/"
    local f
    grep -rl -e '__HOME__' -e '__TOKEN__' "$HOME" 2>/dev/null | while IFS= read -r f; do
      sed -e "s#__HOME__#$HOME#g" -e "s#__TOKEN__#$LEGACY_TOKEN#g" "$f" >"$f.x" && cat "$f.x" >"$f" && rm -f "$f.x"
    done || true
  fi
}

new_repo() { # dir [remote]  git repo with an origin remote (default: a tracked work remote; "" = none)
  mkdir -p "$1" && git -C "$1" init -q
  if [ "${2-$WORK_REMOTE}" != "" ]; then git -C "$1" remote add origin "${2-$WORK_REMOTE}"; fi
}
in_repo() { # fixture dir -> prints the path of a copy of the fixture whose cwd is dir
  local copy; copy="$(mktemp "$TEST_TMP/fixture.XXXXXX")"
  sed "s#/tmp/nawala-proj#$2#g" "$1" >"$copy"
  printf '%s' "$copy"
}

hash_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum <"$1" | cut -d' ' -f1; else shasum -a 256 <"$1" | cut -d' ' -f1; fi; }

# file tree with modes and content hashes: used for "nothing changed" / "restored byte-for-byte"
snapshot() {
  (cd "$HOME" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
    if [ -f "$f" ]; then
      printf '%s %s %s\n' "$(ls -ld "$f" | cut -c1-10)" "$(hash_file "$f")" "$f"
    else
      printf '%s dir %s\n' "$(ls -ld "$f" | cut -c1-10)" "$f"
    fi
  done)
}

OUT=""
run() { # run a command, keep its combined output in $OUT, return its exit code
  local rc=0
  OUT="$("$@" 2>&1)" || rc=$?
  printf '%s\n' "$OUT" >>"$ALL_OUTPUT"
  return "$rc"
}
install_sh() { run bash "$INSTALL" "$@"; }

fail() { printf '    FAIL: %s\n' "$*" >&2; return 1; }
assert_eq() { [ "$1" = "$2" ] || fail "${3:-values differ}: expected [$2] got [$1]"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "${3:-missing} [$2]"; printf '%s\n' "$1" | head -20 >&2; return 1 ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "${3:-unexpected} [$2]" ;; esac; }
assert_same_tree() { # before after
  [ "$1" = "$2" ] || { diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") | head -20 >&2; fail "${3:-tree changed}"; return 1; }
}
json_get() { jq -r "$2" "$1"; }
