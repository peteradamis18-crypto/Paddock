# The lead's one-liner (W1-8): stage the Stream Deck add-on, then irdash installs it (copies it into Stream Deck's Plugins folder,
# restarts Stream Deck on MAIN, waits for the add-on to connect). Nobody clicks Install. This script never touches %APPDATA%:
# the lead's Claude session is inside a packaged app whose AppData writes go to a private copy (CLAUDE.md rule 3); irdash is not.
#   bump $ver in deck-intro\install.ps1, then:   powershell -ExecutionPolicy Bypass -File tools\addon-update.ps1
# -Port is for the test's pretend irdash only.
param([int]$Port = 8199)
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\guard.ps1')
$busy = Get-RigBusy
if ($busy) { "Not now: $busy - the add-on install restarts Stream Deck. Run this when the rig is free."; exit 1 }
$cli = Join-Path $root 'irdeck-cli.exe'
if ((Test-Path $cli) -and ((& $cli state) -match 'telemetry=on|onTrack=True')) { 'iRacing is in a session - run this when you are out of the car.'; exit 1 }

& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'deck-intro\install.ps1') -Stage
if ($LASTEXITCODE -ne 0) { 'Staging the add-on failed.'; exit 1 }

# the header irdash wants on anything that changes something (rigstate.cs Gate); a long wait: Stream Deck restarts
$say = ''
try {
  $req = [Net.HttpWebRequest]::Create("http://localhost:$Port/api/do?c=addoninstall")
  $req.Headers.Add('X-Paddock', '1'); $req.Timeout = 90000
  try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response }
  if ($resp -eq $null) { throw 'irdash did not answer' }
  $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8); $body = $sr.ReadToEnd(); $sr.Dispose(); $resp.Close()
  $m = [regex]::Match($body, '"say"\s*:\s*"((?:[^"\\]|\\.)*)"')
  $say = if ($m.Success) { $m.Groups[1].Value } else { $body }
} catch { $say = "irdash did not answer: $($_.Exception.Message)" }
$say
if ($say -match 'installed and running') { exit 0 }
exit 1
