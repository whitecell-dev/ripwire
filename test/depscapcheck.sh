#!/usr/bin/env bash
# depscapcheck.sh — F1 gate: the --deps INNER <inc> row list is lossless, not hard-capped.
#
# serialize.h::packDeps used to cut every file's <inc> rows at 40 with only an unparseable
# <!-- +more --> marker — a module with 66 imports exposed 40 rows and the true count survived
# only in the includes= attribute. The inner list is now windowed with the same pageview.h
# primitives as the outer per-file list (effectiveRowCap/pageWindow/pageDisclosure):
# --deps-limit=N raises the per-file cap, --deps-offset=M skips rows in every file, and a file
# that was cut discloses shown=/capped=/total=/has_more=/next_offset=/offset=/limit= on its own
# <f> (includes= is the total), so every import is retrievable.
#
# Fixtures are built in a throwaway dir (never the tree): one file with exactly 39 / 40 / 41 /
# 66 imports, plus a 150-import file for the large-list arm.
#
# Asserts:
#   (A) 39 and 40 imports: every row served, NO paging block on the <f> (byte-identical default).
#   (B) 41 and 66 imports: default serves 40 + <!-- +more -->, and the <f> carries the arithmetic
#       paging block (shown=40 capped=1 total=N has_more=1 next_offset=40).
#   (C) --deps-limit=N serves every row (41, 66, 150 all retrievable without omission).
#   (D) pages union to the total: limit=30 pages of the 66-list concatenate to the --deps-limit=66
#       row set, in order, with no drop and no duplication; the last page says has_more=0.
#   (E) --deps-offset past the end is an empty page (shown=0), never an error.
#   (F) refusals: --deps-limit/--deps-offset without --deps exit 1; --deps-limit=0 exits 1.
#   (G) determinism: two runs are byte-identical.
#
# Usage:  test/depscapcheck.sh   |   RIPWIRE_BIN=asan/ripwire test/depscapcheck.sh
# Exits non-zero on any failure. Does NOT edit test/regression.sh or test/golden.xml.

set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok(){ printf '  PASS  %s\n' "$*" || { fail=1; printf '  FAIL  could not write the PASS line for: %s\n' "$*"; }; return 0; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }
echo "depscapcheck: BIN=$BIN  TMP=$TMP"

mkcorp() {  # $1 = dir, $2 = import count
    mkdir -p "$1/gen"
    for i in $( seq 0 $(( $2 - 1 )) ); do printf 'int f%d();\n' "$i" >"$1/gen/h$i.h"; done
    { for i in $( seq 0 $(( $2 - 1 )) ); do printf '#include "gen/h%d.h"\n' "$i"; done
      printf 'int main(){return 0;}\n'; } >"$1/consumer.c"
}
mkcorp "$TMP/c39" 39; mkcorp "$TMP/c40" 40; mkcorp "$TMP/c41" 41; mkcorp "$TMP/c66" 66; mkcorp "$TMP/c150" 150

fline()  { "$BIN" "$1" --deps --no-cache 2>/dev/null | sed 's/</\n</g' | grep '<f p="consumer.c"'; }
rows()   { "$BIN" "$@" --no-cache 2>/dev/null | grep -o '<inc t="[^"]*"'; }
attr()   { printf '%s' "$1" | sed -n "s/.*[[:space:]]$2=\"\([^\"]*\)\".*/\1/p"; }

# ── (A) below and at the cap: complete, undisclosed ───────────────────────────────────────────────
for n in 39 40; do
    line="$( fline "$TMP/c$n" )"
    rc="$( rows "$TMP/c$n" --deps | wc -l | tr -d ' ' )"
    if [ "$rc" = "$n" ] && [ "$( attr "$line" includes )" = "$n" ] && ! printf '%s' "$line" | grep -q 'shown='; then
        ok "($n imports) all $n rows served, no paging block on the <f>"
    else
        no "($n imports) want $n rows and no shown= (rows=$rc line=$line)"
    fi
done

# ── (B) above the cap: 40 rows + marker + arithmetic paging block ────────────────────────────────
for n in 41 66; do
    "$BIN" "$TMP/c$n" --deps --no-cache 2>/dev/null >"$TMP/d$n"
    line="$( grep -o '<f p="consumer.c"[^>]*>' "$TMP/d$n" )"
    rc="$( grep -o '<inc t="[^"]*"' "$TMP/d$n" | wc -l | tr -d ' ' )"
    if [ "$rc" = "40" ] && grep -q '<!-- +more -->' "$TMP/d$n" \
        && [ "$( attr "$line" shown )" = "40" ] && [ "$( attr "$line" capped )" = "1" ] \
        && [ "$( attr "$line" total )" = "$n" ] && [ "$( attr "$line" includes )" = "$n" ] \
        && [ "$( attr "$line" has_more )" = "1" ] && [ "$( attr "$line" next_offset )" = "40" ]; then
        ok "($n imports) default serves 40 + marker, <f> says shown=40 capped=1 total=$n has_more=1 next_offset=40"
    else
        no "($n imports) default disclosure wrong (rows=$rc line=$line)"
    fi
done

# ── (C) raised cap serves every row ───────────────────────────────────────────────────────────────
for n in 41 66 150; do
    rc="$( rows "$TMP/c$n" --deps --deps-limit="$n" | wc -l | tr -d ' ' )"
    line="$( fline "$TMP/c$n" )"
    if [ "$rc" = "$n" ]; then
        ok "($n imports) --deps-limit=$n serves all $n rows without omission"
    else
        no "($n imports) --deps-limit=$n served $rc rows, want $n"
    fi
done

# ── (D) pages union to the total, in order ────────────────────────────────────────────────────────
rows "$TMP/c66" --deps --deps-limit=66 | sort >"$TMP/all66"
{ rows "$TMP/c66" --deps --deps-limit=30 --deps-offset=0
  rows "$TMP/c66" --deps --deps-limit=30 --deps-offset=30
  rows "$TMP/c66" --deps --deps-limit=30 --deps-offset=60; } | sort >"$TMP/pages"
if cmp -s "$TMP/all66" "$TMP/pages"; then
    ok "(66 imports) 30+30+6 pages union to the 66-row set, in order, no drop and no duplication"
else
    no "(66 imports) paged union differs from the full row set"
fi
last="$( "$BIN" "$TMP/c66" --deps --deps-limit=30 --deps-offset=60 --no-cache 2>/dev/null | sed 's/</\n</g' | grep '<f p="consumer.c"' )"
if [ "$( attr "$last" shown )" = "6" ] && [ "$( attr "$last" has_more )" = "0" ] && [ "$( attr "$last" next_offset )" = "66" ]; then
    ok "(66 imports) last page says shown=6 has_more=0 next_offset=66 — the loop terminates"
else
    no "(66 imports) last-page disclosure wrong ($last)"
fi
# seam rows are the exact continuation: page 1 ends h29, page 2 starts h30 and ends h59
if [ "$( rows "$TMP/c66" --deps --deps-limit=30 | tail -1 )" = '<inc t="gen/h29.h"' ] \
    && [ "$( rows "$TMP/c66" --deps --deps-limit=30 --deps-offset=30 | head -1 )" = '<inc t="gen/h30.h"' ] \
    && [ "$( rows "$TMP/c66" --deps --deps-limit=30 --deps-offset=30 | tail -1 )" = '<inc t="gen/h59.h"' ]; then
    ok "(66 imports) page seams are exact (h29|h30 … h59|h60)"
else
    no "(66 imports) page seam rows are wrong"
fi

# ── (E) offset past the end: empty page, still disclosed ──────────────────────────────────────────
past="$( "$BIN" "$TMP/c66" --deps --deps-offset=999 --no-cache 2>/dev/null | sed 's/</\n</g' | grep '<f p="consumer.c"' )"
if [ "$( attr "$past" shown )" = "0" ] && [ "$( attr "$past" has_more )" = "0" ]; then
    ok "(66 imports) --deps-offset=999 is an empty disclosed page (shown=0 has_more=0)"
else
    no "(66 imports) past-the-end page wrong ($past)"
fi

# ── (F) refusals ──────────────────────────────────────────────────────────────────────────────────
"$BIN" "$TMP/c66" --deps-limit=5 --no-cache >/dev/null 2>&1
[ $? -ne 0 ] && ok "--deps-limit without --deps refuses" || no "--deps-limit without --deps exited 0"
"$BIN" "$TMP/c66" --deps-offset=5 --no-cache >/dev/null 2>&1
[ $? -ne 0 ] && ok "--deps-offset without --deps refuses" || no "--deps-offset without --deps exited 0"
"$BIN" "$TMP/c66" --deps --deps-limit=0 --no-cache >/dev/null 2>&1
[ $? -ne 0 ] && ok "--deps-limit=0 refuses" || no "--deps-limit=0 exited 0"

# ── (G) determinism ───────────────────────────────────────────────────────────────────────────────
"$BIN" "$TMP/c66" --deps --deps-limit=25 --deps-offset=17 --no-cache 2>/dev/null >"$TMP/g1"
"$BIN" "$TMP/c66" --deps --deps-limit=25 --deps-offset=17 --no-cache 2>/dev/null >"$TMP/g2"
if cmp -s "$TMP/g1" "$TMP/g2"; then
    ok "paged --deps output is byte-identical across runs"
else
    no "paged --deps output differs across runs"
fi

[ "$fail" = 0 ] && printf 'depscapcheck: ALL PASS\n' || printf 'depscapcheck: FAILURES ABOVE\n'
exit "$fail"
