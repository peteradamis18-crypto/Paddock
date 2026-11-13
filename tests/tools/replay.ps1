# replay.ps1 - play an .ibt telemetry file into irdash as a pretend session (W0-8). TEST HOOK ONLY.
#   tests\tools\replay.ps1 -File <ibt> -Speed 20 [-From 0 -To 600] [-Base http://localhost:8199] [-Wait] [-Stop]
# Needs dash\test-hook.on next to irdash.exe (404 without it) and no real session (409 while one is on).
# The lead runs this against the live irdash only when the rig is free. -Stop ends the pretend session.
param([string]$File = '', [double]$Speed = 20, [double]$From = 0, [double]$To = 0, [string]$Base = 'http://localhost:8199',
      [switch]$Wait, [switch]$Stop, [switch]$Status)
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'guard.ps1')
Assert-RigFree
function Get-Url($u) {
  try { $r = [Net.HttpWebRequest]::Create($u); $r.Timeout = 8000; $resp = $r.GetResponse(); $s = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd(); $resp.Close(); return $s }
  catch [Net.WebException] { $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }; throw "irdash answered $code for $u" }
}
if ($Stop) { Get-Url "$Base/api/test/end" | Out-Null; 'replay stopped'; return }
if ($Status) { Get-Url "$Base/api/test/ibt?status=1"; return }
if (-not $File) { throw 'give -File <the .ibt>' }
$q = "file=$([Uri]::EscapeDataString((Resolve-Path $File).Path))&speed=$Speed&from=$From&to=$To"
Get-Url "$Base/api/test/ibt?$q" | Out-Null
Start-Sleep -Milliseconds 700
$st = Get-Url "$Base/api/test/ibt?status=1"
"started: $st"
if ($Wait) {
  do { Start-Sleep -Seconds 2; $st = Get-Url "$Base/api/test/ibt?status=1"; $o = $st | ConvertFrom-Json; "pos $($o.pos) s  lap $($o.lap)  sent $($o.sent)" } while ($o.running)
  'replay finished (the last frame stays up; run with -Stop to end it)'
}
