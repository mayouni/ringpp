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
# FINDINGS F-31: every gate above asks whether an access RAISES or returns the
# right LENGTH. This one asks whether the BYTES match what plain Ring would
# have produced, which is how the "NULL"-prefix crash was found after the
# others had been green for weeks.
Gate "P2 differential" "differential.ring" "GATE PASSED"

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
      ($chk -match "rpp/substr-in-loop") -and
      ($chk -match "rpp/len-in-loop-header")
"{0} {1,-16} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), "T1 check gate", "4 rules fire on the local fixture"
if (-not $ok) { $fail++ }

# The advice layer, both directions. Advice must be INVISIBLE by default --
# an "adv" line in plain `check` output means opportunities are being
# presented as defects -- and must appear, both rules, under --advise.
# The fixture contains one for-in and one rebuild-patch on purpose.
$advDefaultClean = ($chk -notmatch "rpp/advise-") -and ($chk -match "idiom is faster")
$advOut = & $ringpp check "tests\fixtures\lint_bad.ring" --advise 2>&1 | Out-String
$advShown = ($advOut -match "rpp/advise-forin") -and ($advOut -match "rpp/advise-patch-rebuild")
$aOk = $advDefaultClean -and $advShown
"{0} {1,-16} {2}" -f $(if ($aOk) { "PASS" } else { "FAIL" }), "T1 advise gate", "hidden by default, both advice rules fire under --advise"
if (-not $aOk) {
    $fail++
    if (-not $advDefaultClean) { "       default output leaked advice, or lost the summary line" }
    if (-not $advShown)        { "       --advise did not show both advice rules" }
}

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

# B1 — `ringpp deps`: what must ship beside a program. Three assertions,
# and the third is the one that matters. A dependency report that answers
# "nothing to worry about" when it could not follow the loads is the same
# defect tests/fidelity.ps1 carried for a year, so the refusal is gated
# harder than the happy path.
Push-Location $root
$depsBad = @()
$fx = Join-Path $root "tests\fixtures\deps"

# 1. a program reaching stdlib must name the library that killed B0 on Linux
$d1 = & $ringpp deps (Join-Path $fx "uses_stdlib.ring") --ring "D:\ring127" 2>&1 | Out-String
if ($d1 -notmatch "libring_odbc\.so")   { $depsBad += "stdlib program does not name libring_odbc.so" }
if ($d1 -notmatch "ring_odbc\.dll")     { $depsBad += "stdlib program does not name the windows spelling" }

# 2. a pure program must be called pure
$d2 = & $ringpp deps (Join-Path $fx "pure.ring") --ring "D:\ring127" 2>&1 | Out-String
if ($d2 -notmatch "PURE RING")          { $depsBad += "pure program not reported as pure" }

# 3. THE ONE THAT MATTERS: with no --ring the loads cannot be followed, so
#    the answer must be a refusal and a non-zero exit -- never "pure".
$d3 = & $ringpp deps (Join-Path $fx "uses_stdlib.ring") 2>&1 | Out-String
$d3code = $LASTEXITCODE
if ($d3 -match "PURE RING")             { $depsBad += "claimed PURE RING while unable to follow its loads" }
if ($d3 -notmatch "NO VERDICT")         { $depsBad += "did not refuse a verdict it could not reach" }
if ($d3code -eq 0)                      { $depsBad += "exited 0 on an unanswerable question" }

"{0} {1,-16} {2}" -f $(if ($depsBad.Count -eq 0) { "PASS" } else { "FAIL" }), "b1 deps",
    $(if ($depsBad.Count -eq 0) { "names the native libs; refuses a verdict it cannot reach" } else { "" })
if ($depsBad.Count) { $fail++; $depsBad | ForEach-Object { "       $_" } }
Pop-Location

# B0 — is a .ringo portable across platforms (FINDINGS F-29). Needs a Linux
# Ring runtime, which it cross-compiles with `zig cc` when zig is present and
# runs under WSL; without either it prints its own SKIP and exits 0. It is in
# the suite so the answer cannot rot silently under a future Ring: the object
# format is versioned separately from the language (OBJECT 1.25 vs Ring
# 1.27.0), so this is exactly the claim that can go stale without anyone
# touching Ring++.
Push-Location $root
$b0 = & powershell -File (Join-Path $root "tests\b0_bytecode.ps1") -Quiet 2>&1 | Out-String
$b0line = ($b0 -split "`n" | Where-Object { $_ -match '^(PASS|FAIL|SKIP) b0' } | Select-Object -First 1)
if ($b0line) { $b0line.TrimEnd() } else { "FAIL {0,-16} {1}" -f "b0 bytecode", "no verdict line" }
if ($b0line -match '^FAIL' -or -not $b0line) { $fail++ }
Pop-Location

# The CLI campaign. Every other CLI gate points the tool at a fixture built to
# make a named rule fire; this one asks what it does when it CANNOT do what was
# asked. `ringpp check typo.ring` used to answer "0 error ... in 1 files" and
# exit 0 about a file that does not exist -- a clean verdict on nothing, from
# the tool whose whole pitch is that it refuses to guess (FINDINGS F-34).
$cli = & powershell -File (Join-Path $root "tests\cli_campaign.ps1") 2>&1 | Out-String
$cliOk = $cli -match 'CLI CAMPAIGN PASSED'
"{0} {1,-16} {2}" -f $(if ($cliOk) { "PASS" } else { "FAIL" }), "T2 cli campaign", `
    $(if ($cliOk) { ($cli -split "`n" | Where-Object { $_ -match 'adversarial cases' } | Select-Object -First 1).Trim() } else { "" })
if (-not $cliOk) { $fail++; $cli -split "`n" | Select-Object -Last 8 | ForEach-Object { "       $_" } }

# B2 — one runtime stub per platform, generalising B0's mechanism. Same SKIP
# discipline: no zig, no VM source, no gate failure, just a named reason.
# Rebuilds all five from source every run (~6 s) rather than trusting a
# committed binary, which is the point -- runtime/ is gitignored output, not
# vendored state, so there is nothing here that CAN go silently stale.
Push-Location $root
$b2 = & powershell -File (Join-Path $root "tests\b2_runtimes.ps1") -Quiet 2>&1 | Out-String
$b2line = ($b2 -split "`n" | Where-Object { $_ -match '^(PASS|FAIL|SKIP) b2' } | Select-Object -First 1)
if ($b2line) { $b2line.TrimEnd() } else { "FAIL {0,-16} {1}" -f "b2 runtimes", "no verdict line" }
if ($b2line -match '^FAIL' -or -not $b2line) { $fail++ }
Pop-Location

# B3 -- `ringpp build`: assemble bytecode + a B2 runtime stub + B1's declared
# native libs. Four sub-checks (pure, bundle, refuses, cross); each prints its
# own line, folded into one gate here the way b0/b2's SKIP discipline is kept
# by their own scripts.
Push-Location $root
$b3 = & powershell -File (Join-Path $root "tests\b3_build.ps1") -Quiet 2>&1 | Out-String
$b3lines = ($b3 -split "`n" | Where-Object { $_ -match '^(PASS|FAIL|SKIP) b3' })
if ($b3lines) { $b3lines | ForEach-Object { $_.TrimEnd() } } else { "FAIL {0,-16} {1}" -f "b3 build", "no verdict line" }
if (($b3lines | Where-Object { $_ -match '^FAIL' }).Count -gt 0 -or -not $b3lines) { $fail++ }
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

# The OPEN defects in the vendored grammar, narrowed from the same corpus run
# that confirmed #2. These fixtures are the inverse of the gate above: Ring
# accepts all eight, and the grammar rejects the four xfail_ ones today.
# Pinning the known-bad set is what makes the next grammar bump legible. An
# xfail_ that starts parsing means upstream fixed it and the notes are now
# stale; an ok_ that stops parsing means a fix was bought with a regression.
# Both deserve to fail the build, which is why this gate is not a TODO in a
# markdown file. See upstream\tree-sitter-ring-notes.md.
Push-Location $root
$opDir = Join-Path $root "tests\fixtures\tsring_open"
$opBad = @()
foreach ($c in (Get-ChildItem $opDir -Filter *.ring | Sort-Object Name)) {
    $rejected = ((& $ringpp check $c.FullName 2>&1 | Out-String) -match "rpp/unparsed")
    $expected = $c.Name.StartsWith("xfail_")
    if ($rejected -ne $expected) {
        if ($expected) { $opBad += "$($c.Name) now PARSES -- upstream fixed it; update the notes" }
        else           { $opBad += "$($c.Name) no longer parses -- a fix cost a regression" }
    }
}
"{0} {1,-16} {2}" -f $(if ($opBad.Count -eq 0) { "PASS" } else { "FAIL" }), "tsring open",
    $(if ($opBad.Count -eq 0) { "4 known-bad + 4 controls unchanged (case-fold, trailing dot)" } else { "" })
if ($opBad.Count) { $fail++; $opBad | ForEach-Object { "       $_" } }
Pop-Location

# A path into a temp directory cannot be a default. THREE scripts here were
# hardcoded to an absolute path inside one session's scratchpad -- both
# bench\toolchain\probe-*.ps1 and bench\treesitter\sweep.ps1 -- and every one
# was dead the moment that session ended. Worse, each failed by quietly doing
# nothing useful rather than by saying so, which is how the second and third
# came to be written after the first had already rotted. The lesson only holds
# if something checks it. Runtime-derived scratch ($env:TEMP, $PSScriptRoot)
# is fine; it is the FROZEN name that rots.
Push-Location $root
$fossils = @()
foreach ($f in (Get-ChildItem $root -Recurse -File -Filter *.ps1 |
                Where-Object { $_.FullName -notlike '*\vendor\*' })) {
    $n = 0
    # ReadAllLines, not Get-Content: this repository has been burned by
    # PowerShell decoding UTF-8 as Windows-1252 on the way in.
    foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
        $n++
        if ($l -match '"[A-Za-z]:\\[^"]*\\Temp\\') {
            $fossils += "{0}:{1}" -f $f.FullName.Replace($root, "").TrimStart("\"), $n
        }
    }
}
"{0} {1,-16} {2}" -f $(if ($fossils.Count -eq 0) { "PASS" } else { "FAIL" }), "no fossil paths",
    $(if ($fossils.Count -eq 0) { "no script hardcodes a path into a Temp directory" } else { "" })
if ($fossils.Count) { $fail++; $fossils | ForEach-Object { "       $_ hardcodes a temp path -- make it a parameter" } }
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

# The N-Queens case study (docs/CASE-QUEENS.md). Gated because its claim is
# a CORRECTNESS one before it is a speed one: six variants of someone else's
# program, two of them a different algorithm, all required to agree on 3905
# solutions. If a rewrite ever drifts, this fails here rather than in a
# document nobody re-ran. N is kept at 9 so the gate costs about a second;
# the published table uses 11.
$qOut = & powershell -File (Join-Path $PSScriptRoot 'queens_gate.ps1') 2>&1 | Out-String
if ($qOut -match 'SKIP') {
    "SKIP {0,-16} {1}" -f "queens case", ($qOut -replace '.*SKIP\s*', '').Trim()
} elseif ($qOut -match 'QUEENS OK') {
    $nSol = if ($qOut -match 'agree: (\d+) solutions') { $Matches[1] } else { '?' }
    "{0} {1,-16} {2}" -f "PASS", "queens case", "6 variants agree on $nSol solutions; bitmask is fastest"
} else {
    "{0} {1,-16} {2}" -f "FAIL", "queens case", "variants disagree -- run bench\queens\run.ps1"
    $qOut -split "`n" | Where-Object { $_ -match 'FAIL' } | ForEach-Object { "       " + $_.Trim() }
    $fail++
}

# OPTIONAL: the whole library, its gates and the algorithm suite on a real
# arm64 phone. Same policy as the corpus gate above -- no device attached is
# a named SKIP, never a failure, because most machines running this suite
# have no phone plugged into them. When a device IS there it is the strongest
# check in this file: the same sources, on a different instruction set,
# required to compute byte-identical answers.
$andOut = & powershell -File (Join-Path $PSScriptRoot 'android_campaign.ps1') 2>&1 | Out-String
if ($andOut -match 'SKIP android campaign -- (.+)') {
    "SKIP {0,-16} {1}" -f "android device", ("optional: " + $Matches[1].Trim())
} elseif ($andOut -match 'ANDROID CAMPAIGN PASSED') {
    $nGates = ([regex]::Matches($andOut, 'PASS gate ')).Count
    $nIdent = if ($andOut -match 'PASS (\d+) computed results byte-identical') { $Matches[1] } else { '?' }
    "{0} {1,-16} {2}" -f "PASS", "android device", "$nGates gates on arm64; $nIdent results byte-identical with x64"
} else {
    "{0} {1,-16} {2}" -f "FAIL", "android device", "campaign failed -- run tests\android_campaign.ps1"
    $andOut -split "`n" | Where-Object { $_ -match '^\s+FAIL' } | ForEach-Object { "       " + $_.Trim() }
    $fail++
}

""
if ($fail -eq 0) { "ALL GATES PASSED" } else { "$fail GATE(S) FAILED" }
exit $fail
