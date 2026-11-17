#!/usr/bin/env bash
# Plain-bash test runner: tests/run.sh [file-filter] [test-filter]
# Every test_* function in tests/*.test.sh runs in its own subshell with `set -e`.
# Uses a fake curl (tests/bin/curl): no network, no docker.
set -uo pipefail
cd "$(dirname "$0")/.."
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/nawala-tests.XXXXXX")"
export TEST_TMP
trap 'rm -rf "$TEST_TMP"' EXIT
# shellcheck source=tests/lib.sh
. tests/lib.sh

pass=0; failed=0; failures=""
for file in tests/*.test.sh; do
  case "$file" in *"${1:-}"*) ;; *) continue ;; esac
  # shellcheck source=/dev/null
  . "$file"
  echo "# $file"
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    case "$t" in *"${2:-}"*) ;; *) unset -f "$t"; continue ;; esac
    ( set -e; "$t" ) >"$TEST_TMP/test.out" 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then pass=$((pass + 1)); echo "ok   $t"
    else failed=$((failed + 1)); failures="$failures $t"; echo "FAIL $t"; sed 's/^/    /' "$TEST_TMP/test.out"
    fi
    unset -f "$t"
  done
done

# global check: the token never appeared in anything printed by install.sh or hook.sh
if grep -q -e "$TOKEN" -e "$LEGACY_TOKEN" "$ALL_OUTPUT"; then
  failed=$((failed + 1)); failures="$failures token_never_printed"; echo "FAIL token_never_printed (all captured output)"
else
  pass=$((pass + 1)); echo "ok   token_never_printed ($(wc -l <"$ALL_OUTPUT" | tr -d ' ') lines of captured output checked)"
fi

echo
echo "$pass passed, $failed failed${failures:+ :$failures}"
[ "$failed" = 0 ]
