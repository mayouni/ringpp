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

param(
    [string]$Ring    = "D:\ring127\bin\ring.exe",
    [string]$RingSrc = "D:\ring127\language\src",
    [string]$RingInc = "D:\ring127\language\include",
    [string]$OutDir  = "",
    [switch]$Quiet
)

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutDir) { $OutDir = Join-Path $root "runtime" }

function Say([string]$s) { if (-not $Quiet) { $s } }

$zig = Get-Command zig -EA SilentlyContinue
if (-not $zig) { "SKIP b2 runtimes     no zig on PATH to cross-compile"; exit 0 }
if (-not (Test-Path $RingSrc)) { "SKIP b2 runtimes     Ring VM sources not at $RingSrc"; exit 0 }

# label, zig target triple, output filename, executable on THIS machine
$targets = @(
    @{ Plat = "win64";        Triple = "x86_64-windows-gnu"; Out = "ring.exe"; Exec = "native" }
    @{ Plat = "linux-x64";    Triple = "x86_64-linux-musl";   Out = "ring";     Exec = "wsl" }
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

foreach ($t in $targets) {
    $dir = Join-Path $OutDir $t.Plat
    New-Item -ItemType Directory -Force $dir | Out-Null
    $out = Join-Path $dir $t.Out
    & zig cc -target $t.Triple -O2 -w -I $RingInc $srcs -o $out -lm 2>&1 | Out-Null
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
    $(if ($fail -eq 0) { "5 platforms built; 2 executed and match Ring's own build" } else { "" })
exit $fail
