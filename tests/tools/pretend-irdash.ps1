# pretend-irdash.ps1 - build, start, stop and record the pretend irdash (tests\tools\pretend-irdash.cs, W0-8).
#   pretend-irdash.ps1                      start on 8299 (answers the recorded routes from tests\fixtures\irdash)
#   pretend-irdash.ps1 -Ibt <file> -Speed 20   also serves /stream from that .ibt at 20x
#   pretend-irdash.ps1 -Www dash\www        also serves the pages, so a browser can open http://localhost:8299/v2/home.html
#   pretend-irdash.ps1 -Stop                stop the one on -Port
#   pretend-irdash.ps1 -Record              copy the live irdash's GET answers into the fixtures (read-only; only with sim=False)
# Never uses port 8199 as the pretend port.
param([int]$Port = 8299, [string]$Ibt = '', [double]$Speed = 20, [string]$Www = '', [switch]$Loop, [switch]$Stop, [switch]$Record,
      [string]$Base = 'http://localhost:8199', [string]$Cli = '')
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot; $root = Split-Path -Parent (Split-Path -Parent $here)
$fix = Join-Path $root 'tests\fixtures\irdash'
$bin = Join-Path $here 'bin'; $exe = Join-Path $bin 'pretend-irdash.exe'; $src = Join-Path $here 'pretend-irdash.cs'
if ($Port -eq 8199) { throw 'port 8199 is the real irdash' }

function Build-Pretend {
  New-Item -ItemType Directory -Force $bin | Out-Null
  if ((Test-Path $exe) -and (Get-Item $exe).LastWriteTime -gt (Get-Item $src).LastWriteTime) { return }
  $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  & $csc -nologo -optimize+ -target:exe "-out:$exe" -r:System.dll -r:System.Core.dll $src
  if ($LASTEXITCODE -ne 0) { throw 'pretend-irdash.cs does not compile' }
}

# (big answers - /vault/list, /vault/recorder, /official - are left out on purpose: the fixtures stay small)
# the GET routes the add-on and the pages read (state routes only; ones that need an id are skipped)
$routes = @('/showcase', '/showcase?who=page', '/overlays', '/guest', '/mydrive', '/mydrive/lists', '/replay', '/api/rec/races', '/workbench/state',
  '/sound?peek=1', '/sound', '/ac', '/ac?live=1', '/home', '/career', '/keymsg', '/nav', '/version', '/health', '/debrief/state', '/debrief/nav',
  '/vault', '/vault/item', '/vault/nav', '/perf/live', '/perf/checklist', '/sessions', '/doctor',
  '/tv', '/tv/data', '/systems', '/realworld', '/brief', '/ailevel', '/watch/coverage', '/race')

if ($Stop) {
  $pf = Join-Path $bin "pretend-irdash.$Port.pid"
  if (Test-Path $pf) { Stop-Process -Id ([int](Get-Content $pf)) -Force -ErrorAction SilentlyContinue; Remove-Item $pf }
  'stopped'; return
}

if ($Record) {
  if (-not $Cli) { $Cli = Join-Path $env:TEMP 'ird\irdeck-cli.exe' }
  if (-not (Test-Path $Cli)) { powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-irdeck.ps1') -NoDeploy | Out-Null }
  $state = (& $Cli state) -join ' '
  if ($state -notmatch 'sim=False') { throw "the sim is running or state is unclear ($state): not recording" }
  New-Item -ItemType Directory -Force $fix | Out-Null
  $n = 0
  foreach ($r in $routes) {
    # read-only GET, one at a time, short timeout
    try {
      $req = [Net.HttpWebRequest]::Create($Base + $r); $req.Timeout = 8000; $req.Method = 'GET'
      $resp = $req.GetResponse(); $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8); $body = $sr.ReadToEnd(); $sr.Dispose(); $resp.Close()
    } catch { "skip $r : $($_.Exception.Message)"; continue }
    $path, $q = $r -split '\?', 2
    $key = $path.Trim('/').Replace('/', '_'); if ($key -eq '') { $key = '_root' }
    if ($q) { $key += '~' + $q }
    $isJson = $true; try { $null = $body | ConvertFrom-Json } catch { $isJson = $false }
    $ext = if ($isJson -and $body.Trim().Length -gt 0) { 'json' } else { 'txt' }
    [IO.File]::WriteAllText((Join-Path $fix "$key.$ext"), $body, (New-Object Text.UTF8Encoding($false)))
    "recorded $r -> $key.$ext ($($body.Length) bytes)"; $n++
  }
  "recorded $n routes"; return
}

Build-Pretend
$pf = Join-Path $bin "pretend-irdash.$Port.pid"
if (Test-Path $pf) { Stop-Process -Id ([int](Get-Content $pf)) -Force -ErrorAction SilentlyContinue }
$a = @("$Port", '--fixtures', "`"$fix`"")
if ($Ibt) { $a += @('--ibt', "`"$Ibt`"", '--speed', "$Speed") }
if ($Www) { $a += @('--www', "`"$((Resolve-Path $Www).Path)`"") }
if ($Loop) { $a += '--loop' }
$p = Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden -PassThru
$p.Id | Set-Content $pf
for ($i = 0; $i -lt 40; $i++) {
  try { $null = (New-Object Net.WebClient).DownloadString("http://localhost:$Port/__stats"); "pretend irdash up on http://localhost:$Port/ (pid $($p.Id))"; return } catch { Start-Sleep -Milliseconds 150 }
}
throw 'pretend irdash did not start'

