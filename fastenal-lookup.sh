#!/usr/bin/env bash
# fastenal-lookup.sh -- resolve Fastenal SKUs to manufacturer + OEM part number
# SPDX-FileCopyrightText: 2026 clg <clg@hackerforge.net>
# SPDX-License-Identifier: GPL-3.0-or-later
# with zero LLM involvement.
#
# How it works:
#   * fastenal.com sits behind Akamai and 403s datacenter IPs, so pages are
#     fetched through the r.jina.ai rendering proxy (free, no key needed,
#     rate-limited -- keep SLEEP >= 2 for bulk runs).
#   * Primary parse: the proxy's markdown render. The spec block is a plain
#     label/value list:  SKU / Manufacturer Part No. / UNSPSC / Manufacturer /
#     Brand, values optionally wrapped in [text](url) links.
#   * Fallback: some renders drop link-wrapped Manufacturer/Brand cells; for
#     those the raw HTML is fetched (X-Return-Format: html) and the spec table
#     divs  <div class="fw-bold me-2">LABEL</div><div>VALUE</div>  are grepped.
#     (HTML mode intermittently returns the unrendered SPA shell; the script
#     detects and retries.)
#
# Usage:   ./fastenal-lookup.sh 0345865 0700343 ...
#          ./fastenal-lookup.sh < skus.txt        (one SKU per line; # comments OK)
#          xargs -n 32 ./fastenal-lookup.sh < skus.txt   (parallel-ish batches)
# Output:  TSV: sku, title, manufacturer, brand, mfr_part_no, unspsc, status
# Env:     CACHE=dir   disk cache (default ~/.cache/fastenal-lookup)
#          SLEEP=secs  pause between live fetches (default 2)
# Sourcing this file (e.g. from tests/run.sh) imports the functions only;
# main() runs when the script is executed directly.

fetch_md() {  # sku -> cached markdown on stdout, or fail
  local sku="$1" f="$CACHE/$sku.md" try
  [[ -s $f ]] && grep -q '### Product Attributes\|### Not Found' "$f" && { cat "$f"; return 0; }
  for try in 1 2 3; do
    curl -sfL --max-time 90 -H "X-Timeout: 30" \
      "https://r.jina.ai/https://www.fastenal.com/product/details/$sku" -o "$f" || return 1
    # rendered pages carry the attributes table or a Not Found heading;
    # unrendered SPA shells are tiny and useless -- retry
    grep -q '### Product Attributes\|### Not Found' "$f" && { cat "$f"; return 0; }
    sleep 2
  done
  rm -f "$f"; return 1
}

fetch_html() {  # sku -> cached html on stdout, or fail
  local sku="$1" f="$CACHE/$sku.html" try
  [[ -s $f ]] && grep -q 'fw-bold me-2\|>Not Found<' "$f" && { cat "$f"; return 0; }
  for try in 1 2 3; do
    curl -sfL --max-time 90 -H "X-Return-Format: html" -H "X-Timeout: 30" \
      "https://r.jina.ai/https://www.fastenal.com/product/details/$sku" -o "$f" || return 1
    grep -q 'fw-bold me-2\|>Not Found<' "$f" && { cat "$f"; return 0; }
    sleep 2
  done
  rm -f "$f"; return 1
}

parse_md() {  # markdown on stdin -> \x1f-separated: title mfr brand mpn unspsc status
  awk -F'\t' -v want="$1" '
    BEGIN { n = split("SKU|Manufacturer Part No.|UNSPSC|Manufacturer|Brand", L, "|")
            for (i = 1; i <= n; i++) lbl[L[i]] = 1 }
    function clean(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      if (s ~ /^\[[^]]*\]\(/) { match(s, /\[[^]]*\]/); s = substr(s, 2, RLENGTH - 2) }
      return s
    }
    /^Title: / { title = substr($0, 8); sub(/ *\| *Fastenal$/, "", title) }
    /### Not Found/ { status = "NOT_FOUND"; exit }
    /^(Alternative|Related) Items/ { exit }   # spec block is above this
    /!\[/ { next }                             # skip image lines
    {
      c = clean($0)
      if (c == "" || c ~ /^###/) { if (c ~ /^###/) cur = ""; next }
      if (c in lbl) { cur = c; next }
      if (cur != "" && !(cur in val)) { val[cur] = c; cur = "" }
    }
    END {
      if (status == "" && val["SKU"] != want) status = "NO_DATA"   # junk/redirected render
      printf "%s\037%s\037%s\037%s\037%s\037%s\n", title, val["Manufacturer"], val["Brand"], \
            val["Manufacturer Part No."], val["UNSPSC"], (status == "" ? "OK" : status)
    }
  ' | head -1
}

parse_html() {  # html on stdin -> \x1f-separated: mfr brand mpn unspsc (fixed order)
  local h="$(sed 's|</div></div>|\n|g')"
  g() { grep -oP "<div class=\"fw-bold me-2\">$1</div><div>(<a[^>]*>)?\K[^<]*" <<<"$h" | head -1; }
  printf '%s\037%s\037%s\037%s\n' "$(g 'Manufacturer')" "$(g 'Brand')" \
    "$(g 'Manufacturer Part No\.')" "$(g 'UNSPSC')"
}

main() {
  CACHE="${CACHE:-$HOME/.cache/fastenal-lookup}"
  SLEEP="${SLEEP:-2}"
  mkdir -p "$CACHE"

  # SKUs from args, or one per line from stdin (CRLF, blanks, #-comments tolerated)
  if (( $# == 0 )); then
    [[ -t 0 ]] && { echo "usage: ${0##*/} SKU [SKU...]  (or pipe SKUs on stdin)" >&2; exit 1; }
    mapfile -t skus < <(tr -d '\r' | grep -Ev '^[[:space:]]*($|#)')
    set -- "${skus[@]}"
  fi
  (( $# > 0 )) || { echo "${0##*/}: no SKUs given" >&2; exit 1; }

  printf 'sku\ttitle\tmanufacturer\tbrand\tmfr_part_no\tunspsc\tstatus\n'

  for sku in "$@"; do
  if md=$(fetch_md "$sku"); then
    IFS=$'\037' read -r title mfr brand mpn unspsc status <<<"$(parse_md "$sku" <<<"$md")"
    # some renders drop link-wrapped Manufacturer/Brand cells -> HTML fallback
    if [[ $status == OK && ( -z $mfr || -z $brand ) ]] && html=$(fetch_html "$sku"); then
      IFS=$'\037' read -r hmfr hbrand hmpn hunspsc <<<"$(parse_html <<<"$html")"
      mfr=${mfr:-$hmfr}; brand=${brand:-$hbrand}
      mpn=${mpn:-$hmpn};   unspsc=${unspsc:-$hunspsc}
    fi
    [[ $status == OK && -z $mfr && -z $brand && -z $mpn ]] && status=PARTIAL
  else
    title=-; mfr=-; brand=-; mpn=-; unspsc=-; status=FETCH_FAILED
  fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sku" "${title:--}" "${mfr:--}" "${brand:--}" "${mpn:--}" "${unspsc:--}" "$status"
    sleep "$SLEEP"
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
