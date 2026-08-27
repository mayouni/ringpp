# The N-Queens case study as a gate.
#
# Thin wrapper over bench\queens\run.ps1 with a board size small enough to
# belong in a pre-commit suite. The study's published table uses N=11 and
# takes about half a minute; N=9 asks the same question of every variant in
# about a second, and the question is the point: do all six agree on the
# number of solutions?
#
# Speed is NOT asserted here. Timings are hardware, and a gate that fails
# because the machine was busy teaches people to ignore it. What is asserted
# is that six rewrites of someone else's program -- two of them a different
# algorithm entirely -- still find exactly the same solutions.

$root  = Split-Path -Parent $PSScriptRoot
$study = Join-Path $root 'bench\queens\run.ps1'

if (-not (Test-Path $study)) { Write-Host "SKIP queens case  bench\queens\run.ps1 not present"; exit 0 }

$out = & powershell -File $study -N 9 -Reps 1 2>&1 | Out-String
Write-Host $out.Trim()
if ($out -match 'QUEENS OK') { exit 0 }
exit 1
