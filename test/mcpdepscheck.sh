#!/usr/bin/env bash
# mcpdepscheck.sh — F3 gate: the MCP `deps` verb exposes the --deps facts losslessly.
#
# No earlier MCP verb answered --deps at all, so the inner <inc> rows (F1) were unreachable from
# this surface. `deps` is the CLI --deps twin: the same computation (resolveStructuralIncludeAdj +
# sccCycles + dependencyHealth + restrictDependencyHealth + afferent) and the same packDeps renderer
# the CLI arm calls, over the warm index. limit/offset window the per-file list; deps_limit/deps_offset
# window the <inc> rows inside each file.
#
# Fixtures are built in a throwaway dir (never the tree): one file with 66 imports (above the 40-row
# display default) plus a small file below it.
#
# Asserts:
#   (A) default serves 40 rows with the arithmetic paging block (shown=40 capped=1 total=66
#       has_more=1 next_offset=40).
#   (B) deps_limit=66 serves every row without omission.
#   (C) pages union to the total: deps_limit=30 pages at offsets 0/30/60 concatenate to the
#       deps_limit=66 row set, in order; the last page says has_more=0.
#   (D) CLI/MCP parity: the MCP row set equals the CLI --deps row set on the same dir.
#   (E) refusals: deps_limit=0, deps_limit=abc and an unknown field all refuse loudly; a batch
#       sub-query naming deps is refused inline (whole-repo scope, like connect/explore).
#   (F) multi-root answers (deps is not single-root): a `paths` call serves, never refuses.
#   (G) determinism: two identical calls are byte-identical.
#   (H) tools/list advertises deps with exactly the path/paths/limit/offset/deps_limit/deps_offset
#       properties, each carrying a description.
#
# Usage:  test/mcpdepscheck.sh   |   RIPWIRE_BIN=asan/ripwire test/mcpdepscheck.sh
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
echo "mcpdepscheck: BIN=$BIN  TMP=$TMP"

mkdir -p "$TMP/big/gen" "$TMP/mra" "$TMP/mrb"
for i in $( seq 0 65 ); do printf 'int f%d();\n' "$i" >"$TMP/big/gen/h$i.h"; done
{ for i in $( seq 0 65 ); do printf '#include "gen/h%d.h"\n' "$i"; done
  printf 'int main(){return 0;}\n'; } >"$TMP/big/consumer.c"
printf 'int x(){return 1;}\n' >"$TMP/mra/x.c"
printf 'int y(){return 2;}\n' >"$TMP/mrb/y.c"

mcp() {  # $1 = arguments JSON object (without surrounding braces content) — prints the raw response line
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"deps","arguments":{'"$1"'}}}' \
        | "$BIN" --mcp 2>/dev/null | tail -1
}
mcpText() {  # $1 = args — prints the answer TEXT (or __ERROR__:message)
    mcp "$1" | python3 -c 'import sys,json
r = json.load( sys.stdin )
if "error" in r: print( "__ERROR__:" + r["error"].get( "message", "" ) )
else:            print( r["result"]["content"][0]["text"] )'
}
mcpRows() {  # $1 = args — prints the <inc t=> row set in served order (sort at the call site)
    mcpText "$1" | grep -o '<inc t="[^"]*"'
}

# ── (A) default: 40 rows + arithmetic disclosure ──────────────────────────────────────────────────
defText="$( mcpText '"path":"'"$TMP/big"'"' )"
defLine="$( printf '%s' "$defText" | grep -o '<f p="[^"]*consumer.c"[^>]*>' )"
if [ "$( printf '%s' "$defText" | grep -o '<inc t="[^"]*"' | wc -l | tr -d ' ' )" = "40" ] \
    && printf '%s' "$defLine" | grep -q 'shown="40" capped="1" total="66" has_more="1" next_offset="40"'; then
    ok "(A) default serves 40 rows, <f> says shown=40 capped=1 total=66 has_more=1 next_offset=40"
else
    no "(A) default MCP deps disclosure wrong ($defLine)"
fi

# ── (B) raised cap serves every row ───────────────────────────────────────────────────────────────
[ "$( mcpRows '"path":"'"$TMP/big"'","deps_limit":66' | wc -l | tr -d ' ' )" = "66" ] \
    && ok "(B) deps_limit=66 serves all 66 rows without omission" \
    || no "(B) deps_limit=66 did not serve 66 rows"

# ── (C) pages union to the total ──────────────────────────────────────────────────────────────────
mcpRows '"path":"'"$TMP/big"'","deps_limit":66' | LC_ALL=C sort >"$TMP/mcp_all"
{ mcpRows '"path":"'"$TMP/big"'","deps_limit":30,"deps_offset":0'
  mcpRows '"path":"'"$TMP/big"'","deps_limit":30,"deps_offset":30'
  mcpRows '"path":"'"$TMP/big"'","deps_limit":30,"deps_offset":60'; } | LC_ALL=C sort >"$TMP/mcp_pages"
if cmp -s "$TMP/mcp_all" "$TMP/mcp_pages"; then
    ok "(C) 30+30+6 MCP pages union to the 66-row set, no drop and no duplication"
else
    no "(C) MCP paged union differs from the full row set"
fi
mcpText '"path":"'"$TMP/big"'","deps_limit":30,"deps_offset":60' | grep -q 'has_more="0"' \
    && ok "(C) last MCP page says has_more=0 — the loop terminates" \
    || no "(C) last MCP page lacks has_more=0"

# ── (D) CLI/MCP parity on the same dir ────────────────────────────────────────────────────────────
"$BIN" "$TMP/big" --deps --deps-limit=66 --no-cache 2>/dev/null | grep -o '<inc t="[^"]*"' | LC_ALL=C sort >"$TMP/cli_all"
if cmp -s "$TMP/cli_all" "$TMP/mcp_all"; then
    ok "(D) MCP row set == CLI --deps row set on the same dir"
else
    no "(D) MCP and CLI --deps row sets differ"
fi

# ── (E) refusals ──────────────────────────────────────────────────────────────────────────────────
mcpText '"path":"'"$TMP/big"'","deps_limit":0' | grep -q '__ERROR__' \
    && ok "(E) deps_limit=0 refuses" || no "(E) deps_limit=0 did not refuse"
mcpText '"path":"'"$TMP/big"'","deps_limit":"abc"' | grep -q '__ERROR__.*deps_limit' \
    && ok "(E) deps_limit=abc refuses naming the field" || no "(E) deps_limit=abc did not refuse"
mcpText '"path":"'"$TMP/big"'","deps_foo":1' | grep -q '__ERROR__.*deps_foo' \
    && ok "(E) unknown field deps_foo refuses naming the field" || no "(E) unknown field deps_foo did not refuse"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"batch","arguments":{"path":"'"$TMP/big"'","queries":[{"verb":"deps"}]}}}' \
    | "$BIN" --mcp 2>/dev/null | tail -1 | grep -q 'ok=\\"0\\"' \
    && ok "(E) batch sub-query naming deps is refused inline (whole-repo scope is not batchable)" \
    || no "(E) batch served deps or failed the whole batch"

# ── (F) multi-root answers ────────────────────────────────────────────────────────────────────────
mcpText '"paths":["'"$TMP/mra"'","'"$TMP/mrb"'"]' | grep -q '<deps ' \
    && ok "(F) multi-root paths call answers (deps is not single-root)" \
    || no "(F) multi-root deps call did not answer"

# ── (G) determinism ───────────────────────────────────────────────────────────────────────────────
mcpText '"path":"'"$TMP/big"'","deps_limit":25,"deps_offset":17' >"$TMP/m1"
mcpText '"path":"'"$TMP/big"'","deps_limit":25,"deps_offset":17' >"$TMP/m2"
if cmp -s "$TMP/m1" "$TMP/m2"; then
    ok "(G) paged MCP deps output is byte-identical across runs"
else
    no "(G) paged MCP deps output differs across runs"
fi

# ── (H) tools/list advertises deps with the six declared properties ──────────────────────────────
if printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | "$BIN" --mcp 2>/dev/null | tail -1 | python3 -c 'import sys,json
tools = { t["name"]: t for t in json.load( sys.stdin )["result"]["tools"] }
deps = tools.get( "deps" )
assert deps, "deps not advertised"
props = deps["inputSchema"]["properties"]
assert sorted( props ) == [ "deps_limit", "deps_offset", "limit", "offset", "path", "paths" ], sorted( props )
assert all( props[k].get( "description" ) for k in props ), "property without description"
print( "ok" )' | grep -q ok; then
    ok "(H) tools/list advertises deps with the six described properties"
else
    no "(H) deps tools/list stanza wrong (name, properties or descriptions)"
fi

[ "$fail" = 0 ] && printf 'mcpdepscheck: ALL PASS\n' || printf 'mcpdepscheck: FAILURES ABOVE\n'
exit "$fail"
