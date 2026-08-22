# Build a minimal Zig tree that can compile C for ONE target family.
param([string]$Src, [string]$Dst, [string[]]$LibcDirs, [string[]]$IncludeDirs)

if (Test-Path -LiteralPath $Dst) { Remove-Item -LiteralPath $Dst -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$Dst\lib\libc\include" | Out-Null

Copy-Item "$Src\zig.exe" "$Dst\zig.exe"

# Always required: std (compiler_rt is Zig and imports it), clang builtin
# headers, the compiler support trees, and the top-level lib/*.zig shims.
foreach ($d in @("std", "include", "compiler", "compiler_rt", "libunwind", "init")) {
    if (Test-Path -LiteralPath "$Src\lib\$d") {
        robocopy "$Src\lib\$d" "$Dst\lib\$d" /E /NFL /NDL /NJH /NJS /NP | Out-Null
    }
}
Get-ChildItem "$Src\lib" -File | ForEach-Object { Copy-Item $_.FullName "$Dst\lib\" }
if (Test-Path -LiteralPath "$Src\lib\c") { robocopy "$Src\lib\c" "$Dst\lib\c" /E /NFL /NDL /NJH /NJS /NP | Out-Null }

foreach ($d in $LibcDirs) {
    if (Test-Path -LiteralPath "$Src\lib\libc\$d") {
        robocopy "$Src\lib\libc\$d" "$Dst\lib\libc\$d" /E /NFL /NDL /NJH /NJS /NP | Out-Null
    }
}
Get-ChildItem "$Src\lib\libc" -File -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName "$Dst\lib\libc\" }

foreach ($d in $IncludeDirs) {
    if (Test-Path -LiteralPath "$Src\lib\libc\include\$d") {
        robocopy "$Src\lib\libc\include\$d" "$Dst\lib\libc\include\$d" /E /NFL /NDL /NJH /NJS /NP | Out-Null
    }
}

"{0,-14} {1,7:N1} MB" -f (Split-Path $Dst -Leaf), ((Get-ChildItem $Dst -Recurse -File | Measure-Object -Property Length -Sum).Sum/1MB)
