param([string]$Root, [string]$Label, [int]$Max = 100000)

$exe = "C:\Users\ASUSV3~1\AppData\Local\Temp\claude\D--GitHub-ringpp\fdeaf626-4510-40de-af51-7afcbbf0bc5c\scratchpad\tsprobe\tsprobe.exe"
$files = Get-ChildItem $Root -Recurse -File -Filter *.ring -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -notmatch '\\vendor\\|-copy|- Copie' } |
         Select-Object -First $Max

$ok = 0; $bad = 0; $bytes = 0; $badlist = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($f in $files) {
    $null = & $exe $f.FullName --quiet 2>&1
    if ($LASTEXITCODE -eq 0) { $ok++ } else { $bad++; $badlist += $f.FullName }
    $bytes += $f.Length
}
$sw.Stop()
"{0,-22} {1,5} files  {2,8:N1} KB  clean {3,5}  errors {4,4}  ({5:P1} clean)  {6:N1} s wall" -f `
   $Label, $files.Count, ($bytes/1KB), $ok, $bad, ($(if($files.Count){$ok/$files.Count}else{0})), $sw.Elapsed.TotalSeconds
if ($bad -gt 0) {
    "  files with parse errors (first 12):"
    $badlist | Select-Object -First 12 | ForEach-Object { "    " + $_.Replace($Root, "") }
}
