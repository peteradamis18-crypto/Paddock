# photo-order-test.ps1 - offline: the side-screen gallery order (dash\src\galorder.cs, W0-10).
# Sets of pictures made in a random creation order in a temp folder: the order must be newest set first, by name
# inside a set, identical on two calls, and each set must be one unbroken run (so a pair never straddles two sets).
#   powershell -ExecutionPolicy Bypass -File tests\photo-order-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP ("photo-order-" + $PID); New-Item -ItemType Directory -Force $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Check($what, $cond) { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what" } }
'photo order test'
& $csc /nologo /target:exe "/out:$tmp\dump.exe" /r:System.dll /r:System.Core.dll (Join-Path $root 'dash\src\galorder.cs') (Join-Path $PSScriptRoot 'photo-order-dump.cs')
Check 'galorder.cs compiles on its own' ($LASTEXITCODE -eq 0)
$pics = Join-Path $tmp 'pics'; New-Item -ItemType Directory -Force "$pics\mine" | Out-Null
# set 0 (no prefix), set 2 (r2-), set 3 (r3-) and Peter's own folder; created in a shuffled order with random dates
$names = @('07-a.jpg', '09-b.jpg', 'r2-001-a.jpg', 'r2-002-b.jpg', 'r2-010-c.jpg', 'r3-001-a.jpg', 'r3-002-b.jpg', 'mine\own1.jpg', 'mine\own2.jpg')
foreach ($n in ($names | Get-Random -Count $names.Count)) {
  $f = Join-Path $pics $n; Set-Content $f 'x'; (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-(Get-Random -Maximum 5000))
}
Set-Content (Join-Path $pics 'credits.json') '[]'
$a = @(& "$tmp\dump.exe" $pics); $b = @(& "$tmp\dump.exe" $pics)
$want = 'own1.jpg,own2.jpg,r3-001-a.jpg,r3-002-b.jpg,r2-001-a.jpg,r2-002-b.jpg,r2-010-c.jpg,07-a.jpg,09-b.jpg'
Check 'newest set first, then by name inside each set' (($a -join ',') -eq $want)
Check 'the same order on a second call' (($a -join ',') -eq ($b -join ','))
$sets = @()
foreach ($n in $a) { if ($n -match '^r(\d+)-') { $sets += [int]$matches[1] } elseif ($n -like 'own*') { $sets += 100000 } else { $sets += 0 } }
$runs = 1; for ($k = 1; $k -lt $sets.Count; $k++) { if ($sets[$k] -ne $sets[$k - 1]) { $runs++ } }
Check 'each set is one unbroken run (pairs stay inside their set)' ($runs -eq 4)
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"photo order: $script:pass ok, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
