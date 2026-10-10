# fastenal-lookup.ps1 -- Fastenal SKU -> manufacturer + OEM part number
# SPDX-FileCopyrightText: 2026 clg <clg@hackerforge.net>
# SPDX-License-Identifier: GPL-3.0-or-later
# PowerShell port of fastenal-lookup.sh (no dependencies; works on Windows
# PowerShell 5.1 and PowerShell 7+, and on Linux/macOS pwsh).
#
# Usage:
#   .\fastenal-lookup.ps1 0345865 0700343 ...          args
#   Get-Content skus.txt | .\fastenal-lookup.ps1       pipe
#   .\fastenal-lookup.ps1 < skus.txt                   redirect (CRLF/# ok)
#   .\fastenal-lookup.ps1 .\skus.txt                   path to a SKU list file
#   .\fastenal-lookup.ps1 -Pretty ...                   formatted table
#   .\fastenal-lookup.ps1 ... | Out-File -Encoding utf8 out.csv
#     (use Out-File, not >, on PS 5.1 to keep UTF-8 + BOM intact)
#   .\fastenal-lookup.ps1 -Tsv ...                      tab-separated (default: CSV)
#
# Method (same as the bash version): fetch the Fastenal product page through
# the r.jina.ai rendering proxy (fastenal.com blocks non-browser clients),
# parse the markdown spec block (SKU / Manufacturer Part No. / UNSPSC /
# Manufacturer / Brand), fall back to raw-HTML mode for renders that drop
# link-wrapped cells. Disk-cached under %LOCALAPPDATA%\fastenal-lookup
# (or ~/.cache/fastenal-lookup on Unix).
#
# Dot-sourcing this file from a script (e.g. tests/run.ps1) imports the
# functions below into the caller's scope; the dispatch (init/stdin/emit)
# is skipped unless the script is run standalone (e.g. via -File).
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)]
    [string[]]$Sku,
    [switch]$Pretty,
    [switch]$Tsv,
    [string]$CacheDir,
    [int]$SleepSec = 2
)

begin {
    $script:Standalone = $false
    $script:rows = New-Object System.Collections.Generic.List[object]
    $script:sawInput = $false

    # sku -> markdown or html text; null on failure. Cache is validated on
    # read too (a previously-cached unrendered SPA shell is refetched).
    function Get-Page {
        param([string]$Sku, [ValidateSet('md', 'html')][string]$Mode)
        $ext = if ($Mode -eq 'md') { 'md' } else { 'html' }
        $path = Join-Path $CacheDir "$Sku.$ext"
        $url = "https://r.jina.ai/https://www.fastenal.com/product/details/$Sku"
        $okPattern = if ($Mode -eq 'md') { '### Product Attributes|### Not Found' }
                     else { 'fw-bold me-2|>Not Found<' }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $c = [IO.File]::ReadAllText($path)   # strips BOM, reads UTF-8
            if ($c -match $okPattern) { return $c }
        }
        $headers = @{}
        if ($Mode -eq 'html') { $headers['X-Return-Format'] = 'html' }
        for ($i = 0; $i -lt 3; $i++) {
            try {
                $r = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 90 -UserAgent 'fastenal-lookup/1.0 (+https://github.com/cgoetzke/part-lookups)'
                if ($r.Content -match $okPattern) {
                    [IO.File]::WriteAllText($path, $r.Content, (New-Object Text.UTF8Encoding($false)))
                    return $r.Content
                }
            } catch { }
            Start-Sleep -Seconds 2
        }
        return $null
    }

    # markdown -> fields (port of the awk state machine)
    function ConvertFrom-Md {
        param([string]$Md, [string]$WantSku)
        $labels = @('SKU', 'Manufacturer Part No.', 'UNSPSC', 'Manufacturer', 'Brand')
        $val = @{}
        $cur = $null
        $title = $null
        $status = 'OK'
        foreach ($line in ($Md -split "`r?`n")) {
            if ($line -match '^Title: (.+)$') { $title = $Matches[1] -replace ' \|\s*Fastenal$', ''; continue }
            if ($line -match '### Not Found') { $status = 'NOT_FOUND'; break }
            if ($line -match '^(Alternative|Related) Items') { break }
            if ($line -match '!\[') { continue }                        # images
            $c = $line.Trim()
            if ($c -eq '') { continue }
            if ($c -match '^###') { $cur = $null; continue }           # headings
            if ($labels -contains $c) { $cur = $c; continue }
            if ($cur -and -not $val.ContainsKey($cur)) {
                if ($c -match '^\[([^\]]*)\]\(') { $c = $Matches[1] }  # [text](url)
                $val[$cur] = $c
                $cur = $null
            }
        }
        if ($status -eq 'OK' -and $val['SKU'] -cne $WantSku) { $status = 'NO_DATA' }
        [pscustomobject]@{
            Title = $title; Mfr = $val['Manufacturer']; Brand = $val['Brand']
            Mpn = $val['Manufacturer Part No.']; Unspsc = $val['UNSPSC']; Status = $status
        }
    }

    # raw html -> fields (spec table: <div class="fw-bold me-2">L</div><div>V</div>)
    function ConvertFrom-Html {
        param([string]$Html)
        $pairs = $Html -replace '</div></div>', "`n"
        function Get-Val([string]$Label) {
            $re = '<div class="fw-bold me-2">' + [regex]::Escape($Label) + '</div><div>(?:<a[^>]*>)?([^<]*)'
            if ($pairs -match $re) { $Matches[1].Trim() } else { $null }
        }
        [pscustomobject]@{
            Mfr = Get-Val 'Manufacturer'; Brand = Get-Val 'Brand'
            Mpn = Get-Val 'Manufacturer Part No.'; Unspsc = Get-Val 'UNSPSC'
        }
    }

    function Invoke-Lookup {
        param([string]$Sku)
        $md = Get-Page -Sku $Sku -Mode md
        if ($md) {
            $r = ConvertFrom-Md -Md $md -WantSku $Sku
            if ($r.Status -eq 'OK' -and (-not $r.Mfr -or -not $r.Brand)) {
                $html = Get-Page -Sku $Sku -Mode html
                if ($html) {
                    $h = ConvertFrom-Html -Html $html
                    if (-not $r.Mfr)    { $r.Mfr    = $h.Mfr }
                    if (-not $r.Brand)  { $r.Brand  = $h.Brand }
                    if (-not $r.Mpn)    { $r.Mpn    = $h.Mpn }
                    if (-not $r.Unspsc) { $r.Unspsc = $h.Unspsc }
                }
            }
            if ($r.Status -eq 'OK' -and -not $r.Mfr -and -not $r.Brand -and -not $r.Mpn) { $r.Status = 'PARTIAL' }
        } else {
            $r = [pscustomobject]@{ Title = '-'; Mfr = '-'; Brand = '-'; Mpn = '-'; Unspsc = '-'; Status = 'FETCH_FAILED' }
        }
        $script:rows.Add([pscustomobject]@{
            Sku = $Sku; Title = $r.Title; Manufacturer = $r.Mfr; Brand = $r.Brand
            MfrPartNo = $r.Mpn; Unspsc = $r.Unspsc; Status = $r.Status
        })
        if ($script:Standalone) { Start-Sleep -Seconds $SleepSec }   # pacing parity with bash
    }

    function Add-Skus {
        # accepts SKU strings; a path to an existing file is read as a SKU list instead
        param([string[]]$Items)
        foreach ($s in $Items) {
            $t = "$s".Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            if (Test-Path -LiteralPath $t -PathType Leaf) {
                Add-Skus -Items ([IO.File]::ReadAllLines($t))
            } else {
                $script:sawInput = $true
                if ($t -notmatch '^[A-Za-z0-9._-]{1,32}$') {
                    # SKUs become cache filenames -- keep them inside the charset
                    [Console]::Error.WriteLine(("invalid SKU '{0}' (allowed: letters, digits, . _ -; max 32)" -f $t))
                    $script:rows.Add([pscustomobject]@{
                        Sku = $t; Title = '-'; Manufacturer = '-'; Brand = '-'
                        MfrPartNo = '-'; Unspsc = '-'; Status = 'INVALID_SKU'
                    })
                } else {
                    Invoke-Lookup -Sku $t
                }
            }
        }
    }

    # CSV field: RFC4180-quote when it contains , " or newline
    function ConvertTo-CsvField {
        param([string]$Field)
        if ($Field -match '[,"\r\n]') { '"' + $Field.Replace('"', '""') + '"' } else { $Field }
    }

    # Excel-safe twin: ="v" for values Excel would coerce on CSV open
    # (leading zeros; date/fraction/scientific lookalikes: digits and
    # . , / + e E after a digit, dot, or plus start), and for anything
    # Excel would evaluate as a formula (via ConvertTo-XlsField)
    function ConvertTo-ExcelField {
        param([string]$Field)
        if ($Field -match '^[0-9.+][0-9.,/+eE-]*$') { '="' + $Field + '"' }
        elseif ($Field -eq '-') { $Field }
        else { ConvertTo-XlsField $Field }
    }

    # CSV-formula neuter: a field Excel would evaluate (= + - @ tab CR
    # prefix) becomes an inert ="..." literal, like the _excel twins.
    # The exact '-' missing-value marker passes through.
    function ConvertTo-XlsField {
        param([string]$Field)
        if ($Field -ne '-' -and $Field -match '^[=+@\t\r-]') { '="' + $Field.Replace('"', '""') + '"' } else { $Field }
    }

    # TSV field: embedded tabs/newlines would break the column count;
    # replace with spaces (same sanitization as the bash port)
    function ConvertTo-TsvField {
        param([string]$Field)
        $Field -replace "[`t`r`n]", ' '
    }

    # --- functions end here; below runs only standalone ---
    if ($MyInvocation.ScriptName -ne '') { return }   # dot-sourced: import only
    $script:Standalone = $true

    # PS 5.1 on older Windows may default below TLS 1.2
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    if (-not $CacheDir) {
        $CacheDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'fastenal-lookup' }
                    else { Join-Path $HOME '.cache/fastenal-lookup' }
    }
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
}

process {
    if ($script:Standalone -and $Sku) { Add-Skus -Items $Sku }
}

end {
    if (-not $script:Standalone) { return }
    if (-not $script:sawInput) {
        if ([Console]::IsInputRedirected) {
            Add-Skus -Items ([Console]::In.ReadToEnd() -split "`r?`n")
        } else {
            $ans = Read-Host 'Fastenal SKUs (space/comma separated, or a path to a .txt list)'
            if ($ans) { Add-Skus -Items ($ans -split '[,\s]+') }
        }
        if (-not $script:sawInput) {
            [Console]::Error.WriteLine('usage: fastenal-lookup.ps1 [-Pretty] SKU [SKU...]  (or pipe/redirect SKUs, or pass a .txt list file)')
            exit 1
        }
    }
    if ($Pretty) {
        $script:rows | Format-Table Sku,
            @{n='Title';e={ if ($_.Title -and $_.Title.Length -gt 55) { $_.Title.Substring(0,55) + '...' } else { $_.Title } }},
            Manufacturer, Brand, MfrPartNo, Unspsc, Status -AutoSize | Out-String -Width 4096
    } else {
        # Default output: Excel-friendly CSV (comma-delimited, RFC4180-
        # quoted, UTF-8 BOM via Out-File on PS 5.1). CSV carries _excel
        # twins of the two key columns: formula cells (="0345865") that
        # Excel renders intact instead of coercing to number/date.
        # -Tsv restores pure tab-separated output for pipes.
        if ($Tsv) {
            ('sku','title','manufacturer','brand','mfr_part_no','unspsc','status') -join "`t"
            foreach ($r in $script:rows) {
                $f = @($r.Sku, $r.Title, $r.Manufacturer, $r.Brand, $r.MfrPartNo, $r.Unspsc, $r.Status) |
                     ForEach-Object { if ($_ -eq $null -or $_ -eq '') { '-' } else { "$_" } }
                ($f | ForEach-Object { ConvertTo-TsvField $_ }) -join "`t"
            }
        } else {
            ('sku','sku_excel','title','manufacturer','brand','mfr_part_no','mfr_part_excel','unspsc','status') -join ','
            foreach ($r in $script:rows) {
                $f = @((ConvertTo-XlsField "$($r.Sku)"), (ConvertTo-ExcelField "$($r.Sku)"),
                       (ConvertTo-XlsField "$($r.Title)"), (ConvertTo-XlsField "$($r.Manufacturer)"), (ConvertTo-XlsField "$($r.Brand)"),
                       (ConvertTo-XlsField "$($r.MfrPartNo)"), (ConvertTo-ExcelField "$($r.MfrPartNo)"),
                       (ConvertTo-XlsField "$($r.Unspsc)"), (ConvertTo-XlsField "$($r.Status)")) |
                     ForEach-Object { if ($_ -eq $null -or $_ -eq '') { '-' } else { "$_" } }
                ($f | ForEach-Object { ConvertTo-CsvField $_ }) -join ','
            }
        }
    }
}
