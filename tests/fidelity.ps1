# T1 fidelity gate: every file `ringpp check` reports a parse error for must
# also be rejected by Ring's own scanner, and vice versa.
#
# tree-sitter is a LENS, not a judge (docs/DESIGN_TOOLCHAIN.md §5). A
# disagreement is a bug in the vendored grammar, never a user-facing
# diagnostic.
param(
    [string]$Root,
    [string]$Ringpp = "D:\GitHub\ringpp\zig-out\bin\ringpp.exe",
    [string]$Ring   = "D:\ring127\bin\ring.exe",
    [int]$Sample    = 0        # 0 = all disagreeing candidates
)

$tmp = Join-Path $env:TEMP ("rpp_fid_" + [IO.Path]::GetRandomFileName() + ".txt")
& $Ringpp check $Root > $tmp 2>&1

# files ringpp flagged with a parse error
$bad = @{}
$cur = ""
foreach ($l in Get-Content $tmp) {
    if ($l -match '^[A-Za-z]:\\') { $cur = $l.Trim() }
    elseif ($l -match '\srpp/parse-error') { if ($cur) { $bad[$cur] = $true } }
}
Remove-Item -LiteralPath $tmp -Force

$all = Get-ChildItem $Root -Recurse -File -Filter *.ring -ErrorAction SilentlyContinue
"files scanned              : {0}" -f $all.Count
"ringpp says 'parse error'  : {0}" -f $bad.Count

# Does Ring's own scanner agree? Error (C..) and (S..) are the scanner/parser
# classes. Run from the file's own directory, otherwise `load` fails with
# Error (E9) and we would be measuring load paths, not syntax.
function RingRejects([string]$f) {
    Push-Location (Split-Path $f)
    $out = & $Ring $f -norun 2>&1 | Out-String
    Pop-Location
    return ($out -match 'Error \((C|S)\d+\)')
}

$agree = 0; $ringppOnly = @(); $ringOnly = @()
$cands = @($bad.Keys)
if ($Sample -gt 0 -and $cands.Count -gt $Sample) { $cands = $cands | Get-Random -Count $Sample }
foreach ($f in $cands) { if (RingRejects $f) { $agree++ } else { $ringppOnly += $f } }

# and the other direction, on a sample of files ringpp accepted
$clean = $all | Where-Object { -not $bad.ContainsKey($_.FullName) }
$checkN = if ($Sample -gt 0) { [Math]::Min($Sample, $clean.Count) } else { $clean.Count }
foreach ($f in ($clean | Get-Random -Count $checkN)) { if (RingRejects $f.FullName) { $ringOnly += $f.FullName } }

""
"of {0} checked, Ring agrees : {1}" -f $cands.Count, $agree
"ringpp rejects, Ring OK    : {0}   <-- grammar too strict" -f $ringppOnly.Count
"Ring rejects, ringpp OK    : {0}   <-- grammar too permissive (of {1} sampled)" -f $ringOnly.Count, $checkN
if ($ringppOnly.Count) { "  too strict:"; $ringppOnly | Select-Object -First 10 | ForEach-Object { "    $_" } }
if ($ringOnly.Count)   { "  too permissive:"; $ringOnly | Select-Object -First 10 | ForEach-Object { "    $_" } }
