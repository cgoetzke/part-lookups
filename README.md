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
./fastenal-lookup.sh < skus-example.txt > out.tsv        # TSV to stdout
./fastenal-lookup.sh -Pretty 0345865 0700343 2>/dev/null # bash has no -Pretty;
                                                         # pipe through column -t -s$'\t'
```

```powershell
.\fastenal-lookup.ps1 -Pretty 0345865 0700343            # formatted table
.\fastenal-lookup.ps1 .\skus-example.txt                  # list file arg
Get-Content skus.txt | .\fastenal-lookup.ps1              # pipe
... | Out-File -Encoding utf8 out.tsv                     # save (use Out-File, not >, on PS 5.1)
```

Or on Windows: double-click `lookup.bat`, or drag a SKU-list `.txt` onto it.

Input: SKUs as args, one per line on stdin, or a `.txt` list file
(blank lines and `#` comments tolerated). Output TSV columns:
`sku, title, manufacturer, brand, mfr_part_no, unspsc, status`.

## How it works

fastenal.com sits behind Akamai and rejects non-browser clients, so pages
are fetched through the free `r.jina.ai` rendering proxy (~20 req/min
unauthenticated — the default 2s pacing stays well under). The primary parse
reads the markdown render's spec block (`SKU` / `Manufacturer Part No.` /
`UNSPSC` / `Manufacturer` / `Brand` label/value pairs); a raw-HTML fallback
greps the `<div class="fw-bold me-2">LABEL</div><div>VALUE</div>` spec table
for renders that drop link-wrapped cells. Fetched pages are cached under
`~/.cache/fastenal-lookup` (`%LOCALAPPDATA%\fastenal-lookup` on Windows), so
reruns are free.

Statuses: `OK` / `NOT_FOUND` (Fastenal has no such SKU) / `NO_DATA`
(unusable render) / `PARTIAL` (fields missing) / `FETCH_FAILED`.

## Data notes

- Fastenal private-label items (ORMADUS, Body Guard, ...) list manufacturer
  `FASTENAL APPROVED VENDOR` and **no** `mfr_part_no` — that is genuine
  (no separate OEM number exists), not a lookup failure.
- `unspsc` is the vendor-neutral UNSPSC commodity code — useful for finding
  equivalents at other distributors.
- Fastenal also prints manufacturer part numbers in "BRY5965Y"-style form;
  the OEM's own catalog number may be shorter (e.g. Bryant `5965Y`).
