<#
.SYNOPSIS
    Tests the maximum payload size accepted by Invoke-GenerateQR across all
    error correction levels, for both text and byte array inputs.

.DESCRIPTION
    Performs a binary search for the exact byte threshold at which QRCoder
    stops accepting data for each ECC level (L, M, Q, H).
    Results are printed to the console and written to a CSV summary.

.NOTES
    Dot-source Invoke-GenerateQR.ps1 before running, or place both files in
    the same directory — the script will dot-source automatically.
#>

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Auto dot-source if function not already loaded ────────────────────────────
if (-not (Get-Command Invoke-GenerateQR -ErrorAction SilentlyContinue)) {
    $scriptPath = Join-Path $PSScriptRoot 'Invoke-GenerateQR.ps1'
    if (Test-Path $scriptPath) {
        . $scriptPath
        Write-Host "[setup] Loaded Invoke-GenerateQR from: $scriptPath" -ForegroundColor Cyan
    } else {
        throw "Invoke-GenerateQR.ps1 not found in $PSScriptRoot — dot-source it manually first."
    }
}

# ── Helpers ───────────────────────────────────────────────────────────────────

function Test-QRBytes {
    <#
    Attempts to generate a QR code from a byte array of the given size.
    Returns $true on success, $false on capacity failure.
    Throws for any unexpected error.
    #>
    param(
        [int]    $Size,
        [string] $ECC
    )
    $ba = [byte[]]::new($Size)
    # Fill with printable ASCII (0x41 = 'A') so QRCoder uses binary mode
    for ($i = 0; $i -lt $Size; $i++) { $ba[$i] = 0x41 }

    try {
        $null = Invoke-GenerateQR -Bytes $ba -ErrorCorrection $ECC -NoDisplay -TestLimits
        return $true
    } catch {
        $msg = $_.Exception.Message
        # QRCoder throws when data exceeds version 40 capacity
        if ($msg -match 'too long|capacity|version|exceed|overflow|data') {
            return $false
        }
        # Re-throw anything unexpected
        throw
    }
}

function Test-QRText {
    <#
    Attempts to generate a QR code from an ASCII string of the given length.
    Returns $true on success, $false on capacity failure.
    #>
    param(
        [int]    $Length,
        [string] $ECC
    )
    $text = 'A' * $Length

    try {
        $null = Invoke-GenerateQR -Text $text -ErrorCorrection $ECC -NoDisplay -TestLimits
        return $true
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'too long|capacity|version|exceed|overflow|data') {
            return $false
        }
        throw
    }
}

function Find-MaxSize {
    <#
    Binary search between $Low and $High (inclusive) for the largest value
    where $TestBlock returns $true.
    #>
    param(
        [int]      $Low,
        [int]      $High,
        [string]   $ECC,
        [string]   $Mode,       # 'Bytes' or 'Text'
        [string]   $Label
    )

    $best = $Low - 1

    while ($Low -le $High) {
        $mid = [int](($Low + $High) / 2)

        Write-Host "  [$Label] testing size $mid ... " -NoNewline

        $ok = if ($Mode -eq 'Bytes') {
            Test-QRBytes -Size $mid -ECC $ECC
        } else {
            Test-QRText  -Length $mid -ECC $ECC
        }

        if ($ok) {
            Write-Host "OK" -ForegroundColor Green
            $best = $mid
            $Low  = $mid + 1
        } else {
            Write-Host "FAIL" -ForegroundColor Red
            $High = $mid - 1
        }
    }

    return $best
}

# ── Main ──────────────────────────────────────────────────────────────────────

$eccLevels   = @('L', 'M', 'Q', 'H')
$results     = [System.Collections.Generic.List[PSCustomObject]]::new()

# Theoretical maximums per QR spec (version 40) — used as upper bounds
# Bytes: L=2953  M=2331  Q=1663  H=1273
# Text (alphanumeric ASCII): L=4296  M=3391  Q=2420  H=1852
$byteUpperBounds = @{ L = 3100; M = 2500; Q = 1800; H = 1400 }
$textUpperBounds = @{ L = 4500; M = 3600; Q = 2600; H = 2000 }

$totalStart = Get-Date
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Invoke-GenerateQR  —  Maximum Payload Size Tests"      -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

foreach ($ecc in $eccLevels) {

    Write-Host "── ECC level: $ecc ─────────────────────────────────────" -ForegroundColor Yellow
    Write-Host ""

    # ── Byte array test ───────────────────────────────────────────────────
    Write-Host "  [Bytes / ECC $ecc]  Binary search 1 .. $($byteUpperBounds[$ecc])" -ForegroundColor White
    $t0      = Get-Date
    $maxBytes = Find-MaxSize -Low 1 -High $byteUpperBounds[$ecc] `
                             -ECC $ecc -Mode 'Bytes' `
                             -Label "Bytes/$ecc"
    $elapsed = (Get-Date) - $t0

    Write-Host "  => Max bytes  (ECC $ecc): $maxBytes  [$([math]::Round($elapsed.TotalSeconds,1))s]" `
               -ForegroundColor Cyan
    Write-Host ""

    # ── Text test ─────────────────────────────────────────────────────────
    Write-Host "  [Text  / ECC $ecc]  Binary search 1 .. $($textUpperBounds[$ecc])" -ForegroundColor White
    $t0      = Get-Date
    $maxText  = Find-MaxSize -Low 1 -High $textUpperBounds[$ecc] `
                             -ECC $ecc -Mode 'Text' `
                             -Label "Text/$ecc"
    $elapsed = (Get-Date) - $t0

    Write-Host "  => Max chars  (ECC $ecc): $maxText  [$([math]::Round($elapsed.TotalSeconds,1))s]" `
               -ForegroundColor Cyan
    Write-Host ""

    $results.Add([PSCustomObject]@{
        ECC          = $ecc
        MaxBytes     = $maxBytes
        MaxTextChars = $maxText
        SpecBytes    = @{ L=2953; M=2331; Q=1663; H=1273 }[$ecc]
        SpecChars    = @{ L=4296; M=3391; Q=2420; H=1852 }[$ecc]
    })
}

$totalElapsed = (Get-Date) - $totalStart

# ── Results table ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RESULTS  (QR spec reference values in parentheses)"   -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-6} {1,14} {2,14} {3,14} {4,14}" -f `
    'ECC', 'Max bytes', '(spec)', 'Max chars', '(spec)') -ForegroundColor White
Write-Host ("{0,-6} {1,14} {2,14} {3,14} {4,14}" -f `
    '---', '---------', '------', '---------', '------')

foreach ($r in $results) {
    $byteMatch = if ($r.MaxBytes -eq $r.SpecBytes) { '✓' } else { '≠' }
    $textMatch = if ($r.MaxTextChars -eq $r.SpecChars) { '✓' } else { '≠' }

    Write-Host ("{0,-6} {1,12} {2,2} {3,8} {4,12} {5,2} {6,8}" -f `
        $r.ECC,
        $r.MaxBytes,    "($($r.SpecBytes)) $byteMatch",
        '',
        $r.MaxTextChars,"($($r.SpecChars)) $textMatch",
        '') -ForegroundColor $(if ($byteMatch -eq '✓' -and $textMatch -eq '✓') { 'Green' } else { 'Yellow' })
}

Write-Host ""
Write-Host "Total elapsed: $([math]::Round($totalElapsed.TotalSeconds,1))s" -ForegroundColor Gray

# ── CSV export ────────────────────────────────────────────────────────────────
$csvPath = Join-Path $PSScriptRoot 'QRCapacityResults.csv'
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "Results saved to: $csvPath" -ForegroundColor Gray
Write-Host ""