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

# The unit tests need the Zig COMPILER, which a package user is promised they
# will never need. So its absence is a named SKIP, not a failure -- the same
# policy as the optional corpus gate below. Anyone adapting the CLI has Zig
# and gets the gate; anyone who merely installed the package does not, and
# must still be able to run this suite green.
$zig = Get-Command zig -ErrorAction SilentlyContinue
if ($zig) {
    $null = & zig build test 2>&1
    "{0} {1,-16}" -f $(if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }), "T1 zig test"
    if ($LASTEXITCODE -ne 0) { $fail++ }
} else {
    "{0} {1,-16} {2}" -f "SKIP", "T1 zig test", "no zig on PATH -- the CLI source tests need the compiler"
}

# Which ringpp binary the gates below drive. A fresh clone has NO zig-out --
# it is gitignored -- so hardcoding it made the documented command
# `powershell -File tests\run-all.ps1` fail five gates for everyone who
# cloned the repository, while a perfectly good binary sat in bin\win64.
# Found by actually cloning it. Preference order: a developer's fresh build
# first, the shipped binary second, and the choice is PRINTED, because a
# suite that silently tests a different artefact than you think is worse
# than one that fails.
$ringpp = $null
foreach ($cand in @("zig-out\bin\ringpp.exe", "bin\win64\ringpp.exe")) {
    if (Test-Path (Join-Path $root $cand)) { $ringpp = Join-Path $root $cand; break }
}
if (-not $ringpp) {
    "FAIL {0,-16} {1}" -f "T1 cli", "no ringpp.exe in zig-out\bin or bin\win64"
    $fail++
    $ringpp = "ringpp.exe"   # let the gates below fail loudly rather than crash
} else {
    "     {0,-16} {1}" -f "using", (Resolve-Path $ringpp -Relative)
}

# T1. SELF-CONTAINED, and that is the point. This gate used to scan a path
# inside D:\GitHub\stzlib, which made Ring++'s own suite unrunnable by anyone
# who does not also have Softanza checked out beside it. Ring++ is
# dependency-free and a Ring package; its gates may not require another
# repository to exist.
#
# Assert the RULE, never a line number: fixture lines move when the fixture
# is edited, and pinning stkPointer.ring:720:44 once failed for the right
# rule at the wrong address.
$chk = & $ringpp check "tests\fixtures\lint_bad.ring" 2>&1 | Out-String
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
    $cOut = & $ringpp check $corpus 2>&1 | Out-String
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
$listed = & $ringpp why 2>&1 | Out-String
$whyRules = (
    ([regex]::Matches($listed, "rpp/[a-z-]+") | ForEach-Object { $_.Value }) +
    ([regex]::Matches($chk,    "rpp/[a-z-]+") | ForEach-Object { $_.Value })
) | Sort-Object -Unique
if ($whyRules.Count -lt 9) { $whyOk = $false; "       expected at least 9 rules, listed $($whyRules.Count)" }
foreach ($r in $whyRules) {
    $null = & $ringpp why $r 2>&1
    if ($LASTEXITCODE -ne 0) { $whyOk = $false; "       no why entry for $r" }
}
$byCode = & $ringpp why R4 2>&1 | Out-String
if ($byCode -notmatch "rpp/empty-catch") { $whyOk = $false; "       R4 did not resolve to rpp/empty-catch" }
$null = & $ringpp why R99 2>&1
if ($LASTEXITCODE -eq 0) { $whyOk = $false; "       an unknown query must exit non-zero" }
"{0} {1,-16} {2}" -f $(if ($whyOk) { "PASS" } else { "FAIL" }), "T2 why gate", "$($whyRules.Count) rule(s) explained; R4 resolves; unknown exits 1"
if (-not $whyOk) { $fail++ }

# T2, level 1 type checking. Two fixtures, and the second matters more: the
# clean one must produce absolutely nothing. Every defect in the bad fixture
# was confirmed against Ring 1.27 before its rule was written.
$tyOk = $true
$bad = & $ringpp check "tests\fixtures\types_bad.ring" 2>&1 | Out-String
foreach ($r in @("rpp/type-arity","rpp/type-arg-mismatch","rpp/type-hints-missing","rpp/type-not-a-hint")) {
    if ($bad -notmatch [regex]::Escape($r)) { $tyOk = $false; "       $r did not fire on types_bad.ring" }
}
if ($bad -notmatch "R19") { $tyOk = $false; "       too-few-args was not reported as R19" }
if ($bad -notmatch "R20") { $tyOk = $false; "       too-many-args was not reported as R20" }

$good = & $ringpp check "tests\fixtures\types_good.ring" 2>&1 | Out-String
if ($good -match "rpp/type-") {
    $tyOk = $false
    "       FALSE POSITIVE on types_good.ring:"
    $good -split "`n" | Select-String "rpp/type-" | ForEach-Object { "         $_" }
}
"{0} {1,-16} {2}" -f $(if ($tyOk) { "PASS" } else { "FAIL" }), "T2 type gate", "5 rules fire on the bad fixture; the good one is silent"
if (-not $tyOk) { $fail++ }

# T2, the PROJECT layer: cross-file checking through the load graph.
# Every fixture verdict below was first confirmed by running Ring itself
# (app.ring -> R19, dup_main.ring -> C22, indep_a.ring -> clean).
$xf = & $ringpp check "tests\fixtures\xfile" 2>&1 | Out-String
$xfOk = ($xf -match "rpp/type-arity") -and ($xf -match "defined in .*lib\.ring") -and
        ($xf -match "rpp/type-duplicate-func") -and ($xf -match "dup_main") -and
        ($xf -notmatch "indep_")
"{0} {1,-16} {2}" -f $(if ($xfOk) { "PASS" } else { "FAIL" }), "T2 xfile gate", "cross-file arity names lib.ring; C22 at the join; independent programs silent"
if (-not $xfOk) { $fail++; $xf -split "`n" | Select-Object -Last 6 | ForEach-Object { "       $_" } }
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

# The four cases from ysdragon/tree-sitter-ring#2. Ring accepts all four; the
# grammar vendored at 65b185e rejected only case 4, and v1.1.1 fixed it. This
# gate exists so a future grammar bump cannot quietly undo that -- and so the
# three cases that ALWAYS worked cannot quietly break, which is the regression
# a one-case gate would miss. See upstream\tree-sitter-ring-notes.md.
Push-Location $root
$i2dir = "tests\fixtures\tsring_issue2"
$i2bad = @()
foreach ($c in (Get-ChildItem (Join-Path $root $i2dir) -Filter *.ring | Sort-Object Name)) {
    $o = & $ringpp check $c.FullName 2>&1 | Out-String
    if ($o -match "rpp/unparsed") { $i2bad += $c.Name }
}
"{0} {1,-16} {2}" -f $(if ($i2bad.Count -eq 0) { "PASS" } else { "FAIL" }), "tsring #2",
    $(if ($i2bad.Count -eq 0) { "all 4 digit-leading cases parse (grammar v1.1.1)" } else { "" })
if ($i2bad.Count) { $fail++; $i2bad | ForEach-Object { "       $_ is rejected -- the grammar regressed" } }
Pop-Location

# The package manifest promises a prebuilt binary per platform, and a
# promise nobody checks is how `ringpm install` starts failing on a machine
# nobody here owns. This asserts that every file the manifest lists exists,
# and -- because a file existing says nothing about what is IN it -- that
# each platform binary carries the right magic bytes for its target. A
# Windows .exe copied into bin/linux-x64 would pass an existence check and
# fail on the user's machine.
Push-Location $root
$magic = @{
    "bin/win64/ringpp.exe"    = @(0x4D, 0x5A)                    # MZ   -- PE
    "bin/linux-x64/ringpp"    = @(0x7F, 0x45, 0x4C, 0x46)        # ELF
    "bin/linux-arm64/ringpp"  = @(0x7F, 0x45, 0x4C, 0x46)        # ELF
    "bin/macos-x64/ringpp"    = @(0xCF, 0xFA, 0xED, 0xFE)        # Mach-O 64 LE
    "bin/macos-arm64/ringpp"  = @(0xCF, 0xFA, 0xED, 0xFE)        # Mach-O 64 LE
}
# .NET rather than Get-Content: -AsByteStream is PowerShell 7 and this
# machine runs 5.1, where the same read needs -Encoding Byte. Reading the
# bytes directly works on both and cannot be silently decoded as text.
$pkg = [IO.File]::ReadAllText((Join-Path $root "package.ring"))
$binBad = @()
foreach ($f in $magic.Keys) {
    if (-not $pkg.Contains($f)) { $binBad += "$f not listed in package.ring"; continue }
    $p = Join-Path $root $f
    if (-not (Test-Path $p)) { $binBad += "$f listed but missing"; continue }
    $fs = [IO.File]::OpenRead($p)
    $head = New-Object byte[] 4
    $null = $fs.Read($head, 0, 4)
    $fs.Close()
    $want = $magic[$f]
    for ($i = 0; $i -lt $want.Count; $i++) {
        if ($head[$i] -ne $want[$i]) { $binBad += "$f is not the format it claims"; break }
    }
}
# And the reverse direction: a manifest entry with no file on disk. Only the
# file ARRAYS are scanned -- :run holds a shell command that also ends in
# .ring, and reading it as a path is a false positive this gate already had.
$arrays = [regex]::Matches($pkg, '(?s):(files|windowsfiles|macosfiles|ubuntufiles)\s*=\s*\[(.*?)\]')
foreach ($a in $arrays) {
    foreach ($m in [regex]::Matches($a.Groups[2].Value, '"([^"]+)"')) {
        $rel = $m.Groups[1].Value
        if (-not (Test-Path (Join-Path $root $rel))) { $binBad += "$rel listed but missing" }
    }
}
"{0} {1,-16} {2}" -f $(if ($binBad.Count -eq 0) { "PASS" } else { "FAIL" }), "pkg binaries",
    $(if ($binBad.Count -eq 0) { "5 platform binaries listed, present, and the right format" } else { "" })
if ($binBad.Count) { $fail++; $binBad | Select-Object -Unique | ForEach-Object { "       $_" } }
Pop-Location

""
if ($fail -eq 0) { "ALL GATES PASSED" } else { "$fail GATE(S) FAILED" }
exit $fail
