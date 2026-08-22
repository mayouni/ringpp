# Every Ring++ gate, one command.
#
#     powershell -File tests\run-all.ps1
#
# The .ring tests use `load "../ringpp.ring"`, so they must run with this
# directory as the working directory. That is what this script is for.
param([string]$Ring = "D:\ring127\bin\ring.exe")

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
Push-Location $here

$fail = 0

function Gate([string]$name, [string]$file, [string]$want) {
    $out = & $Ring $file 2>&1 | Out-String
    $ok = $out -match [regex]::Escape($want)
    "{0} {1,-16} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $(if ($ok) { "" } else { "expected: $want" })
    if (-not $ok) { $script:fail++; $out -split "`n" | Select-Object -Last 6 | ForEach-Object { "       $_" } }
}

"Ring++ gates  (Ring: $Ring)"
""
Gate "P1 probe"     "probe_smoke.ring"  "PROBE OK"
Gate "P2 buffer"    "buffer.ring"       "0 failed"
Gate "P2 fuzz"      "fuzz_bounds.ring"  "GATE PASSED"
Gate "P3 idioms"    "idioms.ring"       "0 failed"
# FINDINGS F-25: an Rpp object must never write into its caller's variables.
# The rest of the suite could not see this bug -- fuzz_bounds.ring even
# contains a live collision and passed anyway.
Gate "P2 collision" "name_collision.ring" "0 failed"

Pop-Location

# The Zig side: unit tests plus the T1 gate.
Push-Location $root
$null = & zig build test 2>&1
"{0} {1,-16}" -f $(if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }), "T1 zig test"
if ($LASTEXITCODE -ne 0) { $fail++ }

# T1. SELF-CONTAINED, and that is the point. This gate used to scan a path
# inside D:\GitHub\stzlib, which made Ring++'s own suite unrunnable by anyone
# who does not also have Softanza checked out beside it. Ring++ is an
# independent project and a Ring package; its gates may not require another
# repository to exist.
#
# Assert the RULE, never a line number: fixture lines move when the fixture
# is edited, and pinning stkPointer.ring:720:44 once failed for the right
# rule at the wrong address.
$chk = & ".\zig-out\bin\ringpp.exe" check "tests\fixtures\lint_bad.ring" 2>&1 | Out-String
$ok = ($chk -match "rpp/varptr-unknown-name") -and
      ($chk -match "rpp/empty-catch") -and
      ($chk -match "rpp/substr-in-loop")
"{0} {1,-16} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), "T1 check gate", "3 rules fire on the local fixture"
if (-not $ok) { $fail++ }

# OPTIONAL: the same checker over a large real corpus, when one happens to be
# present. Never required -- but NAMED when skipped, because a gate quietly
# not run is a green nobody earned (PX, CENTRAL-PXLATENCY-01).
$corpus = "D:\GitHub\stzlib\libraries\stzlib\core\system"
if (Test-Path $corpus) {
    $cOut = & ".\zig-out\bin\ringpp.exe" check $corpus 2>&1 | Out-String
    $cOk = ($cOut -match "rpp/varptr-unknown-name") -and ($cOut -match "0 warn")
    "{0} {1,-16} {2}" -f $(if ($cOk) { "PASS" } else { "FAIL" }), "T1 corpus", "optional: Softanza present, dead varptr found"
    if (-not $cOk) { $fail++ }
} else {
    "SKIP {0,-16} {1}" -f "T1 corpus", "optional corpus absent (Softanza not checked out) -- not required"
}

# T2. The catalog-coverage and dangling-citation guards live in `zig build
# test` above; what that cannot check is that the binary actually answers.
# Every rule the check gate just printed must be explainable, and the error
# code a user arrives with must reach the same entry as the rule.
$whyOk = $true
# Every rule the binary advertises, plus every rule the check gate just
# printed. The first set proves the listing is not lying; the second proves
# check and why cannot drift apart in the field.
$listed = & ".\zig-out\bin\ringpp.exe" why 2>&1 | Out-String
$whyRules = (
    ([regex]::Matches($listed, "rpp/[a-z-]+") | ForEach-Object { $_.Value }) +
    ([regex]::Matches($chk,    "rpp/[a-z-]+") | ForEach-Object { $_.Value })
) | Sort-Object -Unique
if ($whyRules.Count -lt 9) { $whyOk = $false; "       expected at least 9 rules, listed $($whyRules.Count)" }
foreach ($r in $whyRules) {
    $null = & ".\zig-out\bin\ringpp.exe" why $r 2>&1
    if ($LASTEXITCODE -ne 0) { $whyOk = $false; "       no why entry for $r" }
}
$byCode = & ".\zig-out\bin\ringpp.exe" why R4 2>&1 | Out-String
if ($byCode -notmatch "rpp/empty-catch") { $whyOk = $false; "       R4 did not resolve to rpp/empty-catch" }
$null = & ".\zig-out\bin\ringpp.exe" why R99 2>&1
if ($LASTEXITCODE -eq 0) { $whyOk = $false; "       an unknown query must exit non-zero" }
"{0} {1,-16} {2}" -f $(if ($whyOk) { "PASS" } else { "FAIL" }), "T2 why gate", "$($whyRules.Count) rule(s) explained; R4 resolves; unknown exits 1"
if (-not $whyOk) { $fail++ }

# T2, level 1 type checking. Two fixtures, and the second matters more: the
# clean one must produce absolutely nothing. Every defect in the bad fixture
# was confirmed against Ring 1.27 before its rule was written.
$tyOk = $true
$bad = & ".\zig-out\bin\ringpp.exe" check "tests\fixtures\types_bad.ring" 2>&1 | Out-String
foreach ($r in @("rpp/type-arity","rpp/type-arg-mismatch","rpp/type-hints-missing","rpp/type-not-a-hint")) {
    if ($bad -notmatch [regex]::Escape($r)) { $tyOk = $false; "       $r did not fire on types_bad.ring" }
}
if ($bad -notmatch "R19") { $tyOk = $false; "       too-few-args was not reported as R19" }
if ($bad -notmatch "R20") { $tyOk = $false; "       too-many-args was not reported as R20" }

$good = & ".\zig-out\bin\ringpp.exe" check "tests\fixtures\types_good.ring" 2>&1 | Out-String
if ($good -match "rpp/type-") {
    $tyOk = $false
    "       FALSE POSITIVE on types_good.ring:"
    $good -split "`n" | Select-String "rpp/type-" | ForEach-Object { "         $_" }
}
"{0} {1,-16} {2}" -f $(if ($tyOk) { "PASS" } else { "FAIL" }), "T2 type gate", "5 rules fire on the bad fixture; the good one is silent"
if (-not $tyOk) { $fail++ }
Pop-Location

# The examples are a gate, not a brochure: each asserts that its raw-Ring and
# Ring++ paths produce byte-identical output before it prints any speedup.
# They run leashed (see examples/run-all.ps1) because this machine has no
# page-file headroom and an example that loops must not be able to take it.
Push-Location (Join-Path $root "examples")
$exOut = & ".\run-all.ps1" -Quiet 2>&1 | Out-String
$exOk = $LASTEXITCODE -eq 0
$exCount = ([regex]::Matches($exOut, "^PASS ", "Multiline")).Count
"{0} {1,-16} {2}" -f $(if ($exOk) { "PASS" } else { "FAIL" }), "examples", "$exCount example(s), each byte-identical vs raw Ring"
if (-not $exOk) { $fail++; $exOut -split "`n" | Select-Object -Last 8 | ForEach-Object { "       $_" } }
Pop-Location

""
if ($fail -eq 0) { "ALL GATES PASSED" } else { "$fail GATE(S) FAILED" }
exit $fail
