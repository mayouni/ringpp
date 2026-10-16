# B2 — one runtime stub per platform Ring++ already ships a CLI for.
#
#     powershell -File tests\b2_runtimes.ps1
#
# Generalises B0's mechanism (`zig cc` against Ring's own VM source, proved
# for one target) across the five platforms bin/README.md already lists for
# the CLI. Output lands in runtime/<platform>/, mirroring bin/'s layout and
# its honesty: two targets are EXECUTED and compared against Ring's own
# official build: three are FORMAT-CHECKED ONLY, because this machine cannot
# run aarch64 or macOS code, and compiled is not the same claim as correct.

# The VM source is VENDORED, under vendor/ring-vm/. That is what lets a
# clean clone build its own runtime -- the first commitment in CLAUDE.md.
# -RingSrc / -RingInc still take an external Ring, for comparing this
# build against another one.
param(
    [string]$Ring    = "D:\ring127\bin\ring.exe",
    [string]$RingSrc = "",
    [string]$RingInc = "",
    [string]$OutDir  = "",
    # -Only <plat>: rebuild ONE platform. The win64 binary keys every cached
    # oracle transcript (bench/why432.py), so rebuilding it for a Linux fix
    # would cost the whole cache.
    [string]$Only    = "",
    [switch]$Quiet
)

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $RingSrc) { $RingSrc = Join-Path $root "vendor\ring-vm\src" }
if (-not $RingInc) { $RingInc = Join-Path $root "vendor\ring-vm\include" }
if (-not $OutDir) { $OutDir = Join-Path $root "runtime" }

function Say([string]$s) { if (-not $Quiet) { $s } }

$zig = Get-Command zig -EA SilentlyContinue
if (-not $zig) { "SKIP b2 runtimes     no zig on PATH to cross-compile"; exit 0 }
# A missing VENDORED source is a FAILURE, never a skip. Absent zig is a
# skip -- the compiler is the developer's to install. Absent source means
# this repository has lost the thing that makes it independent.
if (-not (Test-Path $RingSrc)) {
    if ($RingSrc -like "*vendor*") {
        "FAIL b2 runtimes     vendored VM source missing at $RingSrc"
        exit 1
    }
    "SKIP b2 runtimes     Ring VM sources not at $RingSrc"
    exit 0
}

# label, zig target triple, output filename, executable on THIS machine
$targets = @(
    @{ Plat = "win64";        Triple = "x86_64-windows-gnu"; Out = "ring.exe"; Exec = "native" }
    # linux-x64 is GLIBC and DYNAMIC, as Ring's own Linux build is (2026-09-28).
    # It was static musl, and a static musl binary cannot dlopen at all and
    # has no dynamic symbol table to export -- so this oracle could never load
    # an extension, and every Softanza program loads ziplib first. Never seen,
    # because nothing had run Softanza on it. musl stays where F-40 put it:
    # the phones (linux-arm64).
    @{ Plat = "linux-x64";    Triple = "x86_64-linux-gnu";    Out = "ring";     Exec = "wsl" }
    @{ Plat = "linux-arm64";  Triple = "aarch64-linux-musl";  Out = "ring";     Exec = "" }
    @{ Plat = "macos-x64";    Triple = "x86_64-macos";        Out = "ring";     Exec = "" }
    @{ Plat = "macos-arm64";  Triple = "aarch64-macos";       Out = "ring";     Exec = "" }
)

$magic = @{
    "win64"       = @(0x4D, 0x5A)                    # MZ  -- PE
    "linux-x64"   = @(0x7F, 0x45, 0x4C, 0x46)        # ELF
    "linux-arm64" = @(0x7F, 0x45, 0x4C, 0x46)        # ELF
    "macos-x64"   = @(0xCF, 0xFA, 0xED, 0xFE)        # Mach-O 64 LE
    "macos-arm64" = @(0xCF, 0xFA, 0xED, 0xFE)        # Mach-O 64 LE
}

Push-Location $RingSrc
$srcs = (Get-ChildItem *.c | Where-Object { $_.Name -ne "ringw.c" }).Name
$fail = 0

# Two build-time upgrades, neither touching a line of Ring's source:
#
#   computed goto   Ring SHIPS this fast dispatch behind RING_VM_COMPUTEDGOTO
#                   (vm.c:688, build/vmcgoto/) -- Mahmoud's own door, opened
#                   with a -D. Every target gets it; zig cc is clang, so the
#                   &&label extension it needs is always there. Measured
#                   ~5-8% on the device suite; answers byte-identical.
#
#   mimalloc        MUSL TARGETS ONLY. musl's allocator serves large blocks
#                   with a fresh mmap and frees them with munmap, so every
#                   large-string copy Ring makes became two syscalls plus a
#                   page-fault storm -- profiled on a real phone at ~60% of
#                   all cycles with the interpreter itself at 0.44%
#                   (FINDINGS F-40). Linking mimalloc made string workloads
#                   3.6-7.7x faster and cut total cycles 5.7x. Windows and
#                   macOS stubs keep their platform allocator, which does
#                   not have this behaviour. See vendor/mimalloc/NOTES.md.
$cgoto  = Join-Path $RingSrc "..\build\vmcgoto\vmcgoto.c"
$miDir  = Join-Path $PSScriptRoot "..\vendor\mimalloc"
$miSrc  = Join-Path $miDir "src\static.c"
$miInc  = Join-Path $miDir "include"

# Ring's standard library, vendored, placed the way Ring lays it out: the
# shims in <platform>/load/ beside each binary, the library one level up in
# runtime/libraries/stdlib/ (the shim's /../../libraries). Without these the
# oracle cannot load a Softanza program past line 6 of its loader.
$stdlib = Join-Path $root "vendor\ring-stdlib"
if (Test-Path $stdlib) {
    $libDst = Join-Path $OutDir "libraries"
    if (Test-Path $libDst) { Remove-Item -Recurse -Force $libDst }
    Copy-Item -Recurse (Join-Path $stdlib "libraries") $libDst
}

# The ringzip extension's Ring-side files, once, where the shim in load/
# looks for them: <exefolder>/load/../../extensions/ringzip -- that is
# runtime/extensions/ringzip, shared by every platform. The native half is
# built per platform inside the loop below.
$zipDir = Join-Path $root "vendor\ring-ext\ringzip"
$zipSrc = Join-Path $zipDir "ring_libzip.c"
$zipBuilt = 0
if (Test-Path $zipSrc) {
    $extDst = Join-Path $OutDir "extensions\ringzip"
    if (Test-Path $extDst) { Remove-Item -Recurse -Force $extDst }
    New-Item -ItemType Directory -Force $extDst | Out-Null
    Copy-Item (Join-Path $zipDir "ziplib.ring") $extDst
    Copy-Item (Join-Path $zipDir "ring_libzip.rh") $extDst
}

foreach ($t in $targets) {
    if ($Only -and $t.Plat -ne $Only) { continue }
    $dir = Join-Path $OutDir $t.Plat
    New-Item -ItemType Directory -Force $dir | Out-Null
    if (Test-Path $stdlib) {
        $loadDst = Join-Path $dir "load"
        if (Test-Path $loadDst) { Remove-Item -Recurse -Force $loadDst }
        Copy-Item -Recurse (Join-Path $stdlib "load") $loadDst
    }
    $out = Join-Path $dir $t.Out
    # Remove the previous binary FIRST. zig cc that fails leaves it in
    # place, Test-Path passes, and the magic-byte check below then
    # validates yesterday's file -- a build that did not happen reading
    # as a build that did. Found when the macOS targets started failing
    # and the other three 'rebuilt' to byte-identical output.
    if (Test-Path $out) { Remove-Item -Force $out }

    $extra = @("-DRING_VM_COMPUTEDGOTO=1", $cgoto)
    if ($t.Triple -like "*-musl" -and (Test-Path $miSrc)) {
        $extra += @("-DMI_MALLOC_OVERRIDE=1", "-I", $miInc, $miSrc)
    }
    # The oracle EXPORTS its C API, so a Ring extension built against it can
    # import from it -- Ring's own layout is ring.dll + a launcher and the
    # extensions import from the DLL; one static binary that exports the same
    # names is the same contract with one file. Windows gets an import
    # library beside the binary for the extension build below; ELF exports
    # its dynamic symbols so a dlopen'ed .so resolves against the running
    # binary; Mach-O exports non-static symbols by default.
    if ($t.Triple -like "*-windows-*") {
        # Built as ONE string first: written inline inside @( ... ), PowerShell
        # 5.1 handed zig `-Wl,--out-implib,` and the path as two arguments,
        # the linker took yesterday's libring.a as an INPUT, and every symbol
        # of the VM was reported twice.
        $implib = "-Wl,--out-implib," + (Join-Path $dir "libring.a")
        $extra += @("-Wl,--export-all-symbols", $implib)
    } elseif ($t.Triple -like "*-linux-*") {
        $extra += @("-Wl,--export-dynamic")
    }
    & zig cc -target $t.Triple -O2 -w -I $RingInc $srcs @extra -o $out -lm 2>&1 | Out-Null
    if (-not (Test-Path $out)) {
        "FAIL b2 runtimes     $($t.Plat): zig cc did not produce $($t.Out)"
        $fail++; continue
    }

    # Magic-byte check, every target, every time -- format is not optional.
    $fs = [IO.File]::OpenRead($out)
    $head = New-Object byte[] 4
    $null = $fs.Read($head, 0, 4)
    $fs.Close()
    $want = $magic[$t.Plat]
    $ok = $true
    for ($i = 0; $i -lt $want.Count; $i++) { if ($head[$i] -ne $want[$i]) { $ok = $false; break } }
    if (-not $ok) {
        "FAIL b2 runtimes     $($t.Plat): built but is not the format it claims"
        $fail++; continue
    }

    # ringzip -- the one native Ring extension live Softanza loads (line 1 of
    # base/file/stzFile.ring). Built from the vendored sources with the same
    # zig cc, against the vendored headers, importing from THIS binary. Only
    # ring_libzip.c is compiled: it #includes zip.c itself, as Ring's own
    # script does. A missing extension is a FAIL, not a note: without it the
    # oracle still cannot load a Softanza program.
    if (Test-Path $zipSrc) {
        $zipOut = Join-Path $dir $(if ($t.Triple -like "*-windows-*") { "ring_libzip.dll" } elseif ($t.Triple -like "*-macos*") { "libring_libzip.dylib" } else { "libring_libzip.so" })
        if (Test-Path $zipOut) { Remove-Item -Force $zipOut }
        $zflags = @("-shared", "-I", $RingInc, "-I", $zipDir, (Join-Path $zipDir "ring_libzip.c"))
        if ($t.Triple -like "*-windows-*") {
            $zflags += @("-L", $dir, "-lring", "-Wl,--export-all-symbols")
        } elseif ($t.Triple -like "*-macos*") {
            $zflags += @("-Wl,-undefined,dynamic_lookup")
        } else {
            $zflags += @("-fPIC")
        }
        & zig cc -target $t.Triple -O2 -w @zflags -o $zipOut 2>&1 | Out-Null
        if (-not (Test-Path $zipOut)) {
            "FAIL b2 runtimes     $($t.Plat): zig cc did not produce $(Split-Path -Leaf $zipOut) (ringzip)"
            $fail++; continue
        }
        $zipBuilt++
    }

    if ($t.Exec -eq "") {
        Say ("  {0,-14} built, format OK, NOT executed here" -f $t.Plat)
        continue
    }

    # Executable here: compile+run a fixture and diff against Ring's own
    # official build. This is a DIFFERENT question from B0's -- B0 asked
    # whether bytecode travels; this asks whether a runtime WE built from
    # source behaves like the one Mahmoud ships.
    $fx = Join-Path $env:TEMP ("rpp_b2_" + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force $fx | Out-Null
    @'
func Main
	? "str  : " + upper("abc")
	? "int  : " + (7 * 6) + " " + (2 ** 10)
	? "float: " + (1/3)
	n = 0
	for i = 1 to 100 n += i next
	? "loop : " + n
'@ | Set-Content -Path (Join-Path $fx "t.ring") -Encoding ascii

    # The reference is Ring's OFFICIAL build, which lives outside this
    # repository -- the one reach in this script, and the only kind the
    # project allows: a COMPARISON, at build time, never a dependency of the
    # product. It is guarded because an absent installation used to make
    # `$ref` an error string and the diff fail for the wrong reason, which
    # is the "gate that passes because the files happen to exist" this
    # project warns about, wearing its other face.
    if (-not (Test-Path $Ring)) {
        Say ("  {0,-14} built, format OK; NOT compared -- no official Ring at {1}" -f $t.Plat, $Ring)
        Remove-Item $fx -Recurse -Force -EA SilentlyContinue
        continue
    }
    $ref = (& $Ring (Join-Path $fx "t.ring") 2>&1 | Out-String).Replace("`r`n","`n").TrimEnd()

    if ($t.Exec -eq "native") {
        $got = (& $out (Join-Path $fx "t.ring") 2>&1 | Out-String).Replace("`r`n","`n").TrimEnd()
    } else {
        # wsl: stage through the repo dir, /mnt paths resolve reliably there
        $stage = Join-Path $root ".b2_stage"
        New-Item -ItemType Directory -Force $stage | Out-Null
        Copy-Item $out (Join-Path $stage "r") -Force
        Copy-Item (Join-Path $fx "t.ring") $stage -Force
        $drive = ($root.Substring(0,1)).ToLower()
        $mnt = "/mnt/$drive" + ($root.Substring(2) -replace '\\','/') + "/.b2_stage"
        $cmd = "cp $mnt/r /tmp/r2 && chmod +x /tmp/r2 && cp $mnt/t.ring /tmp/ && cd /tmp && ./r2 t.ring 2>&1"
        $got = (& wsl -d Ubuntu -- bash -c $cmd | Out-String).Replace("`r`n","`n").TrimEnd()
        Remove-Item $stage -Recurse -Force -EA SilentlyContinue
    }
    Remove-Item $fx -Recurse -Force -EA SilentlyContinue

    if ($got -eq $ref) {
        Say ("  {0,-14} built, format OK, EXECUTED, matches official build" -f $t.Plat)
    } else {
        "FAIL b2 runtimes     $($t.Plat): output differs from the official build"
        Say "     official: $($ref -split "`n" | Select-Object -First 2)"
        Say "     built   : $($got -split "`n" | Select-Object -First 2)"
        $fail++
    }
}

"{0} {1,-16} {2}" -f $(if ($fail -eq 0) { "PASS" } else { "FAIL" }), "b2 runtimes", `
    $(if ($fail -eq 0) { if ($Only) { "$Only built, ringzip built for $zipBuilt; the other platforms NOT rebuilt (-Only)" } else { "5 platforms built, ringzip built for $zipBuilt; 2 executed and match Ring's own build" } } else { "" })
exit $fail
