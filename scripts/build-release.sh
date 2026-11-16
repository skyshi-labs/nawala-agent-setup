#!/usr/bin/env bash
# Build the release assets into OUTDIR (default: dist/):
#   install.sh        self-contained: hook.sh and templates/ embedded verbatim as quoted heredocs
#                     (readable, no base64), so one sha256 covers everything that gets installed
#   hook.sh           identical to the repo file (for auditing; install.sh never downloads it)
#   templates.tar.gz  the templates/ directory (for auditing)
#   SHA256SUMS        sha256 of the three files above
# The build checks that every embedded file round-trips byte-for-byte via --print-file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
mkdir -p "$OUT"
cd "$ROOT"

DELIM="NAWALA_EMBED_EOF"
files="hook.sh $(find templates -type f ! -name '.*' | LC_ALL=C sort | tr '\n' ' ')"

embed="$(mktemp)"
trap 'rm -f "$embed"' EXIT
{
  echo "NAWALA_EMBEDDED=1"
  echo "embedded_file() {"
  echo "  case \"\$1\" in"
  for f in $files; do
    [ -z "$(tail -c 1 "$f")" ] || { echo "build: $f must end with a newline" >&2; exit 1; }
    if grep -qx "$DELIM" "$f"; then echo "build: $f contains the heredoc delimiter" >&2; exit 1; fi
    case "$f" in *"'"*) echo "build: bad file name $f" >&2; exit 1 ;; esac
    echo "    '$f') cat <<'$DELIM'"
    cat "$f"
    echo "$DELIM"
    echo "      ;;"
  done
  echo "    *) return 1 ;;"
  echo "  esac"
  echo "}"
} >"$embed"

awk -v embed="$embed" '
  /^# >>> embedded files/ { print; while ((getline line < embed) > 0) print line; skip = 1; next }
  /^# <<< embedded files/ { skip = 0 }
  !skip { print }
' install.sh >"$OUT/install.sh"
chmod 755 "$OUT/install.sh"
grep -q '^NAWALA_EMBEDDED=1$' "$OUT/install.sh" || { echo "build: embedding failed" >&2; exit 1; }

cp hook.sh "$OUT/hook.sh"
chmod 755 "$OUT/hook.sh"

# reproducible tarball where GNU tar is available (CI); plain tar elsewhere
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar --sort=name --mtime='2020-01-01 00:00Z' --owner=0 --group=0 --numeric-owner -cf - templates | gzip -n >"$OUT/templates.tar.gz"
else
  tar -cf - templates | gzip -n >"$OUT/templates.tar.gz"
fi

# round-trip check: what install.sh would install == the repo files
for f in $files; do
  HOME="${TMPDIR:-/tmp}" bash "$OUT/install.sh" --print-file "$f" | cmp -s - "$f" || { echo "build: embedded $f differs" >&2; exit 1; }
done

(
  cd "$OUT"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum install.sh hook.sh templates.tar.gz; else shasum -a 256 install.sh hook.sh templates.tar.gz; fi
) >"$OUT/SHA256SUMS"
echo "built $(grep -c '' "$OUT/SHA256SUMS") assets in $OUT (version $(bash "$OUT/install.sh" --version))"
cat "$OUT/SHA256SUMS"
