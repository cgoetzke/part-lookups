#!/usr/bin/env bash
# Offline test suite for fastenal-lookup.sh -- real fixtures + stubbed network.
# Run from anywhere: tests/run.sh
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
ROOT=$PWD
FIX=$ROOT/tests/fixtures/cache
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
assert_eq() { # desc expected actual
  if [[ $2 == "$3" ]]; then ok "$1"; else fail=$((fail+1)); echo "FAIL $1"
    echo "  expected: $(printf %q "$2")"; echo "  actual:   $(printf %q "$3")"; fi
}
row() { grep "^$2"$'\t' <<<"$1"; }

# --- sourcing imports functions, runs nothing (source in THIS shell;
#     a command substitution would subshell it away)
srcout=$(mktemp)
source ./fastenal-lookup.sh > "$srcout" 2>&1
assert_eq "sourcing is silent" "" "$(cat "$srcout")"
rm -f "$srcout"

# --- parse_md unit tests (against real cached renders)
mdf() { parse_md "$2" < "$FIX/$1" | tr '\037' '|'; }
assert_eq "md: full fields (0700344)" \
  "15A 125V 2P 3W 5-15 Yellow Straight Connector|HUBBELL|BRYANT|BRY5969Y|39121421|OK" \
  "$(mdf 0700344.md 0700344)"
assert_eq "md: private label, no mpn (0345865)" \
  "1/2\" x 6\" OAL 135° Split Black / Gold High Speed Steel Straight Jobber Drill|FASTENAL APPROVED VENDOR|ORMADUS||23241634|OK" \
  "$(mdf 0345865.md 0345865)"
assert_eq "md: pipe in title stripped (9999999)" \
  "Material Test Report|Fastenal Approved Vendor|||77102001|OK" \
  "$(mdf 9999999.md 9999999)"
assert_eq "md: not-found page" "Not Found|||||NOT_FOUND" "$(mdf 0000001.md 0000001)"
assert_eq "md: SPA shell -> NO_DATA" "|||||NO_DATA" "$(mdf 0000002.md 0000002)"

# --- parse_html unit test
assert_eq "html: spec-table pairs" "HUBBELL|BRYANT|BRY5965Y|39121402" \
  "$(parse_html < "$FIX/0700343.html" | tr '\037' '|')"

# --- end-to-end, offline via fixture cache
E() { SLEEP=0 CACHE="$FIX" ./fastenal-lookup.sh "$@"; }
out=$(E 0700344 0345865 9999999 0000001)
assert_eq "e2e: header" \
  "$(printf 'sku\ttitle\tmanufacturer\tbrand\tmfr_part_no\tunspsc\tstatus')" "$(head -1 <<<"$out")"
assert_eq "e2e: 0700344 row" \
  "$(printf '0700344\t15A 125V 2P 3W 5-15 Yellow Straight Connector\tHUBBELL\tBRYANT\tBRY5969Y\t39121421\tOK')" \
  "$(row "$out" 0700344)"
assert_eq "e2e: 0345865 row (private label, '-' for missing mpn)" \
  "$(printf '0345865\t1/2" x 6" OAL 135° Split Black / Gold High Speed Steel Straight Jobber Drill\tFASTENAL APPROVED VENDOR\tORMADUS\t-\t23241634\tOK')" \
  "$(row "$out" 0345865)"
assert_eq "e2e: 9999999 row (pipe-free title)" \
  "$(printf '9999999\tMaterial Test Report\tFastenal Approved Vendor\t-\t-\t77102001\tOK')" \
  "$(row "$out" 9999999)"
assert_eq "e2e: NOT_FOUND row" \
  "$(printf '0000001\tNot Found\t-\t-\t-\t-\tNOT_FOUND')" "$(row "$out" 0000001)"
out3=$(E 0700343)
assert_eq "e2e: md/html fallback fills blank fields (0700343)" \
  "$(printf '0700343\t15A 125V 2P 3W NEMA 5-15 Yellow Straight Blade Plug\tHUBBELL\tBRYANT\tBRY5965Y\t39121402\tOK')" \
  "$(row "$out3" 0700343)"

# --- stdin: CRLF, comments, blank lines
n=$(printf '0700344\r\n# a comment\n\n0345865\n' | SLEEP=0 CACHE="$FIX" ./fastenal-lookup.sh | wc -l)
assert_eq "stdin: comments/CRLF tolerated (3 output lines)" "3" "$n"

# --- usage error on empty stdin
out=$(./fastenal-lookup.sh </dev/null 2>&1); rc=$?
assert_eq "empty stdin -> exit 1" "1" "$rc"

# --- stubbed network paths (stub lives in the suite temp dir; nothing
#     generated ever touches the repo)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
STUB=$TMP/bin; mkdir -p "$STUB"
cat > "$STUB/curl" <<'STUBEOF'
#!/usr/bin/env bash
# test stub: emulates curl's -o writing. STUB_EXIT makes it fail outright;
# otherwise writes STUB_BODY_FILE if set, or an unrendered SPA shell.
exit_code=${STUB_EXIT:-0}
[[ $exit_code != 0 ]] && exit "$exit_code"
out=""; prev=""
for a in "$@"; do [[ $prev == -o ]] && out=$a; prev=$a; done
[[ -z $out ]] && exit 0
if [[ -n ${STUB_BODY_FILE:-} ]]; then cat "$STUB_BODY_FILE" > "$out"
else printf '%s' '<html lang="en"><head></head><body><noscript>You need to enable JavaScript to run this app.</noscript><div id="root"></div></body></html>' > "$out"
fi
exit 0
STUBEOF
chmod +x "$STUB/curl"

out=$(PATH="$STUB:$PATH" STUB_EXIT=1 SLEEP=0 CACHE=$TMP ./fastenal-lookup.sh 1234567)
assert_eq "stub: curl failure -> FETCH_FAILED row" \
  "$(printf '1234567\t-\t-\t-\t-\t-\tFETCH_FAILED')" "$(row "$out" 1234567)"

out=$(PATH="$STUB:$PATH" SLEEP=0 CACHE=$TMP ./fastenal-lookup.sh 7654321)
assert_eq "stub: persistent SPA shell -> FETCH_FAILED row" \
  "$(printf '7654321\t-\t-\t-\t-\t-\tFETCH_FAILED')" "$(row "$out" 7654321)"
if [[ ! -e $TMP/7654321.md ]]; then ok "stub: shell page never cached"; else bad "stub: shell page never cached"; fi

printf '%s' '<div id="root"></div>' > "$TMP/0700344.md"   # stale shell sitting in cache
out=$(PATH="$STUB:$PATH" STUB_BODY_FILE="$FIX/0700344.md" SLEEP=0 CACHE=$TMP ./fastenal-lookup.sh 0700344)
assert_eq "stub: stale shell rejected, good page refetched" \
  "$(printf '0700344\t15A 125V 2P 3W 5-15 Yellow Straight Connector\tHUBBELL\tBRYANT\tBRY5969Y\t39121421\tOK')" \
  "$(row "$out" 0700344)"

echo
echo "passed $pass, failed $fail"
(( fail == 0 ))
