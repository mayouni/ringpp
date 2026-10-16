# Every Ring++ gate, one command.
#
#     powershell -File tests\run-all.ps1
#     powershell -File tests\run-all.ps1 -Fast      # skip the ReleaseSafe passes
#
# Ring++ is a register VM (rnx) and a compiler from Ring source to its
# bytecode (rnxc). Existing Ring programs are the compatibility
# specification, and "the same answer as Ring" is decided by running them on
# the ORACLE: Ring 1.27's own VM, built HERE from vendor/ring-vm by
# tests\b2_runtimes.ps1 -- not an installation someone else controls.
#
# The gates, in order:
#
#   vendored VM        Ring's VM source, every hash        (the oracle's source)
#   vendored ts        the tree-sitter runtime, every hash
#   vendored grammar   the Ring grammar, every hash        (rnxc's front end)
#   vendored mi        mimalloc, every hash                (F-40)
#   b2 runtimes        builds the oracle, and four other platforms, from source
#   examples           09-15 on the oracle, leashed, each reaching its OK marker
#   gate.py            zig build -j2, ReleaseFast and ReleaseSafe; A/B against
#                      the oracle; the Softanza census; refusal; 7.2; 5.1
#   (the checker is a STEP of gate.py: the 17 rules against tests/fixtures)
#
# A gate that could not run is named with its reason, never quietly skipped.
# Nothing here is backgrounded and the native build is capped at -j2: this
# machine has 31.6 GB of RAM and a 2 GB page file, and it freezes rather
# than slows.
param([switch]$Fast)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$fail = 0

# ReadAllLines, not Get-Content: the project does not round-trip text
# through Get-Content/Set-Content anywhere, and a manifest is exactly the
# kind of file where a decoding surprise would be invisible.
function Manifest([string]$label, [string]$dir, [string]$what) {
    $man = Join-Path $dir "SHA256SUMS"
    if (-not (Test-Path $man)) {
        "FAIL {0,-16} {1}" -f $label, "no SHA256SUMS in $dir"
        $script:fail++
        return
    }
    $bad = 0; $n = 0
    foreach ($line in [IO.File]::ReadAllLines($man)) {
        if (-not $line.Trim()) { continue }
        $n++
        $want, $rel = $line -split '  ', 2
        $f = Join-Path $dir $rel.Replace('/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path $f)) { $bad++; continue }
        if ((Get-FileHash $f -Algorithm SHA256).Hash -ne $want.ToUpper()) { $bad++ }
    }
    "{0} {1,-16} {2}" -f $(if ($bad -eq 0) { "PASS" } else { "FAIL" }), $label, "$n file(s) of $what, every hash matching"
    if ($bad -ne 0) { $script:fail++ }
}

Push-Location $root
"Ring++ gates"
""

# ---- what a clean clone must contain, byte for byte ---------------------
# Needs no Ring, no compiler and no network: it reads files and hashes them.
# These fail the day the things making this project independent go missing
# or get edited by accident.
Manifest "vendored VM"      (Join-Path $root "vendor\ring-vm")          "Ring's VM source -- the oracle builds from it"
Manifest "vendored ts"      (Join-Path $root "vendor\tree-sitter")      "the tree-sitter runtime"
Manifest "vendored grammar" (Join-Path $root "vendor\tree-sitter-ring") "the Ring grammar -- rnxc's front end"
Manifest "vendored mi"      (Join-Path $root "vendor\mimalloc")         "mimalloc"
Manifest "vendored stdlib"  (Join-Path $root "vendor\ring-stdlib")      "Ring's standard library -- the estate's line 6"
Manifest "vendored ringzip" (Join-Path $root "vendor\ring-ext\ringzip") "the one native Ring extension the estate loads"

# ---- the oracle, built from that source ---------------------------------
# Rebuilds all five platforms every run (~6 s warm) rather than trusting a
# committed binary: runtime/ is gitignored output, so nothing there CAN go
# silently stale.
$b2 = & powershell -File (Join-Path $root "tests\b2_runtimes.ps1") -Quiet 2>&1 | Out-String
$b2line = ($b2 -split "`n" | Where-Object { $_ -match '^(PASS|FAIL|SKIP) b2' } | Select-Object -First 1)
if ($b2line) { $b2line.TrimEnd() } else { "FAIL b2 runtimes     no verdict line -- run tests\b2_runtimes.ps1 by hand"; $fail++ }
if ($b2line -match '^FAIL') { $fail++ }
$oracle = Join-Path $root "runtime\win64\ring.exe"
$haveOracle = Test-Path $oracle

# ---- the examples, on the oracle ----------------------------------------
# Each prints "EXAMPLE nn OK" only after its byte-identical check; the leash
# in examples\run-all.ps1 caps memory and time per child and refuses to start
# one when the machine's free RAM is low.
if ($haveOracle) {
    $ex = & powershell -File (Join-Path $root "examples\run-all.ps1") -Ring $oracle -Quiet 2>&1 | Out-String
    $exOk = $ex -match 'ALL (\d+) EXAMPLE\(S\) PASSED'
    $exN = if ($exOk) { $Matches[1] } else { '?' }
    "{0} {1,-16} {2}" -f $(if ($exOk) { "PASS" } else { "FAIL" }), "examples", $(if ($exOk) { "$exN on the oracle, every OK marker reached" } else { "see examples\run-all.ps1" })
    if (-not $exOk) { $fail++; $ex -split "`n" | Where-Object { $_ -match '^\s*FAIL|did not reach|expected' } | Select-Object -First 8 | ForEach-Object { "       " + $_.Trim() } }
} else {
    "{0} {1,-16} {2}" -f "FAIL", "examples", "no oracle at runtime\win64\ring.exe -- b2 did not produce it"
    $fail++
}

# ---- the VM and the compiler: bench\gate.py -----------------------------
# Builds rnx and rnxc (-j2) in ReleaseFast and, unless -Fast, ReleaseSafe;
# then the A/B against the oracle, the Softanza census (a named SKIP when the
# corpus is absent), the refusal probe, contract 7.2 and the 5.1 socket.
# gate.py names every gate it skipped, and the console gate is opt-in there
# because it opens a window on the desktop.
""
$py = Get-Command python -ErrorAction SilentlyContinue
$zig = Get-Command zig -ErrorAction SilentlyContinue
if (-not $py) {
    "{0} {1,-16} {2}" -f "FAIL", "gate.py", "no python on PATH"
    $fail++
} elseif (-not $zig) {
    "{0} {1,-16} {2}" -f "FAIL", "gate.py", "no zig on PATH -- the VM and compiler cannot be built"
    $fail++
} else {
    $gargs = @((Join-Path $root "bench\gate.py"))
    if ($Fast) { $gargs += "--fast" }
    & python @gargs 2>&1 | ForEach-Object { "   " + $_ }
    $gok = ($LASTEXITCODE -eq 0)
    ""
    "{0} {1,-16} {2}" -f $(if ($gok) { "PASS" } else { "FAIL" }), "gate.py", $(if ($gok) { "GATE PASSED" } else { "see above" })
    if (-not $gok) { $fail++ }
}

# ---- the checker: now a step inside bench\gate.py -------------------------
# The checker is a step of bench\gate.py now, not a line of its own: it
# was folded into rnxc on 2026-09-10, and a gate that names a component
# it no longer skips is worse than no line at all.

Pop-Location
""
if ($fail -eq 0) { "ALL GATES PASSED" } else { "$fail GATE(S) FAILED" }
exit $fail
