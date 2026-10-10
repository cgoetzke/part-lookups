# part-lookups

Resolve distributor SKUs to manufacturer + OEM part number.

## Tools

| File | Environment |
|---|---|
| `fastenal-lookup.sh` | bash — Linux/macOS/Git Bash (needs curl, GNU grep/sed/awk) |
| `fastenal-lookup.ps1` | PowerShell 5.1+ / 7 — zero dependencies, Windows-friendly |
| `lookup.bat` | double-click wrapper for the .ps1 (prompts for SKUs) |

## Usage

```sh
./fastenal-lookup.sh < examples/fastenal-skus.txt > out.csv    # CSV (Excel-friendly: quoted, BOM, twins)
TSV=1 ./fastenal-lookup.sh < examples/fastenal-skus.txt | column -t -s$'\t'  # TSV (pipe-friendly)
```

```powershell
.\fastenal-lookup.ps1 -Pretty 0345865 0700343            # formatted table
.\fastenal-lookup.ps1 .\examples\fastenal-skus.txt        # list file arg (CSV default)
Get-Content -Encoding UTF8 examples\fastenal-skus.txt | .\fastenal-lookup.ps1  # pipe (5.1-safe)
.\fastenal-lookup.ps1 -Tsv 0345865                       # tab-separated
... | Out-File -Encoding utf8 out.csv                     # save (5.1 adds the BOM; PS 7 utf8 is BOM-less -- use utf8BOM there)
```

CSV mode also emits `sku_excel` / `mfr_part_excel` twin columns: formula cells (`="0345865"`) that Excel renders intact instead of eating leading zeros or turning `06-243` into a date. TSV output (`TSV=1` / `-Tsv`) stays lean for scripts; fields containing tabs or newlines are replaced with spaces in both implementations. Formula-injection guard: any field Excel would evaluate as a formula (`=`, `+`, `-`, `@`, tab, or CR prefix — including echoed invalid SKUs) is neutered into the same `="..."` literal form in CSV mode; TSV leaves field content untouched.

Or on Windows: double-click `lookup.bat`, or drag a SKU-list `.txt` onto it.

Input: SKUs as args, one per line on stdin, or a `.txt` list file
(blank lines and `#` comments tolerated). Output TSV columns:
`sku, title, manufacturer, brand, mfr_part_no, unspsc, status`.

## How it works

fastenal.com sits behind Akamai and rejects non-browser clients, so pages
are fetched through the free `r.jina.ai` rendering proxy (~20 req/min
unauthenticated; the default 2s pacing (~30/min) can brush that ceiling on
long runs -- raise `SLEEP` / `-SleepSec` to 3+ for bulk). The primary parse
reads the markdown render's spec block (`SKU` / `Manufacturer Part No.` /
`UNSPSC` / `Manufacturer` / `Brand` label/value pairs); a raw-HTML fallback
greps the `<div class="fw-bold me-2">LABEL</div><div>VALUE</div>` spec table
for renders that drop link-wrapped cells. Fetched pages are cached under
`~/.cache/fastenal-lookup` (`%LOCALAPPDATA%\fastenal-lookup` on Windows), so
reruns are free.

Statuses: `OK` / `NOT_FOUND` (Fastenal has no such SKU) / `NO_DATA`
(unusable render) / `PARTIAL` (fields missing) / `FETCH_FAILED`.

## Tests

Offline suites — real cached Fastenal renders as fixtures under
`tests/fixtures/cache/`, network paths stubbed. No dependencies beyond the
scripts themselves.

```sh
tests/run.sh            # bash suite
pwsh tests/run.ps1      # PowerShell suite (powershell.exe 5.1 works too)
```

Notable fixtures: `0700343.md` is a real render whose Manufacturer/Brand
cells were dropped (drives the HTML-fallback path via `0700343.html`);
`9999999.md` regresses the pipe-in-page-title parsing bug; `0000001.md` is a
Not Found page; `0000002.md` is a genuine unrendered SPA shell. Both scripts
are sourceable (`source ./fastenal-lookup.sh` / `. .\fastenal-lookup.ps1`)
so tests can unit-test the parsers directly — dispatch only runs standalone.

## Data notes

- Fastenal private-label items (ORMADUS, Body Guard, ...) list manufacturer
  `FASTENAL APPROVED VENDOR` and **no** `mfr_part_no` — that is genuine
  (no separate OEM number exists), not a lookup failure.
- `unspsc` is the vendor-neutral UNSPSC commodity code — useful for finding
  equivalents at other distributors.
- Fastenal also prints manufacturer part numbers in "BRY5965Y"-style form;
  the OEM's own catalog number may be shorter (e.g. Bryant `5965Y`).

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). Covers the scripts and test
suites. The `tests/fixtures/cache/` page captures are factual product data
(not copyrightable) and carry no license claim.
