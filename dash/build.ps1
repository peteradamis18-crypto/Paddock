# Builds irdash.exe (and the tiny probe.exe Rig Doctor uses) with the C# compiler that ships with Windows
# (no SDK install needed). Compiles first; only a good build stops a running irdash and puts the new exe in place.
#   build.ps1              build, replace, restart irdash if it was running (never while a sim session is running)
#   build.ps1 -NoDeploy    only compile (to %TEMP%\irdash-build), changes nothing else
# New .cs file for irdash? Add it to $src below. probe.cs is a separate program (its own Main).
param([switch]$NoDeploy)
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
# one build folder per run: several agents may compile at the same time
$tmp = Join-Path $env:TEMP "irdash-build-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$src = @("$d\src\irdash.cs", "$d\src\deltabar.cs", "$d\src\overlays.cs", "$d\src\doctor.cs", "$d\src\data.cs", "$d\src\mydrive.cs",
         "$d\src\replay.cs", "$d\src\gallery.cs", "$d\src\perf.cs", "$d\src\refs.cs", "$d\src\bench.cs", "$d\src\corners.cs", "$d\src\gpsmap.cs", "$d\src\vault.cs", "$d\src\wheel.cs", "$d\src\officialcore.cs", "$d\src\official.cs", "$d\src\realworld.cs", "$d\src\coverage.cs", "$d\src\analysis.cs", "$d\src\coach.cs", "$d\src\workbench.cs", "$d\src\sessionreview.cs", "$d\src\deepdive.cs", "$d\src\sound.cs", "$d\src\deckfeed.cs", "$d\src\recorder.cs", "$d\src\sessmatch.cs", "$d\src\field.cs", "$d\src\debrief.cs", "$d\src\career.cs", "$d\src\gain.cs", "$d\src\rigwin.cs", "$d\src\protools.cs", "$d\src\phone.cs", "$d\src\home.cs", "$d\src\share.cs", "$d\src\replayjump.cs", "$d\src\cars.cs", "$d\src\tv.cs", (Join-Path $d "..\src\deckstate.cs"))
& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$tmp\irdash.exe" `
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll `
  @src
if ($LASTEXITCODE -ne 0) { Write-Host 'build failed (irdash.exe)'; exit 1 }
& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$tmp\probe.exe" "$d\src\probe.cs"
if ($LASTEXITCODE -ne 0) { Write-Host 'build failed (probe.exe)'; exit 1 }
if ($NoDeploy) { Write-Host "built in $tmp (not deployed)"; exit 0 }
# 2026-10-11: an irdash restarted from inside a Codex job could not capture the screen (0 frames) - Codex jobs compile only; the lead deploys
if ($env:PADDOCK_NO_DEPLOY -eq '1') {
  # ask the deploy broker (tools\deploy-broker.ps1, normal context) and wait for its answer
  $req = Join-Path $d 'deploy.request'; $res = Join-Path $d 'deploy.result'
  Remove-Item $res -Force -ErrorAction SilentlyContinue; Set-Content $req "codex job $(Get-Date -Format s)"
  for ($i = 0; $i -lt 120 -and -not (Test-Path $res); $i++) { Start-Sleep 2 }
  if (Test-Path $res) { $r = Get-Content $res -Raw; Write-Host "deploy broker: $r"; if ($r -match '^exit 0') { exit 0 } else { exit 2 } }
  Write-Host "built in $tmp - no deploy broker answered (the lead deploys)"; exit 2
}
# never restart irdash while Peter races or is about to (tests\guard.ps1 has the same rules), nor while a test holds the lock
. (Join-Path (Split-Path -Parent $d) 'tests\guard.ps1')
$busy = Get-RigBusy
if ($busy) { Write-Host "not deployed: $busy - built in $tmp; run build.ps1 again later."; exit 2 }
$lock = Join-Path $d 'deploy.lock'
if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15) { Write-Host "not deployed: a test holds the deploy lock ($(Get-Content $lock)) - run build.ps1 again later."; exit 2 }
# one deploy at a time: two agents deploying together once left the exe locked and the copy failed without a word
$mx = New-Object Threading.Mutex($false, 'Local\paddock-irdash-deploy')
if (-not $mx.WaitOne(120000)) { Write-Host 'not deployed: another deploy is in progress - run build.ps1 again.'; exit 2 }
try {
  $busy = Get-RigBusy; if ($busy) { Write-Host "not deployed: $busy - built in $tmp; run build.ps1 again later."; exit 2 }   # re-check after waiting
  $wasRunning = [bool](Get-Process irdash -ErrorAction SilentlyContinue)
  Get-Process irdash -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 300
  try {
    Copy-Item "$tmp\irdash.exe" "$d\irdash.exe" -Force -ErrorAction Stop
    Copy-Item "$tmp\probe.exe" "$d\probe.exe" -Force -ErrorAction Stop
  } catch {
    Write-Host "deploy FAILED: $($_.Exception.Message)"
    if ($wasRunning) { Start-Process explorer.exe -ArgumentList "`"$d\irdash.exe`"" }   # bring the old one back
    exit 1
  }
  Write-Host "built $d\irdash.exe and probe.exe"
  # start through Explorer so irdash is not tied to whatever window or tool ran this script
  if ($wasRunning) { Start-Process explorer.exe -ArgumentList "`"$d\irdash.exe`"" }
} finally { $mx.ReleaseMutex() }
