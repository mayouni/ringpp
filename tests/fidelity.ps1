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

# WHICH RULE MEANS "this file did not parse". This harness spent its life
# grepping for `rpp/parse-error`, a name that exists nowhere in src/ -- the
# CLI emits `rpp/unparsed`. The forward direction therefore matched nothing
# and reported a structural zero on every corpus, for either grammar, which
# is worse than a wrong number because it looks like a clean result. Caught
# 2026-08-23 when a 6,012-file Softanza root reported 0 parse errors while
# `ringpp check` on the same root reported 67 rpp/unparsed.
#
# So the name is now RESOLVED against the binary's own rule catalogue and the
# run ABORTS if it cannot be found. A harness that cannot fail is not a gate.
$known = (& $Ringpp why 2>&1 | Out-String)
$ruleName = @("rpp/unparsed", "rpp/parse-error") | Where-Object { $known -match [regex]::Escape($_) } | Select-Object -First 1
if (-not $ruleName) {
    "FATAL: this binary knows no parse-failure rule (looked for rpp/unparsed, rpp/parse-error)."
    "       The forward direction would silently measure nothing. Refusing to report a rate."
    exit 2
}
"parse-failure rule         : {0}" -f $ruleName

$tmp = Join-Path $env:TEMP ("rpp_fid_" + [IO.Path]::GetRandomFileName() + ".txt")
& $Ringpp check $Root > $tmp 2>&1

# files ringpp flagged as unparseable
$bad = @{}
$cur = ""
foreach ($l in Get-Content $tmp) {
    if ($l -match '^[A-Za-z]:\\') { $cur = $l.Trim() }
    elseif ($l -match ('\s' + [regex]::Escape($ruleName))) { if ($cur) { $bad[$cur] = $true } }
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
"Ring rejects, ringpp OK    : {0}   <-- grammar too permissive (of {1} examined)" -f $ringOnly.Count, $checkN

# The headline. Printed by the harness rather than computed by hand afterwards,
# and it states its own coverage: a sampled rate reported as a full one is the
# single failure this project exists not to make.
$disagree = $ringppOnly.Count + $ringOnly.Count
$fwdFull  = ($cands.Count -eq $bad.Count)
$revFull  = ($checkN -eq $clean.Count)
""
"DISAGREEMENTS              : {0}  ({1} too strict + {2} too permissive)" -f $disagree, $ringppOnly.Count, $ringOnly.Count
"RATE                       : {0:N3}%  ({1} of {2} files scanned)" -f (100.0*$disagree/$all.Count), $disagree, $all.Count
"coverage                   : forward {0}, reverse {1}" -f `
    $(if ($fwdFull) { "FULL ($($bad.Count) of $($bad.Count) candidates)" } else { "SAMPLED $($cands.Count) of $($bad.Count)" }), `
    $(if ($revFull) { "FULL ($checkN of $($clean.Count) clean)" } else { "SAMPLED $checkN of $($clean.Count) clean" })
if (-not ($fwdFull -and $revFull)) {
    "  NOTE: this rate is NOT a full-corpus rate. Quote it with its coverage."
}

if ($ringppOnly.Count) { "  too strict:"; $ringppOnly | Select-Object -First 10 | ForEach-Object { "    $_" } }
if ($ringOnly.Count)   { "  too permissive:"; $ringOnly | Select-Object -First 10 | ForEach-Object { "    $_" } }
