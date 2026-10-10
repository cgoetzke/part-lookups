# tests/run.ps1 -- offline test suite for fastenal-lookup.ps1
# SPDX-License-Identifier: GPL-3.0-or-later
# Mirrors tests/run.sh. Run:  pwsh tests/run.ps1   (or powershell.exe)
# Written for Windows PowerShell 5.1 compatibility.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$Fix  = Join-Path $PSScriptRoot 'fixtures/cache'

$script:Pass = 0; $script:Fail = 0
function Ok([string]$d) { $script:Pass++; Write-Host "ok   $d" }
function Bad([string]$d, [string]$e, [string]$a) {
    $script:Fail++; Write-Host "FAIL $d"
    Write-Host ("  expected: {0}" -f ("$e" -replace "`t", '<TAB>'))
    Write-Host ("  actual:   {0}" -f ("$a" -replace "`t", '<TAB>'))
}
function AssertEq([string]$d, $e, $a) { if ("$e" -ceq "$a") { Ok $d } else { Bad $d "$e" "$a" } }
function Row($o, [string]$sku) { @($o | Where-Object { $_ -like "$sku`t*" })[0] }

# --- dot-source imports functions, runs no dispatch
. (Join-Path $Root 'fastenal-lookup.ps1')
if (Get-Command ConvertFrom-Md -ErrorAction SilentlyContinue) { Ok 'dot-source imports functions' }
else { Bad 'dot-source imports functions' 'defined' 'missing' }

# --- ConvertFrom-Md unit tests (against real cached renders)
function MdFields([string]$file, [string]$want) {
    $r = ConvertFrom-Md -Md ([IO.File]::ReadAllText((Join-Path $Fix $file))) -WantSku $want
    (@($r.Title, $r.Mfr, $r.Brand, $r.Mpn, $r.Unspsc, $r.Status) | ForEach-Object { "$_" }) -join '|'
}
AssertEq 'md: full fields (0700344)' `
    '15A 125V 2P 3W 5-15 Yellow Straight Connector|HUBBELL|BRYANT|BRY5969Y|39121421|OK' `
    (MdFields '0700344.md' '0700344')
AssertEq 'md: private label, no mpn (0345865)' `
    '1/2" x 6" OAL 135° Split Black / Gold High Speed Steel Straight Jobber Drill|FASTENAL APPROVED VENDOR|ORMADUS||23241634|OK' `
    (MdFields '0345865.md' '0345865')
AssertEq 'md: pipe in title stripped (9999999)' `
    'Material Test Report|Fastenal Approved Vendor|||77102001|OK' `
    (MdFields '9999999.md' '9999999')
AssertEq 'md: not-found page' 'Not Found|||||NOT_FOUND' (MdFields '0000001.md' '0000001')
AssertEq 'md: SPA shell -> NO_DATA' '|||||NO_DATA' (MdFields '0000002.md' '0000002')

# --- ConvertFrom-Html unit test
$h = ConvertFrom-Html -Html ([IO.File]::ReadAllText((Join-Path $Fix '0700343.html')))
AssertEq 'html: spec-table pairs' 'HUBBELL|BRYANT|BRY5965Y|39121402' `
    ((@($h.Mfr, $h.Brand, $h.Mpn, $h.Unspsc) | ForEach-Object { "$_" }) -join '|')

# --- ConvertTo-CsvField unit tests (RFC4180 quoting)
AssertEq 'csv field: plain untouched' 'abc' (ConvertTo-CsvField 'abc')
AssertEq 'csv field: comma quoted' '"a,b"' (ConvertTo-CsvField 'a,b')
AssertEq 'csv field: quote doubled' '"a""b"' (ConvertTo-CsvField 'a"b')

# --- Get-Page: cache hit is offline
$CacheDir = $Fix
$md = Get-Page -Sku 0700344 -Mode md
if ("$md" -match '### Product Attributes') { Ok 'Get-Page cache hit' } else { Bad 'Get-Page cache hit' 'attributes' 'miss' }

# --- Get-Page: stubbed network (function shadows the cmdlet in this scope)
function Invoke-WebRequest {
    param([string]$Uri, [hashtable]$Headers, [switch]$UseBasicParsing, [int]$TimeoutSec)
    [pscustomobject]@{ Content = $script:StubContent }
}
$tdir = Join-Path ([IO.Path]::GetTempPath()) ("fltest-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tdir | Out-Null

$CacheDir = $tdir
$script:StubContent = '<html><head></head><body><div id="root"></div></body></html>'
$md = Get-Page -Sku 1111111 -Mode md
if (-not $md) { Ok 'stub: persistent shell -> null' } else { Bad 'stub: persistent shell -> null' '$null' 'content' }
if (-not (Test-Path (Join-Path $tdir '1111111.md'))) { Ok 'stub: shell not cached' } else { Bad 'stub: shell not cached' 'absent' 'present' }

$good = [IO.File]::ReadAllText((Join-Path $Fix '0700344.md'))
[IO.File]::WriteAllText((Join-Path $tdir '0700344.md'), '<div id="root"></div>')
$script:StubContent = $good
$md = Get-Page -Sku 0700344 -Mode md
AssertEq 'stub: stale shell rejected, good page refetched' $good "$md"

Remove-Item -Recurse -Force $tdir -ErrorAction SilentlyContinue

# --- end-to-end via a child engine process, offline via fixture cache
$psExe = (Get-Process -Id $PID).Path
$script1 = Join-Path $Root 'fastenal-lookup.ps1'
$out = & $psExe -NoProfile -File $script1 -Tsv -CacheDir $Fix -SleepSec 0 0700344 0345865 9999999 0000001
AssertEq 'e2e: header' "sku`ttitle`tmanufacturer`tbrand`tmfr_part_no`tunspsc`tstatus" (@($out)[0])
AssertEq 'e2e: 0700344 row' `
    "0700344`t15A 125V 2P 3W 5-15 Yellow Straight Connector`tHUBBELL`tBRYANT`tBRY5969Y`t39121421`tOK" `
    (Row $out '0700344')
AssertEq 'e2e: 0345865 row' `
    "0345865`t1/2"" x 6"" OAL 135° Split Black / Gold High Speed Steel Straight Jobber Drill`tFASTENAL APPROVED VENDOR`tORMADUS`t-`t23241634`tOK" `
    (Row $out '0345865')
AssertEq 'e2e: 9999999 row' `
    "9999999`tMaterial Test Report`tFastenal Approved Vendor`t-`t-`t77102001`tOK" `
    (Row $out '9999999')
AssertEq 'e2e: NOT_FOUND row' `
    "0000001`tNot Found`t-`t-`t-`t-`tNOT_FOUND" `
    (Row $out '0000001')

$out2 = & $psExe -NoProfile -File $script1 -Tsv -CacheDir $Fix -SleepSec 0 0700343
AssertEq 'e2e: md/html fallback fills blank fields (0700343)' `
    "0700343`t15A 125V 2P 3W NEMA 5-15 Yellow Straight Blade Plug`tHUBBELL`tBRYANT`tBRY5965Y`t39121402`tOK" `
    (Row $out2 '0700343')

$out3 = '0700344', '# comment', '', '0345865' | & $psExe -NoProfile -File $script1 -Tsv -CacheDir $Fix -SleepSec 0
AssertEq 'e2e: pipe input with comments/blanks (3 lines)' 3 @($out3).Count

# --- default output format: Excel-friendly CSV (no BOM from the script
#     itself on PS; Out-File -Encoding utf8 supplies it on 5.1)
$outc = & $psExe -NoProfile -File $script1 -CacheDir $Fix -SleepSec 0 0700344
AssertEq 'e2e: default CSV header' 'sku,title,manufacturer,brand,mfr_part_no,unspsc,status' (@($outc)[0])
AssertEq 'e2e: default CSV row' `
    '0700344,15A 125V 2P 3W 5-15 Yellow Straight Connector,HUBBELL,BRYANT,BRY5969Y,39121421,OK' `
    (@($outc | Where-Object { $_ -like '0700344,*' })[0])

Write-Host ''
Write-Host ("passed {0}, failed {1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
