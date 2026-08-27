# The N-Queens case study, measured.
#
#     powershell -File bench\queens\run.ps1 [-N 11] [-Reps 3]
#
# Runs every variant, MINIMA over repetitions, and refuses to print a
# speed table until the answers agree. `countSol` is the invariant every
# variant must reproduce -- it is a published constant of the problem, so
# a variant that is faster and wrong cannot pass. V0 and V1 must also
# agree on countPlace and countQueen, because their search is identical;
# V2 changes the algorithm and is checked on solutions alone.
#
# Single runs are not reported. An earlier pass of this study quoted them
# and two of the differences it "found" were inside the noise.

param([int]$N = 11, [int]$Reps = 3, [string]$Ring = "D:\ring127\bin\ring.exe")

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path $Ring)) { Write-Host "SKIP queens  no Ring at $Ring"; exit 0 }

$variants = @(
    @{ File = 'v0-original.ring';  Name = 'V0  original';               Group = 'same-search' }
    @{ File = 'v1-one-fabs.ring';  Name = 'V1  one fabs() removed';     Group = 'same-search' }
    @{ File = 'x1-rppindexed.ring'; Name = 'X1  + RppIndexed (rejected)'; Group = 'same-search' }
    @{ File = 'x2-parameter.ring';  Name = 'X2  board as param (rejected)'; Group = 'same-search' }
    @{ File = 'v2-occupancy.ring'; Name = 'V2  occupancy flags';        Group = 'algorithm'   }
    @{ File = 'v3-bitmask.ring';   Name = 'V3  bitmask, no board';      Group = 'algorithm'   }
)

# Ring resolves a relative `load` against the WORKING DIRECTORY, not against
# the script's own folder, so X1's `load "../../ringpp.ring"` only finds the
# library when this runs from bench\queens. Without the push it failed with
# "no TIME line" -- an error about the harness wearing the costume of a
# broken variant.
Push-Location $here
try {

$results = @()
foreach ($v in $variants) {
    $path = Join-Path $here $v.File
    $best = [double]::MaxValue
    $checks = $null
    for ($r = 0; $r -lt $Reps; $r++) {
        $out = & $Ring $path $N 2>&1 | Out-String
        $ms = if ($out -match 'TIME\s+total\s+([0-9.]+)') { [double]$Matches[1] } else { -1 }
        if ($ms -lt 0) { Write-Host "  FAIL $($v.Name): no TIME line"; exit 1 }
        if ($ms -lt $best) { $best = $ms }
        # Checks must be identical across repetitions of the SAME variant too:
        # a search that is not deterministic cannot be compared with anything.
        $c = ($out -split "`n" | Where-Object { $_ -match '^CHECK ' } | ForEach-Object { $_.Trim() }) -join '; '
        if ($null -eq $checks) { $checks = $c }
        elseif ($checks -ne $c) { Write-Host "  FAIL $($v.Name): not deterministic across runs"; exit 1 }
    }
    $results += [pscustomobject]@{ Name = $v.Name; Group = $v.Group; Ms = $best; Checks = $checks }
}

# ---- correctness BEFORE any speed number ----------------------------------
$solOf = { param($c) if ($c -match 'CHECK sol (\d+)') { $Matches[1] } else { '?' } }
# @() is not decoration. Sort-Object -Unique over one distinct value yields a
# bare STRING, and $sols[0] then indexes its first CHARACTER -- this printed
# "all variants agree: 3 solutions" for 3905. Same trap cost a false failure
# in tests\android_campaign.ps1 a day earlier.
$sols  = @($results | ForEach-Object { & $solOf $_.Checks } | Sort-Object -Unique)
if ($sols.Count -ne 1 -or $sols[0] -eq '?') {
    Write-Host "  FAIL variants disagree on the number of solutions:"
    $results | ForEach-Object { Write-Host ("       {0,-26} {1}" -f $_.Name, $_.Checks) }
    exit 1
}
$same = $results | Where-Object { $_.Group -eq 'same-search' }
$sig  = @($same | ForEach-Object { $_.Checks } | Sort-Object -Unique)
if ($sig.Count -ne 1) {
    Write-Host "  FAIL the same-search variants visited different nodes:"
    $same | ForEach-Object { Write-Host ("       {0,-26} {1}" -f $_.Name, $_.Checks) }
    exit 1
}

Write-Host ""
Write-Host ("  N-Queens, boards 1..{0}, minimum of {1} runs" -f $N, $Reps)
Write-Host ("  all variants agree: {0} solutions" -f $sols[0])
Write-Host ""
$base = ($results | Where-Object { $_.Name -like 'V0*' }).Ms
foreach ($r in $results) {
    $speed = if ($r.Ms -gt 0) { '{0,5:N2}x' -f ($base / $r.Ms) } else { '    -' }
    Write-Host ("    {0,-26} {1,9:N0} ms   {2}" -f $r.Name, $r.Ms, $speed)
}
Write-Host ""
Write-Host "  QUEENS OK"

} finally { Pop-Location }
exit 0
