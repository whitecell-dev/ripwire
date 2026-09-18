#!/usr/bin/env bash
# splitidentitycheck.sh — F2 gate: every prov="split" edge is independently addressable.
#
# The resolver's conservative "split over all candidates" is unchanged; what changed is that each
# split edge now carries the target's own identity — to= (the emitted canonical id, the --expand
# selector spelling), p= (the target file, the enclosing <f p=> spelling) and l= (the target line)
# — so a consumer can dereference the candidate without joining IngestResult.references.
#
# Fixtures are built in a throwaway dir (never the tree):
#   flat/    one caller + 5 same-named defs in the same directory  (5 split arms, unscoped)
#   scoped/  one caller + two same-named defs in namespaces A and B (scoped to= spelling)
#   unique/  one caller + one def (the unambiguous control: no identity attrs on the edge)
#
# Asserts:
#   (A) every prov="split" edge carries non-empty to=/p=/l= (all 5 flat arms, both scoped arms).
#   (B) the arms are pairwise distinct — no two split edges share the same (to,p,l) triple.
#   (C) every arm dereferences through the existing selector grammar: --expand=<p>:<name> and
#       --expand=<to> (scoped) exit 0 and name the requested symbol.
#   (D) the --json twin carries the same identity (to/p/l keys) on every split edge.
#   (E) the MCP analyze twin carries the same identity on every split edge.
#   (F) the unambiguous control edge carries prov= nowhere and to=/p=/l= nowhere.
#   (G) determinism: two runs are byte-identical.
#
# Usage:  test/splitidentitycheck.sh   |   RIPWIRE_BIN=asan/ripwire test/splitidentitycheck.sh
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
command -v python3 >/dev/null 2>&1 || { echo "python3 required for JSON assertions"; exit 2; }
echo "splitidentitycheck: BIN=$BIN  TMP=$TMP"

mkdir -p "$TMP/flat" "$TMP/scoped" "$TMP/unique"
printf 'void caller5(){ handler(); }\n' >"$TMP/flat/main.c"
for i in 1 2 3 4 5; do printf 'void handler(){}\n' >"$TMP/flat/d$i.c"; done
printf 'namespace A { void helper() {} }\nnamespace B { void helper() {} }\nvoid callerNs() { helper(); }\n' >"$TMP/scoped/ns.cpp"
printf 'int only(){return 1;}\nint single(){return only();}\n' >"$TMP/unique/u.c"

splitEdges() { "$BIN" "$1" --no-cache 2>/dev/null | grep -o '<c n="[^"]*" prov="split"[^>]*>'; }

# ── (A) every split edge carries the full identity ────────────────────────────────────────────────
flat="$( splitEdges "$TMP/flat" )"
[ "$( printf '%s\n' "$flat" | wc -l | tr -d ' ' )" = "5" ] \
    && ok "(A) flat fixture has exactly 5 split arms" \
    || no "(A) flat fixture split-arm count wrong: $( printf '%s\n' "$flat" | wc -l | tr -d ' ' ) (want 5)"
if printf '%s\n' "$flat" | grep -qE '<c n="handler" prov="split" to="[^"]+" p="[^"]+" l="[0-9]+"/>'; then
    bad="$( printf '%s\n' "$flat" | grep -vE '<c n="handler" prov="split" to="[^"]+" p="[^"]+" l="[0-9]+"/>' | wc -l | tr -d ' ' )"
    [ "$bad" = "0" ] && ok "(A) all 5 flat arms carry non-empty to=/p=/l=" \
        || no "(A) $bad flat arm(s) lack the identity triple"
else
    no "(A) no flat split arm carries the to=/p=/l= triple"
fi
scoped="$( splitEdges "$TMP/scoped" )"
[ "$( printf '%s\n' "$scoped" | wc -l | tr -d ' ' )" = "2" ] \
    && ok "(A) scoped fixture has exactly 2 split arms" \
    || no "(A) scoped fixture split-arm count wrong"
printf '%s\n' "$scoped" | grep -q 'to="ns.cpp::A::helper"' \
    && ok "(A) scoped arm carries the full canonical to= (ns.cpp::A::helper)" \
    || no "(A) scoped to= is not the canonical spelling ($scoped)"
printf '%s\n' "$scoped" | grep -q 'to="ns.cpp::B::helper"' \
    && ok "(A) both namespace candidates are named" \
    || no "(A) B::helper arm missing"

# ── (B) arms are pairwise distinct ────────────────────────────────────────────────────────────────
if [ "$( printf '%s\n' "$flat" | sort -u | wc -l | tr -d ' ' )" = "5" ]; then
    ok "(B) the 5 flat arms are pairwise distinct — each candidate independently addressable"
else
    no "(B) flat split arms are not distinct"
fi

# ── (C) every arm dereferences through the existing selectors ─────────────────────────────────────
deref=0
for i in 1 2 3 4 5; do
    if "$BIN" "$TMP/flat" --expand="d$i.c:handler" --no-cache 2>/dev/null | grep -q 'sym="handler:1"'; then
        deref=$(( deref + 1 ))
    else
        no "(C) p:name selector d$i.c:handler did not resolve"
    fi
done
[ "$deref" = "5" ] && ok "(C) all 5 flat arms dereference via --expand=<p>:<name>"
for to in "ns.cpp::A::helper" "ns.cpp::B::helper"; do
    if "$BIN" "$TMP/scoped" --expand="$to" --no-cache 2>/dev/null | grep -q "<s "; then
        ok "(C) --expand=$to resolves"
    else
        no "(C) --expand=$to did not resolve"
    fi
done

# ── (D) the --json twin ───────────────────────────────────────────────────────────────────────────
"$BIN" "$TMP/flat" --json --no-cache 2>/dev/null >"$TMP/map.json"
if python3 - "$TMP/map.json" <<'PY'; then
import json, sys
d = json.load( open( sys.argv[1] ) )
edges = [ c for f in d["r"] for s in f["s"] for c in s.get( "c", [] ) if c.get( "prov" ) == "split" ]
assert len( edges ) == 5, "want 5 split edges, got %d" % len( edges )
assert all( c.get( "to" ) and c.get( "p" ) and isinstance( c.get( "l" ), int ) for c in edges ), "identity keys missing"
assert len( { ( c["to"], c["p"], c["l"] ) for c in edges } ) == 5, "edges not distinct"
print( "ok" )
PY
    ok "(D) --json carries to/p/l on all 5 split edges, pairwise distinct"
else
    no "(D) --json split-edge identity wrong"
fi

# ── (E) the MCP analyze twin ──────────────────────────────────────────────────────────────────────
mcpSplit="$( printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"analyze","arguments":{"path":"'"$TMP/flat"'"}}}' \
    | "$BIN" --mcp 2>/dev/null | tail -1 | python3 -c 'import sys,json,re
t = json.load( sys.stdin )["result"]["content"][0]["text"]
print( len( re.findall( r"""<c n="handler" prov="split" to="[^"]*" p="[^"]*" l="[0-9]*"/>""", t ) ) )' )"
[ "$mcpSplit" = "5" ] && ok "(E) MCP analyze carries the identity triple on all 5 split arms" \
    || no "(E) MCP analyze split-arm identity count wrong ($mcpSplit, want 5)"

# ── (F) the unambiguous control: no prov=, no identity attrs ─────────────────────────────────────
uniqueC="$( "$BIN" "$TMP/unique" --no-cache 2>/dev/null | grep -o '<c [^>]*>' )"
if printf '%s' "$uniqueC" | grep -q 'prov='; then
    no "(F) unique edge wrongly carries prov= ($uniqueC)"
elif printf '%s' "$uniqueC" | grep -qE ' to=| p=| l='; then
    no "(F) unique edge wrongly carries identity attrs ($uniqueC)"
else
    ok "(F) unambiguous edge is byte-identical to before (no prov=, no to=/p=/l=)"
fi

# ── (G) determinism ───────────────────────────────────────────────────────────────────────────────
"$BIN" "$TMP/flat" --no-cache 2>/dev/null >"$TMP/h1"
"$BIN" "$TMP/flat" --no-cache 2>/dev/null >"$TMP/h2"
if cmp -s "$TMP/h1" "$TMP/h2"; then
    ok "(G) split-edge output is byte-identical across runs"
else
    no "(G) split-edge output differs across runs"
fi

[ "$fail" = 0 ] && printf 'splitidentitycheck: ALL PASS\n' || printf 'splitidentitycheck: FAILURES ABOVE\n'
exit "$fail"
